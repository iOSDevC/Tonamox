import Foundation
import Synchronization
@testable import TerminalBridgeKit

/// A clock that only moves when the test calls `advance(by:)`.
final class ManualClock: BridgeClock {
    private struct Sleeper {
        let id: UUID
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct Timeline {
        var now: Duration = .zero
        var sleepers: [Sleeper] = []
        var cancelled: Set<UUID> = []
    }

    private let state = Mutex(Timeline())

    func now() -> Duration {
        state.withLock { $0.now }
    }

    var sleeperCount: Int {
        state.withLock { $0.sleepers.count }
    }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let immediate: Result<Void, any Error>? = state.withLock { state in
                    if state.cancelled.remove(id) != nil { return .failure(CancellationError()) }
                    if duration <= .zero { return .success(()) }
                    state.sleepers.append(Sleeper(id: id, deadline: state.now + duration, continuation: continuation))
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            self.cancelSleeper(id)
        }
    }

    func advance(by duration: Duration) {
        let due: [Sleeper] = state.withLock { state in
            state.now += duration
            let now = state.now
            let due = state.sleepers.filter { $0.deadline <= now }
            state.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }

    private func cancelSleeper(_ id: UUID) {
        let sleeper: Sleeper? = state.withLock { state in
            if let index = state.sleepers.firstIndex(where: { $0.id == id }) {
                return state.sleepers.remove(at: index)
            }
            state.cancelled.insert(id)
            return nil
        }
        sleeper?.continuation.resume(throwing: CancellationError())
    }
}

actor FakeInjector: TerminalTextInjector {
    private(set) var typedTexts: [String] = []
    private var target = TargetStatus(session: "tnx-test", window: "0", state: .ready, foreground: "zsh")
    private var outcome: InjectionOutcome = .typed(verified: true)

    func currentTarget() -> TargetStatus {
        target
    }

    func type(_ text: String) -> InjectionOutcome {
        typedTexts.append(text)
        return outcome
    }

    func setOutcome(_ newOutcome: InjectionOutcome) {
        outcome = newOutcome
    }
}

actor RecordingRecorder: WriteRecorder {
    private(set) var records: [WriteRecord] = []

    func record(_ write: WriteRecord) {
        records.append(write)
    }
}

final class EventLog: Sendable {
    private let storage = Mutex<[PhoneBridgeEvent]>([])

    var all: [PhoneBridgeEvent] {
        storage.withLock { $0 }
    }

    func contains(_ event: PhoneBridgeEvent) -> Bool {
        storage.withLock { $0.contains(event) }
    }

    private func append(_ event: PhoneBridgeEvent) {
        storage.withLock { $0.append(event) }
    }

    static func collecting(_ stream: AsyncStream<PhoneBridgeEvent>) -> EventLog {
        let log = EventLog()
        Task {
            for await event in stream {
                log.append(event)
            }
        }
        return log
    }
}

/// Polls `condition` in real time until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

enum TestSecrets {
    static let primary = Data((0..<20).map { UInt8($0) })
    static let other = Data((100..<120).map { UInt8($0) })
}
