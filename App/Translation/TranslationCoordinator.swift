import CoreVideo
import Foundation
import Observation

@Observable
final class TranslationCoordinator {
    private(set) var state: TranslationState = .stopped
    private(set) var latestEntry: TranslationEntry?
    private(set) var visibleEntries: [TranslationEntry] = []
    private(set) var recentEntries: [TranslationEntry] = []
    private(set) var lastError: String?
	private(set) var processedFrames = 0
	private(set) var skippedFrames = 0
	private(set) var ocrStatusMessage = "لم يبدأ OCR بعد."
	private(set) var lastDetectedText = ""
	private(set) var translationStatusMessage = "لم يُرسل نص إلى الترجمة بعد."
	private(set) var submittedTranslationCount = 0
	private(set) var returnedTranslationCount = 0

    var region: CaptureRegion = .fullScreen {
        didSet { ocr.region = region }
    }
    var sourceLanguage = "en-US" {
        didSet { ocr.sourceLanguage = sourceLanguage }
    }
    var minimumFrameInterval: Duration = .milliseconds(250)

    private let ocr: OCRService
    private let translator: TextTranslationService
    private var ocrTask: Task<Void, Never>?
    private var translationTasks: [UInt64: Task<Void, Never>] = [:]
    private var lastSubmittedAt: ContinuousClock.Instant?
    private var lastObservationFingerprint = ""
    private var nextGeneration: UInt64 = 0
    private var cache: [String: String] = [:]

    let appleTranslationBridge: AnyObject?

    init(ocr: OCRService = OCRService(), translator: TextTranslationService? = nil) {
        self.ocr = ocr
        self.ocr.sourceLanguage = "en-US"
#if canImport(SwiftUI) && canImport(Translation)
        if #available(iOS 18.0, *) {
            let bridge = AppleTranslationBridge()
                self.appleTranslationBridge = bridge
                // Prefer Apple's on-device Translation framework. Do not send
                // recognized game text to an external proxy by default.
                self.translator = translator ?? bridge
        } else {
            self.appleTranslationBridge = nil
            self.translator = translator ?? DefaultTranslationService()
        }
#else
        self.appleTranslationBridge = nil
        self.translator = translator ?? DefaultTranslationService()
#endif
    }

	func start() {
        ocrTask?.cancel()
        ocrTask = nil
        nextGeneration &+= 1
        translationTasks.values.forEach { $0.cancel() }
        translationTasks.removeAll()
        lastObservationFingerprint = ""
		lastError = nil
		ocrStatusMessage = "OCR يعمل وينتظر إطارًا نصيًا."
		translationStatusMessage = "بانتظار نص إنجليزي من OCR."
		state = .running
    }

    func pause() {
        ocrTask?.cancel()
        ocrTask = nil
        state = .paused
    }

    func stop() {
        ocrTask?.cancel()
        ocrTask = nil
        nextGeneration &+= 1
        translationTasks.values.forEach { $0.cancel() }
        translationTasks.removeAll()
		state = .stopped
		lastObservationFingerprint = ""
		visibleEntries = []
		ocrStatusMessage = "تم إيقاف OCR والترجمة."
		translationStatusMessage = "تم إيقاف الترجمة."
    }

    func submit(pixelBuffer: CVPixelBuffer) {
        guard state == .running else {
            skippedFrames += 1
            return
        }
        let now = ContinuousClock.now
        if let lastSubmittedAt, lastSubmittedAt.duration(to: now) < minimumFrameInterval {
            skippedFrames += 1
            return
        }
        lastSubmittedAt = now

        // Only OCR is replaced by a newer frame. A translation already in
        // progress is allowed to finish; its generation controls visibility.
        ocrTask?.cancel()
        let ocr = self.ocr
        ocrTask = Task { [weak self] in
            guard let self else { return }
			guard let result = await ocr.recognize(pixelBuffer: pixelBuffer, capturedAt: now), !Task.isCancelled else {
				self.ocrStatusMessage = "لم يُكتشف نص في آخر إطار."
				return
			}
			self.ocrStatusMessage = "اكتشف OCR نصًا إنجليزيًا."
			self.acceptOCR(result)
        }
    }

		private func acceptOCR(_ result: OCRResult) {
			let observations = result.observations.filter { !Self.normalize($0.text).isEmpty }
			guard !observations.isEmpty else {
				skippedFrames += 1
				return
			}
		// Do not queue a second Core ML/Apple translation while the previous one
		// is still running. Keeping the observation fingerprint unchanged here lets the next
		// OCR frame retry the latest text without building an unbounded backlog.
		guard translationTasks.isEmpty else {
			skippedFrames += 1
			return
		}
            let fingerprint = observations.map { observation in
                let box = observation.boundingBox
                return [
                    Self.normalize(observation.text),
                    String(format: "%.4f", box.minX),
                    String(format: "%.4f", box.minY),
                    String(format: "%.4f", box.width),
                    String(format: "%.4f", box.height)
                ].joined(separator: "|")
            }.joined(separator: "\u{1F}")
            guard fingerprint != lastObservationFingerprint else {
                skippedFrames += 1
                return
            }
            lastObservationFingerprint = fingerprint
			lastDetectedText = result.text
			visibleEntries = []
			processedFrames += 1
	        nextGeneration &+= 1
	        let generation = nextGeneration
	        let translator = self.translator
			translationStatusMessage = "جارٍ تجهيز الترجمة المحلية…"
			let task = Task { [weak self] in
                // Let the synchronous caller register this task before it can
                // finish and remove its generation from the task table.
                await Task.yield()
	            guard let self else { return }
                defer { self.translationTasks[generation] = nil }
			for observation in observations {
				guard !Task.isCancelled else { return }
				let normalized = Self.normalize(observation.text)
				if let cached = self.cache[normalized] {
					self.publish(cached, observation: observation, result: result, generation: generation)
					continue
				}
				self.submittedTranslationCount += 1
				do {
					let translated = try await translator.translate(observation.text)
					guard !Task.isCancelled, !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
					self.cache[normalized] = translated
					self.returnedTranslationCount += 1
					self.translationStatusMessage = "اكتملت الترجمة."
					self.publish(translated, observation: observation, result: result, generation: generation)
				} catch {
					guard !Task.isCancelled else { return }
					self.lastObservationFingerprint = ""
					self.lastError = error.localizedDescription
					self.translationStatusMessage = "تعذرت ترجمة نص مكاني: \(error.localizedDescription)"
				}
			}
	        }
	        translationTasks[generation] = task
	    }

	    private func publish(_ translated: String, observation: OCRTextObservation, result: OCRResult, generation: UInt64) {
        // A late translation may finish, but it must never replace a newer one.
        guard generation == nextGeneration, (state == .running || state == .paused) else { return }
        let finished = ContinuousClock.now
		let entry = TranslationEntry(
	            sourceText: observation.text,
	            translatedText: translated,
	            boundingBox: observation.boundingBox,
	            confidence: observation.confidence,
	            metrics: LatencyMetrics(
	                capturedAt: result.capturedAt,
	                ocrStartedAt: result.startedAt,
	                ocrFinishedAt: result.finishedAt,
                translationFinishedAt: finished,
                displayedAt: ContinuousClock.now
            )
		)
		latestEntry = entry
		visibleEntries.append(entry)
		recentEntries = ([entry] + recentEntries).prefix(6).map { $0 }
	}

    private static func normalize(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}
