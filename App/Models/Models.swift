import Foundation
import Observation

/// A PlayStation that has been registered (linked) with this phone.
struct Console: Codable, Identifiable, Hashable {
	var id = UUID()
	var name: String
	var host: String
	var ps5: Bool
	/// rp_regist_key: 16 bytes (ASCII hex, zero padded)
	var registKey: Data
	/// rp_key ("morning"): 16 bytes
	var rpKey: Data
	var mac: Data
}

@Observable
final class ConsoleStore {
	private(set) var consoles: [Console] = []

	@ObservationIgnored private let url: URL = {
		let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir.appendingPathComponent("consoles.json")
	}()

	init() {
		if let data = try? Data(contentsOf: url),
			let decoded = try? JSONDecoder().decode([Console].self, from: data)
		{
			consoles = decoded
		}
	}

	func add(_ console: Console) {
		// Re-registering the same console replaces the old keys
		consoles.removeAll { $0.mac == console.mac && !console.mac.isEmpty }
		consoles.append(console)
		save()
	}

	func update(_ console: Console) {
		guard let index = consoles.firstIndex(where: { $0.id == console.id }) else { return }
		consoles[index] = console
		save()
	}

	func remove(_ console: Console) {
		consoles.removeAll { $0.id == console.id }
		save()
	}

	private func save() {
		do {
			let data = try JSONEncoder().encode(consoles)
			try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
		} catch {
			log.error("Saving consoles failed: \(error.localizedDescription, privacy: .public)")
		}
	}
}

// MARK: - Stream settings

enum StreamResolution: Int, Codable, CaseIterable, Identifiable {
	case p720 = 720
	case p1080 = 1080

	var id: Int { rawValue }
	var label: String { "\(rawValue)p" }
	var size: (width: UInt32, height: UInt32) {
		switch self {
		case .p720: (1280, 720)
		case .p1080: (1920, 1080)
		}
	}
}

enum VideoCodecChoice: String, Codable, CaseIterable, Identifiable {
	case h265
	case h264

	var id: String { rawValue }
    var label: String { self == .h265 ? "H.265 (HEVC)" : "H.264" }
}

enum DisplayMode: String, Codable, CaseIterable, Identifiable {
	/// Whole picture visible, black bars where the screen isn't 16:9
	case fit
	/// Fill the screen, cropping whatever overflows
	case zoom

	var id: String { rawValue }
    var label: String { self == .fit ? "ملاءمة كاملة" : "تكبير لملء الشاشة" }
}

enum TranslationTheme: String, Codable, CaseIterable, Identifiable {
	case sideScreen
	case midnight
	case pitchBlack

	var id: String { rawValue }
	var label: String {
		switch self {
            case .sideScreen: "شاشة جانبية"
            case .midnight: "منتصف الليل"
            case .pitchBlack: "أسود كامل"
		}
	}
}

enum TranslationColorChoice: String, Codable, CaseIterable, Identifiable {
	case black
	case white
	case yellow
	case cyan
	case green

	var id: String { rawValue }
	var label: String {
		switch self {
		case .black: "أسود"
		case .white: "أبيض"
		case .yellow: "أصفر"
		case .cyan: "سماوي"
		case .green: "أخضر"
		}
	}
}

struct StreamSettings: Codable, Equatable {
	var resolution: StreamResolution = .p1080
	var fps: Int = 60
	var bitrateMbps: Int = 30
	var codec: VideoCodecChoice = .h265
	var hdr: Bool = false
	var displayMode: DisplayMode = .fit
	var sharpUpscaling: Bool = true
	var showStats: Bool = false
	/// Phone gyro for controllers without motion sensors (e.g. GameSir G8+)
	var phoneMotion: Bool = true
	var rumble: Bool = true
	/// Use the controller's Select/View button as the DualSense touchpad click
	var selectIsTouchpad: Bool = false
	/// Keep a ProMotion screen at 120 Hz while streaming, so frames wait less for the next refresh
	var highRefreshDisplay: Bool = true
	var translationSourceLanguage: String = "en-US"
	var translationTargetLanguage: String = "ar"
	var translationRegion: CaptureRegion = .fullScreen
	var translationFontSize: Double = 28
	var translationPositionY: Double = 0.88
	var translationIntervalMs: Int = 250
	var translationTextColor: TranslationColorChoice = .white
	var translationBackgroundColor: TranslationColorChoice = .black
	var translationBackgroundOpacity: Double = 0.72
	var translationTheme: TranslationTheme = .sideScreen

