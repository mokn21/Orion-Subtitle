import SwiftUI

enum OrionPalette {
    static let background = Color(red: 0.098, green: 0.106, blue: 0.094)
    static let panel = Color(red: 0.169, green: 0.180, blue: 0.153)
    static let panelAlt = Color(red: 0.133, green: 0.145, blue: 0.122)
    static let cream = Color(red: 0.973, green: 0.953, blue: 0.851)
    static let muted = Color(red: 0.804, green: 0.780, blue: 0.651)
    static let olive = Color(red: 0.725, green: 0.698, blue: 0.541)
    static let stroke = Color(red: 0.314, green: 0.294, blue: 0.220)
}

struct ConsoleListView: View {
    @Environment(ConsoleStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @State private var monitor = HostMonitor()
    @State private var discovery = LANDiscovery()
    @State private var showingAdd = false
    @State private var showingSettings = false
    @State private var playing: Console?
    @State private var startBlackTranslation = false
    @State private var startControlOnly = false
    @State private var waking: UUID?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    TranslationModesView(
                        liveAction: { startFirstConsole(black: false, controlOnly: false) },
                        blackAction: { startFirstConsole(black: true, controlOnly: false) },
                        controlAction: { startFirstConsole(black: false, controlOnly: true) }
                    )
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("أجهزة PlayStation").font(.title2.bold()).foregroundStyle(OrionPalette.cream)
                            Text("\(store.consoles.count) أجهزة مرتبطة").font(.caption).foregroundStyle(OrionPalette.muted)
                        }
                        Spacer()
                        Button { showingAdd = true } label: {
                            Label("إضافة جهاز", systemImage: "plus")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .background(OrionPalette.olive, in: Capsule())
                                .foregroundStyle(OrionPalette.background)
                        }.buttonStyle(.plain)
                    }
                    if store.consoles.isEmpty {
                        emptyState
                    } else {
                        VStack(spacing: 12) {
                            ForEach(store.consoles) { console in
                                ConsoleRow(
                                    console: console,
                                    status: monitor.statuses[console.id],
                                    waking: waking == console.id,
                                    play: { connect(console) },
                                    wake: { wake(console) }
                                )
                            }
                        }
                    }
                    HStack {
                        Label("ترجمة محلية على الجهاز", systemImage: "lock.shield")
                        Spacer()
                        Text("ORION • 2026")
                    }
                    .font(.caption2).foregroundStyle(OrionPalette.muted)
                    .padding(.top, 4)
                }
                .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 36)
                .frame(maxWidth: 980).frame(maxWidth: .infinity)
            }
            .background(OrionPalette.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingSettings = true } label: { Image(systemName: "gearshape").foregroundStyle(OrionPalette.cream) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAdd = true } label: { Image(systemName: "plus").foregroundStyle(OrionPalette.cream) }
                }
            }
            .sheet(isPresented: $showingAdd, onDismiss: { if playing == nil { discovery.start() } }) {
                AddConsoleView().onAppear { discovery.stop() }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .fullScreenCover(item: $playing) { console in
                StreamView(console: console, startInBlackMode: startBlackTranslation, startInControlMode: startControlOnly)
            }
        }
        .tint(OrionPalette.olive)
        .preferredColorScheme(.dark)
        .onAppear { monitor.sync(with: store.consoles); discovery.start() }
        .onChange(of: store.consoles) { _, consoles in monitor.sync(with: consoles) }
        .onChange(of: playing) { _, playing in
            if playing == nil { monitor.sync(with: store.consoles); discovery.start() }
            else { monitor.stopAll(); discovery.stop() }
        }
        .onChange(of: discovery.consoles) { _, found in
            for console in store.consoles {
                if let match = found.first(where: { $0.id == console.hostID }), match.host != console.host {
                    var updated = console
                    updated.host = match.host
                    store.update(updated)
                }
            }
        }
        .onChange(of: monitor.statuses) { _, statuses in
            if let id = waking, statuses[id]?.state == .ready,
               let console = store.consoles.first(where: { $0.id == id }) {
                waking = nil
                connect(console)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 20).fill(OrionPalette.panelAlt)
                Image(systemName: "captions.bubble.fill").font(.system(size: 34, weight: .medium)).foregroundStyle(OrionPalette.cream)
                Image(systemName: "sparkle").font(.system(size: 13, weight: .bold)).foregroundStyle(OrionPalette.olive).offset(x: 22, y: -23)
            }
            .frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text("ORION").font(.system(size: 27, weight: .bold, design: .rounded)).tracking(3).foregroundStyle(OrionPalette.cream)
                Text("SUBTITLES").font(.system(size: 11, weight: .semibold)).tracking(3).foregroundStyle(OrionPalette.olive)
                Text("ترجمتك أقرب إلى لحظتك").font(.caption).foregroundStyle(OrionPalette.muted)
            }
            Spacer()
            Image(systemName: "sparkles").font(.title2).foregroundStyle(OrionPalette.olive.opacity(0.8))
        }
        .padding(18)
        .background(OrionPalette.panel, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(OrionPalette.stroke, lineWidth: 1))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "playstation.logo").font(.system(size: 36)).foregroundStyle(OrionPalette.olive)
            Text("لم تتم إضافة جهاز بعد").font(.headline).foregroundStyle(OrionPalette.cream)
            Text("اربط جهاز PS5 لبدء Remote Play والترجمة المباشرة.")
                .font(.subheadline).multilineTextAlignment(.center).foregroundStyle(OrionPalette.muted)
            Button("ربط جهاز PlayStation") { showingAdd = true }.buttonStyle(.borderedProminent).tint(OrionPalette.olive)
        }
        .frame(maxWidth: .infinity).padding(28)
        .background(OrionPalette.panel, in: RoundedRectangle(cornerRadius: 20))
    }

    private func connect(_ console: Console) { start(console, black: false, controlOnly: false) }

    private func startFirstConsole(black: Bool, controlOnly: Bool) {
        guard let console = store.consoles.first else { showingAdd = true; return }
        start(console, black: black, controlOnly: controlOnly)
    }

    private func start(_ console: Console, black: Bool, controlOnly: Bool) {
        startBlackTranslation = black
        startControlOnly = controlOnly
        playing = console
    }

    private func wake(_ console: Console) {
        if ConsoleWaker.wake(console) {
            waking = console.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
                if waking == console.id { waking = nil }
            }
        }
    }
}

