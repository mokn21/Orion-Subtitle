import GameController
import SwiftUI
#if canImport(Translation)
import Translation
#endif

struct StreamView: View {
	let console: Console
	let startInBlackMode: Bool

	@Environment(SettingsStore.self) private var settingsStore
	@Environment(\.dismiss) private var dismiss
	@Environment(\.scenePhase) private var scenePhase
		@State private var session: StreamSession?
		@State private var translationBridge: AnyObject?
		@State private var lifecycleGate = RemotePlayLifecycleGate()
		@State private var pendingDisappearStop: Task<Void, Never>?
		@State private var isViewVisible = false
	@State private var showMenu = false
	@State private var showMenuButton = false
	@State private var hideMenuButton: Task<Void, Never>?
	@State private var folded = false
	/// The user says this screen is fine, whatever the fold check thinks
	@State private var playHereAnyway = false
	/// Unfolded but the window is portrait: we wait (or pause) and ask the user
	/// to turn the phone. Once a stream is landscape, AppDelegate locks it there.
	@State private var portrait = false
	@State private var windowSize: CGSize = .zero
	/// No controller connected yet; we ask before connecting (there are no on-screen controls)
	@State private var needsController = !Self.hasController
	@State private var showSettingsHint = false
	@State private var showPSButton = false
	@State private var showTranslationDiagnostics = false
	@State private var showRegionEditor = false
	@State private var showQuickBar = false
	@State private var quickBarHideTask: Task<Void, Never>?
	@State private var hidePSButton: Task<Void, Never>?
	@State private var pin = ""
	@State private var phone = PhoneStatus()
	@State private var showHeatWarning = false
	@State private var blackTranslationMode: Bool

	init(console: Console, startInBlackMode: Bool = false) {
		self.console = console
		self.startInBlackMode = startInBlackMode
		_blackTranslationMode = State(initialValue: startInBlackMode)
	}
	/// The corner hints show once per stream screen, not again after a reconnect
	@State private var hintShown = false

	private static var hasController: Bool {
		GCController.controllers().contains { $0.extendedGamepad != nil }
	}

	var body: some View {
		GeometryReader { geo in
			content
				.onAppear { updateFolded(geo.size) }
				.onChange(of: geo.size) { _, size in updateFolded(size) }
		}
		// The text input keyboard must not shrink our size: that reads as folded/portrait,
		// which hides the text box, which closes the keyboard, and round it goes
		.ignoresSafeArea(.keyboard)
		.statusBarHidden()
		.persistentSystemOverlays(.hidden)
		.defersSystemGestures(on: .all)
		// The session itself starts from updateFolded, once we know we're on a usable screen
		.onAppear {
			isViewVisible = true
			pendingDisappearStop?.cancel()
			pendingDisappearStop = nil
			AppDelegate.setStreaming(true)
		}
		.onDisappear {
			quickBarHideTask?.cancel()
			isViewVisible = false
			pendingDisappearStop?.cancel()
			pendingDisappearStop = Task { @MainActor in
				try? await Task.sleep(for: .milliseconds(750))
				guard !Task.isCancelled, !isViewVisible else { return }
				stop()
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
			// A flip between the two landscapes keeps the same window size, so pick
			// up iOS's new orientation (for controller motion) once it has rotated
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { update() }
		}
		.onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in
			guard needsController, Self.hasController else { return }
			needsController = false
			update()
		}
		.onChange(of: session?.state == .streaming) { _, streaming in
			guard streaming, !hintShown else { return }
			hintShown = true
			flashSettingsHint()
		}
			.onChange(of: phone.isHot) { _, hot in
				if hot, settingsStore.settings.fps > 30 { flashHeatWarning() }
			}
			.onChange(of: blackTranslationMode) { _, enabled in
				session?.setTranslationBlackMode(enabled)
			}
			.onChange(of: scenePhase) { _, phase in
			session?.setPaused(phase != .active || folded || portrait)
		}
					.sheet(isPresented: $showTranslationDiagnostics) {
					if let session {
							TranslationDiagnosticsView(coordinator: session.translationCoordinator, bridge: translationBridge)
					}
				}
				.sheet(isPresented: $showRegionEditor) {
					if let session {
						CaptureRegionEditorView(
							pixelBuffer: session.latestFrame,
							region: Binding(
								get: { settingsStore.settings.translationRegion },
								set: {
									settingsStore.settings.translationRegion = $0
									session.apply(settingsStore.settings)
								}
							)
						)
					}
				}
		.modifier(AppleTranslationTaskModifier(bridge: translationBridge))
		}

