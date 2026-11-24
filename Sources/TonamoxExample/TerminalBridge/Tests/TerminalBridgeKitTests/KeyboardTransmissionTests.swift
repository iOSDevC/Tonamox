import Testing
@testable import TerminalBridgeKit

@Suite struct KeyboardTransmissionTests {
    private static let interval = HIDKeyboardDescriptor.reportInterval

    private func plan(_ text: String) throws -> KeyboardTypingPlan {
        try KeyboardTypingPlan.make(text: text, layout: .layout(.macUS), acknowledged: []).get()
    }

    /// Sends up to `count` reports, one per interval from `start`; returns what went out.
    @discardableResult
    private func send(_ count: Int, _ transmission: inout KeyboardTransmission, from start: Duration = .zero)
        -> [HIDKeyboardReport]
    {
        var sent: [HIDKeyboardReport] = []
        var now = start
        while sent.count < count, let next = transmission.next() {
            transmission.check(at: now)
            guard transmission.end == nil else { break }
            sent.append(next)
            transmission.didSend(at: now)
            now += Self.interval
        }
        return sent
    }

    @Test func sendsEveryReportInOrderThenCompletes() throws {
        let built = try plan("aB c")
        var transmission = KeyboardTransmission(plan: built)
        #expect(transmission.totalReports == built.reports.count)
        let sent = send(.max, &transmission)
        #expect(sent == built.reports)
        #expect(transmission.sentReports == built.reports.count)
        #expect(transmission.end == .completed)
        #expect(transmission.cleanupReport == nil)
        #expect(KeyboardTransmissionEnd.completed.message.contains("antes de pulsar Enter"))
    }

    @Test(arguments: [
        KeyboardTransmissionEnd.cancelled, .hostDisconnected, .bluetoothOff, .appInactive, .keyHeldTooLong,
        .capsLockTurnedOn, .unsafeReport,
    ])
    func abortDropsTheRestAndNeverResumes(reason: KeyboardTransmissionEnd) throws {
        var transmission = KeyboardTransmission(plan: try plan("abc"))
        send(3, &transmission)
        transmission.abort(reason)
        #expect(transmission.end == reason)
        #expect(transmission.next() == nil)
        transmission.didSend(at: .seconds(1))
        #expect(transmission.sentReports == 3)
        transmission.abort(.cancelled)
        transmission.hostLEDsChanged(.capsLock)
        transmission.check(at: .seconds(10))
        #expect(transmission.end == reason)
        #expect(transmission.next() == nil)
        #expect(reason.message.hasSuffix("Bórralo antes de seguir."))
        #expect(reason.message(afterSending: 0).hasSuffix("No se ha enviado nada."))
    }

    @Test func cleanupReportIsReleasedOnlyAfterSomethingWasSent() throws {
        var untouched = KeyboardTransmission(plan: try plan("abc"))
        untouched.abort(.cancelled)
        #expect(untouched.cleanupReport == nil)

        var partial = KeyboardTransmission(plan: try plan("abc"))
        send(2, &partial)
        #expect(partial.cleanupReport == nil)
        partial.abort(.hostDisconnected)
        #expect(partial.cleanupReport == .released)

        var completed = KeyboardTransmission(plan: try plan("abc"))
        completed.abort(.completed)
        #expect(completed.end == .cancelled)
    }

    @Test func keyHeldPastTheLimitAbortsBeforeTheRelease() throws {
        let limit = HIDKeyboardDescriptor.maxKeyHold
        var waiting = KeyboardTransmission(plan: try plan("a"))
        send(2, &waiting)
        let keyDownAt = Self.interval
        waiting.check(at: keyDownAt + limit)
        #expect(waiting.end == nil)
        waiting.check(at: keyDownAt + limit + .milliseconds(1))
        #expect(waiting.end == .keyHeldTooLong)
        #expect(waiting.next() == nil)
        #expect(waiting.sentReports == 2)
        #expect(waiting.cleanupReport == .released)

        // A release accepted too late still ends the job: the host may already have repeated the key.
        var late = KeyboardTransmission(plan: try plan("a"))
        send(2, &late)
        #expect(late.next() == .released)
        late.didSend(at: keyDownAt + limit + .milliseconds(5))
        #expect(late.end == .keyHeldTooLong)
        #expect(late.sentReports == 3)

        // Modifier-only reports never arm the watchdog.
        var shifted = KeyboardTransmission(plan: try plan("A"))
        send(2, &shifted)
        shifted.check(at: .seconds(5))
        #expect(shifted.end == nil)
    }

    @Test func capsLockTurnedOnMidJobAborts() throws {
        var transmission = KeyboardTransmission(plan: try plan("abc"))
        send(2, &transmission)
        transmission.hostLEDsChanged(.numLock)
        transmission.hostLEDsChanged([])
        #expect(transmission.end == nil)
        transmission.hostLEDsChanged([.numLock, .capsLock])
        #expect(transmission.end == .capsLockTurnedOn)
        #expect(transmission.next() == nil)
        #expect(transmission.cleanupReport == .released)
    }

    @Test func endedTransmissionReturnsNoMoreReports() throws {
        var transmission = KeyboardTransmission(plan: try plan("a"))
        send(.max, &transmission)
        #expect(transmission.end == .completed)
        #expect(transmission.next() == nil)
        transmission.didSend(at: .seconds(1))
        transmission.abort(.hostDisconnected)
        #expect(transmission.sentReports == transmission.totalReports)
        #expect(transmission.end == .completed)
    }

    @Test func nextRepeatsTheSameReportUntilItIsAccepted() throws {
        var transmission = KeyboardTransmission(plan: try plan("a"))
        let first = transmission.next()
        #expect(transmission.next() == first)
        #expect(transmission.sentReports == 0)
    }
}
