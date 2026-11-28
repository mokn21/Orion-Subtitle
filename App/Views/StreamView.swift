import GameController
import SwiftUI
import Observation
#if canImport(Translation)
import Translation
#endif

struct StreamView: View {
	let console: Console
	let startInBlackMode: Bool
	let startInControlMode: Bool

	@Environment(SettingsStore.self) private var settingsStore
	@Environment(TranslationHistoryStore.self) private var translationHistory
	@Environment(TVLinkPublisher.self) private var tvLinkPublisher
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
	@State private var needsController: Bool
	@State private var showSettingsHint = false
	@State private var showPSButton = false
	@State private var showTranslationDiagnostics = false
	@State private var showTVLinkSetup = false
	@State private var showRegionEditor = false
    @State private var showSecondRegionEditor = false
	@State private var showQuickBar = false
	@State private var quickBarHideTask: Task<Void, Never>?
	@State private var hidePSButton: Task<Void, Never>?
	@State private var pin = ""
	@State private var phone = PhoneStatus()
	@State private var showHeatWarning = false
	@State private var blackTranslationMode: Bool

	init(console: Console, startInBlackMode: Bool = false, startInControlMode: Bool = false) {
		self.console = console
		self.startInBlackMode = startInBlackMode
        self.startInControlMode = startInControlMode
		_blackTranslationMode = State(initialValue: startInBlackMode)
        _needsController = State(initialValue: !Self.hasController && !startInControlMode)
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
        .preferredColorScheme(startInControlMode ? nil : .dark)
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
		.onChange(of: session?.translationCoordinator.visibleEntries ?? []) { _, _ in publishTVEntries() }
		.onChange(of: session?.translationCoordinator.secondaryCoordinator?.visibleEntries ?? []) { _, _ in publishTVEntries() }
		.onChange(of: tvLinkPublisher.isConnected) { _, connected in if connected { publishTVEntries() } }
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
			session?.setPaused(phase != .active || (!startInControlMode && (folded || portrait)))
		}
					.sheet(isPresented: $showTVLinkSetup) {
					TVLinkSetupView(publisher: tvLinkPublisher)
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
        .sheet(isPresented: $showSecondRegionEditor) {
            if let session {
                CaptureRegionEditorView(
                    pixelBuffer: session.latestFrame,
                    title: "منطقة OCR الثانية",
                    region: Binding(
                        get: { settingsStore.settings.translationSecondRegion },
                        set: {
                            settingsStore.settings.translationSecondRegion = $0
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

				if startInControlMode {
                    controlOnlyDashboard(for: session)
                } else if blackTranslationMode, let session {
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

					if let session, !startInControlMode {
						overlay(for: session)
						if !blackTranslationMode {
							translationOverlay(for: session)
						}
					}

				if blackTranslationMode, let session {
					blackModeToolbar(for: session)
				}

			if showSettingsHint && !showMenuButton && !startInControlMode {
				settingsHint
					.transition(.opacity)
			}

			if showMenuButton && !startInControlMode {
				menuButton
					.transition(.opacity)
			}

			if showPSButton && !startInControlMode {
				psButton
					.transition(.opacity)
			}

				if showHeatWarning && !startInControlMode {
					heatWarning
						.transition(.opacity)
				}

				if showQuickBar, let session, !startInControlMode {
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
			} else if !startInControlMode && folded {
				pausedOverlay
			} else if !startInControlMode && portrait {
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
				let session = StreamSession(console: console, settings: settingsStore.settings, historyStore: translationHistory, renderVideo: !startInControlMode)
		if let orientation = interfaceOrientation {
			session.input.interfaceOrientation = orientation
		}
		session.input.onMenuCombo = { showMenu = true }
				self.translationBridge = session.translationCoordinator.appleTranslationBridge
				self.session = session
			session.start()
			session.setTranslationBlackMode(startInBlackMode || startInControlMode)
			session.translationCoordinator.start()
		lifecycleGate.markActive(attemptID)
		}

		private func stop() {
			guard let stopID = lifecycleGate.beginStop() else {
				log.notice("Ignored duplicate Remote Play stop request for \(console.name, privacy: .public)")
				return
			}
			log.notice("Stopping Remote Play lifecycle \(stopID.uuidString, privacy: .public) for \(console.name, privacy: .public)")
				tvLinkPublisher.disconnect()
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
		let canPlay = startInControlMode || (!isFolded && !portrait)
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

    private func controlOnlyDashboard(for session: StreamSession?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    Image(systemName: "captions.bubble.fill")
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(OrionPalette.buttonText)
                        .frame(width: 58, height: 58)
                        .background(OrionPalette.olive, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ORION CONTROL")
                            .font(.headline.weight(.heavy)).tracking(1.4)
                            .foregroundStyle(OrionPalette.cream)
                        Text("وضع التحكم فقط")
                            .font(.caption).foregroundStyle(OrionPalette.muted)
                    }
                    Spacer()
                    HStack(spacing: 7) {
                        Circle()
                            .fill(tvLinkPublisher.isConnected ? Color.green : OrionPalette.olive)
                            .frame(width: 8, height: 8)
                        Text(tvLinkPublisher.isConnected ? "التلفاز متصل" : "جاهز للربط")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(OrionPalette.cream)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(OrionPalette.panelAlt, in: Capsule())
                }
                .padding(18)
                .background(OrionPalette.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(OrionPalette.stroke, lineWidth: 1))

                VStack(alignment: .leading, spacing: 8) {
                    Text("لوحة التحكم")
                        .font(.system(size: 27, weight: .bold, design: .rounded))
                        .foregroundStyle(OrionPalette.cream)
                    Text("تعمل جلسة Remote Play في الخلفية لتغذية OCR، من دون إنشاء عارض لصورة اللعبة أو عرض شاشة سوداء.")
                        .font(.subheadline)
                        .foregroundStyle(OrionPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let session {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        controlMetric(
                            title: "Remote Play",
                            value: session.state == .streaming ? "متصل" : "جارٍ الاتصال",
                            detail: session.console.name,
                            icon: "gamecontroller.fill",
                            positive: session.state == .streaming
                        )
                        controlMetric(
                            title: "OCR",
                            value: session.translationCoordinator.state == .running ? "يعمل" : "متوقف مؤقتًا",
                            detail: session.translationCoordinator.ocrStatusMessage,
                            icon: "text.viewfinder",
                            positive: session.translationCoordinator.state == .running
                        )
                        controlMetric(
                            title: "النصوص الحالية",
                            value: "\(session.translationCoordinator.visibleEntries.count)",
                            detail: "ترجمات ظاهرة الآن",
                            icon: "captions.bubble",
                            positive: true
                        )
                        controlMetric(
                            title: "الإطارات المعالجة",
                            value: "\(session.translationCoordinator.processedFrames)",
                            detail: "تم تجاوز \(session.translationCoordinator.skippedFrames) إطارًا",
                            icon: "waveform.path",
                            positive: true
                        )
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Label("حالة الترجمة", systemImage: "character.bubble")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(OrionPalette.cream)
                        Text(session.translationCoordinator.translationStatusMessage)
                            .font(.caption)
                            .foregroundStyle(OrionPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(OrionPalette.panelAlt, in: RoundedRectangle(cornerRadius: 17, style: .continuous))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("أدوات الجلسة")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(OrionPalette.cream)
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                            controlActionCard(
                                title: session.translationCoordinator.state == .running ? "إيقاف OCR مؤقتًا" : "استئناف OCR",
                                subtitle: session.translationCoordinator.state == .running ? "إيقاف قراءة النص" : "متابعة قراءة النص",
                                icon: session.translationCoordinator.state == .running ? "pause.fill" : "play.fill"
                            ) {
                                if session.translationCoordinator.state == .running { session.translationCoordinator.pause() }
                                else { session.translationCoordinator.start() }
                            }
                            controlActionCard(title: "قص المنطقة", subtitle: "تحديد مساحة قراءة النص", icon: "crop") {
                                showRegionEditor = true
                            }
                            controlActionCard(title: "المنطقة الثانية", subtitle: "إعداد منطقة OCR إضافية", icon: "viewfinder") {
                                if session.translationCoordinator.secondaryEnabled { showSecondRegionEditor = true }
                            }
                            .opacity(session.translationCoordinator.secondaryEnabled ? 1 : 0.5)
                            .disabled(!session.translationCoordinator.secondaryEnabled)
                            controlActionCard(title: "إعداد التلفاز", subtitle: tvLinkPublisher.status, icon: "tv") {
                                showTVLinkSetup = true
                            }
                        }
                    }
                } else {
                    ProgressView("جارٍ تجهيز جلسة Remote Play…")
                        .tint(OrionPalette.olive)
                        .foregroundStyle(OrionPalette.cream)
                        .frame(maxWidth: .infinity)
                        .padding(24)
                        .background(OrionPalette.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }

                Button(role: .destructive) {
                    stop()
                    dismiss()
                } label: {
                    Label("إيقاف الجلسة", systemImage: "stop.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(16)
                        .background(OrionPalette.stroke, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .foregroundStyle(OrionPalette.cream)
                }
                .buttonStyle(.plain)
            }
            .padding(24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .background(OrionPalette.background.ignoresSafeArea())
        .environment(\.layoutDirection, Locale.current.language.languageCode?.identifier == "ar" ? .rightToLeft : .leftToRight)
    }

    private func controlMetric(title: String, value: String, detail: String, icon: String, positive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(OrionPalette.olive)
                Spacer()
                Circle()
                    .fill(positive ? Color.green : OrionPalette.olive)
                    .frame(width: 7, height: 7)
            }
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(OrionPalette.muted)
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(OrionPalette.cream)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(OrionPalette.muted)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
        .padding(15)
        .background(OrionPalette.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(OrionPalette.stroke, lineWidth: 1))
    }

    private func controlActionCard(title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                Image(systemName: icon).font(.title2).foregroundStyle(OrionPalette.olive)
                Text(title).font(.headline).foregroundStyle(OrionPalette.cream)
                Text(subtitle).font(.caption).foregroundStyle(OrionPalette.muted).lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
            .padding(15).background(OrionPalette.panel, in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(OrionPalette.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

	private func quickToolbar(for session: StreamSession) -> some View {
		HStack(spacing: 8) {
            quickTool(blackTranslationMode ? "عرض اللعبة" : "شاشة سوداء",
                icon: blackTranslationMode ? "play.tv" : "rectangle.fill") {
                blackTranslationMode.toggle()
                session.setTranslationBlackMode(blackTranslationMode)
            }
			quickTool(tvLinkPublisher.isConnected ? "TV متصل" : "التلفاز", icon: "tv") {
				showTVLinkSetup = true
			}
            quickTool("تنظيف", icon: "eraser") {
                session.translationCoordinator.clearVisibleEntries()
                session.translationCoordinator.secondaryCoordinator?.clearVisibleEntries()
                tvLinkPublisher.clearAllSubtitles()
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
            if session.translationCoordinator.secondaryEnabled {
                quickTool("منطقة ٢", icon: "viewfinder") {
                    showSecondRegionEditor = true
                }
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

	private func publishTVEntries() {
		guard let session else {
			tvLinkPublisher.update([])
			return
		}
		let entries = session.translationCoordinator.visibleEntries +
			(session.translationCoordinator.secondaryEnabled
				? (session.translationCoordinator.secondaryCoordinator?.visibleEntries ?? [])
				: [])
		tvLinkPublisher.update(entries)
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
                        let entries = session.translationCoordinator.visibleEntries +
                            (session.translationCoordinator.secondaryEnabled
                                ? (session.translationCoordinator.secondaryCoordinator?.visibleEntries ?? [])
                                : [])
						ForEach(entries) { entry in
							let frame = spatialFrame(for: entry.boundingBox, in: geo.size, mode: session.settings.displayMode)
                            ZStack {
                                RoundedRectangle(cornerRadius: 2).fill(subtitleBackgroundColor(entry.backgroundColorHex))
                                Text(entry.translatedText)
                                    .font(.system(
                                        size: min(session.settings.translationFontSize, max(7, frame.height * 0.68)),
                                        weight: entry.isSelectedMenuItem ? .heavy : .semibold
                                    ))
                                    .multilineTextAlignment(.center)
                                    .environment(\.layoutDirection, Locale.current.language.languageCode?.identifier == "ar" ? .rightToLeft : .leftToRight)
                                    .lineLimit(1)
                                    .allowsTightening(true)
                                    .minimumScaleFactor(0.10)
                                    .foregroundStyle(translationColor(session.settings.translationTextColor))
                                    .frame(width: max(1, frame.width), height: max(1, frame.height), alignment: .center)
                            }
                            // Keep both the black cover and Arabic text inside the
                            // original OCR rectangle. Intrinsic Arabic width must
                            // never enlarge the cover across nearby game content.
                            .frame(width: max(1, frame.width), height: max(1, frame.height))
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                            .overlay {
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(entry.isSelectedMenuItem ? Color.yellow.opacity(0.95) : .clear,
                                            lineWidth: entry.isSelectedMenuItem ? 2 : 0)
                            }
                            .position(x: frame.midX, y: frame.midY)
					}
					}
				// Match MetalStreamView's full-screen coordinate space, including safe areas.
				.ignoresSafeArea()
				.clipped()
				.allowsHitTesting(false)
				}
			}

			/// Converts Vision's bottom-left normalized coordinates into the displayed
			/// 16:9 video rectangle, including iPad letterboxing.
			private func subtitleBackgroundColor(_ hex: String) -> Color {
                let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                guard let rgb = UInt32(value, radix: 16) else { return .black }
                return Color(.sRGB, red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: 1)
            }

            private func spatialFrame(for visionRect: CGRect, in size: CGSize, mode: DisplayMode) -> CGRect {
                VideoCoordinateMapper.displayRect(for: visionRect, in: size, mode: mode)
            }

			private func blackTranslationScreen(for session: StreamSession) -> some View {
            let allEntries = session.translationCoordinator.recentEntries +
                (session.translationCoordinator.secondaryEnabled
                    ? (session.translationCoordinator.secondaryCoordinator?.recentEntries ?? [])
                    : [])
            let sortedEntries = allEntries.sorted { $0.createdAt > $1.createdAt }
			return VStack(spacing: 18) {
					if let entry = sortedEntries.first {
						Text(entry.translatedText)
							.font(.system(size: session.settings.translationFontSize + 10, weight: .bold))
							.multilineTextAlignment(.center)
							.environment(\.layoutDirection, Locale.current.language.languageCode?.identifier == "ar" ? .rightToLeft : .leftToRight)
							.foregroundStyle(translationColor(session.settings.translationTextColor))
							ForEach(Array(sortedEntries.dropFirst()), id: \.id) { previous in
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
				.environment(\.layoutDirection, Locale.current.language.languageCode?.identifier == "ar" ? .rightToLeft : .leftToRight)
			}

				private func blackModeToolbar(for session: StreamSession) -> some View {
					HStack(spacing: 8) {
						quickTool("عرض اللعبة", icon: "play.tv") {
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
                    if session.translationCoordinator.secondaryEnabled {
                        quickTool("المنطقة ٢", icon: "viewfinder") { showSecondRegionEditor = true }
                    }
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