	private var content: some View {
		ZStack {
			Color.black.ignoresSafeArea()

				if blackTranslationMode, let session {
					blackTranslationScreen(for: session)
				} else if let session, let renderer = session.renderer {
				MetalStreamView(
					renderer: renderer,
					highRefresh: session.settings.highRefreshDisplay,
						onTouch: { _ in },
							onTap: { _ in revealQuickBar() },
							onCornerTap: { revealQuickBar() },
							onLeftCornerTap: { revealQuickBar() }
				)
				.ignoresSafeArea()
			}

					if let session {
						overlay(for: session)
						if !blackTranslationMode {
							translationOverlay(for: session)
						}
					}

				if blackTranslationMode, let session {
					blackModeToolbar(for: session)
				}

			if showSettingsHint && !showMenuButton {
				settingsHint
					.transition(.opacity)
			}

			if showMenuButton {
				menuButton
					.transition(.opacity)
			}

			if showPSButton {
				psButton
					.transition(.opacity)
			}

				if showHeatWarning {
					heatWarning
						.transition(.opacity)
				}

				if showQuickBar, let session {
					quickToolbar(for: session)
						.transition(.move(edge: .top).combined(with: .opacity))
				}

				if let session, let text = session.keyboardText, !folded, !portrait {
				KeyboardOverlay(
					initialText: text,
					onChange: { session.keyboardChanged($0) },
					onSubmit: { session.keyboardSubmit($0) },
					onCancel: { session.keyboardCancel() }
				)
			}

			if needsController && session == nil {
				controllerOverlay
			} else if folded {
				pausedOverlay
			} else if portrait {
				rotateOverlay
			}
		}
	}

	/// Used to map controller motion to the screen
	private var interfaceOrientation: UIInterfaceOrientation? {
		(UIApplication.shared.connectedScenes.first as? UIWindowScene)?.interfaceOrientation
	}

	// MARK: - Lifecycle

	private func startSession() {
		guard let attemptID = lifecycleGate.begin() else {
			log.notice("Ignored duplicate StreamView start request for \(console.name, privacy: .public)")
			return
		}
		log.notice("Starting Remote Play attempt \(attemptID.uuidString, privacy: .public) for \(console.name, privacy: .public)")
				let session = StreamSession(console: console, settings: settingsStore.settings)
		if let orientation = interfaceOrientation {
			session.input.interfaceOrientation = orientation
		}
		session.input.onMenuCombo = { showMenu = true }
				self.translationBridge = session.translationCoordinator.appleTranslationBridge
				self.session = session
			session.start()
			session.setTranslationBlackMode(startInBlackMode)
			session.translationCoordinator.start()
		lifecycleGate.markActive(attemptID)
		}

		private func stop() {
			guard let stopID = lifecycleGate.beginStop() else {
				log.notice("Ignored duplicate Remote Play stop request for \(console.name, privacy: .public)")
				return
			}
			log.notice("Stopping Remote Play lifecycle \(stopID.uuidString, privacy: .public) for \(console.name, privacy: .public)")
				 session?.translationCoordinator.stop()
				 session?.stop()
			session = nil
			translationBridge = nil
		AppDelegate.setStreaming(false)
		lifecycleGate.finishStop(stopID)
		}

	/// On a foldable, streaming only happens on the inner screen: we wait for the
	/// unfold before connecting, and pause if it's folded mid-session.
	/// Normal iPhones are never "folded".
	private func updateFolded(_ size: CGSize) {
		guard size.width > 0, size.height > 0 else { return }
		AppDelegate.windowSizeChanged(size)
		windowSize = size
		update()
	}

	private func update() {
		let size = windowSize
		guard size.width > 0, size.height > 0 else { return }
		let isFolded = DeviceLayout.isFolded(size) && !playHereAnyway
		folded = isFolded
		portrait = !isFolded && size.height > size.width
		let canPlay = !isFolded && !portrait
		guard session != nil else {
			if canPlay && !needsController { startSession() }
			return
		}
		session?.setPaused(!canPlay || scenePhase != .active)
		if let orientation = interfaceOrientation {
			session?.input.interfaceOrientation = orientation
		}
	}

