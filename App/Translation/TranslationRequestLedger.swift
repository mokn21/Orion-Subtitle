import Foundation

/// Small, deterministic bookkeeping layer for the single Apple Translation worker.
/// It does not translate text; it records which request IDs are pending, claimed,
/// completed, or returned to the queue after a session replacement.
struct TranslationRequestLedger {
    private(set) var pending: Set<UUID> = []
    private(set) var claimed: Set<UUID> = []
    private(set) var completed: Set<UUID> = []

    mutating func enqueue(_ id: UUID) {
        guard !completed.contains(id) else { return }
        pending.insert(id)
        claimed.remove(id)
    }

    mutating func claim(_ id: UUID) -> Bool {
        guard pending.remove(id) != nil, !completed.contains(id) else { return false }
        claimed.insert(id)
        return true
    }

    mutating func requeue(_ id: UUID) {
        guard !completed.contains(id) else { return }
        claimed.remove(id)
        pending.insert(id)
    }

    @discardableResult
    mutating func complete(_ id: UUID) -> Bool {
        guard !completed.contains(id) else { return false }
        pending.remove(id)
        claimed.remove(id)
        completed.insert(id)
        return true
    }
}
