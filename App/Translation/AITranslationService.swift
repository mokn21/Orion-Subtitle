import Foundation

/// Calls the Orion translation proxy. The Gemini key never enters the iPad app.
struct ExternalAITranslationService: TextTranslationService {
    private let endpoint: URL
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        let configured = Bundle.main.object(forInfoDictionaryKey: "TRANSLATION_PROXY_URL") as? String
        self.endpoint = URL(string: configured?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? URL(string: "https://invalid.orion-subtitles.invalid/translate")!
    }

    func translate(_ text: String) async throws -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw TranslationError.failed("لا يوجد نص لإرساله إلى الترجمة الخارجية.")
        }
        guard endpoint.host != "invalid.orion-subtitles.invalid" else {
            throw TranslationError.unavailable("لم يتم إعداد خادم الترجمة الخارجية بعد.")
        }
        guard cleaned.count <= 500 else {
            throw TranslationError.failed("النص الملتقط أطول من الحد المسموح للترجمة الخارجية.")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("OrionSubtitles/1", forHTTPHeaderField: "X-Orion-Client")
        request.httpBody = try JSONEncoder().encode(TranslationProxyRequest(
            text: cleaned,
            sourceLanguage: "en",
            targetLanguage: "ar"
        ))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranslationError.failed("استجابة خادم الترجمة غير صالحة.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(TranslationProxyError.self, from: data).error)
                ?? "HTTP \(http.statusCode)"
            throw TranslationError.failed("خادم الترجمة الخارجية: \(message)")
        }

        let result = try JSONDecoder().decode(TranslationProxyResponse.self, from: data)
        let translated = result.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translated.isEmpty else {
            throw TranslationError.failed("أعاد خادم الترجمة نتيجة فارغة.")
        }
        return translated
    }
}

private struct TranslationProxyRequest: Encodable {
    let text: String
    let sourceLanguage: String
    let targetLanguage: String
}

private struct TranslationProxyResponse: Decodable {
    let translation: String
}

private struct TranslationProxyError: Decodable {
    let error: String
}

/// Keeps the existing Apple Translation fallback while the external proxy is unavailable.
struct TranslationFallbackService: TextTranslationService {
    let primary: TextTranslationService
    let fallback: TextTranslationService

    func translate(_ text: String) async throws -> String {
        do {
            return try await primary.translate(text)
        } catch {
            return try await fallback.translate(text)
        }
    }
}
