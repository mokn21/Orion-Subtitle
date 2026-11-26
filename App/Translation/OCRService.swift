import CoreImage
import CoreVideo
import Foundation
import Vision

final class OCRService {
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
        // The capture preview is horizontally mirrored relative to the
        // decoded pixel buffer. Convert the user's visible left/right selection
        // into the corresponding source-image crop.
        let sourceRegionX = 1.0 - selectedRegion.x - selectedRegion.width
        let cropRect = CGRect(
            x: extent.minX + CGFloat(sourceRegionX) * extent.width,
            y: extent.minY + CGFloat(selectedRegion.y) * extent.height,
            width: CGFloat(selectedRegion.width) * extent.width,
            height: CGFloat(selectedRegion.height) * extent.height
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
            // Restore the mirrored crop's detections to the visible preview
            // coordinate system so the replacement overlay lands on the text.
            let fullFrameBox = CGRect(
                x: 1.0 - CGFloat(selectedRegion.x) - local.maxX * CGFloat(selectedRegion.width),
                y: CGFloat(selectedRegion.y) + local.minY * CGFloat(selectedRegion.height),
                width: local.width * CGFloat(selectedRegion.width),
                height: local.height * CGFloat(selectedRegion.height)
            )
            return OCRTextObservation(text: text, boundingBox: fullFrameBox, confidence: candidate.confidence)
        }
        guard !observations.isEmpty else { return nil }
        return OCRResult(observations: observations, capturedAt: capturedAt, startedAt: startedAt, finishedAt: ContinuousClock.now)
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
