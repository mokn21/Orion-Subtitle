import ChiakiKit
import Foundation
import Observation

/// A console that answered a discovery sweep.
struct DiscoveredConsole: Identifiable, Equatable {
	/// Console host ID (its MAC address as hex)
	var id: String
	var name: String
	var host: String
	var ps5: Bool
	var state: HostStatus.State
	var runningApp: String
}

/// Finds PlayStations on the local Wi-Fi by sweeping the subnet with unicast
/// search packets (iOS blocks broadcast without Apple's multicast entitlement).
@Observable
final class LANDiscovery {
	private(set) var consoles: [DiscoveredConsole] = []

	@ObservationIgnored private var handle: OpaquePointer?
	@ObservationIgnored private var context: Unmanaged<Context>?

	private final class Context {
		weak var owner: LANDiscovery?
		init(owner: LANDiscovery) { self.owner = owner }
	}

	var isRunning: Bool { handle != nil }

	func start() {
		guard handle == nil else { return }
		let context = Unmanaged.passRetained(Context(owner: self))
		let handle = ck_discovery_start({ user, status in
			guard let user, let status else { return }
			let context = Unmanaged<Context>.fromOpaque(user).takeUnretainedValue()
			var s = status.pointee
			let state: HostStatus.State =
				switch s.state {
				case CK_HOST_STATE_READY: .ready
				case CK_HOST_STATE_STANDBY: .standby
				default: .unknown
				}
			let found = DiscoveredConsole(
				id: cString(&s.host_id).uppercased(),
				name: cString(&s.host_name),
				host: cString(&s.host_addr),
				ps5: s.ps5,
				state: state,
				runningApp: cString(&s.running_app_name)
			)
			guard !found.id.isEmpty, !found.host.isEmpty else { return }
			DispatchQueue.main.async { [weak owner = context.owner] in
				owner?.record(found)
			}
		}, context.toOpaque())
		if let handle {
			self.handle = handle
			self.context = context
		} else {
			context.release()
			log.error("LAN discovery failed to start")
		}
	}

	func stop() {
		guard let handle else { return }
		// Joins the threads, so no callbacks run after this returns
		ck_discovery_stop(handle)
		self.handle = nil
		context?.release()
		context = nil
	}

	private func record(_ found: DiscoveredConsole) {
		if let index = consoles.firstIndex(where: { $0.id == found.id }) {
			if consoles[index] != found { consoles[index] = found }
		} else {
			consoles.append(found)
		}
	}

	deinit { stop() }
}

/// Reads a fixed-size C char array (imported as a tuple) as a string
private func cString<T>(_ value: inout T) -> String {
	withUnsafeBytes(of: &value) { raw in
		let bytes = raw.bindMemory(to: UInt8.self)
		let end = bytes.firstIndex(of: 0) ?? bytes.count
		return String(decoding: bytes[..<end], as: UTF8.self)
	}
}

extension Console {
	/// Matches the host ID the console reports in discovery replies
	var hostID: String {
		mac.prefix(6).map { String(format: "%02X", $0) }.joined()
	}
}
