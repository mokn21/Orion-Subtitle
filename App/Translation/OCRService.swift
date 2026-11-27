import CoreImage
import CoreVideo
import Foundation
import Vision

final class OCRService {
    private static let colorSamplingContext = CIContext(options: [.cacheIntermediates: false])
    var recognitionLevel: VNRequestTextRecognitionLevel = .accurate
    var region: CaptureRegion = .fullScreen
    var sourceLanguage = "en-US"
    var minimumConfidence: Float = 0.55

    func recognize(pixelBuffer: CVPixelBuffer, capturedAt: ContinuousClock.Instant = ContinuousClock.now) async -> OCRResult? {
        let startedAt = ContinuousClock.now
        let selectedRegion = region.clamped
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = recognitionLevel
        request.recognitionLanguages = sourceLanguage == "auto" ? [] : [sourceLanguage]
        request.usesLanguageCorrection = false

        // Crop the actual image before Vision instead of relying on
        // regionOfInterest. This gives OCR a zero-origin image whose
        // observations can be mapped back to the full video deterministically.
        let fullImage = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = fullImage.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        // MetalRenderer displays the decoded frame without a horizontal flip,
        // so the visual crop selection maps directly to pixel-buffer coordinates.
        let sourceRegion = OCRCoordinateMapper.sourcePixelBufferRegion(for: selectedRegion)
        let cropRect = CGRect(
            x: extent.minX + CGFloat(sourceRegion.x) * extent.width,
            y: extent.minY + CGFloat(sourceRegion.y) * extent.height,
            width: CGFloat(sourceRegion.width) * extent.width,
            height: CGFloat(sourceRegion.height) * extent.height
        ).intersection(extent)
        guard !cropRect.isNull, cropRect.width >= 1, cropRect.height >= 1 else { return nil }

        let croppedImage = fullImage
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
        let handler = VNImageRequestHandler(ciImage: croppedImage, orientation: .up, options: [:])
        do {
            try Task.checkCancellation()
            try handler.perform([request])
            try Task.checkCancellation()
        } catch is CancellationError {
            return nil
        } catch {
            log.error("Vision OCR failed: \(String(describing: error), privacy: .public)")
            return nil
        }

        // Vision coordinates are normalized to the cropped image. Restore
        // full-frame coordinates so the overlay remains aligned with the game.
        let observations = (request.results ?? []).compactMap { observation -> OCRTextObservation? in
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= minimumConfidence else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let local = observation.boundingBox
            // Ignore malformed or screen-sized Vision boxes. A single bad
            // observation must never create a giant black overlay.
            guard local.minX.isFinite, local.minY.isFinite,
                  local.width.isFinite, local.height.isFinite,
                  local.width > 0, local.height > 0,
                  local.minX >= 0, local.minY >= 0,
                  local.maxX <= 1.001, local.maxY <= 1.001,
                  local.width <= 0.95, local.height <= 0.30 else { return nil }
            // Crop coordinates are converted back to the original frame.
            // The overlay must never use crop-relative or mirrored coordinates.
            let fullFrameBox = OCRCoordinateMapper.fullFrameRect(for: local, in: selectedRegion)
            let tvFrameBox = OCRCoordinateMapper.tvFrameRect(for: local, in: selectedRegion)
            let sampledBackground = Self.sampleSurroundingColor(in: fullImage, normalizedBox: fullFrameBox, extent: extent)
            return OCRTextObservation(
                text: text,
                boundingBox: fullFrameBox,
                confidence: candidate.confidence,
                backgroundColorHex: sampledBackground,
                tvBoundingBox: tvFrameBox
            )
        }
        guard !observations.isEmpty else { return nil }
        return OCRResult(observations: observations, capturedAt: capturedAt, startedAt: startedAt, finishedAt: ContinuousClock.now)
    }
    private static func sampleSurroundingColor(in image: CIImage, normalizedBox: CGRect, extent: CGRect) -> String {
        let box = CGRect(x: extent.minX + normalizedBox.minX * extent.width, y: extent.minY + normalizedBox.minY * extent.height, width: normalizedBox.width * extent.width, height: normalizedBox.height * extent.height).intersection(extent)
        guard !box.isNull, box.width > 2, box.height > 2 else { return "#000000" }
        let band = max(2, min(box.height * 0.22, extent.height * 0.012))
        let regions = [
            CGRect(x: box.minX, y: box.maxY, width: box.width, height: band),
            CGRect(x: box.minX, y: box.minY - band, width: box.width, height: band),
            CGRect(x: box.minX - band, y: box.minY, width: band, height: box.height),
            CGRect(x: box.maxX, y: box.minY, width: band, height: box.height)
        ].map { $0.intersection(extent) }.filter { !$0.isNull && $0.width >= 1 && $0.height >= 1 }
        var samples: [(Double, Double, Double)] = []
        for rect in regions {
            let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)])
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { buffer in
                guard let address = buffer.baseAddress else { return }
                Self.colorSamplingContext.render(average, toBitmap: address, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            }
            samples.append((Double(pixel[0]), Double(pixel[1]), Double(pixel[2])))
        }
        guard !samples.isEmpty else { return "#000000" }
        let count = Double(samples.count)
        return String(format: "#%02X%02X%02X", Int(samples.reduce(0) { $0 + $1.0 } / count), Int(samples.reduce(0) { $0 + $1.1 } / count), Int(samples.reduce(0) { $0 + $1.2 } / count))
    }

}

protocol TextTranslationService {
    func translate(_ text: String) async throws -> String
    func translateBatch(_ texts: [String]) async throws -> [String]
    func translateBatch(
        _ texts: [String],
        onPartialResult: @escaping @MainActor @Sendable (Int, String) -> Void
    ) async throws -> [String]
}

extension TextTranslationService {
    /// Services without a native batch API retain a correct sequential fallback
    /// while still publishing each completed line immediately.
    func translateBatch(_ texts: [String]) async throws -> [String] {
        try await translateBatch(texts, onPartialResult: { _, _ in })
    }

    func translateBatch(
        _ texts: [String],
        onPartialResult: @escaping @MainActor @Sendable (Int, String) -> Void
    ) async throws -> [String] {
        var translations: [String] = []
        translations.reserveCapacity(texts.count)
        for (index, text) in texts.enumerated() {
            try Task.checkCancellation()
            let translated = try await translate(text)
            translations.append(translated)
            await onPartialResult(index, translated)
        }
        return translations
    }
}

struct UnavailableTranslationService: TextTranslationService {
    let reason: String
    func translate(_ text: String) async throws -> String { throw TranslationError.unavailable(reason) }
}

enum TranslationError: LocalizedError {
    case unavailable(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason), .failed(let reason): return reason
        }
    }
}
