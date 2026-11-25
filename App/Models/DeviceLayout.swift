import UIKit

/// Works out whether we're on a foldable, and which of its screens we're on.
///
/// The upstream foldable-phone detector is retained for compatibility, but
/// iPad is handled as a native tablet and never enters this foldable path.
/// Sizes are compared in pixels, not points: Display Zoom ("Larger Text")
/// shrinks the point size of the same panel.
enum DeviceLayout {
	private static let innerScreenMinShortSidePixels: CGFloat = 1700
	/// Model identifiers of known foldables. Others are picked up the first time
	/// an inner-screen-sized window is seen.
	private static let knownFoldables: Set<String> = ["iPhone19,4"]
	private static let seenInnerScreenKey = "seenFoldableInnerScreen"

	static let modelIdentifier: String = {
		var info = utsname()
		uname(&info)
		return withUnsafeBytes(of: &info.machine) { raw in
			String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
		}
	}()

	static var isFoldable: Bool {
		knownFoldables.contains(modelIdentifier) || UserDefaults.standard.bool(forKey: seenInnerScreenKey)
	}

	static var nativeScale: CGFloat {
		(UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.nativeScale ?? UIScreen.main.nativeScale
	}

	static func isInnerScreen(_ size: CGSize) -> Bool {
		min(size.width, size.height) * nativeScale >= innerScreenMinShortSidePixels
	}

	/// True on a foldable that's currently showing on its outer screen.
	static func isFolded(_ size: CGSize) -> Bool {
		isFoldable && !isInnerScreen(size)
	}

	static func noteWindowSize(_ size: CGSize) {
		let inner = isInnerScreen(size)
		log.notice("Window \(Int(size.width), privacy: .public)x\(Int(size.height), privacy: .public)pt at \(nativeScale, privacy: .public)x: foldable \(isFoldable, privacy: .public), inner screen \(inner, privacy: .public)")
		if inner, !UserDefaults.standard.bool(forKey: seenInnerScreenKey) {
			UserDefaults.standard.set(true, forKey: seenInnerScreenKey)
		}
	}
}
