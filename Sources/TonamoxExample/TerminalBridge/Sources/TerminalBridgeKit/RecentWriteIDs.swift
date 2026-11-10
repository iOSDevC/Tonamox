import Foundation
import Synchronization

/// Bounded LRU of write ids already typed. Shared across connections for the life of the
/// helper process and seeded at startup from the journal, so a retried id is never typed twice.
public final class RecentWriteIDs: Sendable {
    private struct Entries {
        var order: [UUID] = []
        var members: Set<UUID> = []
    }

    public let capacity: Int
    private let storage = Mutex(Entries())

    /// `seed` is oldest first; only the last `capacity` ids are kept.
    public init(capacity: Int = BridgeConstants.recentWriteCapacity, seed: [UUID] = []) {
        self.capacity = max(1, capacity)
        storage.withLock { storage in
            for id in seed {
                Self.insert(id, into: &storage, capacity: self.capacity)
            }
        }
    }

    public var count: Int {
        storage.withLock { $0.order.count }
    }

    public func contains(_ id: UUID) -> Bool {
        storage.withLock { $0.members.contains(id) }
    }

    public func insert(_ id: UUID) {
        storage.withLock { Self.insert(id, into: &$0, capacity: capacity) }
    }

    private static func insert(_ id: UUID, into storage: inout Entries, capacity: Int) {
        if storage.members.contains(id) {
            storage.order.removeAll { $0 == id }
        }
        storage.order.append(id)
        storage.members.insert(id)
        while storage.order.count > capacity {
            storage.members.remove(storage.order.removeFirst())
        }
    }
}
