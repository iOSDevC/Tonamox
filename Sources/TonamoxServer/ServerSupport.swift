import Foundation
import os
import TonamoxHTTP

/// One log line. `message` is fixed text plus non-secret metadata; `peer` is logged as private.
package struct ServerLogEntry: Sendable, Equatable {
    package let message: String
    package let peer: String?
}

/// The seam in front of `os.Logger`, so tests can read what would be logged. Never pass a credential or content.
package struct ServerLog: Sendable {
    private let sink: @Sendable (ServerLogEntry) -> Void

    package init(sink: @escaping @Sendable (ServerLogEntry) -> Void) {
        self.sink = sink
    }

    package static let system: ServerLog = {
        let logger = Logger(subsystem: "dev.tonamox.server", category: "server")
        return ServerLog { entry in
            logger.info("\(entry.message, privacy: .public) peer=\(entry.peer ?? "-", privacy: .private)")
        }
    }()

    func record(_ message: String, peer: PeerAddress? = nil) {
        sink(ServerLogEntry(message: message, peer: peer?.host))
    }
}

/// Time sources, injectable for tests.
package struct ServerClock: Sendable {
    package var monotonic: @Sendable () -> ContinuousClock.Instant
    package var wall: @Sendable () -> Date

    package init(monotonic: @escaping @Sendable () -> ContinuousClock.Instant,
                 wall: @escaping @Sendable () -> Date) {
        self.monotonic = monotonic
        self.wall = wall
    }

    package static let live = ServerClock(monotonic: { ContinuousClock.now }, wall: { Date() })
}

/// Counts presented, well-formed credentials that matched nothing. A missing header never counts: on loopback
/// every client is 127.0.0.1, so counting it would let any page in the computer's browser lock out the CLI.
package struct FailureBudget: Sendable {
    package let perIPEnabled: Bool
    private var perIP: KeyedTokenBuckets<String>
    private var global: TokenBucket
    private var blockedUntil: [String: ContinuousClock.Instant] = [:]
    private var floodUntil: ContinuousClock.Instant?
    private let blockFor: Duration
    private let floodFor: Duration

    package init(limits: ServerLimits, perIPEnabled: Bool, now: ContinuousClock.Instant) {
        self.perIPEnabled = perIPEnabled
        self.perIP = KeyedTokenBuckets(capacity: limits.authFailuresPerMinutePerIP, per: .seconds(60))
        self.global = TokenBucket(capacity: limits.globalAuthFailuresPerMinute, per: .seconds(60), now: now)
        self.blockFor = limits.authFailureBlock
        self.floodFor = limits.authFloodPause
    }

    package func isFlooded(now: ContinuousClock.Instant) -> Bool {
        floodUntil.map { now < $0 } ?? false
    }

    package func isBlocked(_ peer: String, now: ContinuousClock.Instant) -> Bool {
        guard perIPEnabled, let until = blockedUntil[peer] else { return false }
        return now < until
    }

    package var blockedCount: Int { blockedUntil.count }

    /// Records one failure; returns `true` when it starts a global flood.
    package mutating func recordFailure(from peer: String, now: ContinuousClock.Instant) -> Bool {
        if perIPEnabled, !perIP.take(peer, now: now) {
            if blockedUntil.count >= KeyedTokenBuckets<String>.minimumPruneSize {
                blockedUntil = blockedUntil.filter { now < $0.value }
            }
            blockedUntil[peer] = now + blockFor
        }
        guard !global.take(now: now), !isFlooded(now: now) else { return false }
        floodUntil = now + floodFor
        return true
    }
}

enum SafeLabel {
    /// Printable, at most 60 characters: labels shown on screen come from people or peers.
    static func make(_ text: String) -> String {
        let cleaned = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let label = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? "key" : String(label.prefix(60))
    }
}