	// MARK: - Menu button (top-right hot corner)

	private func revealMenuButton() {
		withAnimation(.easeOut(duration: 0.2)) { showMenuButton = true }
		hideMenuButton?.cancel()
		hideMenuButton = Task { @MainActor in
			try? await Task.sleep(for: .seconds(3))
			guard !Task.isCancelled else { return }
			withAnimation(.easeIn(duration: 0.6)) { showMenuButton = false }
		}
	}

	// MARK: - PS button (top-left hot corner)

	private func revealPSButton() {
		withAnimation(.easeOut(duration: 0.2)) { showPSButton = true }
		schedulePSButtonHide()
	}

	private func schedulePSButtonHide() {
		hidePSButton?.cancel()
		hidePSButton = Task { @MainActor in
			try? await Task.sleep(for: .seconds(3))
			guard !Task.isCancelled else { return }
			withAnimation(.easeIn(duration: 0.6)) { showPSButton = false }
		}
	}

	private var psButton: some View {
		Button {
			session?.pressPSButton()
			// Stay visible a little longer in case they want to press it again
			schedulePSButtonHide()
		} label: {
			Image(systemName: "playstation.logo")
				.font(.title2)
				.foregroundStyle(.white)
				.frame(width: 52, height: 52)
				.background(.black.opacity(0.55), in: Circle())
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.padding(.top, 14)
		.padding(.leading, 20)
		.ignoresSafeArea()
	}

	/// Each time a stream starts, point at the hidden corners, then fade out
	private func flashSettingsHint() {
		withAnimation(.easeOut(duration: 0.3)) { showSettingsHint = true }
		Task { @MainActor in
			try? await Task.sleep(for: .seconds(4))
			withAnimation(.easeIn(duration: 0.8)) { showSettingsHint = false }
		}
	}

	private var settingsHint: some View {
		HStack(alignment: .top) {
			if !showPSButton {
				HStack(spacing: 10) {
					hintIcon("playstation.logo")
					Image(systemName: "arrow.left")
						.font(.title3.weight(.bold))
					hintLabel("Tap this corner for the PS button")
				}
			}
			Spacer(minLength: 16)
			HStack(spacing: 10) {
				hintLabel("Tap this corner for settings")
				Image(systemName: "arrow.right")
					.font(.title3.weight(.bold))
				hintIcon("gearshape.fill")
			}
		}
		.foregroundStyle(.white)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
		.padding(.top, 14)
		.padding(.horizontal, 20)
		.ignoresSafeArea()
		.allowsHitTesting(false)
	}

	// MARK: - Heat warning

	private func flashHeatWarning() {
		withAnimation(.easeOut(duration: 0.3)) { showHeatWarning = true }
		Task { @MainActor in
			try? await Task.sleep(for: .seconds(8))
			withAnimation(.easeIn(duration: 0.8)) { showHeatWarning = false }
		}
	}

	private var heatWarning: some View {
		HStack(spacing: 8) {
			Image(systemName: "thermometer.high")
				Text("ترتفع حرارة الجهاز. سيساعد اختيار 30 إطارًا/ثانية من الإعدادات على تبريده.")
		}
		.font(.subheadline.weight(.semibold))
		.foregroundStyle(.white)
		.padding(.horizontal, 14)
		.padding(.vertical, 8)
		.background(.black.opacity(0.7), in: Capsule())
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
		.padding(.bottom, 16)
		.allowsHitTesting(false)
	}

	private func hintLabel(_ text: String) -> some View {
		Text(text)
			.font(.subheadline.weight(.semibold))
			.padding(.horizontal, 14)
			.padding(.vertical, 8)
			.background(.black.opacity(0.65), in: Capsule())
	}

	private func hintIcon(_ systemName: String) -> some View {
		Image(systemName: systemName)
			.font(.title2)
			.frame(width: 52, height: 52)
			.background(.black.opacity(0.55), in: Circle())
	}

	private func revealQuickBar() {
		withAnimation(.easeOut(duration: 0.2)) { showQuickBar = true }
		quickBarHideTask?.cancel()
		quickBarHideTask = Task { @MainActor in
			try? await Task.sleep(for: .seconds(8))
			guard !Task.isCancelled else { return }
			withAnimation(.easeIn(duration: 0.25)) { showQuickBar = false }
		}
	}

	private func quickToolbar(for session: StreamSession) -> some View {
		HStack(spacing: 8) {
			quickTool("عرض", icon: blackTranslationMode ? "rectangle.fill" : "play.tv") {
				blackTranslationMode.toggle()
				session.setTranslationBlackMode(blackTranslationMode)
			}
			quickTool("كتم", icon: blackTranslationMode ? "speaker.slash.fill" : "speaker.wave.2.fill") {
				blackTranslationMode.toggle()
				session.setTranslationBlackMode(blackTranslationMode)
			}
			quickTool("OCR", icon: session.translationCoordinator.state == .running ? "text.viewfinder" : "text.viewfinder.slash") {
				if session.translationCoordinator.state == .running {
					session.translationCoordinator.pause()
				} else {
					session.translationCoordinator.start()
				}
			}
			quickTool("منطقة", icon: "crop") {
				showRegionEditor = true
			}
				quickTool("اختبار", icon: "checkmark.seal") {
					showTranslationDiagnostics = true
				}
				quickTool("إيقاف العرض", icon: "stop.fill") {
					stop()
					dismiss()
				}
				quickTool("مظهر", icon: "circle.lefthalf.filled") {
				let themes = TranslationTheme.allCases
				if let index = themes.firstIndex(of: settingsStore.settings.translationTheme) {
					settingsStore.settings.translationTheme = themes[(index + 1) % themes.count]
				}
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 9)
		.background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 16))
		.foregroundStyle(.white)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
		.padding(.top, 12)
		.padding(.horizontal, 12)
		.ignoresSafeArea()
	}

