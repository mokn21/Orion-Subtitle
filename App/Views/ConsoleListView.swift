import SwiftUI

struct ConsoleListView: View {
    @Environment(ConsoleStore.self) private var store
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
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        header
                        welcomePanel
                        TranslationModesView(
                            liveAction: { startFirstConsole(black: false, controlOnly: false) },
                            blackAction: { startFirstConsole(black: true, controlOnly: false) },
                            controlAction: { startFirstConsole(black: false, controlOnly: true) }
                        )
                        consoleSection
                        footer
                    }
                    .padding(.horizontal, 26)
                    .padding(.top, 24)
                    .padding(.bottom, 40)
                    .frame(maxWidth: 1180)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: geometry.size.height, alignment: .top)
                }
                .background(OrionPalette.background.ignoresSafeArea())
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingAdd, onDismiss: { if playing == nil { discovery.start() } }) {
                AddConsoleView().onAppear { discovery.stop() }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .fullScreenCover(item: $playing) { console in
                StreamView(console: console, startInBlackMode: startBlackTranslation, startInControlMode: startControlOnly)
            }
        }
        .tint(OrionPalette.olive)
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
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(OrionPalette.olive)
                Image(systemName: "captions.bubble.fill")
                    .font(.system(size: 29, weight: .semibold))
                    .foregroundStyle(OrionPalette.buttonText)
                Image(systemName: "sparkle")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(OrionPalette.buttonText)
                    .offset(x: 21, y: -20)
            }
            .frame(width: 62, height: 62)
            VStack(alignment: .leading, spacing: 3) {
                Text("ORION").font(.system(size: 25, weight: .heavy, design: .rounded)).tracking(2.4).foregroundStyle(OrionPalette.cream)
                Text("SUBTITLES").font(.system(size: 10, weight: .bold)).tracking(3.2).foregroundStyle(OrionPalette.muted)
            }
            Spacer()
            Button { showingSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(OrionPalette.cream)
                    .frame(width: 48, height: 48)
                    .background(OrionPalette.panel, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(OrionPalette.stroke, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("الإعدادات")
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private var welcomePanel: some View {
        HStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                Text("YOUR GAME. YOUR LANGUAGE.")
                    .font(.system(size: 10, weight: .bold)).tracking(2.1).foregroundStyle(OrionPalette.muted)
                Text("ترجم لحظتك،\nوعِش اللعبة.")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(OrionPalette.cream)
                    .fixedSize(horizontal: false, vertical: true)
                Text("ترجمة فورية لنصوص ألعابك، مع تحكم كامل في طريقة العرض.")
                    .font(.subheadline).foregroundStyle(OrionPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button { startFirstConsole(black: false, controlOnly: false) } label: {
                    Label("ابدأ اللعب", systemImage: "play.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(OrionPalette.buttonText)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .background(OrionPalette.olive, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous).fill(OrionPalette.panelAlt).frame(width: 190, height: 150)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(OrionPalette.olive.opacity(0.55), lineWidth: 1.2)
                    .frame(width: 154, height: 112).rotationEffect(.degrees(-7))
                VStack(spacing: 8) {
                    HStack(spacing: 7) {
                        Text("EN")
                        Image(systemName: "arrow.left.arrow.right")
                        Text("AR")
                    }
                    .font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(OrionPalette.olive)
                    Capsule().fill(OrionPalette.stroke.opacity(0.65)).frame(width: 102, height: 5)
                    Capsule().fill(OrionPalette.stroke.opacity(0.35)).frame(width: 76, height: 5)
                    Text("Press to continue").font(.system(size: 9, weight: .medium)).foregroundStyle(OrionPalette.muted)
                    Text("اضغط للمتابعة").font(.system(size: 11, weight: .bold)).foregroundStyle(OrionPalette.cream)
                }
            }
            .accessibilityHidden(true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OrionPalette.panel, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(OrionPalette.stroke, lineWidth: 1))
    }

    private var consoleSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("أجهزتك").font(.title2.weight(.bold)).foregroundStyle(OrionPalette.cream)
                    Text(store.consoles.isEmpty ? "اربط جهاز PlayStation للبدء" : "\(store.consoles.count) أجهزة مرتبطة")
                        .font(.caption).foregroundStyle(OrionPalette.muted)
                }
                Spacer()
                Button { showingAdd = true } label: {
                    Label("إضافة جهاز", systemImage: "plus")
                        .font(.subheadline.weight(.bold)).foregroundStyle(OrionPalette.buttonText)
                        .padding(.horizontal, 15).padding(.vertical, 11)
                        .background(OrionPalette.olive, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            if store.consoles.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 310), spacing: 14)], spacing: 14) {
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
        }
    }

    private var emptyState: some View {
        HStack(spacing: 18) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 28)).foregroundStyle(OrionPalette.olive)
                .frame(width: 58, height: 58)
                .background(OrionPalette.panelAlt, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text("لا توجد أجهزة مرتبطة بعد").font(.headline).foregroundStyle(OrionPalette.cream)
                Text("أضف جهاز PS5 على شبكة Wi-Fi نفسها لبدء Remote Play.")
                    .font(.subheadline).foregroundStyle(OrionPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("ربط جهاز") { showingAdd = true }
                .font(.subheadline.weight(.bold)).foregroundStyle(OrionPalette.buttonText)
                .padding(.horizontal, 15).padding(.vertical, 10)
                .background(OrionPalette.olive, in: Capsule()).buttonStyle(.plain)
        }
        .padding(18)
        .background(OrionPalette.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(OrionPalette.stroke, lineWidth: 1))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
            Text("معالجة محلية • خصوصيتك أولًا")
            Spacer()
            Text("ORION").tracking(2)
        }
        .font(.caption2.weight(.medium)).foregroundStyle(OrionPalette.muted).padding(.top, 4)
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
        HStack(spacing: 13) {
            Image(systemName: "playstation.logo")
                .font(.system(size: 22, weight: .medium)).foregroundStyle(OrionPalette.cream)
                .frame(width: 48, height: 48)
                .background(OrionPalette.panelAlt, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(console.name).font(.headline).foregroundStyle(OrionPalette.cream)
                Text(console.host).font(.caption.monospaced()).foregroundStyle(OrionPalette.muted)
                statusLabel
            }
            Spacer(minLength: 4)
            if waking {
                ProgressView().tint(OrionPalette.olive)
            } else if status?.state == .standby {
                Button("إيقاظ", action: wake).buttonStyle(.bordered).tint(OrionPalette.olive)
            } else {
                Button("تشغيل", action: play).buttonStyle(.borderedProminent).tint(OrionPalette.olive)
                    .disabled(status?.state != .ready && status != nil)
            }
        }
        .padding(16).frame(maxWidth: .infinity, minHeight: 96)
        .background(OrionPalette.panel, in: RoundedRectangle(cornerRadius: 21, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 21, style: .continuous).stroke(OrionPalette.stroke, lineWidth: 1))
    }

    @ViewBuilder private var statusLabel: some View {
        switch status?.state {
        case .ready:
            Label(status?.runningApp.isEmpty == false ? status!.runningApp : "جاهز", systemImage: "circle.fill")
                .font(.caption2).foregroundStyle(.green)
        case .standby:
            Label("وضع الاستعداد", systemImage: "moon.fill").font(.caption2).foregroundStyle(OrionPalette.olive)
        default:
            Label(waking ? "جارٍ الإيقاظ…" : "غير متصل", systemImage: "circle")
                .font(.caption2).foregroundStyle(OrionPalette.muted)
        }
    }
}
