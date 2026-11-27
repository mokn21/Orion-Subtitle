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
    private var visibleExpiryTask: Task<Void, Never>?
    private var lastSubmittedAt: ContinuousClock.Instant?
    private var lastObservationFingerprint = ""
    private var latestOCRObservations: [OCRTextObservation] = []
    private var nextGeneration: UInt64 = 0
    private var cache: [String: String] = [:]
    private var cacheOrder: [String] = []
    private let maximumCachedTranslations = 512
    // A short grace period tolerates a missed OCR frame without leaving stale TV captions.
    private let visibleEntryExpirationInterval: TimeInterval = 0.45

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
        latestOCRObservations = []
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
        visibleExpiryTask?.cancel()
        visibleExpiryTask = nil
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
        latestOCRObservations = []
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
        ocrTask = Task { @MainActor [weak self] in
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
                    self.latestOCRObservations = []
                    self.lastObservationFingerprint = ""
                    self.nextGeneration &+= 1
                    self.pruneExpiredVisibleEntries()
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
            latestOCRObservations = observations
			guard !observations.isEmpty else {
                skippedFrames += 1
                lastObservationFingerprint = ""
                nextGeneration &+= 1
                // Clear captions after an empty OCR frame instead of leaving
                // their last successful translation visible indefinitely.
                pruneExpiredVisibleEntries()
                return
            }
        // Keep translated overlays attached to the latest OCR box. Small
        // per-frame Vision jitter must not invalidate a stable translation.
        refreshVisibleEntryGeometry(with: observations)

        // Do not queue a second translation while the previous one is running.
        guard translationTasks.isEmpty else {
            skippedFrames += 1
            return
        }

        // Text identity is stable; bounding boxes are refreshed independently.
        let fingerprint = observations.map { Self.normalize($0.text) }.joined(separator: "\u{1F}")
        guard fingerprint != lastObservationFingerprint else {
            skippedFrames += 1
            return
        }
        lastObservationFingerprint = fingerprint
			lastDetectedText = result.text
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
            // Translate each distinct normalized string once per OCR frame.
            // Repeated game labels can reuse one result across multiple boxes.
            var uncachedTexts: [String] = []
            var observationsByText: [[OCRTextObservation]] = []
            var indexByText: [String: Int] = [:]

            for observation in observations {
                guard !Task.isCancelled else { return }
                let normalized = Self.normalize(observation.text)
                if let cached = self.cache[normalized] {
                    self.publish(cached, observation: observation, result: result, generation: generation)
                } else if let index = indexByText[normalized] {
                    observationsByText[index].append(observation)
                } else {
                    indexByText[normalized] = uncachedTexts.count
                    uncachedTexts.append(observation.text)
                    observationsByText.append([observation])
                }
            }

            guard !uncachedTexts.isEmpty else {
                self.translationStatusMessage = "اكتملت الترجمة من الذاكرة المؤقتة."
                return
            }

            self.submittedTranslationCount += uncachedTexts.count
            do {
                _ = try await translator.translateBatch(uncachedTexts) { [weak self] index, translated in
                    guard let self,
                          !Task.isCancelled,
                          generation == self.nextGeneration,
                          observationsByText.indices.contains(index) else { return }
                    let matchingObservations = observationsByText[index]
                    let cleaned = translated.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleaned.isEmpty, let first = matchingObservations.first else { return }
                    self.storeCachedTranslation(cleaned, for: Self.normalize(first.text))
                    self.returnedTranslationCount += 1
                    for observation in matchingObservations {
                        self.publish(cleaned, observation: observation, result: result, generation: generation)
                    }
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

	
    private func refreshVisibleEntryGeometry(with observations: [OCRTextObservation]) {
        guard !visibleEntries.isEmpty else { return }
        var usedObservationIndices = Set<Int>()

        visibleEntries = visibleEntries.map { currentEntry in
            let key = Self.normalize(currentEntry.sourceText)
            let candidates = observations.indices.filter {
                guard !usedObservationIndices.contains($0),
                      Self.normalize(observations[$0].text) == key else { return false }
                // Identical words elsewhere on the screen are new observations,
                // not proof that the old caption is still visible.
                let box = observations[$0].boundingBox
                return hypot(box.midX - currentEntry.boundingBox.midX,
                             box.midY - currentEntry.boundingBox.midY) <= 0.12
            }
            guard let bestIndex = candidates.min(by: { lhs, rhs in
                let old = currentEntry.boundingBox
                let left = observations[lhs].boundingBox
                let right = observations[rhs].boundingBox
                let leftDX = left.midX - old.midX
                let leftDY = left.midY - old.midY
                let rightDX = right.midX - old.midX
                let rightDY = right.midY - old.midY
                return leftDX * leftDX + leftDY * leftDY < rightDX * rightDX + rightDY * rightDY
            }) else {
                return currentEntry
            }

            usedObservationIndices.insert(bestIndex)
            var updated = currentEntry
            updated.boundingBox = observations[bestIndex].boundingBox
            updated.confidence = observations[bestIndex].confidence
            updated.lastSeenAt = Date()
            return updated
        }
        pruneExpiredVisibleEntries()
        scheduleVisibleEntryExpiry()
    }

    private func scheduleVisibleEntryExpiry() {
        guard visibleExpiryTask == nil, !visibleEntries.isEmpty else { return }
        visibleExpiryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(75))
                guard let self else { return }
                self.pruneExpiredVisibleEntries()
                if self.visibleEntries.isEmpty {
                    self.visibleExpiryTask = nil
                    return
                }
            }
        }
    }

    private func pruneExpiredVisibleEntries() {
        let now = Date()
        visibleEntries.removeAll { now.timeIntervalSince($0.lastSeenAt) > visibleEntryExpirationInterval }
    }

    private func publish(_ translated: String, observation: OCRTextObservation, result: OCRResult, generation: UInt64) {
        // A result is publishable only while OCR still sees its source text.
        // This prevents a slow translation from appearing after the source vanishes.
        guard generation == nextGeneration,
              (state == .running || state == .paused),
              let currentObservation = Self.currentObservation(for: observation, among: latestOCRObservations)
        else { return }
        let finished = ContinuousClock.now
		let entry = TranslationEntry(
	            sourceText: currentObservation.text,
	            translatedText: translated,
	            boundingBox: currentObservation.boundingBox,
	            confidence: currentObservation.confidence,
	            metrics: LatencyMetrics(
	                capturedAt: result.capturedAt,
	                ocrStartedAt: result.startedAt,
	                ocrFinishedAt: result.finishedAt,
                translationFinishedAt: finished,
                displayedAt: ContinuousClock.now
            )
		)
        let normalizedText = Self.normalize(entry.sourceText)
        let nearestExistingIndex = visibleEntries.indices
            .filter { Self.normalize(visibleEntries[$0].sourceText) == normalizedText }
            .min { lhs, rhs in
                let a = visibleEntries[lhs].boundingBox
                let b = visibleEntries[rhs].boundingBox
                let da = pow(a.midX - entry.boundingBox.midX, 2) + pow(a.midY - entry.boundingBox.midY, 2)
                let db = pow(b.midX - entry.boundingBox.midX, 2) + pow(b.midY - entry.boundingBox.midY, 2)
                return da < db
            }

        var isNewVisibleEntry = true
        if let index = nearestExistingIndex {
            let existing = visibleEntries[index].boundingBox
            let distance = hypot(existing.midX - entry.boundingBox.midX, existing.midY - entry.boundingBox.midY)
            if distance < 0.045 {
                var updated = visibleEntries[index]
                updated.boundingBox = entry.boundingBox
                updated.confidence = entry.confidence
                updated.lastSeenAt = Date()
                visibleEntries[index] = updated
                latestEntry = updated
                isNewVisibleEntry = false
            }
        }

        if isNewVisibleEntry {
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
        scheduleVisibleEntryExpiry()
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

    static func currentObservation(
        for source: OCRTextObservation,
        among observations: [OCRTextObservation]
    ) -> OCRTextObservation? {
        let key = normalize(source.text)
        return observations
            .filter { normalize($0.text) == key }
            .min { lhs, rhs in
                let sourcePoint = source.boundingBox
                let leftDistance = pow(lhs.boundingBox.midX - sourcePoint.midX, 2) +
                    pow(lhs.boundingBox.midY - sourcePoint.midY, 2)
                let rightDistance = pow(rhs.boundingBox.midX - sourcePoint.midX, 2) +
                    pow(rhs.boundingBox.midY - sourcePoint.midY, 2)
                return leftDistance < rightDistance
            }
    }

    private static func normalize(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}
