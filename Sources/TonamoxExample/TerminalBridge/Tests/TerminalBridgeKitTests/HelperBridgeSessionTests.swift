import Foundation
import Testing
@testable import TerminalBridgeKit

@Suite struct HelperBridgeSessionTests {
    private func makeSession(
        injector: FakeInjector,
        recent: RecentWriteIDs = RecentWriteIDs(),
        recorder: RecordingRecorder? = nil,
        clock: ManualClock
    ) -> HelperBridgeSession {
        HelperBridgeSession(
            secret: TestSecrets.primary,
            helperID: UUID(),
            helperName: "test",
            injector: injector,
            recentWrites: recent,
            recorder: recorder,
            clock: clock
        )
    }

    private func errorCode(_ message: BridgeMessage) -> BridgeErrorCode? {
        if case .error(let report) = message { return report.code }
        return nil
    }

    @Test func typesAValidLineAndRemembersIt() async {
        let injector = FakeInjector()
        let recent = RecentWriteIDs()
        let clock = ManualClock()
        let session = makeSession(injector: injector, recent: recent, clock: clock)
        let id = UUID()
        let reply = await session.process(WriteRequest(id: id, text: "printf hello"))
        guard case .ack(let ack) = reply else {
            Issue.record("expected an ack, got \(reply)")
            return
        }
        #expect(ack.result == .typed)
        #expect(ack.textSHA256 == BridgeDigest.sha256Hex("printf hello"))
        #expect(recent.contains(id))
        #expect(await injector.typedTexts == ["printf hello"])
    }

    @Test func rateLimitsWritesCloserThan300Milliseconds() async {
        let injector = FakeInjector()
        let clock = ManualClock()
        let session = makeSession(injector: injector, clock: clock)
        _ = await session.process(WriteRequest(id: UUID(), text: "true"))
        clock.advance(by: .milliseconds(299))
        #expect(errorCode(await session.process(WriteRequest(id: UUID(), text: "true"))) == .rateLimited)
        clock.advance(by: .milliseconds(300))
        #expect(errorCode(await session.process(WriteRequest(id: UUID(), text: "true"))) == nil)
        #expect(await injector.typedTexts.count == 2)
    }

    @Test func refusesUnknownIntentsWithoutTyping() async {
        let injector = FakeInjector()
        let session = makeSession(injector: injector, clock: ManualClock())
        let request = WriteRequest(id: UUID(), intent: .unrecognized(kind: "task"), text: "git status")
        #expect(errorCode(await session.process(request)) == .unsupportedIntent)
        #expect(await injector.typedTexts.isEmpty)
    }

    @Test func reChecksThePolicyOnTheHelper() async {
        let injector = FakeInjector()
        let recorder = RecordingRecorder()
        let clock = ManualClock()
        let session = makeSession(injector: injector, recorder: recorder, clock: clock)
        #expect(errorCode(await session.process(WriteRequest(id: UUID(), text: "touch x\r"))) == .policy)
        clock.advance(by: .seconds(1))
        #expect(errorCode(await session.process(WriteRequest(id: UUID(), text: "echo año"))) == .policy)
        clock.advance(by: .seconds(1))
        #expect(errorCode(await session.process(WriteRequest(id: UUID(), text: nil))) == .policy)
        #expect(await injector.typedTexts.isEmpty)
        #expect(await recorder.records.map(\.outcome) == [.refused(.policy), .refused(.policy)])
    }

    @Test func requiresEveryWarningToBeAcknowledged() async {
        let injector = FakeInjector()
        let clock = ManualClock()
        let session = makeSession(injector: injector, clock: clock)
        let partial = WriteRequest(id: UUID(), text: "sudo rm -rf /tmp/x", acknowledgedWarnings: ["sudo"])
        let reply = await session.process(partial)
        guard case .error(let report) = reply else {
            Issue.record("expected an error")
            return
        }
        #expect(report.code == .unacknowledgedWarnings)
        #expect(report.warnings == ["rmRecursiveForce"])
        clock.advance(by: .seconds(1))
        let accepted = await session.process(WriteRequest(
            id: UUID(),
            text: "sudo rm -rf /tmp/x",
            acknowledgedWarnings: ["sudo", "rmRecursiveForce"]
        ))
        guard case .ack(let ack) = accepted else {
            Issue.record("expected an ack")
            return
        }
        #expect(ack.warnings == ["sudo", "rmRecursiveForce"])
        #expect(await injector.typedTexts == ["sudo rm -rf /tmp/x"])
    }

    @Test func idsSeededFromTheJournalAreNotTypedAgain() async {
        let injector = FakeInjector()
        let id = UUID()
        let session = makeSession(injector: injector, recent: RecentWriteIDs(seed: [id]), clock: ManualClock())
        guard case .ack(let ack) = await session.process(WriteRequest(id: id, text: "printf again")) else {
            Issue.record("expected an ack")
            return
        }
        #expect(ack.result == .alreadyTyped)
        #expect(ack.verified == false)
        #expect(await injector.typedTexts.isEmpty)
    }

    @Test func injectorRefusalsAreForwardedAndNotRemembered() async {
        let injector = FakeInjector()
        await injector.setOutcome(.refused(.foregroundNotShell, detail: "vim"))
        let recent = RecentWriteIDs()
        let session = makeSession(injector: injector, recent: recent, clock: ManualClock())
        let id = UUID()
        let reply = await session.process(WriteRequest(id: id, text: "printf x"))
        #expect(reply == .error(ErrorReport(id: id, code: .foregroundNotShell, detail: "vim")))
        #expect(!recent.contains(id))
    }
}
