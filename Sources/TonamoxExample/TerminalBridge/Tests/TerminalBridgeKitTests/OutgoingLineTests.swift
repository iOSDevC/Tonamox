import Foundation
import Testing
@testable import TerminalBridgeKit

@Suite struct OutgoingLineTests {
    private let id = CaptureID("1a2b3c4d")!

    private func candidate(_ text: String, multiline: Bool = false) -> CommandCandidate {
        CommandCandidate(text: text, sourceLine: text, lineIndex: 0, isPartOfMultilineCommand: multiline)
    }

    private func capture(_ original: String, _ host: HostOS = .macOS) throws -> CaptureLines {
        try CaptureWrapper.wrap(original, host: host, id: id).get()
    }

    /// A capture whose final line differs in ways the real wrapper never produces.
    private func fakeCapture(original: String, wrapped: String) -> CaptureLines {
        CaptureLines(
            host: .macOS, id: id, original: original, wrapped: wrapped, readBack: "true", returnsToClipboard: true,
            filePath: "$HOME/.tonamox-capture/c-1a2b3c4d.txt"
        )
    }

    @Test func withoutCaptureTheOutgoingTextIsTheOriginal() throws {
        let line = candidate("git status")
        let outgoing = try OutgoingLine.make(candidate: line, isPossiblyTruncated: false, capture: nil).get()
        #expect(outgoing.text == "git status")
        #expect(outgoing.candidateID == line.id)
        #expect(outgoing.capture == nil)
        #expect(outgoing.localWarnings.isEmpty)
    }

    @Test func withCaptureTheOutgoingTextIsTheWrappedLine() throws {
        let lines = try capture("git status")
        let outgoing = try OutgoingLine.make(candidate: candidate("git status"), isPossiblyTruncated: false, capture: lines)
            .get()
        #expect(outgoing.text == lines.wrapped)
        #expect(outgoing.capture == lines)
    }

    @Test func localWarningsAreTheOriginalsThenTheFinalLinesWithoutDuplicates() throws {
        let real = try OutgoingLine.make(
            candidate: candidate("sudo rm -rf build"), isPossiblyTruncated: false, capture: try capture("sudo rm -rf build")
        ).get()
        #expect(real.localWarnings == ["sudo", "rmRecursiveForce"])
        let fake = fakeCapture(original: "rm -rf x", wrapped: "sudo rm -rf x | sh")
        let outgoing = try OutgoingLine.make(candidate: candidate("rm -rf x"), isPossiblyTruncated: false, capture: fake)
            .get()
        #expect(outgoing.localWarnings == ["rmRecursiveForce", "sudo", "pipeToShell"])
    }

    @Test func multilineAndPossiblyCutLinesAreRefused() {
        let multi = OutgoingLine.make(candidate: candidate("ls", multiline: true), isPossiblyTruncated: false, capture: nil)
        #expect(multi == .failure(.line(CommandCandidate.multilineNote + " No se ha enviado nada.")))
        let cut = OutgoingLine.make(candidate: candidate("ls"), isPossiblyTruncated: true, capture: nil)
        #expect(cut == .failure(.line(KeyboardWriteFlow.possiblyTruncatedReason + " No se ha enviado nada.")))
    }

    @Test func policyIsCheckedOnTheOriginalAndTheFinalLine() {
        let original = OutgoingLine.make(candidate: candidate("echo café"), isPossiblyTruncated: false, capture: nil)
        #expect(original == .failure(.policy([.disallowedCharacter(scalar: 0xE9, offset: 8)])))
        let long = fakeCapture(original: "ls", wrapped: "ls " + String(repeating: "a", count: 600))
        let final = OutgoingLine.make(candidate: candidate("ls"), isPossiblyTruncated: false, capture: long)
        #expect(final == .failure(.policy([.tooLong(bytes: 603)])))
    }

    @Test func captureForAnotherTextIsRefused() throws {
        let other = try capture("git status")
        let result = OutgoingLine.make(candidate: candidate("git diff"), isPossiblyTruncated: false, capture: other)
        #expect(result == .failure(.captureMismatch))
        #expect(OutgoingLineRefusal.captureMismatch.message.hasSuffix("No se ha enviado nada."))
    }

    static let failedHelper: CommandSendState = .failed(writeID: UUID(), reason: "x", helperWarnings: [])
    static let busyHelper: [CommandSendState] = [
        .confirming(writeID: UUID(), returningTo: .idle), .sending(writeID: UUID()),
        .sent(
            writeID: UUID(),
            ack: WriteAck(id: UUID(), result: .typed, bytes: 2, textSHA256: "x", warnings: [], verified: true),
            target: "tnx:0"
        ),
        failedHelper,
    ]
    static let busyKeyboard: [KeyboardSendState] = [
        .confirming(jobID: UUID(), layoutID: .macUS, returningTo: .idle),
        .typing(jobID: UUID(), sentReports: 1, totalReports: 4),
        .typed(jobID: UUID(), layoutID: .macUS, keystrokes: 2, unverified: ""),
        .failed(jobID: UUID(), reason: "x", sentReports: 1),
    ]
    static let busyClipboard: [ClipboardCopyState] = [.confirming(copyID: UUID(), returningTo: .idle)]

    private func canChange(
        helper: CommandSendState = .idle,
        refusedLocally: Bool = false,
        keyboard: KeyboardSendState = .idle,
        clipboard: ClipboardCopyState = .idle
    ) -> Bool {
        CaptureToggle.canChange(
            helper: helper, helperRefusedLocally: refusedLocally, keyboard: keyboard, clipboard: clipboard
        )
    }

    @Test func toggleIsLockedWhileAnyChannelMayHaveTypedOrHasADialogOpen() {
        #expect(canChange())
        for helper in Self.busyHelper {
            #expect(!canChange(helper: helper))
        }
        for keyboard in Self.busyKeyboard {
            #expect(!canChange(keyboard: keyboard))
        }
        for clipboard in Self.busyClipboard {
            #expect(!canChange(clipboard: clipboard))
        }
    }

    @Test func failuresThatTypedNothingDoNotLockTheToggle() {
        #expect(canChange(helper: Self.failedHelper, refusedLocally: true))
        #expect(canChange(keyboard: .failed(jobID: UUID(), reason: "x", sentReports: 0)))
        #expect(canChange(clipboard: .copied(copyID: UUID(), text: "ls", expiresAt: .distantPast)))
        #expect(canChange(clipboard: .failed(copyID: UUID(), reason: "x")))
    }

    @Test func refusedLocallyOnlyFreesAFailedHelper() {
        for helper in Self.busyHelper where helper != Self.failedHelper {
            #expect(!canChange(helper: helper, refusedLocally: true))
        }
    }

    @Test func helperAndClipboardRefuseANonMacCapture() throws {
        let linux = try capture("ls", .linux)
        let windows = try capture("dir", .windows)
        #expect(CaptureToggle.channelRefusal(capture: linux, channelReachesOnlyMac: true)?.contains("Linux") == true)
        #expect(CaptureToggle.channelRefusal(capture: windows, channelReachesOnlyMac: true)?.contains("Windows") == true)
        #expect(CaptureToggle.channelRefusal(capture: linux, channelReachesOnlyMac: false) == nil)
        #expect(CaptureToggle.channelRefusal(capture: try capture("ls"), channelReachesOnlyMac: true) == nil)
        #expect(CaptureToggle.channelRefusal(capture: nil, channelReachesOnlyMac: true) == nil)
    }
}
