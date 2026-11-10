import Foundation
import Testing
import TerminalBridgeKit

@Suite struct CommandWriteFlowTests {
    private let firstID = UUID()
    private let secondID = UUID()
    private var ack: WriteAck {
        WriteAck(id: firstID, result: .typed, bytes: 2, textSHA256: "x", warnings: [], verified: true)
    }

    private func fresh(_ id: UUID) -> () -> UUID {
        { id }
    }

    @Test func idleWritesWithANewIDWhenThereAreNoWarnings() {
        let step = CommandWriteFlow.step(for: .idle, localWarnings: [], newID: fresh(firstID))
        #expect(step == .write(writeID: firstID, acknowledged: []))
    }

    @Test func idleWithWarningsAsksFirst() {
        let step = CommandWriteFlow.step(for: .idle, localWarnings: ["sudo"], newID: fresh(firstID))
        #expect(step == .confirm(writeID: firstID))
        let open = CommandWriteFlow.beginConfirmation(.idle, writeID: firstID)
        let dialog = CommandWriteFlow.confirmation(for: open, localWarnings: ["sudo"])
        #expect(dialog == CommandConfirmation(writeID: firstID, isRewrite: false, acknowledged: ["sudo"]))
    }

    @Test func retryAfterAFailureReusesTheSameID() {
        let failed = CommandSendState.failed(writeID: firstID, reason: "timeout", helperWarnings: [])
        let step = CommandWriteFlow.step(for: failed, localWarnings: [], newID: fresh(secondID))
        #expect(step == .write(writeID: firstID, acknowledged: []))
    }

    @Test func retryAcknowledgesTheWarningsTheHelperAskedFor() {
        let failed = CommandSendState.failed(writeID: firstID, reason: "avisos", helperWarnings: ["sudo", "dd"])
        let step = CommandWriteFlow.step(for: failed, localWarnings: ["dd"], newID: fresh(secondID))
        #expect(step == .confirm(writeID: firstID))
        let open = CommandWriteFlow.beginConfirmation(failed, writeID: firstID)
        let dialog = CommandWriteFlow.confirmation(for: open, localWarnings: ["dd"])
        #expect(dialog?.writeID == firstID)
        #expect(dialog?.acknowledged == ["dd", "sudo"])
        #expect(dialog?.isRewrite == false)
    }

    @Test func writingASentLineAgainAsksAndUsesANewID() {
        let sent = CommandSendState.sent(writeID: firstID, ack: ack, target: "tnx:0")
        let step = CommandWriteFlow.step(for: sent, localWarnings: [], newID: fresh(secondID))
        #expect(step == .confirm(writeID: secondID))
        let open = CommandWriteFlow.beginConfirmation(sent, writeID: secondID)
        let dialog = CommandWriteFlow.confirmation(for: open, localWarnings: [])
        #expect(dialog == CommandConfirmation(writeID: secondID, isRewrite: true, acknowledged: []))
    }

    @Test func cancelRestoresThePreviousState() {
        let sent = CommandSendState.sent(writeID: firstID, ack: ack, target: "tnx:0")
        let open = CommandWriteFlow.beginConfirmation(sent, writeID: secondID)
        #expect(CommandWriteFlow.cancelConfirmation(open) == sent)
        #expect(CommandWriteFlow.cancelConfirmation(.idle) == .idle)
        #expect(CommandWriteFlow.confirmation(for: sent, localWarnings: []) == nil)
    }

    @Test func busyStatesIgnoreTaps() {
        let open = CommandWriteFlow.beginConfirmation(.idle, writeID: firstID)
        #expect(CommandWriteFlow.step(for: open, localWarnings: [], newID: fresh(secondID)) == .nothing)
        #expect(CommandWriteFlow.step(for: .sending(writeID: firstID), localWarnings: [], newID: fresh(secondID)) == .nothing)
    }

    @Test func buttonNeedsATypeableLineAndAConnection() {
        let sent = CommandSendState.sent(writeID: firstID, ack: ack, target: "tnx:0")
        #expect(CommandWriteFlow.canTap(.idle, isTypeable: true, isConnected: true))
        #expect(!CommandWriteFlow.canTap(.idle, isTypeable: false, isConnected: true))
        #expect(!CommandWriteFlow.canTap(sent, isTypeable: true, isConnected: false))
        #expect(!CommandWriteFlow.canTap(.sending(writeID: firstID), isTypeable: true, isConnected: true))
        #expect(CommandWriteFlow.blockedReason(sent, isTypeable: true, isConnected: false) == CommandWriteFlow.disconnectedReason)
        #expect(CommandWriteFlow.blockedReason(.idle, isTypeable: true, isConnected: true) == nil)
        #expect(CommandWriteFlow.blockedReason(.idle, isTypeable: false, isConnected: false) == nil)
    }
}
