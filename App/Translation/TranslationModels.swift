import CoreGraphics
import Foundation

struct OCRTextObservation: Equatable, Identifiable {
    let id: UUID
    let text: String
    /// Vision normalized coordinates. Origin is bottom-left; values are 0...1.
    let boundingBox: CGRect
    let confidence: Float

    init(id: UUID = UUID(), text: String, boundingBox: CGRect, confidence: Float) {
        self.id = id
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
    }
}

struct CaptureRegion: Equatable, Codable {
    /// Vision normalized coordinates: origin is bottom-left, values are 0...1.
    var x: Double = 0
    var y: Double = 0
    var width: Double = 1
    var height: Double = 1

    static let fullScreen = CaptureRegion()

    var clamped: CaptureRegion {
        let safeWidth = min(max(width, 0.05), 1)
        let safeHeight = min(max(height, 0.05), 1)
        return CaptureRegion(
            x: min(max(x, 0), 1 - safeWidth),
            y: min(max(y, 0), 1 - safeHeight),
            width: safeWidth,
            height: safeHeight
        )
    }

    var cgRect: CGRect {
        let r = clamped
        return CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
    }
}

struct LatencyMetrics: Equatable {
    var capturedAt: ContinuousClock.Instant?
    var ocrStartedAt: ContinuousClock.Instant?
    var ocrFinishedAt: ContinuousClock.Instant?
    var translationFinishedAt: ContinuousClock.Instant?
    var displayedAt: ContinuousClock.Instant?

    var ocrMilliseconds: Double? { duration(from: ocrStartedAt, to: ocrFinishedAt) }
    var translationMilliseconds: Double? { duration(from: ocrFinishedAt, to: translationFinishedAt) }
    var totalMilliseconds: Double? { duration(from: capturedAt, to: displayedAt) }

    private func duration(from start: ContinuousClock.Instant?, to end: ContinuousClock.Instant?) -> Double? {
        guard let start, let end else { return nil }
        return Double(start.duration(to: end).components.attoseconds) / 1_000_000_000_000_000 +
            Double(start.duration(to: end).components.seconds) * 1000
    }
}

struct OCRResult: Equatable {
    let observations: [OCRTextObservation]
    let capturedAt: ContinuousClock.Instant
    let startedAt: ContinuousClock.Instant
    let finishedAt: ContinuousClock.Instant
    var text: String { observations.map(\.text).joined(separator: " ") }
}

enum VideoCoordinateMapper {
    /// Maps Vision's normalized bottom-left rectangle to the displayed video.
    /// The video is aspect-fitted inside the supplied view, so unused area is
    /// treated as letterboxing and excluded from the returned rectangle.
    static func displayRect(
        for visionRect: CGRect,
        in viewSize: CGSize,
        videoAspect: CGFloat = 16.0 / 9.0,
        mode: DisplayMode = .fit
    ) -> CGRect {
        guard viewSize.width > 0, viewSize.height > 0, videoAspect > 0 else { return .zero }
        let fittedHeight = viewSize.width / videoAspect
        let videoHeight: CGFloat
        switch mode {
        case .fit:
            videoHeight = min(viewSize.height, fittedHeight)
        case .zoom:
            videoHeight = max(viewSize.height, fittedHeight)
        }
        let videoSize = CGSize(width: videoHeight * videoAspect, height: videoHeight)
        let origin = CGPoint(
            x: (viewSize.width - videoSize.width) / 2,
            y: (viewSize.height - videoSize.height) / 2
        )
        return CGRect(
            x: origin.x + (1 - visionRect.maxX) * videoSize.width,
            y: origin.y + (1 - visionRect.maxY) * videoSize.height,
            width: visionRect.width * videoSize.width,
            height: visionRect.height * videoSize.height
        )
    /// Converts a displayed capture region to the horizontally mirrored
/// pixel-buffer region used by the Remote Play decoder.
enum OCRCoordinateMapper {
    static func sourcePixelBufferRegion(for displayedRegion: CaptureRegion) -> CaptureRegion {
        let region = displayedRegion.clamped
        return CaptureRegion(
            x: 1 - region.x - region.width,
            y: region.y,
            width: region.width,
            height: region.height
        )
    }

    /// Converts a crop-local Vision rectangle back to pixel-buffer coordinates.
    /// Keep this space unchanged for the TV publisher; the iPad overlay applies
    /// its own horizontal display transform in VideoCoordinateMapper.
    static func fullFrameRect(for localVisionRect: CGRect, in captureRegion: CaptureRegion) -> CGRect {
        let sourceRegion = sourcePixelBufferRegion(for: captureRegion)
        return CGRect(
            x: CGFloat(sourceRegion.x) + localVisionRect.minX * CGFloat(sourceRegion.width),
            y: CGFloat(sourceRegion.y) + localVisionRect.minY * CGFloat(sourceRegion.height),
            width: localVisionRect.width * CGFloat(sourceRegion.width),
            height: localVisionRect.height * CGFloat(sourceRegion.height)
        )
    }
}   }
}

struct TranslationEntry: Identifiable, Equatable {
    let id = UUID()
    let sourceText: String
    let translatedText: String
    /// The original text position in Vision normalized coordinates.
    var boundingBox: CGRect
    var confidence: Float
    var lastSeenAt = Date()
    let createdAt = Date()
    let metrics: LatencyMetrics
}

enum TranslationState: Equatable {
    case stopped
    case running
    case paused
    case unavailable(String)
    case failed(String)
}
