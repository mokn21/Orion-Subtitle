import CoreGraphics
import Foundation

struct OCRTextObservation: Equatable, Identifiable {
    let id: UUID
    let text: String
    /// Vision normalized coordinates. Origin is bottom-left; values are 0...1.
    let boundingBox: CGRect
    let confidence: Float
    let backgroundColorHex: String
    let tvBoundingBox: CGRect
    let visualBrightness: Double?
    var isSelectedMenuItem = false

    init(id: UUID = UUID(), text: String, boundingBox: CGRect, confidence: Float, backgroundColorHex: String = "#000000", tvBoundingBox: CGRect? = nil, visualBrightness: Double? = nil, isSelectedMenuItem: Bool = false) {
        self.id = id
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.backgroundColorHex = backgroundColorHex
        self.tvBoundingBox = tvBoundingBox ?? boundingBox
        self.visualBrightness = visualBrightness
        self.isSelectedMenuItem = isSelectedMenuItem
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
            // Remote Play's iPad preview is horizontally mirrored relative to the decoded pixel buffer.
            // Mirror the complete rectangle so translated Arabic stays over its source text.
            x: origin.x + (1 - visionRect.maxX) * videoSize.width,
            y: origin.y + (1 - visionRect.maxY) * videoSize.height,
            width: visionRect.width * videoSize.width,
            height: visionRect.height * videoSize.height
        )
    }
}

/// Maps the visible crop directly to the decoded pixel buffer and restores
/// crop-local Vision boxes to the same unmirrored full-frame coordinate space.
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

    static func fullFrameRect(for localVisionRect: CGRect, in captureRegion: CaptureRegion) -> CGRect {
        let region = sourcePixelBufferRegion(for: captureRegion)
        return CGRect(
            x: CGFloat(region.x) + localVisionRect.minX * CGFloat(region.width),
            y: CGFloat(region.y) + localVisionRect.minY * CGFloat(region.height),
            width: localVisionRect.width * CGFloat(region.width),
            height: localVisionRect.height * CGFloat(region.height)
        )
    }

    /// Retains the legacy TV coordinate convention independently from the
    /// corrected iPad preview coordinates. The TV's displayed placement stays stable.
    static func tvFrameRect(for localVisionRect: CGRect, in captureRegion: CaptureRegion) -> CGRect {
        let region = captureRegion.clamped
        let tvRegionX = 1 - region.x - region.width
        return CGRect(
            x: CGFloat(tvRegionX) + localVisionRect.minX * CGFloat(region.width),
            y: CGFloat(region.y) + localVisionRect.minY * CGFloat(region.height),
            width: localVisionRect.width * CGFloat(region.width),
            height: localVisionRect.height * CGFloat(region.height)
        )
    }
}

struct TranslationEntry: Identifiable, Equatable {
    let id = UUID()
    let sourceText: String
    let translatedText: String
    /// The original text position in Vision normalized coordinates.
    var boundingBox: CGRect
    var confidence: Float
    var backgroundColorHex: String = "#000000"
    var tvBoundingBox: CGRect = .zero
    var lastSeenAt = Date()
    var isSelectedMenuItem = false
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

/// Conservative visual detector for game-menu focus.
/// It compares aligned OCR rows within one frame and requires the same
/// enlarged + brighter candidate to persist across consecutive OCR frames.
struct MenuSelectionDetector {
    private var activeKeys: [Int: String] = [:]
    private var pendingKeys: [Int: String] = [:]
    private var pendingCounts: [Int: Int] = [:]
    private var emptyFrameCounts: [Int: Int] = [:]

