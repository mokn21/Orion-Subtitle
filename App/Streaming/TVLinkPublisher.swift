import Foundation
import Network
import Observation

/// Sends already-translated OCR entries to a paired Orion TV receiver.
/// Coordinates remain Vision-normalized (bottom-left origin) and are never
/// derived from the iPad view's point-space layout.
@MainActor
@Observable
final class TVLinkPublisher {
    private(set) var status = "غير متصل"
    private(set) var isConnected = false

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.orion.subtitles.tv-link")
    private var pairingToken = ""
    private var latestEntries: [TranslationEntry] = []
    private var sentIDs = Set<String>()
    private var receiveBuffer = ""

    func connect(host: String, portText: String, token: String) {
        disconnect()
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty,
              let rawPort = UInt16(portText),
              let port = NWEndpoint.Port(rawValue: rawPort),
              !trimmedToken.isEmpty else {
            status = "تحقق من عنوان التلفاز والمنفذ ورمز الاقتران."
            return
        }

        pairingToken = trimmedToken
        UserDefaults.standard.set(trimmedHost, forKey: "orion.tv.host")
        UserDefaults.standard.set(portText, forKey: "orion.tv.port")
        UserDefaults.standard.set(trimmedToken, forKey: "orion.tv.token")
        status = "جارٍ الاتصال بالتلفاز…"

        let candidate = NWConnection(host: NWEndpoint.Host(trimmedHost), port: port, using: .tcp)
        connection = candidate
        candidate.stateUpdateHandler = { [weak self, weak candidate] state in
            guard let candidate else { return }
            Task { @MainActor [weak self] in
                guard let self, self.connection === candidate else { return }
                switch state {
                case .ready:
                    self.status = "تم الاتصال بالشبكة؛ جارٍ التحقق من الاقتران…"
                    self.sendRaw([
                        "type": "hello",
                        "protocol": 1,
                        "token": self.pairingToken
                    ], using: candidate)
                    self.receive(from: candidate)
                case .failed(let error):
                    self.isConnected = false
                    self.status = "فشل الاتصال: \(error.localizedDescription)"
                case .cancelled:
                    self.isConnected = false
                case .waiting(let error):
                    self.status = "بانتظار الشبكة: \(error.localizedDescription)"
                default:
                    break
                }
            }
        }
        candidate.start(queue: queue)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        isConnected = false
        sentIDs.removeAll()
        receiveBuffer = ""
        status = "غير متصل"
    }

    func update(_ entries: [TranslationEntry]) {
        latestEntries = entries
        guard isConnected else { return }
        sendCurrentEntries()
    }

    private func sendCurrentEntries() {
        let current = Dictionary(uniqueKeysWithValues: latestEntries.map { ($0.id.uuidString, $0) })
        for removedID in sentIDs.subtracting(current.keys) {
            send(["type": "subtitle.clear", "id": removedID])
        }
        for (id, entry) in current {
            let box = entry.tvBoundingBox
            send([
                "type": "subtitle.show",
                "id": id,
                "text": entry.translatedText,
                "backgroundColor": entry.backgroundColorHex,
                "rect": [
                    "x": Double(box.minX),
                    "y": Double(box.minY),
                    "width": Double(box.width),
                    "height": Double(box.height)
                ],
                "ttlMs": 350
            ])
        }
        sentIDs = Set(current.keys)
    }

    private func receive(from candidate: NWConnection) {
        candidate.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self, weak candidate] data, _, complete, error in
            guard let candidate else { return }
            Task { @MainActor [weak self] in
                guard let self, self.connection === candidate else { return }
                if let data, !data.isEmpty {
                    self.receiveBuffer += String(decoding: data, as: UTF8.self)
                    while let newline = self.receiveBuffer.firstIndex(of: "\n") {
                        let line = String(self.receiveBuffer[..<newline])
                        self.receiveBuffer = String(self.receiveBuffer[self.receiveBuffer.index(after: newline)...])
                        guard let bytes = line.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { continue }
                        if object["type"] as? String == "hello.ack" {
                            self.isConnected = true
                            self.status = "متصل بالتلفاز"
                            self.send([
                                "type": "style.set",
                                "style": [
                                    "textColor": "#FFFFFFFF",
                                    "backgroundColor": "#FF000000",
                                    "backgroundAlpha": 1.0,
                                    "fontScale": 0.68
                                ]
                            ])
                            self.sendCurrentEntries()
                        } else if object["type"] as? String == "error" {
                            self.isConnected = false
                            self.status = "رفض التلفاز رمز الاقتران."
                            candidate.cancel()
                        }
                    }
                }
                if let error {
                    self.isConnected = false
                    self.status = "انقطع اتصال التلفاز: \(error.localizedDescription)"
                    return
                }
                if !complete { self.receive(from: candidate) }
            }
        }
    }

    private func send(_ object: [String: Any]) {
        guard let connection, isConnected else { return }
        sendRaw(object, using: connection)
    }

    private func sendRaw(_ object: [String: Any], using connection: NWConnection) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isConnected = false
                self.status = "تعذر إرسال الترجمة: \(error.localizedDescription)"
            }
        })
    }
}
