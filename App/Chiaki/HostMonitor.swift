import ChiakiKit
import Foundation
import Observation

struct HostStatus: Equatable {
	enum State { case unknown, ready, standby }
	var state: State
	var name: String
	var runningApp: String
}

/// Polls registered consoles over unicast UDP so the list can show Ready/Standby/Offline.
@Observable
final class HostMonitor {
	private(set) var statuses: [UUID: HostStatus] = [:]

	@ObservationIgnored private var monitors: [UUID: (handle: OpaquePointer, context: Unmanaged<Context>, host: String)] = [:]

	private final class Context {
		let id: UUID
		weak var owner: HostMonitor?
		init(id: UUID, owner: HostMonitor) {
			self.id = id
			self.owner = owner
		}
	}

	func sync(with consoles: [Console]) {
		let wanted = Dictionary(consoles.map { ($0.id, $0.host) }, uniquingKeysWith: { a, _ in a })
		// Drop removed consoles, and restart ones whose IP changed
		for (id, monitor) in monitors where wanted[id] != monitor.host {
			stop(id)
		}
		for console in consoles where monitors[console.id] == nil {
			let context = Unmanaged.passRetained(Context(id: console.id, owner: self))
			let handle = ck_host_monitor_start(console.host, { user, status in
				guard let user, let status else { return }
				let context = Unmanaged<Context>.fromOpaque(user).takeUnretainedValue()
				let s = status.pointee
				let state: HostStatus.State =
					switch s.state {
					case CK_HOST_STATE_READY: .ready
					case CK_HOST_STATE_STANDBY: .standby
					default: .unknown
					}
				var copy = s
				let name = withUnsafeBytes(of: &copy.host_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
				let app = withUnsafeBytes(of: &copy.running_app_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
				let id = context.id
				DispatchQueue.main.async { [weak owner = context.owner] in
					owner?.statuses[id] = HostStatus(state: state, name: name, runningApp: app)
				}
			}, context.toOpaque())
			if let handle {
				monitors[console.id] = (handle, context, console.host)
			} else {
				context.release()
			}
		}
	}

	func stopAll() {
		for id in monitors.keys { stop(id) }
	}

	private func stop(_ id: UUID) {
		guard let (handle, context, _) = monitors.removeValue(forKey: id) else { return }
		// Joins the discovery thread, so no callbacks run after this returns.
		ck_host_monitor_stop(handle)
		context.release()
		statuses[id] = nil
	}

	deinit { stopAll() }
}

enum ConsoleWaker {
	static func wake(_ console: Console) -> Bool {
		console.registKey.withUnsafeBytes { raw in
			guard raw.count == 16 else { return false }
			return ck_wakeup(console.host, raw.bindMemory(to: UInt8.self).baseAddress, console.ps5) == 0
		}
	}
}
