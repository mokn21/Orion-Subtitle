import Foundation
import Observation

enum AppleTranslationDiagnosticPhase: String, CaseIterable, Identifiable {
    case configurationCreated
    case modifierMounted
    case bridgeReceivedByModifier
    case translationTaskStarted
    case translationTaskClosureEnded
    case sessionReceived
    case workerStarted
    case sessionReady
    case requestEnqueued
    case requestConsumed
    case availabilityStarted
    case availabilityFinished
    case preparationStarted
    case preparationFinished
    case requestGateOpened
    case translateStarted
    case translateFinished
    case failed
    case timedOut

    var id: String { rawValue }
}

struct AppleTranslationDiagnosticEvent: Identifiable {
    let id = UUID()
    let phase: AppleTranslationDiagnosticPhase
    let message: String
    let succeeded: Bool?
    let timestamp: Date
    let elapsedMilliseconds: Double?
    let details: String?
}

struct AppleTranslationFailure: Identifiable {
    let id = UUID()
    let phase: AppleTranslationDiagnosticPhase
    let typeName: String
    let domain: String?
    let code: Int?
    let localizedDescription: String
    let userInfo: String?
    let timestamp: Date
}

#if canImport(SwiftUI) && canImport(Translation)
import SwiftUI
import Translation

@available(iOS 18.0, *)
@Observable
final class AppleTranslationBridge: TextTranslationService {
    struct PendingRequest {
        let id: UUID
        let text: String
        let continuation: CheckedContinuation<String, Error>
    }

    let source = Locale.Language(identifier: "en")
    let target = Locale.Language(identifier: "ar")
    var configuration: TranslationSession.Configuration?
    private let requestStream: AsyncStream<PendingRequest>
    private let requestContinuation: AsyncStream<PendingRequest>.Continuation
    private(set) var statusMessage = "لم تبدأ الترجمة بعد."
    private(set) var sessionReady = false
    private(set) var diagnosticEvents: [AppleTranslationDiagnosticEvent] = []
    private(set) var diagnosticCounts: [String: Int] = [:]
    private(set) var lastFailure: AppleTranslationFailure?
    private var diagnosticStartedAt = Date()

    // One stream, one worker. The worker runs inside the structured
    // translationTask action, so SwiftUI cancellation also cancels the Apple
    // session before its view disappears.
    private var sessionGeneration: UInt64 = 0
    private var ledger = TranslationRequestLedger()
    private var pendingRequests: [UUID: PendingRequest] = [:]
    private var readinessWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var availabilityFailure: TranslationError?
    private var activeSession: TranslationSession?
    private var activeGeneration: UInt64?

    init() {
        let pair = AsyncStream<PendingRequest>.makeStream()
        requestStream = pair.stream
        requestContinuation = pair.continuation
        configuration = TranslationSession.Configuration(source: source, target: target)
        record(.configurationCreated, message: "تم إنشاء TranslationSession.Configuration للإنجليزية إلى العربية.", succeeded: true)
    }

    func translate(_ text: String) async throws -> String {
        guard #available(iOS 18.0, *) else {
            throw TranslationError.unavailable("ترجمة Apple المخصصة تتطلب iPadOS 18 أو أحدث؛ التطبيق يبقى متوافقًا مع iPadOS 17.")
        }
        if let availabilityFailure {
            throw availabilityFailure
        }

