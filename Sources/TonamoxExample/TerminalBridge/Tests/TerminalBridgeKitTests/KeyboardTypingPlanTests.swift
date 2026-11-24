import Testing
@testable import TerminalBridgeKit

@Suite struct KeyboardTypingPlanTests {
    private static let allRules = RiskyRule.allCases.map(\.rawValue)
    /// Every printable ASCII character, wrapped so the policy's edge-space rule passes.
    private static let everyPrintable = "x" + String(HostKeyboardLayout.printableASCII) + "x"

    private func report(_ modifierByte: UInt8, _ keyUsage: UInt8) -> HIDKeyboardReport {
        HIDKeyboardReport(modifierByte: modifierByte, keyUsage: keyUsage)
    }

    private func plan(_ text: String, _ id: HostKeyboardLayoutID, acknowledged: [String] = [])
        -> Result<KeyboardTypingPlan, KeyboardTypingRefusal>
    {
        KeyboardTypingPlan.make(text: text, layout: HostKeyboardLayout.layout(id), acknowledged: acknowledged)
    }

    /// Any scalar: printable ASCII, controls, newlines, Latin-1, emoji.
    private func randomText(using generator: inout SeededGenerator) -> String {
        let length = Int.random(in: 1...24, using: &generator)
        let pools: [ClosedRange<UInt32>] = [0x20...0x7E, 0x20...0x7E, 0x20...0x7E, 0x00...0x1F, 0x7F...0xFF, 0x1F600...0x1F64F]
        let scalars = (0..<length).compactMap { _ in
            Unicode.Scalar(UInt32.random(in: pools.randomElement(using: &generator) ?? 0x20...0x7E, using: &generator))
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private func check(_ text: String, on layout: HostKeyboardLayout) -> Bool {
        switch KeyboardTypingPlan.make(text: text, layout: layout, acknowledged: Self.allRules) {
        case .success(let built):
            return built.reports.allSatisfy { $0.isPermitted(within: layout.permittedModifiers) }
        case .failure:
            return true
        }
    }

    @Test func unmodifiedKeystrokeIsKeyThenRelease() throws {
        let keystroke = try #require(HIDKeystroke(modifiers: [], usage: 0x04))
        #expect(HIDReportSequencer.reports(for: keystroke) == [report(0, 0x04), .released])
    }

    @Test func modifiedKeystrokePressesTheModifierFirstAndReleasesEverything() throws {
        let keystroke = try #require(HIDKeystroke(modifiers: .rightAlt, usage: 0x1F))
        #expect(HIDReportSequencer.reports(for: keystroke) == [
            report(0x40, 0), report(0x40, 0x1F), report(0x40, 0), .released,
        ])
    }

    @Test func repeatedCharactersAreReleasedBetweenPresses() throws {
        let built = try plan("aa", .macUS).get()
        #expect(built.reports == [.released, report(0, 0x04), .released, report(0, 0x04), .released, .released])
        #expect(built.keystrokeCount == 2)
    }

    @Test(arguments: HostKeyboardLayoutID.allCases)
    func noPlanContainsAForbiddenReport(id: HostKeyboardLayoutID) throws {
        let layout = HostKeyboardLayout.layout(id)
        let full = try KeyboardTypingPlan.make(text: Self.everyPrintable, layout: layout, acknowledged: Self.allRules).get()
        #expect(full.reports.allSatisfy { $0.isPermitted && $0.isPermitted(within: layout.permittedModifiers) })
        var generator = SeededGenerator(seed: 0x544E_5821 ^ UInt64(id.rawValue.utf8.count))
        var failures = 0
        for _ in 0..<300 where !check(randomText(using: &generator), on: layout) {
            failures += 1
        }
        #expect(failures == 0)
    }

    @Test func refusesAnUnacknowledgedRiskyCommand() {
        #expect(plan("sudo ls", .macUS) == .failure(.unacknowledgedWarnings([.sudo])))
        #expect(plan("sudo ls", .macUS, acknowledged: ["dd"]) == .failure(.unacknowledgedWarnings([.sudo])))
    }

    @Test func acknowledgedRiskyCommandIsTyped() throws {
        let built = try plan("sudo ls", .macUS, acknowledged: ["sudo"]).get()
        #expect(built.text == "sudo ls")
        #expect(built.keystrokeCount == 7)
    }

