import SwiftUI

struct TVLinkSetupView: View {
    @Environment(\.dismiss) private var dismiss
    let publisher: TVLinkPublisher

    @State private var host = UserDefaults.standard.string(forKey: "orion.tv.host") ?? ""
    @State private var port = UserDefaults.standard.string(forKey: "orion.tv.port") ?? "38641"
    @State private var token = UserDefaults.standard.string(forKey: "orion.tv.token") ?? ""

    var body: some View {
        NavigationStack {
            Form {
                Section("بيانات التلفاز") {
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
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("تم") { dismiss() }
                }
            }
        }
    }
}
