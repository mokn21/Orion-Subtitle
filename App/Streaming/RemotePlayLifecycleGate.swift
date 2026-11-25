import Foundation

/// Serializes the UI-side lifetime of one Remote Play session.
/// SwiftUI may evaluate a view more than once, but only one lifecycle phase
/// may own a connection attempt at a time.
struct RemotePlayLifecycleGate {
    enum Phase: Equatable {
        case idle
        case starting(UUID)
        case active(UUID)
        case stopping(UUID)
    }

    private(set) var phase: Phase = .idle

    mutating func begin() -> UUID? {
        guard case .idle = phase else { return nil }
        let id = UUID()
        phase = .starting(id)
        return id
    }

    mutating func markActive(_ id: UUID) {
        guard phase == .starting(id) else { return }
        phase = .active(id)
    }

    mutating func beginStop() -> UUID? {
        switch phase {
        case .starting(let id), .active(let id):
            phase = .stopping(id)
            return id
        case .idle, .stopping(_):
            return nil
        }
    }

    mutating func finishStop(_ id: UUID) {
        guard phase == .stopping(id) else { return }
        phase = .idle
    }
}