        let id = UUID()
        do {
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { [weak self] in
                    guard let self else { throw TranslationError.failed("انتهت جلسة الترجمة.") }
                    try await self.waitUntilReady(id: id)
                    return try await self.enqueueAndWait(id: id, text: text)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(20))
                    throw TranslationError.failed("لم تستجب جلسة Apple Translation خلال 20 ثانية. تحقق من الجلسة ونماذج اللغة ثم حاول مرة أخرى.")
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw TranslationError.failed("لم تُرجع جلسة Apple Translation نتيجة.")
                }
                return result
            }
        } catch {
            if error.localizedDescription.contains("20 ثانية") {
                recordFailure(error, phase: .timedOut, message: "انتهت مهلة انتظار جلسة Apple Translation.")
            }
            throw error
        }
    }

    private func enqueueAndWait(id: UUID, text: String) async throws -> String {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let request = PendingRequest(id: id, text: text, continuation: continuation)
                pendingRequests[id] = request
                ledger.enqueue(id)
                record(.requestEnqueued, message: "وصل طلب ترجمة إلى AsyncStream: \(text)", succeeded: true)
                requestContinuation.yield(request)
            }
        }, onCancel: {
            self.cancelRequest(id)
        })
    }

    private func waitUntilReady(id: UUID) async throws {
        if sessionReady { return }
        if let availabilityFailure { throw availabilityFailure }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if sessionReady {
                    continuation.resume()
                } else if let availabilityFailure {
                    continuation.resume(throwing: availabilityFailure)
                } else {
                    readinessWaiters[id] = continuation
                }
            }
        }, onCancel: {
            guard let continuation = readinessWaiters.removeValue(forKey: id) else { return }
            continuation.resume(throwing: TranslationError.failed("أُلغي انتظار جاهزية جلسة Apple Translation."))
        })
    }

    private func cancelRequest(_ id: UUID) {
        guard let request = pendingRequests.removeValue(forKey: id), ledger.complete(id) else { return }
        request.continuation.resume(throwing: TranslationError.failed("أُلغي طلب الترجمة قبل عودة النتيجة."))
    }

    @available(iOS 18.0, *)
    func run(session: TranslationSession) async {
        record(.translationTaskStarted, message: "بدأ translationTask.", succeeded: true)
        record(.sessionReceived, message: "استلم التطبيق TranslationSession فعلية من SwiftUI.", succeeded: true)
        sessionGeneration &+= 1
        let generation = sessionGeneration
        activeSession = session
        activeGeneration = generation
        availabilityFailure = nil
        sessionReady = false
        statusMessage = "جارٍ تشغيل جلسة Apple Translation…"

        // Do not create an unstructured Task here. Apple invalidates a
        // TranslationSession when the attached view disappears or its
        // configuration changes; keeping the session in a detached child task
        // can therefore lead to a fatal error on the next translate call.
        await process(session: session, generation: generation)
    }

    func recordModifierMounted() {
        record(.modifierMounted, message: "تم تركيب AppleTranslationTaskModifier على واجهة Remote Play.", succeeded: true)
        record(.bridgeReceivedByModifier, message: "وصل bridge غير nil إلى AppleTranslationTaskModifier.", succeeded: true)
    }

    func recordTranslationTaskClosureStarted() {
        record(.translationTaskStarted, message: "بدأ closure الخاص بـ translationTask.", succeeded: true)
    }

    func recordTranslationTaskClosureEnded() {
        record(.translationTaskClosureEnded, message: "خرج closure الخاص بـ translationTask أو أُلغي.", succeeded: true)
    }

    @available(iOS 18.0, *)
    private func process(session: TranslationSession, generation: UInt64) async {
        record(.workerStarted, message: "بدأ عامل استهلاك AsyncStream.", succeeded: true)
        record(.sessionReceived, message: "استلمت الجلسة؛ SDK الحالية لا توفر session.isReady أو canRequestDownloads على TranslationSession.", succeeded: true)
        record(.availabilityStarted, message: "جارٍ فحص توفر English إلى Arabic.", succeeded: nil)
        let availability = await LanguageAvailability().status(from: source, to: target)
        record(.availabilityFinished, message: "حالة توفر English إلى Arabic: \(String(describing: availability)).", succeeded: availability == .installed || availability == .supported)
        guard availability == .installed || availability == .supported else {
            let error = TranslationError.unavailable("لا تتوفر ترجمة English إلى العربية على هذا الجهاز. لم تُعرض ترجمة وهمية.")
            recordFailure(error, phase: .availabilityFinished, message: "زوج اللغات غير متاح على الجهاز.")
            availabilityFailure = error
            statusMessage = error.localizedDescription
            failReadinessWaiters(with: error)
            failPending(with: error)
            return
        }

        statusMessage = availability == .installed
            ? "نماذج ترجمة English إلى العربية جاهزة."
            : "نماذج ترجمة English إلى العربية غير مثبتة؛ سيطلب النظام تنزيلها."

        do {
                statusMessage = "جارٍ طلب تنزيل نماذج English إلى العربية…"
                record(.preparationStarted, message: "بدأ prepareTranslation لتنزيل نموذج اللغة.", succeeded: nil)
                try await session.prepareTranslation()
                record(.preparationFinished, message: "انتهى prepareTranslation بنجاح؛ لا توفر SDK قيمة session.isReady.", succeeded: true)
                statusMessage = "تم تنزيل نماذج English إلى العربية وأصبحت جاهزة."
            } catch {
                recordFailure(error, phase: .preparationFinished, message: "فشل prepareTranslation.")
                let failure = TranslationError.failed("تعذر تنزيل نماذج Apple Translation. وافق على التنزيل وتحقق من اتصال الإنترنت ثم حاول مرة أخرى.")
                availabilityFailure = failure
                statusMessage = failure.localizedDescription
                failReadinessWaiters(with: failure)
                failPending(with: failure)
                return
            }

        sessionReady = true
        statusMessage = "جلسة Apple Translation جاهزة للترجمة الإنجليزية إلى العربية."
        record(.sessionReady, message: "اجتازت الجلسة prepareTranslation وأصبحت بوابة الطلبات مفتوحة.", succeeded: true)
        record(.requestGateOpened, message: "فُتحت بوابة الطلبات بعد نجاح prepareTranslation.", succeeded: true, details: "generation=\(generation)")
        let waiters = readinessWaiters
        readinessWaiters.removeAll()
        for waiter in waiters.values { waiter.resume() }

        for await request in requestStream {
            guard generation == sessionGeneration, !Task.isCancelled else {
                // Leave the current stream item available to the replacement
                // worker. The pending continuation is still alive.
                requestContinuation.yield(request)
                return
            }
            guard ledger.claim(request.id) else {
                // A duplicate stream item or an already completed request.
                continue
            }
            record(.requestConsumed, message: "استهلك العامل طلب ترجمة: \(request.text)", succeeded: true, details: "generation=\(generation)")

            do {
                record(.translateStarted, message: "تم استدعاء session.translate.", succeeded: nil)
                let response = try await session.translate(request.text)
                if Task.isCancelled || generation != sessionGeneration {
                    ledger.requeue(request.id)
                    requestContinuation.yield(request)
                    return
                }
                let translatedText = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !translatedText.isEmpty else {
                    throw TranslationError.failed("أعاد Apple Translation نتيجة فارغة؛ لم تُعرض ترجمة وهمية.")
                }
                if ledger.complete(request.id) {
                    pendingRequests.removeValue(forKey: request.id)
                    request.continuation.resume(returning: translatedText)
                    record(.translateFinished, message: "رجعت targetText بنتيجة غير فارغة.", succeeded: true)
                }
            } catch is CancellationError {
                ledger.requeue(request.id)
                requestContinuation.yield(request)
                return
            } catch {
                _ = ledger.complete(request.id)
                pendingRequests.removeValue(forKey: request.id)
                recordFailure(error, phase: .translateFinished, message: "فشل session.translate.")
                request.continuation.resume(throwing: TranslationError.failed(Self.arabicErrorMessage(for: error)))
            }
        }
    }

    private func failPending(with error: TranslationError) {
        let requests = Array(pendingRequests.values)
        pendingRequests.removeAll()
        for request in requests where ledger.complete(request.id) {
            request.continuation.resume(throwing: error)
        }
    }

    private func failReadinessWaiters(with error: TranslationError) {
        let waiters = readinessWaiters
        readinessWaiters.removeAll()
        for waiter in waiters.values {
            waiter.resume(throwing: error)
        }
    }

    private static func arabicErrorMessage(for error: Error) -> String {
        if let translationError = error as? TranslationError, let message = translationError.errorDescription {
            return message
        }
        return "تعذرت ترجمة النص بواسطة Apple Translation. تحقق من توفر نماذج اللغة ثم حاول مرة أخرى."
    }

    private func record(_ phase: AppleTranslationDiagnosticPhase, message: String, succeeded: Bool?, details: String? = nil) {
        diagnosticCounts[phase.rawValue, default: 0] += 1
        let elapsed = Date().timeIntervalSince(diagnosticStartedAt) * 1000
        diagnosticEvents.append(AppleTranslationDiagnosticEvent(
            phase: phase,
            message: message,
            succeeded: succeeded,
            timestamp: Date(),
            elapsedMilliseconds: elapsed,
            details: details
        ))
        if diagnosticEvents.count > 200 { diagnosticEvents.removeFirst(diagnosticEvents.count - 200) }
    }

    func directPrepareTranslation() async throws {
        let session = try await waitForActiveSession()
        let generation = activeGeneration.map(String.init) ?? "none"
        record(.preparationStarted, message: "بدأ اختبار prepareTranslation المباشر.", succeeded: nil, details: "generation=\(generation)")
        do {
            try await session.prepareTranslation()
            record(.preparationFinished, message: "نجح اختبار prepareTranslation المباشر.", succeeded: true, details: "generation=\(generation)")
        } catch {
            recordFailure(error, phase: .preparationFinished, message: "فشل اختبار prepareTranslation المباشر.")
            throw error
        }
    }

    func directTranslate(_ text: String) async throws -> String {
        let session = try await waitForActiveSession()
        let generation = activeGeneration.map(String.init) ?? "none"
        record(.translateStarted, message: "بدأ اختبار session.translate المباشر دون AsyncStream.", succeeded: nil, details: "generation=\(generation)")
        do {
            let response = try await session.translate(text)
            let translated = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !translated.isEmpty else {
                throw TranslationError.failed("أعادت الجلسة المباشرة targetText فارغًا.")
            }
            record(.translateFinished, message: "نجح اختبار session.translate المباشر.", succeeded: true, details: "generation=\(generation)")
            return translated
        } catch {
            recordFailure(error, phase: .translateFinished, message: "فشل اختبار session.translate المباشر.")
            throw error
        }
    }

    private func waitForActiveSession() async throws -> TranslationSession {
        for _ in 0..<200 {
            if let activeSession { return activeSession }
            try await Task.sleep(for: .milliseconds(100))
        }
        let error = TranslationError.failed("انتهت مهلة انتظار sessionReceived؛ لم تصل TranslationSession إلى bridge.")
        recordFailure(error, phase: .timedOut, message: "انتهى انتظار الجلسة للاختبار المباشر.")
        throw error
    }

    private func recordFailure(_ error: Error, phase: AppleTranslationDiagnosticPhase, message: String) {
        let nsError = error as NSError
        let userInfo = Self.sanitizedUserInfo(nsError.userInfo)
        let failure = AppleTranslationFailure(
            phase: phase,
            typeName: String(reflecting: type(of: error)),
            domain: nsError.domain,
            code: nsError.code,
            localizedDescription: nsError.localizedDescription,
            userInfo: userInfo,
            timestamp: Date()
        )
        lastFailure = failure
        record(.failed, message: message, succeeded: false, details: "type=\(failure.typeName); domain=\(failure.domain ?? ""); code=\(failure.code ?? 0); description=\(failure.localizedDescription); userInfo=\(failure.userInfo ?? "")")
    }

    private static func sanitizedUserInfo(_ values: [String: Any]) -> String? {
        let blocked = ["password", "token", "secret", "key", "authorization", "cookie"]
        let safe = values.compactMap { key, value -> String? in
            let lower = key.lowercased()
            guard !blocked.contains(where: { lower.contains($0) }) else { return nil }
            if let value = value as? String { return "\(key)=\(value)" }
            if let value = value as? NSNumber { return "\(key)=\(value)" }
            return "\(key)=\(String(describing: value))"
        }
        return safe.isEmpty ? nil : safe.sorted().joined(separator: "; ")
    }
}
#endif

#if !canImport(SwiftUI) || !canImport(Translation)
final class AppleTranslationBridge {}
#endif

struct DefaultTranslationService: TextTranslationService {
    func translate(_ text: String) async throws -> String {
        throw TranslationError.unavailable("لم يتم تفعيل Apple Translation على إصدار iPadOS الحالي.")
    }
}
