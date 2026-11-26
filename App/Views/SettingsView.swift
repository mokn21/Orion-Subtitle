import SwiftUI

/// Stream settings, shared by the main settings sheet and the in-stream menu.
struct StreamSettingsForm: View {
	@Binding var settings: StreamSettings

	var body: some View {
		Section {
				Picker("الدقة", selection: $settings.resolution) {
				ForEach(StreamResolution.allCases) { Text($0.label).tag($0) }
			}
				Picker("معدل الإطارات", selection: $settings.fps) {
					Text("60 إطارًا/ثانية").tag(60)
					Text("30 إطارًا/ثانية").tag(30)
			}
			VStack(alignment: .leading) {
				HStack {
						Text("معدل البت")
					Spacer()
					Text("\(settings.bitrateMbps) Mbps").foregroundStyle(.secondary).monospacedDigit()
				}
				Slider(value: Binding(get: { Double(settings.bitrateMbps) }, set: { settings.bitrateMbps = Int($0) }), in: 5...100, step: 5)
			}
				Picker("الترميز", selection: $settings.codec) {
				ForEach(VideoCodecChoice.allCases) { Text($0.label).tag($0) }
			}
			.disabled(settings.hdr)
				Toggle("النطاق الديناميكي العالي HDR", isOn: $settings.hdr)
		} header: {
				Text("الفيديو")
		} footer: {
				Text("يدعم PS5 Remote Play حتى 1080p60. قد يخفض PS5 معدل البت عن القيمة المطلوبة. يتطلب HDR ترميز H.265 وتفعيله في إعدادات إخراج الفيديو في PS5. تغيير هذه الخيارات يعيد الاتصال بالبث.")
		}

		Section {
				Picker("طريقة العرض", selection: $settings.displayMode) {
				ForEach(DisplayMode.allCases) { Text($0.label).tag($0) }
			}
				Toggle("تكبير حاد للصورة", isOn: $settings.sharpUpscaling)
			if UIScreen.main.maximumFramesPerSecond > 60 {
					Toggle("شاشة 120 هرتز", isOn: $settings.highRefreshDisplay)
			}
				Toggle("إظهار الإحصاءات", isOn: $settings.showStats)
		} header: {
				Text("العرض")
		} footer: {
				Text("تعرض الملاءمة الصورة كاملة مع أشرطة سوداء عند اختلاف نسبة الشاشة عن 16:9. يملأ التكبير الشاشة ويقص الأطراف الزائدة. قد تستهلك شاشة 120 هرتز بطارية أكثر قليلًا.")
		}

		Section {
			Toggle("Rumble", isOn: $settings.rumble)
			Toggle("Phone gyro for motion controls", isOn: $settings.phoneMotion)
			Toggle("Select button is touchpad click", isOn: $settings.selectIsTouchpad)
		} header: {
				Text("وحدة التحكم")
		} footer: {
				Text("يُستخدم مستشعر حركة iPad عندما لا تحتوي وحدة التحكم على مستشعرات حركة. اضغط Select وStart معًا لمدة ثانية أثناء البث لفتح القائمة.")
		}

	}
}

struct SettingsView: View {
	@Environment(SettingsStore.self) private var store
	@Environment(ConsoleStore.self) private var consoles
	@Environment(TranslationHistoryStore.self) private var translationHistory
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		@Bindable var store = store
		NavigationStack {
			Form {
					StreamSettingsForm(settings: $store.settings, showSecondRegionControls: false)
					TranslationSettingsForm(settings: $store.settings)

                Section {
                    NavigationLink {
                        TranslationHistoryView()
                    } label: {
                        HStack {
                            Label("سجل الترجمات", systemImage: "clock.arrow.circlepath")
                            Spacer()
                            Text("\(translationHistory.entries.count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                } footer: {
                    Text("يُحفظ سجل آخر 1000 ترجمة محليًا على iPad. يمكنك حذف السجل من داخله.")
                }

				Section {
					ShareLink(
						item: DiagnosticsReport(consoleNames: consoles.consoles.map(\.name), settings: store.settings),
							preview: SharePreview("تشخيص Orion Subtitles")
					) {
							Label("مشاركة تقرير التشخيص", systemImage: "ladybug")
					}
					Link(destination: URL(string: "https://github.com/orion-subtitles/orion-subtitles/issues/new")!) {
							Label("الإبلاغ عن مشكلة", systemImage: "exclamationmark.bubble")
					}
				} header: {
						Text("المساعدة")
				} footer: {
						Text("يحتوي التقرير على طراز iPad وتفاصيل الشاشة والإعدادات وسجلات التطبيق منذ فتحه. تُحذف عناوين IP والمفاتيح ومعرّفات الحساب وأسماء الأجهزة. شاركه قبل إغلاق التطبيق حتى تغطي السجلات المشكلة.")
				}
			}
				.navigationTitle("الإعدادات")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
					ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } }
			}
		}
	}
}

private struct TranslationSettingsForm: View {
	@Binding var settings: StreamSettings

