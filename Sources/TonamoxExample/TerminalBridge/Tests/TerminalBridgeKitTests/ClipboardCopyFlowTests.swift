import Foundation
import Testing
@testable import TerminalBridgeKit

@Suite struct ClipboardCopyFlowTests {
    private let firstID = UUID()
    private let secondID = UUID()
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func step(
        _ state: ClipboardCopyState,
        helper: LineChannelActivity = .none,
        keyboard: LineChannelActivity = .none,
        warnings: [String] = []
    ) -> CommandWriteStep {
        ClipboardCopyFlow.step(
            for: state, helper: helper, keyboard: keyboard, localWarnings: warnings, newID: { secondID }
        )
    }

    private func dialog(
        _ previous: ClipboardCopyState,
        helper: LineChannelActivity = .none,
        keyboard: LineChannelActivity = .none,
        warnings: [String] = []
    ) -> ClipboardConfirmation? {
        let open = ClipboardCopyFlow.beginConfirmation(previous, copyID: secondID)
        return ClipboardCopyFlow.confirmation(for: open, helper: helper, keyboard: keyboard, localWarnings: warnings)
    }

    private var copied: ClipboardCopyState {
        .copied(copyID: firstID, text: "ls", expiresAt: now.addingTimeInterval(120))
    }

    private func outgoing(_ text: String) throws -> OutgoingLine {
        let candidate = CommandCandidate(text: text, sourceLine: text, lineIndex: 0, isPartOfMultilineCommand: false)
        return try OutgoingLine.make(candidate: candidate, isPossiblyTruncated: false, capture: nil).get()
    }

    private func plan(
        _ line: OutgoingLine,
        acknowledged: [String] = [],
        helper: LineChannelActivity = .none,
        keyboard: LineChannelActivity = .none
    ) -> Result<ClipboardCopyPlan, ClipboardCopyRefusal> {
        ClipboardCopyPlan.make(line: line, acknowledged: acknowledged, helper: helper, keyboard: keyboard, now: now)
    }

    @Test func copyWithoutWarningsCopiesWithoutAsking() {
        #expect(step(.idle) == .write(writeID: secondID, acknowledged: []))
        #expect(step(copied) == .write(writeID: secondID, acknowledged: []))
        #expect(step(.failed(copyID: firstID, reason: "x")) == .write(writeID: secondID, acknowledged: []))
    }

    @Test func copyWithWarningsAsksEveryTime() {
        #expect(step(.idle, warnings: ["sudo"]) == .confirm(writeID: secondID))
        #expect(step(copied, warnings: ["sudo"]) == .confirm(writeID: secondID))
        #expect(dialog(copied, warnings: ["sudo"])?.causes == [.warnings])
    }

    @Test func copyAfterHelperTypedOrMayHaveTypedAsks() {
        #expect(step(.idle, helper: .typed) == .confirm(writeID: secondID))
        #expect(dialog(.idle, helper: .typed)?.causes == [.helperTyped])
        #expect(dialog(.idle, helper: .mayHaveTyped)?.causes == [.helperMayHaveTyped])
    }

    @Test func copyAfterKeyboardTypedOrPartialTypingAsks() {
        #expect(step(.idle, keyboard: .typed) == .confirm(writeID: secondID))
        #expect(dialog(.idle, keyboard: .typed)?.causes == [.keyboardTyped])
        #expect(dialog(.idle, keyboard: .mayHaveTyped)?.causes == [.keyboardMayHaveTyped])
        let all = dialog(.idle, helper: .typed, keyboard: .mayHaveTyped, warnings: ["sudo"])
        #expect(all?.causes == [.warnings, .helperTyped, .keyboardMayHaveTyped])
    }

