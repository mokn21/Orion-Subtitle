import CoreVideo
import Foundation
import Observation

@MainActor
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
        didSet {
            ocr.sourceLanguage = sourceLanguage
            secondaryCoordinator?.sourceLanguage = sourceLanguage
        }
    }
    var minimumFrameInterval: Duration = .milliseconds(250) {
        didSet { secondaryCoordinator?.minimumFrameInterval = minimumFrameInterval }
    }
    private(set) var secondaryCoordinator: TranslationCoordinator?
    var secondaryEnabled = false {
        didSet {
            guard oldValue != secondaryEnabled else { return }
            if secondaryEnabled, state == .running {
                secondaryCoordinator?.start()
            } else if !secondaryEnabled {
                secondaryCoordinator?.stop()
            }
        }
    }

    private let ocr: OCRService
    private let translator: TextTranslationService
    private let historyStore: TranslationHistoryStore?
    private let historyContext: String?
    private var ocrTask: Task<Void, Never>?
    private var pendingOCRFrame: (pixelBuffer: CVPixelBuffer, capturedAt: ContinuousClock.Instant)?
    private var ocrGeneration: UInt64 = 0
    private var translationTasks: [UInt64: Task<Void, Never>] = [:]
    private var lastSubmittedAt: ContinuousClock.Instant?
    private var lastObservationFingerprint = ""
    private var nextGeneration: UInt64 = 0
    private var cache: [String: String] = [:]
    private var cacheOrder: [String] = []
    private let maximumCachedTranslations = 512

    let appleTranslationBridge: AnyObject?

    init(
        ocr: OCRService = OCRService(),
        translator: TextTranslationService? = nil,
        historyStore: TranslationHistoryStore? = nil,
        historyContext: String? = nil
    ) {
        self.ocr = ocr
        self.historyStore = historyStore
        self.historyContext = historyContext
        self.ocr.sourceLanguage = "en-US"
#if canImport(SwiftUI) && canImport(Translation)
        if #available(iOS 18.0, *) {
            if let translator {
                self.appleTranslationBridge = translator as? AppleTranslationBridge
                self.translator = translator
            } else {
                let bridge = AppleTranslationBridge()
                self.appleTranslationBridge = bridge
                // Prefer Apple's on-device Translation framework. Do not send
                // recognized game text to an external proxy by default.
                self.translator = bridge
            }
        } else {
            self.appleTranslationBridge = nil
            self.translator = translator ?? DefaultTranslationService()
        }
#else
        self.appleTranslationBridge = nil
        self.translator = translator ?? DefaultTranslationService()
