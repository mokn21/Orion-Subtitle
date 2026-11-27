import SwiftUI
import VisionKit
import AVFoundation

struct TVLinkSetupView: View {
    @Environment(\.dismiss) private var dismiss
    let publisher: TVLinkPublisher

    @State private var host = UserDefaults.standard.string(forKey: "orion.tv.host") ?? ""
    @State private var port = UserDefaults.standard.string(forKey: "orion.tv.port") ?? "38641"
    @State private var token = UserDefaults.standard.string(forKey: "orion.tv.token") ?? ""
    @State private var showScanner = false
    @State private var pairingError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("بيانات التلفاز") {
                    Button {
                        showScanner = true
                    } label: {
                        Label("مسح رمز QR من التلفاز", systemImage: "qrcode.viewfinder")
                    }
                    .disabled(!DataScannerViewController.isSupported)

                    TextField("عنوان IP للتلفاز", text: $host)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("المنفذ", text: $port)
                        .keyboardType(.numberPad)
                    SecureField("رمز الاقتران", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Text("اعرض صفحة Orion TV على التلفاز. تأكد أن الآيباد والتلفاز على شبكة Wi‑Fi نفسها، ثم أدخل عنوان IP والمنفذ ورمز الاقتران الظاهر على التلفاز.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("يرسل Orion النص العربي وموقعه فقط؛ لا يرسل صورة اللعبة أو صوتها.")
                    if let pairingError {
                        Text(pairingError).font(.footnote).foregroundStyle(.red)
                    }
                        .font(.footnote)
                }

                Section("حالة الاتصال") {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(publisher.isConnected ? Color.green : Color.secondary)
                            .frame(width: 9, height: 9)
                        Text(publisher.status)
                    }
                    Button("اتصال بالتلفاز") {
                        publisher.connect(host: host, portText: port, token: token)
                    }
                    .disabled(host.isEmpty || port.isEmpty || token.isEmpty)
                    if publisher.isConnected {
                        Button("قطع الاتصال", role: .destructive) {
                            publisher.disconnect()
                        }
                    }
                }
            }
            .navigationTitle("Orion TV Mode")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showScanner) {
                NavigationStack {
                    Group {
                        if DataScannerViewController.isSupported {
                            TVPairingQRScanner { payload in
                                applyPairingPayload(payload)
                            }
                        } else {
                            ContentUnavailableView(
                                "مسح QR غير مدعوم",
                                systemImage: "qrcode",
                                description: Text("يمكنك إدخال عنوان التلفاز ورمز الاقتران يدويًا.")
                            )
                        }
                    }
                    .navigationTitle("مسح رمز Orion TV")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("إلغاء") { showScanner = false }
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("تم") { dismiss() }
                }
            }
        }
    }

    private func requestScannerPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showScanner = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        showScanner = true
                    } else {
                        pairingError = "اسمح لـ Orion باستخدام الكاميرا من إعدادات iPad لمسح رمز التلفاز."
                    }
                }
            }
        default:
            pairingError = "صلاحية الكاميرا غير مفعّلة. اسمح بها من إعدادات iPad أو أدخل بيانات التلفاز يدويًا."
        }
    }

    private func applyPairingPayload(_ payload: String) {
        struct PairingPayload: Decodable {
            let scheme: String
            let version: Int
            let host: String
            let port: Int
            let token: String
        }
        guard let data = payload.data(using: .utf8),
              let pairing = try? JSONDecoder().decode(PairingPayload.self, from: data),
              pairing.scheme == "orion-tv",
              pairing.version == 1,
              !pairing.host.isEmpty,
              !pairing.token.isEmpty,
              (1...65535).contains(pairing.port) else {
            pairingError = "رمز QR غير صالح أو لا ينتمي إلى Orion TV."
            showScanner = false
            return
        }
        host = pairing.host
        port = String(pairing.port)
        token = pairing.token
        pairingError = nil
        showScanner = false
        publisher.connect(host: host, portText: port, token: token)
    }
}
