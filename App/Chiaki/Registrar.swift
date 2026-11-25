import ChiakiKit
import Foundation

enum RegistrationError: LocalizedError {
	case invalidAccountID
	case couldNotStart
	case failed(String)

	var errorDescription: String? {
		switch self {
		case .invalidAccountID: "The PSN account ID should be the base64 value (8 bytes), for example \"AbCdEfGhIjk=\"."
		case .couldNotStart: "Couldn't start registration."
		case .failed(let message): message
		}
	}
}

/// Links this phone to a console using the PIN from Settings > System > Remote Play > Link Device.
enum Registrar {
	private final class Context {
		var continuation: CheckedContinuation<CKRegisteredHost, Error>?
		var handle: OpaquePointer?
	}

	/// MainActor so `context.handle` is set before the callback's main-queue hop can read it.
	@MainActor
	static func register(host: String, ps5: Bool, psnAccountIDBase64: String, pin: UInt32) async throws -> CKRegisteredHost {
		guard let accountID = Data(base64Encoded: psnAccountIDBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
			accountID.count == 8
		else { throw RegistrationError.invalidAccountID }

		let context = Context()
		return try await withCheckedThrowingContinuation { continuation in
			context.continuation = continuation
			let user = Unmanaged.passRetained(context).toOpaque()
			let handle = accountID.withUnsafeBytes { raw in
				ck_regist_start(host, ps5, raw.bindMemory(to: UInt8.self).baseAddress, pin, { user, success, host, error in
					guard let user else { return }
					let context = Unmanaged<Context>.fromOpaque(user).takeRetainedValue()
					let result: Result<CKRegisteredHost, Error>
					if success, let host {
						result = .success(host.pointee)
					} else {
						result = .failure(RegistrationError.failed(error.map { String(cString: $0) } ?? "Registration failed"))
					}
					// ck_regist_destroy joins the registration thread, so it must not run on it.
					DispatchQueue.main.async {
						ck_regist_destroy(context.handle)
						context.continuation?.resume(with: result)
						context.continuation = nil
					}
				}, user)
			}
			if let handle {
				context.handle = handle
			} else {
				Unmanaged<Context>.fromOpaque(user).release()
				continuation.resume(throwing: RegistrationError.couldNotStart)
			}
		}
	}
}

extension CKRegisteredHost {
	func console(host: String) -> Console {
		var copy = self
		let name = withUnsafeBytes(of: &copy.server_nickname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
		let registKey = withUnsafeBytes(of: &copy.regist_key) { Data($0) }
		let rpKey = withUnsafeBytes(of: &copy.rp_key) { Data($0) }
		let mac = withUnsafeBytes(of: &copy.server_mac) { Data($0) }
		return Console(name: name.isEmpty ? "PlayStation" : name, host: host, ps5: ps5, registKey: registKey, rpKey: rpKey, mac: mac)
	}
}