    mutating func annotate(_ observations: [OCRTextObservation]) -> [OCRTextObservation] {
        var output = observations.map { observation -> OCRTextObservation in
            var copy = observation
            copy.isSelectedMenuItem = false
            return copy
        }
        var seenGroups = Set<Int>()
        for indices in alignedGroups(in: observations) {
            guard indices.count >= 2, indices.count <= 10 else { continue }
            let groupID = groupIdentifier(for: indices, in: observations)
            seenGroups.insert(groupID)
            let heights = indices.map { Double(observations[$0].boundingBox.height) }.sorted()
            let brightnessValues = indices.compactMap { observations[$0].visualBrightness }.sorted()
            guard heights.count == indices.count, brightnessValues.count == indices.count,
                  let medianHeight = median(heights), medianHeight > 0,
                  let medianBrightness = median(brightnessValues) else {
                ageOutSelection(for: groupID)
                continue
            }
            let candidates = indices.filter { index in
                let observation = observations[index]
                let ratio = Double(observation.boundingBox.height) / medianHeight
                guard let brightness = observation.visualBrightness else { return false }
                return ratio >= 1.08 && brightness >= medianBrightness + 0.06
            }
            if let winner = candidates.max(by: {
                score($0, medianHeight, medianBrightness, observations) <
                score($1, medianHeight, medianBrightness, observations)
            }) {
                let key = itemIdentifier(observations[winner])
                if pendingKeys[groupID] == key {
                    pendingCounts[groupID, default: 0] += 1
                } else {
                    pendingKeys[groupID] = key
                    pendingCounts[groupID] = 1
                }
                emptyFrameCounts[groupID] = 0
                if pendingCounts[groupID, default: 0] >= 2 { activeKeys[groupID] = key }
            } else {
                ageOutSelection(for: groupID)
            }
            if let activeKey = activeKeys[groupID] {
                for index in indices where itemIdentifier(observations[index]) == activeKey {
                    output[index].isSelectedMenuItem = true
                }
            }
        }
        for groupID in activeKeys.keys where !seenGroups.contains(groupID) {
            ageOutSelection(for: groupID)
        }
        return output
    }

    private mutating func ageOutSelection(for groupID: Int) {
        emptyFrameCounts[groupID, default: 0] += 1
        pendingKeys[groupID] = nil
        pendingCounts[groupID] = 0
        if emptyFrameCounts[groupID, default: 0] >= 3 {
            activeKeys[groupID] = nil
            emptyFrameCounts[groupID] = 0
        }
    }

    private func alignedGroups(in observations: [OCRTextObservation]) -> [[Int]] {
        var remaining = Set(observations.indices)
        var groups: [[Int]] = []
        while let seed = remaining.first {
            remaining.remove(seed)
            var group = [seed]
            var frontier = [seed]
            while let current = frontier.popLast() {
                let box = observations[current].boundingBox
                let neighbours = remaining.filter { candidate in
                    let other = observations[candidate].boundingBox
                    return abs(box.minX - other.minX) <= 0.065 ||
                        abs(box.midX - other.midX) <= 0.065
                }
                for neighbour in neighbours {
                    remaining.remove(neighbour)
                    group.append(neighbour)
                    frontier.append(neighbour)
                }
            }
            if group.count >= 2 { groups.append(group) }
        }
        return groups
    }

    private func groupIdentifier(for indices: [Int], in observations: [OCRTextObservation]) -> Int {
        let left = indices.map { Double(observations[$0].boundingBox.minX) }
        let centre = indices.map { Double(observations[$0].boundingBox.midX) }
        let leftSpread = (left.max() ?? 0) - (left.min() ?? 0)
        let centreSpread = (centre.max() ?? 0) - (centre.min() ?? 0)
        return Int(((median(leftSpread <= centreSpread ? left : centre) ?? 0) * 20).rounded())
    }

    private func itemIdentifier(_ observation: OCRTextObservation) -> String {
        let normalized = observation.text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return "\(normalized)|\(Int((Double(observation.boundingBox.midY) * 30).rounded()))"
    }

    private func score(_ index: Int, _ medianHeight: Double, _ medianBrightness: Double, _ observations: [OCRTextObservation]) -> Double {
        (Double(observations[index].boundingBox.height) / medianHeight - 1) +
            ((observations[index].visualBrightness ?? medianBrightness) - medianBrightness) * 2
    }

    private func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let middle = values.count / 2
        return values.count.isMultiple(of: 2)
            ? (values[middle - 1] + values[middle]) / 2
            : values[middle]
    }
}
