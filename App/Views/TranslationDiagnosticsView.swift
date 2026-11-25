import SwiftUI

struct TranslationDiagnosticsView: View {
    private struct SampleResult: Identifiable {
        let id = UUID()
        let source: String
        let target: String?
        let error: String?
        let elapsedMilliseconds: Double
        let phase: String
    }

    let coordinator: TranslationCoordinator
    let bridge: AnyObject?
    @Environment(\.dismiss) private var dismiss
    @State private var results: [SampleResult] = []
    @State private var running = false
    @State private var status = "لم يبدأ الاختبار."
    @State private var elapsedMilliseconds: Double?
    @State private var directStatus = "لم يبدأ الاختبار المباشر."
    @State private var directRunning = false

    private let samples = ["Hello", "Press start", "The door is locked"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    diagnosticCard(title: "حالة OCR", value: coordinator.ocrStatusMessage)
                    diagnosticCard(title: "آخر نص مكتشف", value: coordinator.lastDetectedText.isEmpty ? "لا يوجد نص مكتشف بعد." : coordinator.lastDetectedText)
                    diagnosticCard(title: "حالة الترجمة", value: coordinator.translationStatusMessage)
                    diagnosticCard(title: "آخر خطأ", value: coordinator.lastError ?? "لا يوجد خطأ مسجل.")
                    diagnosticCard(title: "الإطارات المعالجة", value: "\(coordinator.processedFrames) — المتخطاة: \(coordinator.skippedFrames)")
                    diagnosticCard(title: "طلبات الترجمة", value: "أُرسلت: \(coordinator.submittedTranslationCount) — عادت: \(coordinator.returnedTranslationCount)")

                    if #available(iOS 18.0, *), let bridge = bridge as? AppleTranslationBridge {
                        diagnosticCard(title: "أحداث جلسة Apple الأخيرة", value: "\(bridge.diagnosticEvents.count) حدثًا مسجلًا")
                        Text("عدد مرات كل مرحلة").font(.headline)
                        ForEach(AppleTranslationDiagnosticPhase.allCases) { phase in
                            HStack {
                                Text(phase.rawValue)
                                Spacer()
                                Text("\(bridge.diagnosticCounts[phase.rawValue, default: 0])")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                        ForEach(bridge.diagnosticEvents.suffix(20)) { event in
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(event.succeeded == false ? .red : event.succeeded == true ? .green : .yellow)
                                    .frame(width: 8, height: 8)
                                    .padding(.top, 6)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.message)
                                    Text("\(event.phase.rawValue) — \(String(format: "%.0f ms", event.elapsedMilliseconds ?? 0))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    if let details = event.details {
                                        Text(details).font(.caption2).foregroundStyle(.orange)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        }
                        if let failure = bridge.lastFailure {
                            diagnosticCard(title: "الخطأ الأصلي", value: "type=\(failure.typeName)\ndomain=\(failure.domain ?? "غير متوفر")\ncode=\(failure.code.map(String.init) ?? "غير متوفر")\n\(failure.localizedDescription)\n\(failure.userInfo ?? "لا توجد userInfo آمنة")")
                        }
                    }

                    Divider()
                    Text("اختبار مباشر من جلسة TranslationSession")
                        .font(.headline)
                    Text("يتجاوز هذا الاختبار AsyncStream وTranslationCoordinator ويستعمل الجلسة الحالية مباشرة.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("اختبار prepareTranslation") { runDirectPreparation() }
                        Button("ترجمة مباشرة: Hello") { runDirectTranslation() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(directRunning)
                    diagnosticCard(title: "نتيجة الاختبار المباشر", value: directStatus)

                    Divider()
                    Text("اختبار Apple Translation الحقيقي")
                        .font(.headline)
                    Text("يُرسل هذا الاختبار ثلاث جمل إلى Apple Translation. لا توجد نتائج ثابتة؛ عند عدم توفر الجلسة أو النماذج سيظهر سبب الفشل.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .environment(\.layoutDirection, .rightToLeft)
                    Button(running ? "جارٍ الاختبار…" : "اختبار الترجمة") {
                        runTest()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(running)

                    diagnosticCard(title: "حالة الاختبار", value: status)
                    if let elapsedMilliseconds {
                        diagnosticCard(title: "زمن الاختبار", value: String(format: "%.0f مللي ثانية", elapsedMilliseconds))
                    }
                    ForEach(results) { result in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("الإنجليزية: \(result.source)").font(.subheadline.weight(.semibold))
                            Text(result.target.map { "العربية: \($0)" } ?? "فشل: \(result.error ?? "خطأ غير معروف")").font(.body)
                            Text("المرحلة: \(result.phase) — الزمن: \(String(format: "%.0f مللي ثانية", result.elapsedMilliseconds))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(20)
                .environment(\.layoutDirection, .rightToLeft)
            }
            .navigationTitle("تشخيص الترجمة")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("إغلاق") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func diagnosticCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private func runTest() {
        guard !running else { return }
        running = true
        results = []
        status = "جارٍ إرسال النصوص إلى Apple Translation…"
        let started = ContinuousClock.now
        Task {
            do {
                guard #available(iOS 18.0, *), let bridge = bridge as? AppleTranslationBridge else {
                    throw TranslationError.unavailable("اختبار Apple Translation يتطلب iPadOS 18 أو أحدث وجلسة ترجمة مفعلة.")
                }
                var output: [SampleResult] = []
                for sample in samples {
                    let startedSample = ContinuousClock.now
                    do {
                        let translated = try await bridge.translate(sample)
                        let finishedSample = ContinuousClock.now
                        output.append(SampleResult(
                            source: sample,
                            target: translated,
                            error: nil,
                            elapsedMilliseconds: Self.elapsedMilliseconds(startedSample, finishedSample),
                            phase: "translateFinished"
                        ))
                    } catch {
                        let finishedSample = ContinuousClock.now
                        output.append(SampleResult(
                            source: sample,
                            target: nil,
                            error: error.localizedDescription,
                            elapsedMilliseconds: Self.elapsedMilliseconds(startedSample, finishedSample),
                            phase: bridge.diagnosticEvents.last?.phase.rawValue ?? "failed"
                        ))
                    }
                }
                let finished = ContinuousClock.now
                await MainActor.run {
                    results = output
                    elapsedMilliseconds = Double(started.duration(to: finished).components.seconds) * 1000 + Double(started.duration(to: finished).components.attoseconds) / 1_000_000_000_000_000
                    status = "اكتمل اختبار النصوص الثلاثة؛ راجع نجاح أو فشل كل نص على حدة."
                    running = false
                }
            } catch {
                await MainActor.run {
                    status = error.localizedDescription
                    running = false
                }
            }
        }
    }

    private func runDirectPreparation() {
        guard !directRunning else { return }
        directRunning = true
        directStatus = "جارٍ استدعاء prepareTranslation مباشرة…"
        Task {
            do {
                guard #available(iOS 18.0, *), let bridge = bridge as? AppleTranslationBridge else {
                    throw TranslationError.unavailable("يتطلب الاختبار المباشر iPadOS 18 وجلسة فعالة.")
                }
                try await bridge.directPrepareTranslation()
                await MainActor.run {
                    directStatus = "نجح prepareTranslation المباشر. راجع الأحداث والعدادات."
                    directRunning = false
                }
            } catch {
                await MainActor.run {
                    directStatus = "فشل prepareTranslation: \(error.localizedDescription)"
                    directRunning = false
                }
            }
        }
    }

    private func runDirectTranslation() {
        guard !directRunning else { return }
        directRunning = true
        directStatus = "جارٍ استدعاء session.translate مباشرة…"
        Task {
            do {
                guard #available(iOS 18.0, *), let bridge = bridge as? AppleTranslationBridge else {
                    throw TranslationError.unavailable("يتطلب الاختبار المباشر iPadOS 18 وجلسة فعالة.")
                }
                let translated = try await bridge.directTranslate("Hello")
                await MainActor.run {
                    directStatus = "نجحت الترجمة المباشرة: \(translated)"
                    directRunning = false
                }
            } catch {
                await MainActor.run {
                    directStatus = "فشلت الترجمة المباشرة: \(error.localizedDescription)"
                    directRunning = false
                }
            }
        }
    }

    private static func elapsedMilliseconds(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: end)
        return Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }
}
