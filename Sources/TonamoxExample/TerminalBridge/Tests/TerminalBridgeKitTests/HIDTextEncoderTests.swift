import Testing
@testable import TerminalBridgeKit

@Suite struct HIDTextEncoderTests {
    private static let spikeLine = "tonamox ble hid ok 123"

    /// The spike's own US mapping: a-z from 0x04, 1-9 from 0x1E, 0 at 0x27, space 0x2C.
    private static func spikeUsage(_ scalar: Unicode.Scalar) -> UInt8 {
        switch scalar {
        case "a"..."z": UInt8(0x04 + scalar.value - 0x61)
        case "1"..."9": UInt8(0x1E + scalar.value - 0x31)
        case "0": 0x27
        default: 0x2C
        }
    }

    private func encoded(_ text: String, _ id: HostKeyboardLayoutID) -> Result<[HIDKeystroke], HIDEncodingFailure> {
        HIDTextEncoder.encode(text, layout: HostKeyboardLayout.layout(id))
    }

    @Test(arguments: [HostKeyboardLayoutID.macUS, .macSpanishISO])
    func encodesTheVerifiedSpikeLineWithTheSpikeUsages(id: HostKeyboardLayoutID) throws {
        let typed = try encoded(Self.spikeLine, id).get()
        #expect(typed.map(\.usage.rawValue) == Self.spikeLine.unicodeScalars.map(Self.spikeUsage))
        #expect(typed.allSatisfy { $0.modifiers.isEmpty })
    }

    @Test(arguments: HostKeyboardLayoutID.allCases)
    func uppercaseUsesShift(id: HostKeyboardLayoutID) throws {
        let typed = try encoded("Ab", id).get()
        let expected = ["S04", "05"].compactMap { keystrokes(fromCell: $0)?.first }
        #expect(typed == expected)
        #expect(typed.count == 2)
    }

    @Test(arguments: ["ls\n", "ls\rx", "a\tb", "a\u{1B}b", "a\u{7F}b", "a\u{0}b", "a\u{85}b", "x\u{2028}y"])
    func refusesNewlineReturnTabEscapeAndControlCharactersBeforeMapping(text: String) {
        for id in HostKeyboardLayoutID.allCases {
            guard case .failure(.policy(let violations)) = encoded(text, id) else {
                Issue.record("\(id.rawValue) did not refuse \(text.debugDescription) by policy")
                continue
            }
            #expect(!violations.isEmpty)
        }
    }

    @Test func refusesNonASCIIText() {
        guard case .failure(.policy(let violations)) = encoded("echo ñ", .macSpanishISO) else {
            Issue.record("ñ was not refused")
            return
        }
        #expect(violations == [.disallowedCharacter(scalar: 0xF1, offset: 5)])
    }

    @Test func refusesTheWholeTextWhenAnyCharacterIsUnmappable() {
        let layout = HostKeyboardLayout.macUS.removing("|")
        let result = HIDTextEncoder.encode("ls | wc", layout: layout)
        #expect(result == .failure(.unmappable([UnmappableCharacter(scalar: 0x7C, offset: 3)])))
        #expect((try? HIDTextEncoder.encode("ls wc", layout: layout).get())?.count == 5)
    }

    @Test func listsEveryUnmappableCharacterWithItsOffset() {
        let layout = HostKeyboardLayout.macUS.removing("|~")
        guard case .failure(.unmappable(let characters)) = HIDTextEncoder.encode("a|b~c|d", layout: layout) else {
            Issue.record("not refused")
            return
        }
        #expect(characters.map(\.offset) == [1, 3, 5])
        #expect(characters.map(\.scalar) == [0x7C, 0x7E, 0x7C])
        #expect(characters.first?.message == "«|» U+007C en la posición 2")
    }

    @Test func capsTheNumberOfReportedCharacters() {
        let layout = HostKeyboardLayout.macUS.removing("|")
        let text = "a" + String(repeating: "|a", count: 40)
        guard case .failure(.unmappable(let characters)) = HIDTextEncoder.encode(text, layout: layout) else {
            Issue.record("not refused")
            return
        }
        #expect(characters.count == CommandTextPolicy.maxReportedCharacters)
    }

    @Test(arguments: [HostKeyboardLayoutID.macSpanishISO, .windowsSpanish, .linuxSpanish])
    func caretOnSpanishLayoutsIsDeadKeyThenSpace(id: HostKeyboardLayoutID) throws {
        let typed = try encoded("a^b", id).get()
        let expected = ["04", "S2F", "2C", "05"].compactMap { keystrokes(fromCell: $0)?.first }
        #expect(typed == expected)
    }
}
