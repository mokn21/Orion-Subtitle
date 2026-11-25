import ChiakiKit
import CoreVideo
import Foundation
import Observation
import UIKit

struct StreamStats: Equatable {
	var fps: Double = 0
	var bitrateMbps: Double = 0
	var width: Int32 = 0
	var height: Int32 = 0
	var decodeMs: Double = 0
	/// Round trip measured while connecting
	var rttMs: Double = 0
	/// Packets lost recently, 0...1
	var packetLoss: Double = 0
	var failedFrames = 0
	var lostFrames = 0
	var hdrFrames = false
	var controller: String?
	/// The screen's refresh rate, 0 if unknown
	var displayHz: Double = 0
}

/// One Remote Play connection: chiaki session + decoder + renderer + audio + input.
@Observable
final class StreamSession {
	enum State: Equatable {
		case idle
		case connecting
		case streaming
		case needsPIN(incorrect: Bool)
		/// The connection dropped and we're trying again
		case reconnecting(attempt: Int)
		case ended(error: String?)
	}

	static let maxReconnectAttempts = 3

	private(set) var state: State = .idle
	private(set) var stats = StreamStats()
	/// A text box is open on the PS5: the text it started with. nil when there's none.
	private(set) var keyboardText: String?
	/// Folded or backgrounded: video isn't drawn and audio is muted, connection stays up
	private(set) var paused = false
	/// The most recent decoded frame, used only for the in-app OCR region editor.
	@ObservationIgnored private(set) var latestFrame: CVPixelBuffer?

	let console: Console
	private(set) var settings: StreamSettings

	@ObservationIgnored let renderer: MetalRenderer?
	/// OCR observes the decoded Remote Play frame; it never captures another app's screen.
	let translationCoordinator = TranslationCoordinator()
	@ObservationIgnored let input = ControllerInput()
	@ObservationIgnored private let audio = AudioOutput()
	@ObservationIgnored private var decoder: VideoDecoder?
	@ObservationIgnored private var handle: OpaquePointer?
	@ObservationIgnored private var selfRef: Unmanaged<StreamSession>?
	@ObservationIgnored private var statsTimer: Timer?
	@ObservationIgnored private var lastDecoded = 0
	@ObservationIgnored private var lostFrames: Int32 = 0
	@ObservationIgnored private var touchIDs: [Int: Int32] = [:]
	/// Latest controller state, so screen taps can add a touchpad click on top of it
	@ObservationIgnored private var lastPad = CKPadState()
	@ObservationIgnored private var extraButtons: UInt32 = 0
	@ObservationIgnored private var reconnectAttempt = 0
	@ObservationIgnored private var reconnectWork: DispatchWorkItem?
	@ObservationIgnored private var connectionTimeoutWork: DispatchWorkItem?
	@ObservationIgnored private var startWork: DispatchWorkItem?
	@ObservationIgnored private var stopRequestedDuringStart = false
	@ObservationIgnored private var startInProgress = false
	@ObservationIgnored private var activeAttemptID: UUID?
	@ObservationIgnored private var loggedFirstVideo = false
	@ObservationIgnored private var loggedFirstEvent = false
	@ObservationIgnored private var loggedFirstDecodedFrame = false
	@ObservationIgnored private var loggedFirstFrameOnMain = false
	@ObservationIgnored private var loggedDecodeFailure = false
	@ObservationIgnored private var videoCallbackCount = 0

	init(console: Console, settings: StreamSettings) {
		self.console = console
		self.settings = settings
		self.renderer = MetalRenderer()
		self.translationCoordinator.region = settings.translationRegion
		self.translationCoordinator.sourceLanguage = settings.translationSourceLanguage
		self.translationCoordinator.minimumFrameInterval = .milliseconds(settings.translationIntervalMs)
	}

	deinit {
		teardown()
	}

	// MARK: - Lifecycle

