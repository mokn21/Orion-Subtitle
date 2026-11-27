import SwiftUI

struct TranslationModesView: View {
    let liveAction: () -> Void
    let blackAction: () -> Void
    let controlAction: () -> Void

    @Environment(TVLinkPublisher.self) private var tvLinkPublisher
    @State private var showingTVSetup = false
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("طرق الترجمة").font(.title2.bold()).foregroundStyle(OrionPalette.cream)
                Text("اختر طريقة تشغيل Orion حسب الشاشة التي تريد استخدامها.")
                    .font(.subheadline).foregroundStyle(OrionPalette.muted)
            }
            LazyVGrid(columns: columns, spacing: 12) {
                modeCard("الترجمة المباشرة", detail: "عرض اللعبة والترجمة فوق النص", icon: "play.tv", action: liveAction)
                modeCard("شاشة الترجمة", detail: "عرض الترجمات فقط", icon: "captions.bubble", action: blackAction)
                modeCard("وضع التحكم", detail: "إدارة القص وOCR والتلفاز دون عرض اللعبة", icon: "slider.horizontal.3", action: controlAction)
                Button { showingTVSetup = true } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "tv").font(.system(size: 25, weight: .semibold)).foregroundStyle(OrionPalette.olive)
                        HStack {
                            Text("Orion TV").font(.headline).foregroundStyle(OrionPalette.cream)
                            Spacer()
                            Circle().fill(tvLinkPublisher.isConnected ? Color.green : OrionPalette.muted).frame(width: 7, height: 7)
                        }
                        Text(tvLinkPublisher.isConnected ? "التلفاز متصل" : "إعداد وربط التلفاز")
                            .font(.caption).foregroundStyle(OrionPalette.muted)
                    }
                    .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
                    .padding(16)
                    .background(OrionPalette.panel, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(OrionPalette.stroke, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showingTVSetup) { TVLinkSetupView(publisher: tvLinkPublisher) }
    }

    private func modeCard(_ title: String, detail: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon).font(.system(size: 25, weight: .semibold)).foregroundStyle(OrionPalette.olive)
                Text(title).font(.headline).foregroundStyle(OrionPalette.cream)
                Text(detail).font(.caption).foregroundStyle(OrionPalette.muted).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            .padding(16)
            .background(OrionPalette.panel, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(OrionPalette.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