	private func quickTool(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			VStack(spacing: 3) {
				Image(systemName: icon).font(.headline)
				Text(title).font(.caption2)
			}
			.frame(minWidth: 52, minHeight: 42)
		}
		.buttonStyle(.plain)
	}

	private var menuButton: some View {
		Button {
			hideMenuButton?.cancel()
			showMenuButton = false
			revealQuickBar()
		} label: {
			Image(systemName: "gearshape.fill")
				.font(.title2)
				.foregroundStyle(.white)
				.frame(width: 52, height: 52)
				.background(.black.opacity(0.55), in: Circle())
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
		.padding(.top, 14)
			.padding(.trailing, 20)
			.ignoresSafeArea()
		}

		@ViewBuilder
		private func translationOverlay(for session: StreamSession) -> some View {
				if session.translationCoordinator.state == .running || session.translationCoordinator.state == .paused {
					GeometryReader { geo in
						ForEach(session.translationCoordinator.visibleEntries) { entry in
							let frame = spatialFrame(for: entry.boundingBox, in: geo.size)
							VStack(spacing: 4) {
								Text(entry.translatedText)
									.font(.system(size: session.settings.translationFontSize, weight: .semibold))
									.multilineTextAlignment(.center)
									.environment(\.layoutDirection, .rightToLeft)
								Text(entry.sourceText)
									.font(.system(size: max(12, session.settings.translationFontSize * 0.45)))
									.foregroundStyle(.white.opacity(0.7))
							}
							.foregroundStyle(translationColor(session.settings.translationTextColor))
							.padding(.horizontal, 18)
							.padding(.vertical, 10)
							.background(translationColor(session.settings.translationBackgroundColor).opacity(session.settings.translationBackgroundOpacity), in: RoundedRectangle(cornerRadius: 14))
							.frame(width: max(90, min(frame.width, geo.size.width - 24)))
							.position(x: frame.midX, y: frame.midY)
					}
					}
				.allowsHitTesting(false)
				}
			}

			/// Converts Vision's bottom-left normalized coordinates into the displayed
			/// 16:9 video rectangle, including iPad letterboxing.
			private func spatialFrame(for visionRect: CGRect, in size: CGSize) -> CGRect {
				let rect = VideoCoordinateMapper.displayRect(for: visionRect, in: size)
				return CGRect(x: rect.minX, y: rect.minY, width: max(90, rect.width), height: max(52, rect.height))
			}

			private func blackTranslationScreen(for session: StreamSession) -> some View {
			VStack(spacing: 18) {
					if let entry = session.translationCoordinator.latestEntry {
						Text(entry.translatedText)
							.font(.system(size: session.settings.translationFontSize + 10, weight: .bold))
							.multilineTextAlignment(.center)
							.environment(\.layoutDirection, .rightToLeft)
							.foregroundStyle(translationColor(session.settings.translationTextColor))
							ForEach(Array(session.translationCoordinator.recentEntries.dropFirst()), id: \.id) { previous in
							Text(previous.translatedText)
								.font(.system(size: max(14, session.settings.translationFontSize * 0.68), weight: .medium))
								.foregroundStyle(translationColor(session.settings.translationTextColor).opacity(0.68))
								.multilineTextAlignment(.center)
							}
						} else {
						ProgressView()
						Text(session.translationCoordinator.lastError ?? session.translationCoordinator.translationStatusMessage)
							.foregroundStyle(.secondary)
							.multilineTextAlignment(.center)
					}
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.padding(40)
				.background(Color.black.ignoresSafeArea())
				.environment(\.layoutDirection, .rightToLeft)
			}

				private func blackModeToolbar(for session: StreamSession) -> some View {
					HStack(spacing: 8) {
						quickTool("العرض", icon: "play.tv") {
							blackTranslationMode = false
							session.setTranslationBlackMode(false)
						}
						quickTool(session.translationCoordinator.state == .running ? "إيقاف OCR" : "تشغيل OCR",
							icon: session.translationCoordinator.state == .running ? "text.viewfinder" : "text.viewfinder.slash") {
							if session.translationCoordinator.state == .running {
								session.translationCoordinator.pause()
							} else {
								session.translationCoordinator.start()
							}
						}
					quickTool("المنطقة", icon: "crop") { showRegionEditor = true }
					quickTool("اختبار", icon: "checkmark.seal") { showTranslationDiagnostics = true }
					quickTool("إيقاف العرض", icon: "stop.fill") {
						stop()
						dismiss()
					}
				}
					.padding(.horizontal, 12)
					.padding(.vertical, 9)
					.background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 16))
					.foregroundStyle(.white)
					.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
					.padding(.top, 12)
					.padding(.horizontal, 12)
					.ignoresSafeArea()
				}

			private func translationColor(_ choice: TranslationColorChoice) -> Color {
				switch choice {
				case .black: .black
				case .white: .white
				case .yellow: .yellow
				case .cyan: .cyan
				case .green: .green
				}
			}

		// MARK: - Overlays

	@ViewBuilder
	private func overlay(for session: StreamSession) -> some View {
		switch session.state {
			case .idle, .connecting:
				VStack(spacing: 12) {
					ProgressView().controlSize(.large)
					Text("جارٍ الاتصال بـ \(console.name)…").foregroundStyle(.secondary)
					Button("إلغاء") {
						stop()
						dismiss()
					}.buttonStyle(.bordered)
					Button("فتح التشخيص") { showTranslationDiagnostics = true }
						.buttonStyle(.bordered)
				}
		case .streaming:
			if session.settings.showStats {
				StatsOverlay(stats: session.stats, settings: session.settings)
					.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
					.padding(12)
					.allowsHitTesting(false)
			}
		case .needsPIN(let incorrect):
			VStack(spacing: 12) {
					Text(incorrect ? "رمز PIN غير صحيح، حاول مرة أخرى" : "أدخل رمز PIN الخاص بـ Remote Play").font(.headline)
					SecureField("رمز PIN", text: $pin)
					.keyboardType(.numberPad)
					.textFieldStyle(.roundedBorder)
					.frame(width: 200)
				HStack {
						Button("إلغاء") { dismiss() }.buttonStyle(.bordered)
						Button("موافق") {
						session.submitPIN(pin)
						pin = ""
					}
					.buttonStyle(.borderedProminent)
				}
			}
			.padding(24)
			.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
		case .reconnecting(let attempt):
			VStack(spacing: 12) {
				ProgressView().controlSize(.large)
				Text("انقطع الاتصال. جارٍ إعادة الاتصال…").font(.headline)
				Text("المحاولة \(attempt) من \(StreamSession.maxReconnectAttempts)").foregroundStyle(.secondary)
				Button("إلغاء") { dismiss() }.buttonStyle(.bordered)
			}
			.padding(24)
			.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
		case .ended(let error):
			VStack(spacing: 12) {
				if let error {
					Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
					Text(error).multilineTextAlignment(.center).frame(maxWidth: 420)
				} else {
						Text("تم قطع الاتصال")
				}
				HStack {
						Button("إغلاق") { dismiss() }.buttonStyle(.bordered)
						Button("إعادة الاتصال") { session.reconnect() }.buttonStyle(.borderedProminent)
				}
			}
			.padding(24)
			.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
		}
	}

	private var controllerOverlay: some View {
		ZStack {
			Color.black.opacity(0.85).ignoresSafeArea()
			VStack(spacing: 8) {
				Image(systemName: "gamecontroller.fill").font(.largeTitle)
					Text("وصّل وحدة تحكم").font(.title2.bold())
					Text("لا يحتوي Orion Subtitles على أزرار تحكم على الشاشة. شغّل وحدة التحكم أو اقترن بها من إعدادات Bluetooth، وسيتصل \(console.name) عند العثور عليها.")
					.multilineTextAlignment(.center)
					.foregroundStyle(.secondary)
					.frame(maxWidth: 420)
				HStack {
						Button("إلغاء") { dismiss() }.buttonStyle(.bordered)
						Button("الاتصال رغم ذلك") {
						needsController = false
						update()
					}
					.buttonStyle(.bordered)
				}
				.padding(.top, 8)
			}
			.padding(24)
		}
	}

	private var rotateOverlay: some View {
		ZStack {
			Color.black.opacity(0.85).ignoresSafeArea()
			VStack(spacing: 8) {
				Image(systemName: "rotate.right").font(.largeTitle)
					Text("أدر iPad إلى الوضع الأفقي").font(.title2.bold())
					Text(session == nil ? "سيتصل \(console.name) عند تدوير iPad أفقيًا." : "أدر iPad أفقيًا لمتابعة اللعب.")
					.foregroundStyle(.secondary)
					Button(session == nil ? "إلغاء" : "قطع الاتصال") { dismiss() }.buttonStyle(.bordered).padding(.top, 8)
			}
		}
	}

	private var pausedOverlay: some View {
		ZStack {
			Color.black.opacity(0.85).ignoresSafeArea()
			VStack(spacing: 8) {
				Image(systemName: "rectangle.portrait.and.arrow.forward").font(.largeTitle)
				if session == nil {
						Text("افتح iPad لمتابعة اللعب").font(.title2.bold())
						Text("سيتصل \(console.name) عند فتح الجهاز.").foregroundStyle(.secondary)
					HStack {
							Button("إلغاء") { dismiss() }.buttonStyle(.bordered)
							Button("اللعب هنا رغم ذلك") {
							log.notice("Play here anyway at \(Int(windowSize.width), privacy: .public)x\(Int(windowSize.height), privacy: .public)pt")
							playHereAnyway = true
							update()
						}
						.buttonStyle(.bordered)
					}
					.padding(.top, 8)
				} else {
						Text("متوقف مؤقتًا").font(.title2.bold())
						Text("افتح الجهاز لمتابعة اللعب.").foregroundStyle(.secondary)
						Button("قطع الاتصال") { dismiss() }.buttonStyle(.bordered).padding(.top, 8)
				}
			}
		}
	}

	private var menu: some View {
		@Bindable var store = settingsStore
		return NavigationStack {
			Form {
				Section {
					Button("متابعة") { showMenu = false }
					Button("وضع الجهاز في وضع السكون") {
						session?.putConsoleToSleep()
						showMenu = false
					}
					Button("قطع الاتصال", role: .destructive) {
						showMenu = false
						dismiss()
					}
				}
				Section("الترجمة العربية") {
					Toggle("شاشة الترجمة السوداء", isOn: $blackTranslationMode)
					Button("اختبار الترجمة") {
						showMenu = false
						showTranslationDiagnostics = true
					}
					Button("لوحة تشخيص الترجمة") {
						showMenu = false
						showTranslationDiagnostics = true
					}
					Button("محرر منطقة OCR") {
						showMenu = false
						showRegionEditor = true
					}
					Button(session?.translationCoordinator.state == .running ? "Pause translation" : "Start translation") {
						if session?.translationCoordinator.state == .running {
							session?.translationCoordinator.pause()
						} else {
							session?.translationCoordinator.start()
						}
					}
					Button("إيقاف الترجمة", role: .destructive) {
						session?.translationCoordinator.stop()
					}
					if let error = session?.translationCoordinator.lastError {
						Text(error).font(.caption).foregroundStyle(.secondary)
					}
				}
				Section {
					LabeledContent {
						Text(phone.batteryText)
					} label: {
						Label("Battery", systemImage: phone.batterySymbol)
					}
					LabeledContent {
						Text(phone.thermalText).foregroundStyle(phone.isHot ? .orange : .secondary)
					} label: {
						Label("Temperature", systemImage: "thermometer.medium")
					}
					if phone.isHot && store.settings.fps > 30 {
						Button("التبديل إلى 30 إطارًا/ثانية لتبريد الجهاز") { store.settings.fps = 30 }
					}
				} header: {
					Text("الجهاز")
				}
				StreamSettingsForm(settings: $store.settings)
			}
			.navigationTitle(console.name)
			.navigationBarTitleDisplayMode(.inline)
		}
		.onChange(of: store.settings) { _, new in session?.apply(new) }
	}
}

