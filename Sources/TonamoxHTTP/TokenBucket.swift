import Foundation

/// `capacity` tokens, refilled continuously at `capacity` per `period`. Time is passed in, never read.
package struct TokenBucket: Sendable, Equatable {
    package let capacity: Int
    package let period: Duration
    private var available: Double
    private var updatedAt: ContinuousClock.Instant

    package init(capacity: Int, per period: Duration, now: ContinuousClock.Instant) {
        self.capacity = capacity
        self.period = period
        self.available = Double(capacity)
        self.updatedAt = now
    }

    /// Takes one token if there is one.
    package mutating func take(now: ContinuousClock.Instant) -> Bool {
        refill(now: now)
        guard available >= 1 else { return false }
        available -= 1
        return true
    }

    package mutating func remaining(now: ContinuousClock.Instant) -> Int {
        refill(now: now)
        return Int(available)
    }

    private mutating func refill(now: ContinuousClock.Instant) {
        guard now > updatedAt else { return }
        let elapsed = (now - updatedAt) / period
        available = min(Double(capacity), available + elapsed * Double(capacity))
        updatedAt = now
    }
}

/// One ``TokenBucket`` per key, created full on first use. Full buckets are dropped by ``prune(now:)``, which
/// ``take(_:now:)`` runs whenever the table has doubled since the last prune.
package struct KeyedTokenBuckets<Key: Hashable & Sendable>: Sendable {
    package let capacity: Int
    package let period: Duration
    private var buckets: [Key: TokenBucket] = [:]
    private var pruneAt = Self.minimumPruneSize

    package static var minimumPruneSize: Int { 256 }

    package init(capacity: Int, per period: Duration) {
        self.capacity = capacity
        self.period = period
    }

    package var count: Int { buckets.count }

    package mutating func take(_ key: Key, now: ContinuousClock.Instant) -> Bool {
        if buckets[key] == nil, buckets.count >= pruneAt {
            prune(now: now)
            // Doubling keeps pruning amortized O(1) while many keys are still active.
            pruneAt = max(Self.minimumPruneSize, buckets.count * 2)
        }
        var bucket = buckets[key] ?? makeBucket(now: now)
        let allowed = bucket.take(now: now)
        buckets[key] = bucket
        return allowed
    }

    package mutating func prune(now: ContinuousClock.Instant) {
        buckets = buckets.filter { _, bucket in
            var copy = bucket
            return copy.remaining(now: now) < capacity
        }
    }

    private func makeBucket(now: ContinuousClock.Instant) -> TokenBucket {
        TokenBucket(capacity: capacity, per: period, now: now)
    }
}
