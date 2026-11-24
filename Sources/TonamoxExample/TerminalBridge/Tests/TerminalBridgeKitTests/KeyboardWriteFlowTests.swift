import Foundation
import Testing
import TerminalBridgeKit

@Suite struct KeyboardWriteFlowTests {
    private let firstID = UUID()
    private let secondID = UUID()

    private func fresh(_ id: UUID) -> () -> UUID {
        { id }
    }

    private func step(
        _ state: KeyboardSendState,
        helper: HelperLineActivity = .none,
        warnings: [String] = [],
        optionNotice: Bool = false
    ) -> CommandWriteStep {
        KeyboardWriteFlow.step(
            for: state, helper: helper, localWarnings: warnings, needsOptionNotice: optionNotice, newID: fresh(secondID)
        )
    }

    private func dialog(
        _ previous: KeyboardSendState,
        helper: HelperLineActivity = .none,
        warnings: [String] = [],
        optionNotice: Bool = false
    ) -> KeyboardConfirmation? {
        let open = KeyboardWriteFlow.beginConfirmation(previous, jobID: secondID, layoutID: .macSpanishISO)
        return KeyboardWriteFlow.confirmation(
            for: open, helper: helper, localWarnings: warnings, needsOptionNotice: optionNotice
        )
    }

    private var typed: KeyboardSendState {
        .typed(jobID: firstID, layoutID: .macUS, keystrokes: 4, unverified: "")
    }

    @Test func idleWithoutWarningsTypesAtOnce() {
        #expect(step(.idle) == .write(writeID: secondID, acknowledged: []))
    }

