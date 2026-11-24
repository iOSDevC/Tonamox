import Foundation
import Testing
@testable import TerminalBridgeKit

@Suite struct CommandRowActionsTests {
    private let id = UUID()

    private func offer(
        helper: Bool = false,
        helperBusy: Bool = false,
        keyboard: Bool = false,
        keyboardBusy: Bool = false
    ) -> SendChannelOffer {
        SendChannelOffer.make(
            helperConnected: helper, helperInFlight: helperBusy, keyboardActive: keyboard, keyboardInFlight: keyboardBusy
        )
    }

    private func ack(_ result: AckResult, verified: Bool) -> WriteAck {
        WriteAck(id: id, result: result, bytes: 2, textSHA256: "", warnings: [], verified: verified)
    }

    // MARK: Offer

    @Test func helperOnlyOffersTheHelper() {
        #expect(offer(helper: true) == SendChannelOffer(channels: [.helper], unavailableReason: nil))
    }

    @Test func keyboardOnlyOffersTheKeyboard() {
        #expect(offer(keyboard: true) == SendChannelOffer(channels: [.keyboard], unavailableReason: nil))
    }

    @Test func bothAvailableOffersBothNeverChoosing() {
        #expect(offer(helper: true, keyboard: true).channels == [.keyboard, .helper])
        #expect(offer(helper: true, keyboard: true).unavailableReason == nil)
    }

    @Test func nothingAvailableKeepsADisabledHelperWithBothExistingReasons() {
        let none = offer()
        #expect(none.channels == [.helper])
        #expect(none.unavailableReason == "Sin conexión con la Mac. El teclado Bluetooth no está activado.")
    }

    @Test func aChannelBusyWithTheLineStaysOfferedAfterItGoesAway() {
        #expect(offer(helperBusy: true) == SendChannelOffer(channels: [.helper], unavailableReason: nil))
        #expect(offer(keyboardBusy: true).channels == [.keyboard])
        #expect(offer(helperBusy: true, keyboard: true).channels == [.keyboard, .helper])
    }

    // MARK: Labels and symbols

    @Test func channelsHaveDistinctSymbols() {
        #expect(SendChannel.keyboard.symbol == "keyboard")
        #expect(SendChannel.helper.symbol == "cable.connector")
        #expect(Set(SendChannel.allCases.map(\.symbol)).count == SendChannel.allCases.count)
        #expect(!SendChannel.allCases.map(\.symbol).contains(CommandRowActions.copySymbol))
    }

    @Test func labelsNameTheChannelInEveryPhase() {
        #expect(SendChannel.keyboard.accessibilityLabel(.ready) == "Escribir con el teclado Bluetooth")
        #expect(SendChannel.helper.accessibilityLabel(.ready) == "Escribir por USB")
        #expect(SendChannel.helper.accessibilityLabel(.inFlight) == "Enviando por USB")
        #expect(SendChannel.keyboard.accessibilityLabel(.inFlight) == "Tecleando con el teclado Bluetooth")
        #expect(SendChannel.helper.accessibilityLabel(.done) == "Escribir de nuevo por USB")
        #expect(SendChannel.keyboard.accessibilityLabel(.failed) == "Reintentar con el teclado Bluetooth")
    }

    // MARK: Phases

    @Test func helperPhases() {
        let sent = CommandSendState.sent(writeID: id, ack: ack(.typed, verified: true), target: "t:0")
        #expect(CommandIconPhase(helper: .idle) == .ready)
        #expect(CommandIconPhase(helper: .confirming(writeID: id, returningTo: sent)) == .ready)
        #expect(CommandIconPhase(helper: .sending(writeID: id)) == .inFlight)
        #expect(CommandIconPhase(helper: sent) == .done)
        #expect(CommandIconPhase(helper: .failed(writeID: id, reason: "x", helperWarnings: [])) == .failed)
    }

    @Test func keyboardPhases() {
        #expect(CommandIconPhase(keyboard: .idle) == .ready)
        #expect(CommandIconPhase(keyboard: .typing(jobID: id, sentReports: 1, totalReports: 4)) == .inFlight)
        #expect(CommandIconPhase(keyboard: .typed(jobID: id, layoutID: .macUS, keystrokes: 2, unverified: "")) == .done)
        #expect(CommandIconPhase(keyboard: .failed(jobID: id, reason: "x", sentReports: 0)) == .failed)
    }