private struct StatsOverlay: View {
	let stats: StreamStats
	let settings: StreamSettings

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			Text("\(stats.width)×\(stats.height) @ \(Int(stats.fps)) fps")
			Text(String(format: "%.1f Mbps (asked %d)", stats.bitrateMbps, settings.bitrateMbps))
			Text("\(settings.effectiveCodec == .h265 ? "HEVC" : "H.264")\(settings.hdr ? " HDR" : "")  decode \(String(format: "%.1f", stats.decodeMs)) ms")
			Text(String(format: "ping %.0f ms  loss %.1f%%", stats.rttMs, stats.packetLoss * 100))
			if stats.displayHz > 0 { Text("display \(Int(stats.displayHz)) Hz") }
			Text("lost \(stats.lostFrames)  failed \(stats.failedFrames)")
			if let controller = stats.controller { Text(controller) }
		}
		.font(.caption2.monospaced())
		.padding(8)
		.background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
		.foregroundStyle(.white)
	}
}

/// Shown when a text box opens on the PS5: type with the iPad keyboard instead of
/// the controller. Every change is sent, Send submits and Cancel closes the box.
private struct KeyboardOverlay: View {
	let initialText: String
	let onChange: (String) -> Void
	let onSubmit: (String) -> Void
	let onCancel: () -> Void