    @Test func refusalMessagesAreSpanishAndSayNothingWasSent() {
        let refusals: [KeyboardTypingRefusal] = [
            .policy([.empty, .leadingSpace]),
            .unacknowledgedWarnings([.sudo, .dd]),
            .unmappable([UnmappableCharacter(scalar: 0x7C, offset: 3)], layoutTitle: "EE. UU."),
            .layoutChanged,
            .unsafeReport,
        ]
        #expect(refusals.allSatisfy { $0.message.hasSuffix("No se ha enviado nada.") })
        #expect(refusals.allSatisfy { !$0.message.contains("..") })
        #expect(KeyboardTypingRefusal.policy([.empty]).message == "No se puede teclear: La orden está vacía. No se ha enviado nada.")
        #expect(KeyboardTypingRefusal.unmappable([UnmappableCharacter(scalar: 0x7C, offset: 3)], layoutTitle: "EE. UU.").message
            == "La distribución «EE. UU.» no puede escribir: «|» U+007C en la posición 4. No se ha enviado nada.")
        let tooLong = String(repeating: "a", count: 600)
        guard case .failure(let refusal) = plan(tooLong, .macUS) else {
            Issue.record("600 bytes were not refused")
            return
        }
        #expect(refusal == .policy([.tooLong(bytes: 600)]))
    }

    @Test func listsCharactersOutsideTheVerifiedSet() throws {
        #expect(try plan("ls -la ~/x", .macUS).get().unverifiedCharacters == ["s", "-", "~", "/"])
        #expect(try plan("ok 123", .macSpanishISO).get().unverifiedCharacters == ["o", "k", "1", "2", "3"])
        #expect(try plan("ls 123", .macSpanishISO).get().unverifiedCharacters == ["l", "s", "1", "2", "3"])
        #expect(try plan("{}[]<>~^`@#", .macSpanishISO, acknowledged: Self.allRules).get().unverifiedCharacters.isEmpty)
        #expect(try plan(HostKeyboardLayout.probeSpanish, .macSpanishISO, acknowledged: Self.allRules).get()
            .unverifiedCharacters.isEmpty)
        #expect(try plan("ls", .windowsUS).get().unverifiedCharacters == ["l", "s"])
    }

    @Test(arguments: HostKeyboardLayoutID.allCases)
    func everyKeyPressIsReleasedBeforeTheNextKeyPress(id: HostKeyboardLayoutID) throws {
        let built = try plan(Self.everyPrintable, id, acknowledged: Self.allRules).get()
        let pairs = zip(built.reports, built.reports.dropFirst())
        #expect(pairs.allSatisfy { !($0.keyUsage != 0 && $1.keyUsage != 0) })
        // A modifier never changes while a key is down.
        #expect(pairs.allSatisfy { $0.keyUsage == 0 || $1.modifierByte == $0.modifierByte })
    }

    @Test(arguments: HostKeyboardLayoutID.allCases)
    func planStartsAndEndsWithEverythingReleased(id: HostKeyboardLayoutID) throws {
        let built = try plan("echo Hi", id).get()
        #expect(built.reports.first == .released)
        #expect(built.reports.last == .released)
        #expect(built.reports.count == 2 + 4 * 1 + 2 * 6)
    }

    @Test(arguments: HostKeyboardLayoutID.allCases)
    func planReportsUseOnlyTheLayoutsModifiers(id: HostKeyboardLayoutID) throws {
        let layout = HostKeyboardLayout.layout(id)
        let built = try plan(Self.everyPrintable, id, acknowledged: Self.allRules).get()
        #expect(built.permittedModifiers == layout.permittedModifiers)
        #expect(built.reports.allSatisfy { $0.modifierByte & ~layout.permittedModifiers.rawValue == 0 })
        #expect(built.layoutID == id)
    }

    @Test func macPlansWithOptionChordsAreFlagged() throws {
        #expect(try plan("echo a|b", .macSpanishISO).get().usesOptionChords)
        #expect(try !plan("echo a/b", .macSpanishISO).get().usesOptionChords)
        for id in HostKeyboardLayoutID.allCases where id != .macSpanishISO {
            #expect(try !plan(Self.everyPrintable, id, acknowledged: Self.allRules).get().usesOptionChords)
        }
    }
}