	var body: some View {
		Section {
			Picker("لغة النص الأصلي", selection: $settings.translationSourceLanguage) {
				Text("الكشف التلقائي").tag("auto")
				Text("الإنجليزية").tag("en-US")
				Text("الإنجليزية البريطانية").tag("en-GB")
			}
			Picker("لغة الترجمة", selection: $settings.translationTargetLanguage) {
				Text("العربية").tag("ar")
			}
			VStack(alignment: .leading) {
				HStack { Text("حجم الخط"); Spacer(); Text("\(Int(settings.translationFontSize))") }
				Slider(value: $settings.translationFontSize, in: 16...64, step: 1)
			}
			VStack(alignment: .leading) {
				HStack { Text("مكان الترجمة العمودي"); Spacer(); Text("\(Int(settings.translationPositionY * 100))٪") }
				Slider(value: $settings.translationPositionY, in: 0.15...0.92)
			}
				VStack(alignment: .leading) {
					HStack { Text("الفاصل بين فحوص OCR"); Spacer(); Text("\(settings.translationIntervalMs) مللي ثانية") }
					Slider(value: Binding(get: { Double(settings.translationIntervalMs) }, set: { settings.translationIntervalMs = Int($0) }), in: 150...1000, step: 50)
				}
				Picker("لون النص", selection: $settings.translationTextColor) {
					ForEach(TranslationColorChoice.allCases.filter { $0 != .black }) { Text($0.label).tag($0) }
				}
				Picker("لون الخلفية", selection: $settings.translationBackgroundColor) {
					ForEach(TranslationColorChoice.allCases) { Text($0.label).tag($0) }
				}
				VStack(alignment: .leading) {
					HStack { Text("عتامة الخلفية"); Spacer(); Text("\(Int(settings.translationBackgroundOpacity * 100))٪") }
					Slider(value: $settings.translationBackgroundOpacity, in: 0...1)
				}
				Picker("وضع المظهر", selection: $settings.translationTheme) {
					ForEach(TranslationTheme.allCases) { Text($0.label).tag($0) }
				}
				Text("منطقة الالتقاط — اسحب القيم لتحديد المستطيل داخل إطار Remote Play")
			RegionSlider(title: "أفقيًا", value: $settings.translationRegion.x, range: 0...max(0, 1 - settings.translationRegion.width))
			RegionSlider(title: "عموديًا", value: $settings.translationRegion.y, range: 0...max(0, 1 - settings.translationRegion.height))
			RegionSlider(title: "العرض", value: $settings.translationRegion.width, range: 0.1...1)
			RegionSlider(title: "الارتفاع", value: $settings.translationRegion.height, range: 0.1...1)

            Divider()
            Toggle("تفعيل منطقة OCR ثانية مستقلة", isOn: $settings.translationSecondRegionEnabled)
            Text("المنطقة الثانية اختيارية ومعطلة افتراضيًا. تعمل بمسح OCR وذاكرة نتائج مستقلين عن المنطقة الأولى، مع مشاركة محرك الترجمة المحلي.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if settings.translationSecondRegionEnabled {
                RegionSlider(title: "موضع المنطقة الثانية أفقيًا", value: $settings.translationSecondRegion.x, range: 0...max(0, 1 - settings.translationSecondRegion.width))
                RegionSlider(title: "موضع المنطقة الثانية عموديًا", value: $settings.translationSecondRegion.y, range: 0...max(0, 1 - settings.translationSecondRegion.height))
                RegionSlider(title: "عرض المنطقة الثانية", value: $settings.translationSecondRegion.width, range: 0.1...1)
                RegionSlider(title: "ارتفاع المنطقة الثانية", value: $settings.translationSecondRegion.height, range: 0.1...1)
            }
			} header: {
				Text("الترجمة")
			} footer: {
					Text("تُحفظ هذه الإعدادات وتُطبق على OCR والبث التالي. يستخدم التطبيق Apple Translation محليًا. على iPadOS 26.4 أو أحدث يفضّل High Fidelity عند توفره مع الرجوع التلقائي إلى Low Latency؛ وعلى الإصدارات الأقدم يستخدم إعداد الترجمة التقليدي. لا تُرسل النصوص تلقائيًا إلى خادم خارجي.")
			}
	}
}

private struct RegionSlider: View {
	let title: String
	@Binding var value: Double
	let range: ClosedRange<Double>

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			HStack { Text(title); Spacer(); Text(String(format: "%.0f%%", value * 100)).foregroundStyle(.secondary) }
			Slider(value: $value, in: range)
		}
	}
}


private struct TranslationHistoryView: View {
    @Environment(TranslationHistoryStore.self) private var history
    @State private var confirmClear = false

    var body: some View {
        List {
            if history.entries.isEmpty {
                ContentUnavailableView("لا يوجد سجل ترجمات", systemImage: "text.book.closed", description: Text("ستظهر هنا الترجمات التي يعالجها Orion بنجاح."))
            } else {
                ForEach(history.entries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        if let context = entry.context, !context.isEmpty {
                            Text(context)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.sourceText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(entry.translatedText)
                            .font(.body)
                        HStack(spacing: 8) {
                            Text(entry.createdAt, style: .date)
                            Text(entry.createdAt, style: .time)
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
                }
            }
        }
        .navigationTitle("سجل الترجمات")
        .toolbar {
            if !history.entries.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("مسح السجل", role: .destructive) {
                        confirmClear = true
                    }
                }
            }
        }
        .confirmationDialog("هل تريد مسح سجل الترجمات بالكامل؟", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("مسح السجل", role: .destructive) {
                history.clear()
            }
            Button("إلغاء", role: .cancel) {}
        }
    }
}
