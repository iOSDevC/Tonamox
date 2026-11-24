import Foundation

/// One generation at a time on a model, with a bounded queue. Share one instance between the server and the
/// app's own chat on the same model, so they never decode on one context at once.
@MainActor
public final class GenerationTurnstile {
    public let maxQueued: Int
    private var isRunning = false
    private var queue: [UUID] = []
    private var granted: Set<UUID> = []
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    public init(maxQueued: Int = 2) {
        self.maxQueued = maxQueued
    }

    /// A generation holds the turnstile.
    public var isBusy: Bool { isRunning }
    public var queuedCount: Int { queue.count }

    /// Runs `body` when it is this caller's turn. Throws ``ServedModelError/busy`` at once when the queue is full.
    /// The turn ends when `body` returns, so `body` must await the generation itself: breaking out of a
    /// `Tonamox.stream` loop returns before the cancelled decode has stopped.
    public func run<T: Sendable>(_ body: @MainActor () async throws -> T) async throws -> T {
        let slot = try reserve()
        defer { slot.release() }
        try await slot.acquire()
        return try await body()
    }

    /// Takes the turnstile or a queue place without waiting; throws ``ServedModelError/busy`` when full.
    package func reserve() throws -> TurnstileSlot {
        let id = UUID()
        if !isRunning, queue.isEmpty {
            isRunning = true
            granted.insert(id)
        } else if queue.count < maxQueued {
            queue.append(id)
        } else {
            throw ServedModelError.busy
        }
        return TurnstileSlot(id: id, turnstile: self)
    }

    func isGranted(_ id: UUID) -> Bool { granted.contains(id) }

    func wait(for id: UUID) async throws {
        guard !granted.contains(id) else { return }
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if granted.contains(id) {
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.abandon(id) }
        }
    }

    private func abandon(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        queue.removeAll { $0 == id }
        waiter.resume(throwing: CancellationError())
    }

    func release(_ id: UUID) {
        if granted.remove(id) != nil {
            handOver()
        } else {
            queue.removeAll { $0 == id }
            waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        }
    }

    private func handOver() {
        guard !queue.isEmpty else {
            isRunning = false
            return
        }
        let next = queue.removeFirst()
        granted.insert(next)
        waiters.removeValue(forKey: next)?.resume()
    }
}

/// A place in a ``GenerationTurnstile``: running already, or queued.
@MainActor
package final class TurnstileSlot {
    let id: UUID
    private weak var turnstile: GenerationTurnstile?
    private var isReleased = false

    init(id: UUID, turnstile: GenerationTurnstile) {
        self.id = id
        self.turnstile = turnstile
    }

    package var isGranted: Bool { turnstile?.isGranted(id) ?? false }

    package func acquire() async throws {
        try await turnstile?.wait(for: id)
    }

    /// Frees the turnstile or the queue place. Idempotent.
    package func release() {
        guard !isReleased else { return }
        isReleased = true
        turnstile?.release(id)
    }
}
