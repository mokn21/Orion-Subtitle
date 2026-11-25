import SwiftUI

enum TranslationMode: Hashable {
    case liveRemotePlay
    case independentBlack
    case tvComingSoon
}

extension TranslationMode: Identifiable {
    var id: Self { self }
}

struct TranslationModesView: View {
	let liveAction: () -> Void
	let blackAction: () -> Void
	@State private var selectedMode: TranslationMode?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("الترجمة")
                .font(.title2.bold())
            Text("اختر طريقة عرض الترجمة. يقرأ Orion إطارات Remote Play التي يعرضها داخله، ولا يقرأ شاشة تطبيق آخر.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .environment(\.layoutDirection, .rightToLeft)
            HStack(spacing: 12) {
				modeCard("Live Screen Translation", detail: "OCR من بث Remote Play", icon: "play.tv", mode: .liveRemotePlay, action: liveAction)
				modeCard("Independent Black Screen", detail: "شاشة عربية عالية التباين", icon: "rectangle.fill", mode: .independentBlack, action: blackAction)
				modeCard("TV Mode", detail: "Coming Soon", icon: "tv", mode: .tvComingSoon)
            }
        }
        .padding(.vertical, 8)
        .sheet(item: $selectedMode) { mode in
            TranslationModeDetail(mode: mode)
        }
    }

	private func modeCard(_ title: String, detail: String, icon: String, mode: TranslationMode, action: (() -> Void)? = nil) -> some View {
		Button { action?() } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon).font(.title2)
                Text(title).font(.headline).multilineTextAlignment(.leading)
                Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .padding(14)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
		.disabled(mode == .tvComingSoon || action == nil)
        .overlay(alignment: .topTrailing) {
            if mode == .tvComingSoon { Text("Coming Soon").font(.caption2).padding(6) }
        }
    }
}

private struct TranslationModeDetail: View {
    let mode: TranslationMode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 16) {
                    Image(systemName: icon).font(.system(size: 42))
                    Text(title).font(.title2.bold())
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 560)
                }
                .padding(32)
                .environment(\.layoutDirection, .rightToLeft)
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("إغلاق") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }

    private var title: String {
        switch mode {
        case .liveRemotePlay: return "Live Screen Translation"
        case .independentBlack: return "Independent Black Translation Screen"
        case .tvComingSoon: return "TV Mode"
        }
    }

    private var icon: String {
        switch mode {
        case .liveRemotePlay: return "play.tv"
        case .independentBlack: return "rectangle.fill"
        case .tvComingSoon: return "tv"
        }
    }

    private var message: String {
        switch mode {
        case .liveRemotePlay: return "ابدأ Remote Play من قائمة الكونسول. سيعالج Orion الإطارات الداخلية باستخدام Vision OCR، ثم يعرض العربية أسفل البث عند توفر Apple Translation."
        case .independentBlack: return "هذه شاشة سوداء مستقلة للترجمة عالية التباين. تحتاج إلى مصدر إطارات مدعوم؛ لا تلتقط شاشة تطبيق آخر ولا تعرض overlay فوقه."
        case .tvComingSoon: return "هذا الوضع غير متاح حاليًا."
        }
    }
}