	func start() {
		guard handle == nil else {
			log.notice("Ignored duplicate StreamSession.start for \(self.console.name, privacy: .public)")
			return
		}
		guard !startInProgress else {
			log.notice("Ignored overlapping Remote Play start for \(self.console.name, privacy: .public)")
			return
		}
		startInProgress = true
		stopRequestedDuringStart = false
		let attemptID = UUID()
		activeAttemptID = attemptID
		loggedFirstVideo = false
		loggedFirstEvent = false
		loggedFirstDecodedFrame = false
		loggedFirstFrameOnMain = false
		loggedDecodeFailure = false
		videoCallbackCount = 0
		log.notice("StreamSession.start attempt \(attemptID.uuidString, privacy: .public) for \(self.console.name, privacy: .public)")
		defer { startInProgress = false }
		connectionTimeoutWork?.cancel()
		connectionTimeoutWork = nil
		guard let renderer else {
			activeAttemptID = nil
			state = .ended(error: "Metal isn't available on this device.")
			return
		}
		if case .reconnecting = state {} else { state = .connecting }
		keyboardText = nil
		lostFrames = 0
		lastDecoded = 0

		let codec = settings.effectiveCodec
		let decoder = VideoDecoder(hevc: codec == .h265, tenBit: settings.hdr)
		decoder.onFrame = { [weak renderer, weak self] frame in
			renderer?.display(frame)
			guard let self else { return }
			if !self.loggedFirstDecodedFrame {
				self.loggedFirstDecodedFrame = true
				log.notice("Remote Play first decoded CVPixelBuffer size=\(CVPixelBufferGetWidth(frame))x\(CVPixelBufferGetHeight(frame)) attempt=\(self.activeAttemptID?.uuidString ?? "none", privacy: .public)")
			}
			// SwiftUI observation and OCR state are main-actor state. The
			// decoder callback is a Chiaki/VideoToolbox thread.
			Task { @MainActor in
				self.latestFrame = frame
				if !self.loggedFirstFrameOnMain {
					self.loggedFirstFrameOnMain = true
					log.notice("Remote Play first latestFrame update on MainActor attempt=\(self.activeAttemptID?.uuidString ?? "none", privacy: .public)")
				}
				self.translationCoordinator.submit(pixelBuffer: frame)
			}
		}
		self.decoder = decoder
		renderer.resetDiagnostics()
		renderer.onFirstPresented = { [weak self] in
			guard let self else { return }
			log.notice("Remote Play first Metal frame committed attempt=\(self.activeAttemptID?.uuidString ?? "none", privacy: .public)")
		}
		renderer.configure(hdr: settings.hdr, displayMode: settings.displayMode, bicubic: settings.sharpUpscaling)
		renderer.setPaused(paused)

		var config = CKSessionConfig()
		let size = settings.resolution.size
		config.ps5 = console.ps5
		config.width = size.width
		config.height = size.height
		config.max_fps = UInt32(settings.fps)
		config.bitrate_kbps = UInt32(settings.bitrateMbps * 1000)
		config.codec = settings.hdr ? CK_CODEC_H265_HDR : (codec == .h265 ? CK_CODEC_H265 : CK_CODEC_H264)
		// Always advertise a DualSense: the PS5 then sends haptics/trigger data, and
		// for other controllers the haptics are converted to rumble.
		config.enable_dualsense = true
		config.enable_keyboard = true
		config.packet_loss_max = 0.05
		config.verbose_log = false
		withUnsafeMutableBytes(of: &config.regist_key) { _ = console.registKey.prefix(16).copyBytes(to: $0) }
		withUnsafeMutableBytes(of: &config.rp_key) { _ = console.rpKey.prefix(16).copyBytes(to: $0) }

		let ref = Unmanaged.passRetained(self)
		selfRef = ref
		var callbacks = CKSessionCallbacks()
		callbacks.user = ref.toOpaque()
		callbacks.on_video = { user, buf, size, lost, _ in
			guard let user, let buf else { return true }
			return Unmanaged<StreamSession>.fromOpaque(user).takeUnretainedValue().handleVideo(buf, Int(size), lost)
		}
		callbacks.on_event = { user, type, code, message in
			guard let user else { return }
			let session = Unmanaged<StreamSession>.fromOpaque(user).takeUnretainedValue()
			if !session.loggedFirstEvent {
				session.loggedFirstEvent = true
				let eventName = String(describing: type)
				log.notice("Remote Play first Chiaki event type=\(eventName, privacy: .public) attempt=\(session.activeAttemptID?.uuidString ?? "none", privacy: .public)")
			}
				let text = message.map { String(cString: $0) }
				Task { @MainActor in
					session.handleEvent(type, code: code, message: text)
				}
		}
		callbacks.on_rumble = { user, left, right in
			guard let user else { return }
			Unmanaged<StreamSession>.fromOpaque(user).takeUnretainedValue().handleRumble(left, right)
		}
		callbacks.on_trigger_effects = { user, tl, l, tr, r in
			guard let user, let l, let r else { return }
			let left = Array(UnsafeBufferPointer(start: l, count: 10))
			let right = Array(UnsafeBufferPointer(start: r, count: 10))
			let session = Unmanaged<StreamSession>.fromOpaque(user).takeUnretainedValue()
			DispatchQueue.main.async {
				session.input.applyTriggerEffect(typeLeft: tl, left: left, typeRight: tr, right: right)
			}
		}
		callbacks.on_haptics = { user, samples, frames in
			guard let user, let samples else { return }
			Unmanaged<StreamSession>.fromOpaque(user).takeUnretainedValue().handleHaptics(samples, Int(frames))
		}
		callbacks.on_log = { _, level, message in
			guard let message else { return }
			let text = String(cString: message)
			if level & 1 != 0 { chiakiLog.error("\(text, privacy: .public)") } else { chiakiLog.info("\(text, privacy: .public)") }
		}

		let created: OpaquePointer? = console.host.withCString { host in
			config.host = host
			log.notice("Creating Chiaki session attempt=\(attemptID.uuidString, privacy: .public)")
			return ck_session_create(&config, &callbacks)
		}
		guard let created else {
			log.error("Chiaki session creation returned nil attempt=\(attemptID.uuidString, privacy: .public)")
			ref.release()
			selfRef = nil
			activeAttemptID = nil
			state = .ended(error: "Couldn't create the Remote Play session.")
			return
		}
		handle = created

		input.selectIsTouchpad = settings.selectIsTouchpad
		input.phoneMotionEnabled = settings.phoneMotion
		input.rumble.enabled = settings.rumble
		input.onPad = { [weak self] pad in
			self?.lastPad = pad
			self?.sendPad()
		}
		input.onMotion = { [weak self] gyro, accel, ts in
			guard let handle = self?.handle else { return }
			ck_session_set_motion(handle, gyro.x, gyro.y, gyro.z, accel.x, accel.y, accel.z, ts)
		}
		input.onTouch = { [weak self] event in self?.handleTouch(event) }
		input.start()

		audio.start(session: created)
		audio.muted = paused

			log.notice("Starting Chiaki session off MainActor attempt=\(attemptID.uuidString, privacy: .public)")
			let work = DispatchWorkItem { [weak self] in
				let err = ck_session_start(created)
				log.notice("ck_session_start returned code=\(err) attempt=\(attemptID.uuidString, privacy: .public)")
				DispatchQueue.main.async {
					guard let self, self.activeAttemptID == attemptID else { return }
					self.startWork = nil
					self.finishStart(err, attemptID: attemptID)
				}
			}
			startWork = work
			DispatchQueue.global(qos: .userInitiated).async(execute: work)
		}

