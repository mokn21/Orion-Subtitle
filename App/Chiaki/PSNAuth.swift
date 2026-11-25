import Foundation

/// PSN sign-in used only to look up the account ID Remote Play registration needs.
/// Same OAuth client and flow as chiaki-ng (gui/include/psnaccountid.h).
enum PSNAuth {
	static let clientID = "ba495a24-818c-472b-b12d-ff231c1b5745"
	private static let clientSecret = "mvaiZkRsAsI1IBkY"
	static let redirectPrefix = "https://remoteplay.dl.playstation.net/remoteplay/redirect"
	private static let tokenURL = URL(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token")!
	private static let scope =
		"psn:clientapp referenceDataService:countryConfig.read pushNotification:webSocket.desktop.connect sessionManager:remotePlaySession.system.update"

	enum Failure: LocalizedError {
		case noCode
		case badResponse(String)

		var errorDescription: String? {
			switch self {
			case .noCode: "Sign-in didn't return a code. Try again."
			case .badResponse(let detail): "PSN rejected the request: \(detail)"
			}
		}
	}

	static var loginURL: URL {
		var c = URLComponents(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/authorize")!
		c.queryItems = [
			.init(name: "service_entity", value: "urn:service-entity:psn"),
			.init(name: "response_type", value: "code"),
			.init(name: "client_id", value: clientID),
			.init(name: "redirect_uri", value: redirectPrefix),
			.init(name: "scope", value: scope),
			.init(name: "request_locale", value: "en_US"),
			.init(name: "ui", value: "pr"),
			.init(name: "service_logo", value: "ps"),
			.init(name: "layout_type", value: "popup"),
			.init(name: "smcid", value: "remoteplay"),
			.init(name: "prompt", value: "always"),
			.init(name: "PlatformPrivacyWs1", value: "minimal"),
			.init(name: "duid", value: deviceUID),
		]
		return c.url!
	}

	/// "0000000700410080" + 16 random bytes as hex, like chiaki_holepunch_generate_client_device_uid
	private static var deviceUID: String {
		let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
		return "0000000700410080" + bytes.map { String(format: "%02x", $0) }.joined()
	}

	static func code(fromRedirect url: URL) -> String? {
		guard url.absoluteString.hasPrefix(redirectPrefix) else { return nil }
		return URLComponents(url: url, resolvingAgainstBaseURL: false)?
			.queryItems?.first(where: { $0.name == "code" })?.value
	}

	/// Pulls the code out of whatever the user pasted: the full redirect URL,
	/// any text containing `code=…`, or just the bare code.
	static func code(fromPasted text: String) -> String? {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return nil }
		if let url = URL(string: trimmed), let code = code(fromRedirect: url), !code.isEmpty {
			return code
		}
		if let range = trimmed.range(of: "code=") {
			let code = trimmed[range.upperBound...].prefix { $0 != "&" && $0 != "#" && !$0.isWhitespace }
			return code.isEmpty ? nil : String(code).removingPercentEncoding ?? String(code)
		}
		// A bare code: no spaces, no URL punctuation
		let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
		if trimmed.count >= 4, trimmed.unicodeScalars.allSatisfy(allowed.contains) {
			return trimmed
		}
		return nil
	}

	/// Exchanges the redirect code for a token, then returns the base64 account ID.
	static func accountID(forCode code: String) async throws -> String {
		var form = URLComponents()
		form.queryItems = [
			.init(name: "grant_type", value: "authorization_code"),
			.init(name: "code", value: code),
			.init(name: "scope", value: scope),
			.init(name: "redirect_uri", value: redirectPrefix),
		]
		var request = URLRequest(url: tokenURL)
		request.httpMethod = "POST"
		request.setValue(basicAuth, forHTTPHeaderField: "Authorization")
		request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
		// URLComponents leaves '+' alone, which form decoding treats as a space
		request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
		let token = try await json(request)
		guard let accessToken = token["access_token"] as? String else {
			throw Failure.badResponse("no access token")
		}

		var infoRequest = URLRequest(url: tokenURL.appendingPathComponent(accessToken))
		infoRequest.setValue(basicAuth, forHTTPHeaderField: "Authorization")
		infoRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
		let info = try await json(infoRequest)
		let userID: UInt64? =
			if let s = info["user_id"] as? String { UInt64(s) } else { (info["user_id"] as? NSNumber)?.uint64Value }
		guard let userID else { throw Failure.badResponse("no user ID") }
		return encode(userID: userID)
	}

	/// The registration account ID is the numeric user ID as 8 little-endian bytes, base64 encoded.
	static func encode(userID: UInt64) -> String {
		withUnsafeBytes(of: userID.littleEndian) { Data($0) }.base64EncodedString()
	}

	private static var basicAuth: String {
		"Basic " + Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
	}

	private static func json(_ request: URLRequest) async throws -> [String: Any] {
		let (data, response) = try await URLSession.shared.data(for: request)
		let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
		if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
			let detail = object["error_description"] as? String ?? object["error"] as? String ?? "HTTP \(http.statusCode)"
			throw Failure.badResponse(detail)
		}
		return object
	}
}