	/// HDR needs HEVC
	var effectiveCodec: VideoCodecChoice { hdr ? .h265 : codec }

	init() {}

	/// Missing keys keep their defaults, so adding a setting doesn't reset the others
	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		let d = StreamSettings()
		resolution = try c.decodeIfPresent(StreamResolution.self, forKey: .resolution) ?? d.resolution
		fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? d.fps
		bitrateMbps = try c.decodeIfPresent(Int.self, forKey: .bitrateMbps) ?? d.bitrateMbps
		codec = try c.decodeIfPresent(VideoCodecChoice.self, forKey: .codec) ?? d.codec
		hdr = try c.decodeIfPresent(Bool.self, forKey: .hdr) ?? d.hdr
		displayMode = try c.decodeIfPresent(DisplayMode.self, forKey: .displayMode) ?? d.displayMode
		sharpUpscaling = try c.decodeIfPresent(Bool.self, forKey: .sharpUpscaling) ?? d.sharpUpscaling
		showStats = try c.decodeIfPresent(Bool.self, forKey: .showStats) ?? d.showStats
		phoneMotion = try c.decodeIfPresent(Bool.self, forKey: .phoneMotion) ?? d.phoneMotion
		rumble = try c.decodeIfPresent(Bool.self, forKey: .rumble) ?? d.rumble
		selectIsTouchpad = try c.decodeIfPresent(Bool.self, forKey: .selectIsTouchpad) ?? d.selectIsTouchpad
		highRefreshDisplay = try c.decodeIfPresent(Bool.self, forKey: .highRefreshDisplay) ?? d.highRefreshDisplay
		translationSourceLanguage = try c.decodeIfPresent(String.self, forKey: .translationSourceLanguage) ?? d.translationSourceLanguage
		translationTargetLanguage = try c.decodeIfPresent(String.self, forKey: .translationTargetLanguage) ?? d.translationTargetLanguage
		translationRegion = try c.decodeIfPresent(CaptureRegion.self, forKey: .translationRegion) ?? d.translationRegion
			translationFontSize = try c.decodeIfPresent(Double.self, forKey: .translationFontSize) ?? d.translationFontSize
			translationPositionY = try c.decodeIfPresent(Double.self, forKey: .translationPositionY) ?? d.translationPositionY
			translationIntervalMs = try c.decodeIfPresent(Int.self, forKey: .translationIntervalMs) ?? d.translationIntervalMs
			translationTextColor = try c.decodeIfPresent(TranslationColorChoice.self, forKey: .translationTextColor) ?? d.translationTextColor
			translationBackgroundColor = try c.decodeIfPresent(TranslationColorChoice.self, forKey: .translationBackgroundColor) ?? d.translationBackgroundColor
			translationBackgroundOpacity = try c.decodeIfPresent(Double.self, forKey: .translationBackgroundOpacity) ?? d.translationBackgroundOpacity
			translationTheme = try c.decodeIfPresent(TranslationTheme.self, forKey: .translationTheme) ?? d.translationTheme
		}
}

@Observable
final class SettingsStore {
	var settings: StreamSettings {
		didSet { save() }
	}

	@ObservationIgnored private let key = "streamSettings"

	init() {
		if let data = UserDefaults.standard.data(forKey: key),
			let decoded = try? JSONDecoder().decode(StreamSettings.self, from: data)
		{
			settings = decoded
		} else {
			settings = StreamSettings()
		}
	}

	private func save() {
		if let data = try? JSONEncoder().encode(settings) {
			UserDefaults.standard.set(data, forKey: key)
		}
	}
}
