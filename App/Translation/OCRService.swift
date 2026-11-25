import CoreVideo
import Foundation
import Vision

final class OCRService {
    var recognitionLevel: VNRequestTextRecognitionLevel = .fast
    var region: CaptureRegion = .fullScreen
    var sourceLanguage = "en-US"
    var minimumConfidence: Float = 0.35

    func recognize(pixelBuffer: CVPixelBuffer, capturedAt: ContinuousClock.Instant = ContinuousClock.now) async -> OCRResult? {
        let startedAt = ContinuousClock.now
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = recognitionLevel
        request.recognitionLanguages = sourceLanguage == "auto" ? [] : [sourceLanguage]
        request.usesLanguageCorrection = false
        let selectedRegion = region.clamped
        request.regionOfInterest = selectedRegion.cgRect

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            log.error("Vision OCR failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        // Vision uses the ROI as a processing hint. Filter the observations a
        // second time so text whose bounding box lies outside the user's saved
        // rectangle can never reach translation.
        let observations = (request.results ?? []).compactMap { observation -> OCRTextObservation? in
            guard selectedRegion.cgRect.contains(CGPoint(x: observation.boundingBox.midX, y: observation.boundingBox.midY)),
                  let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= minimumConfidence else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return OCRTextObservation(text: text, boundingBox: observation.boundingBox, confidence: candidate.confidence)
        }
        guard !observations.isEmpty else { return nil }
        return OCRResult(observations: observations, capturedAt: capturedAt, startedAt: startedAt, finishedAt: ContinuousClock.now)
    }
}

protocol TextTranslationService {
    func translate(_ text: String) async throws -> String
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
