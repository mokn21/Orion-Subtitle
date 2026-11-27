import SwiftUI

struct TranslationModesView: View {
    let liveAction: () -> Void
    let blackAction: () -> Void
    let controlAction: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 5) {
                Text("اختر طريقة الاستخدام").font(.title2.weight(.bold)).foregroundStyle(OrionPalette.cream)
                Text("كل وضع مصمم لطريقة مختلفة لمشاهدة الترجمة والتحكم بها.")
                    .font(.subheadline).foregroundStyle(OrionPalette.muted)
            }
            LazyVGrid(columns: columns, spacing: 14) {
                modeCard(number: "01", eyebrow: "LIVE PLAY", title: "الترجمة المباشرة",
                    detail: "اللعبة أمامك والترجمة تظهر فوق النص في مكانه.",
                    icon: "play.tv.fill", prominent: true, action: liveAction)
                modeCard(number: "02", eyebrow: "SUBTITLE VIEW", title: "شاشة الترجمة",
                    detail: "واجهة هادئة تركز على النصوص المترجمة فقط.",
                    icon: "captions.bubble.fill", prominent: false, action: blackAction)
                modeCard(number: "03", eyebrow: "CONTROL", title: "وضع التحكم",
                    detail: "تحكم في OCR والقص والجلسة دون رسم صورة اللعبة.",
                    icon: "slider.horizontal.3", prominent: false, action: controlAction)
            }
        }
    }

    private func modeCard(number: String, eyebrow: String, title: String, detail: String,
                          icon: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Image(systemName: icon).font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(prominent ? OrionPalette.buttonText : OrionPalette.olive)
                        .frame(width: 44, height: 44)
                        .background(prominent ? OrionPalette.cream.opacity(0.24) : OrionPalette.panelAlt,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Spacer()
                    Text(number).font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(prominent ? OrionPalette.buttonText.opacity(0.7) : OrionPalette.muted)
                    Image(systemName: "arrow.up.left").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(prominent ? OrionPalette.buttonText : OrionPalette.muted)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(LocalizedStringKey(eyebrow)).font(.system(size: 9, weight: .bold)).tracking(1.7)
                        .foregroundStyle(prominent ? OrionPalette.buttonText.opacity(0.72) : OrionPalette.muted)
                    Text(title).font(.headline.weight(.bold))
                        .foregroundStyle(prominent ? OrionPalette.buttonText : OrionPalette.cream)
                    Text(detail).font(.caption)
                        .foregroundStyle(prominent ? OrionPalette.buttonText.opacity(0.82) : OrionPalette.muted)
                        .fixedSize(horizontal: false, vertical: true).lineLimit(3)
                }
                Spacer(minLength: 0)
            }
            .padding(17).frame(maxWidth: .infinity, minHeight: 170, alignment: .leading)
            .background(prominent ? OrionPalette.olive : OrionPalette.panel,
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(prominent ? OrionPalette.olive : OrionPalette.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