	private func finishStart(_ err: Int32, attemptID: UUID) {
		guard activeAttemptID == attemptID else { return }
		if err != 0 {
			log.error("Chiaki session start failed code=\(err) attempt=\(attemptID.uuidString, privacy: .public)")
			teardown()
			state = .ended(error: "تعذر بدء جلسة Remote Play (رمز \(err)).")
			return
		}
		if stopRequestedDuringStart {
			log.notice("Remote Play start completed after cancellation; cleaning up attempt=\(attemptID.uuidString, privacy: .public)")
			teardown()
			state = .ended(error: nil)
			return
		}
		let timeout = DispatchWorkItem { [weak self] in
			guard let self, self.activeAttemptID == attemptID, case .connecting = self.state else { return }
			log.error("Remote Play connection timed out for \(self.console.name, privacy: .public)")
			self.teardown()
			self.state = .ended(error: "انتهت مهلة الاتصال بـ Remote Play. تأكد من أن PS5 في وضع الاستعداد أو أن Remote Play متاح ثم حاول مرة أخرى.")
		}
		connectionTimeoutWork = timeout
		DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
		UIApplication.shared.isIdleTimerDisabled = true
		statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateStats() }
	}

	/// Stops streaming and frees everything. Safe to call more than once.
	func stop() {
		cancelReconnect()
		teardown()
		if case .ended = state {} else { state = .ended(error: nil) }
	}

	/// Manual reconnect from the "Disconnected" screen
	func reconnect() {
		cancelReconnect()
		if handle != nil { teardown() }
		start()
	}

	private func cancelReconnect() {
		reconnectWork?.cancel()
		reconnectWork = nil
		reconnectAttempt = 0
	}

	/// Drops that are worth retrying: the network went away or the connection
	/// broke, as opposed to e.g. the console being in use or refusing us.
	private static func isRetryable(quitReason code: Int32) -> Bool {
		switch code {
		case 2, 7, 8, 10, 11: true  // SESSION_REQUEST_UNKNOWN, CTRL_UNKNOWN, CTRL_CONNECT_FAILED, STREAM_CONNECTION_UNKNOWN, ..._REMOTE_DISCONNECTED
		default: false
		}
	}

	/// Applies new settings. Codec/resolution/bitrate/HDR changes need a reconnect.
	func apply(_ new: StreamSettings) {
		let needsReconnect =
			new.resolution != settings.resolution || new.fps != settings.fps || new.bitrateMbps != settings.bitrateMbps
			|| new.effectiveCodec != settings.effectiveCodec || new.hdr != settings.hdr
		settings = new
		translationCoordinator.region = new.translationRegion
		translationCoordinator.sourceLanguage = new.translationSourceLanguage
		translationCoordinator.minimumFrameInterval = .milliseconds(new.translationIntervalMs)
		input.selectIsTouchpad = new.selectIsTouchpad
		input.rumble.enabled = new.rumble
		renderer?.setDisplayMode(new.displayMode)
		if needsReconnect, handle != nil {
			teardown()
			start()
		} else {
			renderer?.configure(hdr: new.hdr, displayMode: new.displayMode, bicubic: new.sharpUpscaling)
		}
	}

	func setPaused(_ paused: Bool) {
		guard paused != self.paused else { return }
		self.paused = paused
		renderer?.setPaused(paused)
		audio.muted = paused
		if !paused, let handle {
			// We dropped frames while paused, so get a clean keyframe
			ck_session_request_idr(handle)
		}
	}

	/// Black translation mode keeps decoding frames but mutes Remote Play audio.
	func setTranslationBlackMode(_ enabled: Bool) {
		audio.muted = enabled || paused
	}

	func submitPIN(_ pin: String) {
		guard let handle else { return }
		ck_session_set_login_pin(handle, pin)
		state = .connecting
	}

	func putConsoleToSleep() {
		guard let handle else { return }
		ck_session_goto_bed(handle)
	}

	// MARK: - Text input

	/// Sends the whole text whenever it changes
	func keyboardChanged(_ text: String) {
		guard let handle else { return }
		ck_session_keyboard_set_text(handle, text)
	}

	func keyboardSubmit(_ text: String) {
		guard let handle else { return }
		ck_session_keyboard_set_text(handle, text)
		ck_session_keyboard_accept(handle)
		keyboardText = nil
	}

	func keyboardCancel() {
		if let handle { ck_session_keyboard_reject(handle) }
		keyboardText = nil
	}

	private func teardown() {
		log.notice("StreamSession.teardown for \(self.console.name, privacy: .public)")
		if startWork != nil {
			stopRequestedDuringStart = true
			log.notice("Deferring teardown until ck_session_start returns for \(self.console.name, privacy: .public)")
			return
		}
		connectionTimeoutWork?.cancel()
		connectionTimeoutWork = nil
		statsTimer?.invalidate()
		statsTimer = nil
		input.stop()
		audio.stop()
		if let handle {
			log.notice("Destroying Chiaki session attempt=\(self.activeAttemptID?.uuidString ?? "none", privacy: .public)")
			// Stops and joins chiaki's threads: no callbacks after this
			ck_session_destroy(handle)
		}
		handle = nil
		decoder?.invalidate()
		decoder = nil
		latestFrame = nil
		selfRef?.release()
		selfRef = nil
		activeAttemptID = nil
		stopRequestedDuringStart = false
		startInProgress = false
		UIApplication.shared.isIdleTimerDisabled = false
	}

	// MARK: - Callbacks (chiaki threads)

	private func handleVideo(_ buf: UnsafePointer<UInt8>, _ size: Int, _ lost: Int32) -> Bool {
		videoCallbackCount += 1
		if !loggedFirstVideo {
			loggedFirstVideo = true
			log.notice("Remote Play first video callback size=\(size) attempt=\(self.activeAttemptID?.uuidString ?? "none", privacy: .public)")
		}
		if lost > 0 { lostFrames &+= lost }
		guard let decoder else { return true }
		let decoded = decoder.decode(buf, count: size)
		if !decoded, !loggedDecodeFailure {
			loggedDecodeFailure = true
			log.error("Remote Play first video decode failure callbackCount=\(self.videoCallbackCount) size=\(size) attempt=\(self.activeAttemptID?.uuidString ?? "none", privacy: .public)")
		}
		return decoded
	}

	private func handleRumble(_ left: UInt8, _ right: UInt8) {
		input.rumble.set(left: left, right: right)
	}

	private func handleHaptics(_ samples: UnsafePointer<Int16>, _ frames: Int) {
		// Convert DualSense haptic audio (3 kHz stereo PCM) to rumble strength per side
		var l: Float = 0
		var r: Float = 0
		for i in 0..<frames {
			l = max(l, abs(Float(samples[i * 2])))
			r = max(r, abs(Float(samples[i * 2 + 1])))
		}
		let scale: Float = 255 / 16_384
		input.rumble.set(left: UInt8(min(255, l * scale)), right: UInt8(min(255, r * scale)))
	}

	// MARK: - Events (main thread)

	@MainActor
	private func handleEvent(_ type: CKEventType, code: Int32, message: String?) {
		switch type {
		case CK_EVENT_CONNECTED:
			connectionTimeoutWork?.cancel()
			connectionTimeoutWork = nil
			reconnectAttempt = 0
			log.notice("Remote Play connected for \(self.console.name, privacy: .public)")
			state = .streaming
		case CK_EVENT_LOGIN_PIN_REQUEST:
			state = .needsPIN(incorrect: code != 0)
		case CK_EVENT_KEYBOARD_OPEN:
			keyboardText = message ?? ""
		case CK_EVENT_KEYBOARD_CLOSE:
			keyboardText = nil
		case CK_EVENT_QUIT:
			if reconnectWork != nil {
				log.notice("Ignored duplicate Remote Play quit while reconnect is already scheduled")
				return
			}
			// CHIAKI_QUIT_REASON_STOPPED (1) and ..._REMOTE_SHUTDOWN (12) are normal exits
			let wasError = code != 1 && code != 12
			// Only retry a connection that was working (or a retry that just failed)
			let wasPlaying: Bool
			switch state {
			case .streaming, .reconnecting: wasPlaying = true
			default: wasPlaying = false
			}
			// Tear down off the callback thread (we're on main via async)
			teardown()
			if wasError, wasPlaying, Self.isRetryable(quitReason: code), reconnectAttempt < Self.maxReconnectAttempts {
				reconnectAttempt += 1
				let attempt = reconnectAttempt
				log.notice("Connection lost (\(message ?? "?", privacy: .public)), reconnect attempt \(attempt)")
				state = .reconnecting(attempt: attempt)
				let work = DispatchWorkItem { [weak self] in
					guard let self else { return }
					self.reconnectWork = nil
					self.start()
				}
				reconnectWork = work
				// 1 s, 2 s, 4 s
				DispatchQueue.main.asyncAfter(deadline: .now() + pow(2, Double(attempt - 1)), execute: work)
			} else {
				reconnectAttempt = 0
				state = .ended(error: wasError ? message : nil)
			}
		default:
			break
		}
	}

	private func sendPad() {
		guard let handle else { return }
		var pad = lastPad
		pad.buttons |= extraButtons
		ck_session_set_pad(handle, &pad)
	}

	// MARK: - On-screen touchpad (main thread)

	func screenTouch(_ event: ControllerInput.TouchEvent) {
		handleTouch(event)
	}

	/// On-screen PS button, for controllers whose home button iOS doesn't pass through
	func pressPSButton() {
		let button = UInt32(CK_BUTTON_PS.rawValue)
		extraButtons |= button
		sendPad()
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
			guard let self else { return }
			self.extraButtons &= ~button
			self.sendPad()
		}
	}

	/// A quick tap on the screen: click the touchpad at the touch point, then lift the finger.
	func screenTap(slot: Int) {
		let button = UInt32(CK_BUTTON_TOUCHPAD.rawValue)
		extraButtons |= button
		sendPad()
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
			guard let self else { return }
			self.extraButtons &= ~button
			self.sendPad()
			self.handleTouch(.up(slot: slot))
		}
	}

	private func handleTouch(_ event: ControllerInput.TouchEvent) {
		guard let handle else { return }
		switch event {
		case .down(let slot, let x, let y):
			touchIDs[slot] = ck_session_touch_start(handle, x, y)
		case .move(let slot, let x, let y):
			if let id = touchIDs[slot], id >= 0 { ck_session_touch_move(handle, id, x, y) }
		case .up(let slot):
			if let id = touchIDs.removeValue(forKey: slot), id >= 0 { ck_session_touch_stop(handle, id) }
		}
	}

	private func updateStats() {
		guard let decoder else { return }
		let decoded = decoder.decodedFrames
		var s = StreamStats()
		s.fps = Double(decoded - lastDecoded)
		lastDecoded = decoded
		if let handle {
			s.bitrateMbps = ck_session_measured_bitrate_mbps(handle)
			s.rttMs = ck_session_rtt_ms(handle)
			s.packetLoss = ck_session_packet_loss(handle)
		}
		s.width = decoder.dimensions.width
		s.height = decoder.dimensions.height
		s.decodeMs = decoder.lastDecodeMs
		s.failedFrames = decoder.failedFrames
		s.lostFrames = Int(lostFrames)
		s.hdrFrames = settings.hdr
		s.controller = input.controllerName
		s.displayHz = renderer?.displayHz ?? 0
		stats = s
	}
}