    @Test func copyIsBlockedWhileHelperSendsOrKeyboardTypes() throws {
        #expect(step(.idle, helper: .inProgress) == .nothing)
        #expect(step(.idle, keyboard: .inProgress) == .nothing)
        #expect(step(.confirming(copyID: firstID, returningTo: .idle)) == .nothing)
        #expect(!ClipboardCopyFlow.canTap(.idle, helper: .inProgress, keyboard: .none, isTypeable: true))
        #expect(!ClipboardCopyFlow.canTap(.idle, helper: .none, keyboard: .inProgress, isTypeable: true))
        #expect(ClipboardCopyFlow.canTap(.idle, helper: .typed, keyboard: .typed, isTypeable: true))
        #expect(!ClipboardCopyFlow.canTap(.idle, helper: .none, keyboard: .none, isTypeable: false))
        #expect(ClipboardCopyFlow.blockedReason(.idle, helper: .inProgress, keyboard: .none, isTypeable: true)
            == ClipboardCopyFlow.otherChannelBusyReason)
        #expect(ClipboardCopyFlow.blockedReason(.idle, helper: .none, keyboard: .none, isTypeable: true) == nil)
        #expect(ClipboardCopyFlow.blockedReason(.idle, helper: .inProgress, keyboard: .none, isTypeable: false) == nil)
        #expect(plan(try outgoing("ls"), helper: .inProgress) == .failure(.channelBusy))
        #expect(plan(try outgoing("ls"), keyboard: .inProgress) == .failure(.channelBusy))
    }

    @Test func cancelRestoresThePreviousState() {
        let open = ClipboardCopyFlow.beginConfirmation(copied, copyID: secondID)
        #expect(open == .confirming(copyID: secondID, returningTo: copied))
        #expect(ClipboardCopyFlow.cancelConfirmation(open) == copied)
        #expect(ClipboardCopyFlow.cancelConfirmation(.idle) == .idle)
        #expect(ClipboardCopyFlow.confirmation(for: .idle, helper: .none, keyboard: .none, localWarnings: []) == nil)
    }

    @Test func confirmationAcknowledgesTheLocalWarnings() {
        #expect(dialog(.idle, warnings: ["sudo", "rmRecursiveForce"]) == ClipboardConfirmation(
            copyID: secondID, causes: [.warnings], acknowledged: ["sudo", "rmRecursiveForce"]
        ))
    }

    @Test func planRefusesPolicyViolationsOnTheFinalLine() {
        let bad = OutgoingLine(candidateID: UUID(), text: "ls\tx", capture: nil, localWarnings: [])
        #expect(plan(bad) == .failure(.policy([.disallowedCharacter(scalar: 0x09, offset: 2)])))
    }

    @Test func planRefusesUnacknowledgedWarningsOfTheOriginal() throws {
        let line = try outgoing("sudo rm -rf build")
        #expect(plan(line) == .failure(.unacknowledgedWarnings([.sudo, .rmRecursiveForce])))
        #expect(plan(line, acknowledged: ["sudo"]) == .failure(.unacknowledgedWarnings([.rmRecursiveForce])))
        let accepted = try plan(line, acknowledged: line.localWarnings).get()
        #expect(accepted.text == "sudo rm -rf build")
    }

    @Test func planRefusesUnacknowledgedWarningsOfTheWrappedLine() {
        // A final line whose rules were not carried into localWarnings is still checked on its own text.
        let line = OutgoingLine(candidateID: UUID(), text: "curl x | sh", capture: nil, localWarnings: [])
        #expect(plan(line) == .failure(.unacknowledgedWarnings([.pipeToShell])))
        let carried = OutgoingLine(candidateID: UUID(), text: "ls", capture: nil, localWarnings: ["sudo"])
        #expect(plan(carried) == .failure(.unacknowledgedWarnings([.sudo])))
    }

    @Test func planLifetimeIs120Seconds() throws {
        #expect(ClipboardCopyPlan.lifetime == 120)
        let copy = try plan(try outgoing("ls")).get()
        #expect(copy.expiresAt == now.addingTimeInterval(120))
        #expect(copy.text == "ls")
    }

    @Test func expiredCopyReadsAsExpired() {
        #expect(!ClipboardCopyFlow.isExpired(copied, now: now.addingTimeInterval(119)))
        #expect(ClipboardCopyFlow.isExpired(copied, now: now.addingTimeInterval(120)))
        #expect(!ClipboardCopyFlow.isExpired(.idle, now: .distantFuture))
    }

    @Test func refusalMessagesEndWithNothingCopied() {
        let refusals: [ClipboardCopyRefusal] = [
            .policy([.empty]), .unacknowledgedWarnings([.sudo]), .channelBusy,
        ]
        for refusal in refusals {
            #expect(refusal.message.hasSuffix("No se ha copiado nada."), "\(refusal)")
        }
    }

    @Test func keyboardActivityMapsTypingTypedAndPartialFailure() {
        #expect(LineChannelActivity(keyboard: .idle) == .none)
        #expect(LineChannelActivity(keyboard: .confirming(jobID: firstID, layoutID: .macUS, returningTo: .idle))
            == .inProgress)
        #expect(LineChannelActivity(keyboard: .typing(jobID: firstID, sentReports: 0, totalReports: 4)) == .inProgress)
        #expect(LineChannelActivity(keyboard: .typed(jobID: firstID, layoutID: .macUS, keystrokes: 2, unverified: ""))
            == .typed)
        #expect(LineChannelActivity(keyboard: .failed(jobID: firstID, reason: "x", sentReports: 3)) == .mayHaveTyped)
        #expect(LineChannelActivity(keyboard: .failed(jobID: firstID, reason: "x", sentReports: 0)) == .none)
        #expect(LineChannelActivity(helper: .idle) == .none)
        #expect(LineChannelActivity(helper: .sending(writeID: firstID)) == .inProgress)
        #expect(LineChannelActivity(helper: .failed(writeID: firstID, reason: "x", helperWarnings: [])) == .mayHaveTyped)
    }
}