    @Test func clipboardPhases() {
        #expect(CommandIconPhase(clipboard: .idle) == .ready)
        #expect(CommandIconPhase(clipboard: .copied(copyID: id, text: "ls", expiresAt: .distantFuture)) == .done)
        #expect(CommandIconPhase(clipboard: .failed(copyID: id, reason: "x")) == .failed)
    }

    // MARK: In flight and success

    @Test func openDialogsCountAsInFlight() {
        #expect(CommandRowActions.isInFlight(helper: .confirming(writeID: id, returningTo: .idle)))
        #expect(CommandRowActions.isInFlight(helper: .sending(writeID: id)))
        #expect(!CommandRowActions.isInFlight(helper: .idle))
        #expect(CommandRowActions.isInFlight(keyboard: .confirming(jobID: id, layoutID: .macUS, returningTo: .idle)))
        #expect(!CommandRowActions.isInFlight(keyboard: .failed(jobID: id, reason: "x", sentReports: 2)))
    }

    @Test func onlyAVerifiedFreshHelperWriteEarnsTheCheckmark() {
        let verified = CommandSendState.sent(writeID: id, ack: ack(.typed, verified: true), target: "t:0")
        let unverified = CommandSendState.sent(writeID: id, ack: ack(.typed, verified: false), target: "t:0")
        let repeated = CommandSendState.sent(writeID: id, ack: ack(.alreadyTyped, verified: true), target: "t:0")
        #expect(CommandRowActions.successID(helper: verified) == id)
        #expect(CommandRowActions.successID(helper: unverified) == nil)
        #expect(CommandRowActions.successID(helper: repeated) == nil)
        #expect(CommandRowActions.successID(helper: .failed(writeID: id, reason: "x", helperWarnings: [])) == nil)
    }

    @Test func keyboardAndClipboardSuccessIDs() {
        #expect(CommandRowActions.successID(keyboard: .typed(jobID: id, layoutID: .macUS, keystrokes: 1, unverified: "")) == id)
        #expect(CommandRowActions.successID(keyboard: .typing(jobID: id, sentReports: 0, totalReports: 1)) == nil)
        #expect(CommandRowActions.successID(clipboard: .copied(copyID: id, text: "ls", expiresAt: .distantFuture)) == id)
        #expect(CommandRowActions.successID(clipboard: .failed(copyID: id, reason: "x")) == nil)
    }

    @Test func anUnverifiedKeyboardTypingGetsNoCheckmark() {
        let typed = KeyboardSendState.typed(jobID: id, layoutID: .macUS, keystrokes: 3, unverified: "ñ")
        #expect(CommandRowActions.successID(keyboard: typed) == nil)
    }

    @Test func keyboardStatusOutlivesTheKeyboardWhileTheLineNeedsIt() {
        let confirming = KeyboardSendState.confirming(jobID: id, layoutID: .macUS, returningTo: .idle)
        let typing = KeyboardSendState.typing(jobID: id, sentReports: 1, totalReports: 4)
        let failed = KeyboardSendState.failed(jobID: id, reason: "x", sentReports: 2)
        let typed = KeyboardSendState.typed(jobID: id, layoutID: .macUS, keystrokes: 1, unverified: "")
        #expect(CommandRowActions.showsKeyboardStatus(keyboardActive: true, keyboard: .idle))
        #expect(CommandRowActions.showsKeyboardStatus(keyboardActive: false, keyboard: confirming))
        #expect(CommandRowActions.showsKeyboardStatus(keyboardActive: false, keyboard: typing))
        #expect(CommandRowActions.showsKeyboardStatus(keyboardActive: false, keyboard: failed))
        #expect(!CommandRowActions.showsKeyboardStatus(keyboardActive: false, keyboard: .idle))
        #expect(!CommandRowActions.showsKeyboardStatus(keyboardActive: false, keyboard: typed))
    }
}
