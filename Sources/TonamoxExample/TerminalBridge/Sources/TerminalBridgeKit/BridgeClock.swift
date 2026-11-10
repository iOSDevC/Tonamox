import Foundation
import Synchronization

/// Monotonic time source for timeouts and heartbeats, injectable for tests.
public protocol BridgeClock: Sendable {
    /// Time elapsed since an arbitrary origin.
    func now() -> Duration
    func sleep(for duration: Duration) async throws
}

public struct SystemBridgeClock: BridgeClock {
    private let origin: ContinuousClock.Instant

    public init() {
        origin = ContinuousClock.now
    }

    public func now() -> Duration {
        origin.duration(to: ContinuousClock.now)
    }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// A value delivered once, awaited at most once; finishing before the wait is fine.
final class OneShot<Value: Sendable>: Sendable {
    private enum Delivery {
        case waiting(CheckedContinuation<Value, any Error>?)
        case finished(Result<Value, any Error>)
    }

    private let state = Mutex<Delivery>(.waiting(nil))

    func finish(_ result: Result<Value, any Error>) {
        let continuation: CheckedContinuation<Value, any Error>? = state.withLock { state in
            guard case .waiting(let continuation) = state else { return nil }
            state = .finished(result)
            return continuation
        }
        continuation?.resume(with: result)
    }

    var isFinished: Bool {
        state.withLock { state in
            if case .finished = state { return true }
            return false
        }
    }

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
            let ready: Result<Value, any Error>? = state.withLock { state in
                switch state {
                case .waiting:
                    state = .waiting(continuation)
                    return nil
                case .finished(let result):
                    return result
                }
            }
            if let ready { continuation.resume(with: ready) }
        }
    }
}