    @Test func idleWithWarningsAsksFirst() {
        #expect(step(.idle, warnings: ["sudo"]) == .confirm(writeID: secondID))
        let confirmation = dialog(.idle, warnings: ["sudo"])
        #expect(confirmation == KeyboardConfirmation(
            jobID: secondID, layoutID: .macSpanishISO, causes: [.warnings], acknowledged: ["sudo"]
        ))
    }

    @Test func typedLineAsksBeforeTypingAgain() {
        #expect(step(typed) == .confirm(writeID: secondID))
        #expect(dialog(typed)?.causes == [.retype])
    }

    @Test func refusalBeforeAnyReportRetriesWithoutAsking() {
        let refused = KeyboardSendState.failed(jobID: firstID, reason: "No se ha enviado nada.", sentReports: 0)
        #expect(step(refused) == .write(writeID: secondID, acknowledged: []))
    }

    @Test func failureAfterPartialTypingAsksFirst() {
        let partial = KeyboardSendState.failed(jobID: firstID, reason: "corte", sentReports: 7)
        #expect(step(partial) == .confirm(writeID: secondID))
        #expect(dialog(partial)?.causes == [.afterPartialTyping])
    }

    @Test func cancelRestoresThePreviousState() {
        let open = KeyboardWriteFlow.beginConfirmation(typed, jobID: secondID, layoutID: .macUS)
        #expect(open == .confirming(jobID: secondID, layoutID: .macUS, returningTo: typed))
        #expect(KeyboardWriteFlow.cancelConfirmation(open) == typed)
        #expect(KeyboardWriteFlow.cancelConfirmation(.idle) == .idle)
        #expect(KeyboardWriteFlow.confirmation(for: .idle, helper: .none, localWarnings: [], needsOptionNotice: false) == nil)
    }

    @Test func typingAndConfirmingAreNotTappable() {
        let busy: [KeyboardSendState] = [
            .typing(jobID: firstID, sentReports: 1, totalReports: 9),
            .confirming(jobID: firstID, layoutID: .macUS, returningTo: .idle),
        ]
        for state in busy {
            #expect(step(state) == .nothing)
            #expect(!KeyboardWriteFlow.canTap(state, helper: .none, isTypeable: true, readiness: .ready))
            #expect(KeyboardWriteFlow.blockedReason(state, helper: .none, isTypeable: true, readiness: .off) == nil)
        }
        #expect(KeyboardWriteFlow.canTap(.idle, helper: .none, isTypeable: true, readiness: .ready))
        #expect(KeyboardWriteFlow.canTap(typed, helper: .typed, isTypeable: true, readiness: .ready))
    }

    @Test func untypeableLinesAreNeverTappable() {
        #expect(!KeyboardWriteFlow.canTap(.idle, helper: .none, isTypeable: false, readiness: .ready))
        #expect(KeyboardWriteFlow.blockedReason(.idle, helper: .none, isTypeable: false, readiness: .off) == nil)
    }

    @Test(arguments: [
        KeyboardReadiness.off, .bluetoothUnavailable("Bluetooth está apagado."), .waitingForHost, .multipleHosts(2),
        .capsLockOn, .busy,
    ])
    func blockedReasonNamesTheKeyboardProblem(readiness: KeyboardReadiness) {
        #expect(!KeyboardWriteFlow.canTap(.idle, helper: .none, isTypeable: true, readiness: readiness))
        let reason = KeyboardWriteFlow.blockedReason(.idle, helper: .none, isTypeable: true, readiness: readiness)
        #expect(reason != nil)
        #expect(reason == readiness.message)
        #expect(KeyboardReadiness.ready.message == nil)
    }

    @Test func readinessPrecedenceAndUnknownCapsLockDoesNotBlock() {
        #expect(KeyboardReadiness.evaluate(
            isActive: false, bluetoothProblem: "x", subscriberCount: 3, leds: .capsLock, isBusy: true
        ) == .off)
        #expect(KeyboardReadiness.evaluate(
            isActive: true, bluetoothProblem: "x", subscriberCount: 3, leds: .capsLock, isBusy: true
        ) == .bluetoothUnavailable("x"))
        #expect(KeyboardReadiness.evaluate(
            isActive: true, bluetoothProblem: nil, subscriberCount: 0, leds: .capsLock, isBusy: true
        ) == .waitingForHost)
        #expect(KeyboardReadiness.evaluate(
            isActive: true, bluetoothProblem: nil, subscriberCount: 1, leds: .capsLock, isBusy: true
        ) == .capsLockOn)
        #expect(KeyboardReadiness.evaluate(
            isActive: true, bluetoothProblem: nil, subscriberCount: 1, leds: .numLock, isBusy: true
        ) == .busy)
        #expect(KeyboardReadiness.evaluate(
            isActive: true, bluetoothProblem: nil, subscriberCount: 1, leds: nil, isBusy: false
        ) == .ready)
    }

    @Test func moreThanOneSubscribedHostIsNotReady() {
        let readiness = KeyboardReadiness.evaluate(
            isActive: true, bluetoothProblem: nil, subscriberCount: 2, leds: .capsLock, isBusy: true
        )
        #expect(readiness == .multipleHosts(2))
        #expect(readiness.message?.contains("más de un ordenador") == true)
    }

    @Test func helperInProgressBlocksAndHelperTypedAsks() {
        let writeID = UUID()
        #expect(HelperLineActivity(.idle) == .none)
        #expect(HelperLineActivity(.sending(writeID: writeID)) == .inProgress)
        #expect(HelperLineActivity(.confirming(writeID: writeID, returningTo: .idle)) == .inProgress)

        #expect(step(.idle, helper: .inProgress) == .nothing)
        #expect(!KeyboardWriteFlow.canTap(.idle, helper: .inProgress, isTypeable: true, readiness: .ready))
        #expect(KeyboardWriteFlow.blockedReason(.idle, helper: .inProgress, isTypeable: true, readiness: .ready)
            == KeyboardWriteFlow.helperBusyReason)

        #expect(step(.idle, helper: .typed) == .confirm(writeID: secondID))
        #expect(dialog(.idle, helper: .typed)?.causes == [.helperAlreadyTyped])
    }

    @Test func failedHelperWriteAsksBecauseATimeoutMayHaveTypedTheLine() {
        let failed = CommandSendState.failed(writeID: UUID(), reason: "La Mac no respondió a tiempo.", helperWarnings: [])
        #expect(HelperLineActivity(failed) == .mayHaveTyped)
        #expect(step(.idle, helper: .mayHaveTyped) == .confirm(writeID: secondID))
        #expect(dialog(.idle, helper: .mayHaveTyped)?.causes == [.helperMayHaveTyped])
        #expect(KeyboardWriteFlow.canTap(.idle, helper: .mayHaveTyped, isTypeable: true, readiness: .ready))
    }

    @Test func multilineAndPossiblyCutLinesAreRefusedBeforeAnyPlan() {
        let single = CommandCandidate(text: "ls", sourceLine: "ls", lineIndex: 0, isPartOfMultilineCommand: false)
        let multiline = CommandCandidate(text: "ls \\", sourceLine: "ls \\", lineIndex: 0, isPartOfMultilineCommand: true)
        #expect(KeyboardWriteFlow.lineRefusal(single, isPossiblyTruncated: false) == nil)
        #expect(KeyboardWriteFlow.lineRefusal(multiline, isPossiblyTruncated: false)?.hasPrefix(CommandCandidate.multilineNote) == true)
        #expect(KeyboardWriteFlow.lineRefusal(single, isPossiblyTruncated: true)?.hasPrefix(KeyboardWriteFlow.possiblyTruncatedReason) == true)
        #expect(KeyboardWriteFlow.lineRefusal(multiline, isPossiblyTruncated: true)?.hasSuffix("No se ha enviado nada.") == true)
    }

    @Test func optionChordsOnMacAskUntilTheNoticeIsAccepted() {
        #expect(step(.idle, optionNotice: true) == .confirm(writeID: secondID))
        #expect(dialog(.idle, optionNotice: true)?.causes == [.optionChords])
        #expect(step(.idle, optionNotice: false) == .write(writeID: secondID, acknowledged: []))
    }

    @Test func confirmationNamesEveryCauseAndTheLayout() {
        let confirmation = dialog(typed, helper: .typed, warnings: ["sudo", "dd"], optionNotice: true)
        #expect(confirmation?.causes == [.warnings, .retype, .helperAlreadyTyped, .optionChords])
        #expect(confirmation?.layoutID == .macSpanishISO)
        #expect(confirmation?.acknowledged == ["sudo", "dd"])
        #expect(confirmation?.jobID == secondID)
    }
}