private struct ConsoleRow: View {
    let console: Console
    let status: HostStatus?
    let waking: Bool
    let play: () -> Void
    let wake: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "playstation.logo").font(.title2).foregroundStyle(OrionPalette.cream)
                .frame(width: 48, height: 48).background(OrionPalette.panelAlt, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text(console.name).font(.headline).foregroundStyle(OrionPalette.cream)
                Text(console.host).font(.caption).foregroundStyle(OrionPalette.muted)
                statusLabel
            }
            Spacer()
            if waking { ProgressView().tint(OrionPalette.olive) }
            else if status?.state == .standby {
                Button("إيقاظ", action: wake).buttonStyle(.bordered).tint(OrionPalette.olive)
            } else {
                Button("تشغيل", action: play).buttonStyle(.borderedProminent).tint(OrionPalette.olive)
                    .disabled(status?.state != .ready && status != nil)
            }
        }
        .padding(16)
        .background(OrionPalette.panel, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(OrionPalette.stroke, lineWidth: 1))
        .environment(\.layoutDirection, .rightToLeft)
    }

    @ViewBuilder private var statusLabel: some View {
        switch status?.state {
        case .ready:
            Label(status?.runningApp.isEmpty == false ? status!.runningApp : "جاهز", systemImage: "circle.fill")
                .font(.caption2).foregroundStyle(.green)
        case .standby:
            Label("وضع الاستعداد", systemImage: "moon.fill").font(.caption2).foregroundStyle(OrionPalette.olive)
        default:
            Label(waking ? "جارٍ الإيقاظ…" : "غير متصل", systemImage: "circle").font(.caption2).foregroundStyle(OrionPalette.muted)
        }
    }
}