#endif
    }

    func configureSecondary(historyContext: String? = nil) {
        guard secondaryCoordinator == nil else { return }
        let secondary = TranslationCoordinator(
            ocr: OCRService(),
            translator: translator,
            historyStore: historyStore,
            historyContext: historyContext
        )
        secondary.sourceLanguage = sourceLanguage
        secondary.minimumFrameInterval = minimumFrameInterval
        secondaryCoordinator = secondary
        if secondaryEnabled, state == .running {
            secondary.start()
        }
    }

	func start() {
        ocrGeneration &+= 1
        ocrTask?.cancel()
        ocrTask = nil
        pendingOCRFrame = nil
        nextGeneration &+= 1
        translationTasks.values.forEach { $0.cancel() }
        translationTasks.removeAll()
        lastObservationFingerprint = ""
		lastError = nil
		ocrStatusMessage = "OCR يعمل وينتظر إطارًا نصيًا."
		translationStatusMessage = "بانتظار نص إنجليزي من OCR."
		state = .running
        if secondaryEnabled { secondaryCoordinator?.start() }
    }

    func pause() {
        ocrGeneration &+= 1
        ocrTask?.cancel()
        ocrTask = nil
        pendingOCRFrame = nil
        state = .paused
        secondaryCoordinator?.pause()
    }

    func stop() {
        ocrGeneration &+= 1
        ocrTask?.cancel()
        ocrTask = nil
        pendingOCRFrame = nil
        nextGeneration &+= 1
        translationTasks.values.forEach { $0.cancel() }
        translationTasks.removeAll()
		state = .stopped
        secondaryCoordinator?.stop()
		lastObservationFingerprint = ""
		visibleEntries = []
		ocrStatusMessage = "تم إيقاف OCR والترجمة."
		translationStatusMessage = "تم إيقاف الترجمة."
    }

    func submit(pixelBuffer: CVPixelBuffer) {
        if secondaryEnabled {
            secondaryCoordinator?.submit(pixelBuffer: pixelBuffer)
        }
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

        // Keep exactly one Vision request in flight. If frames arrive while
        // it runs, retain only the newest frame instead of cancelling work
        // that Vision may already be executing synchronously.
        if ocrTask != nil {
            pendingOCRFrame = (pixelBuffer, now)
            skippedFrames += 1
            return
        }
        startOCRWorker(pixelBuffer: pixelBuffer, capturedAt: now)
    }

    private func startOCRWorker(pixelBuffer: CVPixelBuffer, capturedAt: ContinuousClock.Instant) {
        let generation = ocrGeneration
        let ocr = self.ocr
        ocrTask = Task { [weak self] in
            guard let self else { return }
            var frame = (pixelBuffer: pixelBuffer, capturedAt: capturedAt)

            while !Task.isCancelled, self.ocrGeneration == generation {
                let result = await ocr.recognize(
                    pixelBuffer: frame.pixelBuffer,
                    capturedAt: frame.capturedAt
                )
                guard !Task.isCancelled, self.ocrGeneration == generation else { return }

                if let result {
                    self.ocrStatusMessage = "اكتشف OCR نصًا إنجليزيًا."
                    self.acceptOCR(result)
                } else {
                    self.ocrStatusMessage = "لم يُكتشف نص في آخر إطار."
                }

                guard let newestFrame = self.pendingOCRFrame else { break }
                self.pendingOCRFrame = nil
                frame = newestFrame
            }

            guard self.ocrGeneration == generation else { return }
            self.pendingOCRFrame = nil
            self.ocrTask = nil
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
            var uncachedObservations: [OCRTextObservation] = []
            for observation in observations {
                guard !Task.isCancelled else { return }
                let normalized = Self.normalize(observation.text)
                if let cached = self.cache[normalized] {
                    self.publish(cached, observation: observation, result: result, generation: generation)
                } else {
                    uncachedObservations.append(observation)
                }
            }

            guard !uncachedObservations.isEmpty else {
                self.translationStatusMessage = "اكتملت الترجمة من الذاكرة المؤقتة."
                return
            }

            self.submittedTranslationCount += uncachedObservations.count
            do {
                _ = try await translator.translateBatch(uncachedObservations.map(\.text)) { [weak self] index, translated in
                    guard let self,
                          !Task.isCancelled,
                          generation == self.nextGeneration,
                          uncachedObservations.indices.contains(index) else { return }
                    let observation = uncachedObservations[index]
                    let cleaned = translated.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleaned.isEmpty else { return }
                    self.storeCachedTranslation(cleaned, for: Self.normalize(observation.text))
                    self.returnedTranslationCount += 1
                    self.publish(cleaned, observation: observation, result: result, generation: generation)
                }
                guard !Task.isCancelled else { return }
                self.translationStatusMessage = "اكتملت ترجمة الدفعة."
            } catch {
                guard !Task.isCancelled else { return }
                self.lastObservationFingerprint = ""
                self.lastError = error.localizedDescription
                self.translationStatusMessage = "تعذرت ترجمة الدفعة: \(error.localizedDescription)"
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
        historyStore?.append(
            sourceText: entry.sourceText,
            translatedText: entry.translatedText,
            context: historyContext,
            boundingBox: entry.boundingBox,
            confidence: entry.confidence,
            createdAt: entry.createdAt
        )
	}

    private func storeCachedTranslation(_ translated: String, for key: String) {
        if cache[key] == nil {
            cacheOrder.append(key)
        }
        cache[key] = translated
        if cacheOrder.count > maximumCachedTranslations {
            let excessCount = cacheOrder.count - maximumCachedTranslations
            let expiredKeys = Array(cacheOrder.prefix(excessCount))
            cacheOrder.removeFirst(excessCount)
            for expiredKey in expiredKeys {
                cache[expiredKey] = nil
            }
        }
    }

    private static func normalize(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}