	@State private var text = ""
	@FocusState private var focused: Bool

	var body: some View {
		VStack(spacing: 12) {
			Text("اكتب على iPad").font(.headline)
				TextField("النص", text: $text)
				.textFieldStyle(.roundedBorder)
				.textInputAutocapitalization(.never)
				.autocorrectionDisabled()
				.submitLabel(.send)
				.focused($focused)
				.onSubmit { onSubmit(text) }
				.frame(maxWidth: 520)
			HStack {
					Button("إلغاء", action: onCancel).buttonStyle(.bordered)
					Button("إرسال") { onSubmit(text) }.buttonStyle(.borderedProminent)
			}
		}
		.padding(20)
		.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
		.padding(.top, 16)
		.onAppear {
			text = initialText
			focused = true
		}
		.onChange(of: text) { _, new in onChange(new) }
	}
}

/// Hosts the CAMetalLayer-backed view in SwiftUI.
private struct MetalStreamView: UIViewRepresentable {
	let renderer: MetalRenderer
	let highRefresh: Bool
	let onTouch: (ControllerInput.TouchEvent) -> Void
	let onTap: (Int) -> Void
	let onCornerTap: () -> Void
	let onLeftCornerTap: () -> Void

	func makeUIView(context: Context) -> StreamMetalView {
		let view = StreamMetalView(renderer: renderer)
		updateUIView(view, context: context)
		return view
	}

	func updateUIView(_ uiView: StreamMetalView, context: Context) {
		uiView.highRefresh = highRefresh
		uiView.onTouch = onTouch
		uiView.onTap = onTap
		uiView.onCornerTap = onCornerTap
		uiView.onLeftCornerTap = onLeftCornerTap
	}
}
