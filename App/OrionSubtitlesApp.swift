import ChiakiKit
import SwiftUI
import os

let logSubsystem = Bundle.main.bundleIdentifier ?? "orion.subtitles"
let log = Logger(subsystem: logSubsystem, category: "app")
let chiakiLog = Logger(subsystem: logSubsystem, category: "chiaki")

@main
struct OrionSubtitlesApp: App {
	@UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
	@State private var consoles = ConsoleStore()
	@State private var settings = SettingsStore()

	init() {
		ChiakiLib.initialise()
	}

	var body: some Scene {
		WindowGroup {
			ConsoleListView()
				.environment(consoles)
				.environment(settings)
				.preferredColorScheme(.dark)
				.background {
					// Track the window size for the streaming layout.
					GeometryReader { geo in
						Color.clear
							.onAppear { AppDelegate.windowSizeChanged(geo.size) }
							.onChange(of: geo.size) { _, size in AppDelegate.windowSizeChanged(size) }
					}
					.ignoresSafeArea()
				}
		}
	}
}

/// iPadOS manages interface rotation using the supported orientations in Info.plist.
/// Avoid private/runtime orientation hooks so the app builds with the iOS 18 SDK.
final class AppDelegate: NSObject, UIApplicationDelegate {
	static func setStreaming(_ value: Bool) {
		// Rotation remains managed by iPadOS.
	}

	static func windowSizeChanged(_ size: CGSize) {
		guard size.width > 0, size.height > 0 else { return }
		DeviceLayout.noteWindowSize(size)
	}
}

enum ChiakiLib {
	private static let once: Void = {
		ck_set_log_callback({ _, level, message in
			guard let message else { return }
			let text = String(cString: message)
			if level & 1 != 0 {
				chiakiLog.error("\(text, privacy: .public)")
			} else {
				chiakiLog.info("\(text, privacy: .public)")
			}
		}, nil)
		let err = ck_lib_init()
		if err != 0 {
			log.error("chiaki lib init failed: \(err)")
		}
	}()

	static func initialise() {
		_ = once
	}
}
