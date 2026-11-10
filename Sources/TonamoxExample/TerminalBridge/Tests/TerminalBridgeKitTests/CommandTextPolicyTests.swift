import Foundation
import Testing
@testable import TerminalBridgeKit

@Suite struct CommandTextPolicyTests {
    static let forbiddenScalars: [UInt32] = [
        0x0D, 0x0A, 0x09, 0x1B, 0x00, 0x03, 0x15, 0x7F, 0x85, 0x9B,
        0x200B, 0x202E, 0x2066, 0xFEFF, 0x00A0, 0x2028, 0x2029, 0xE000,
        0xF1, 0xE9, 0x20AC, 0x2215, 0xFF0F, 0x0301, 0x1F680
    ]

    private func embedded(_ value: UInt32) -> String {
        var text = "ls"
        text.unicodeScalars.append(Unicode.Scalar(value)!)
        text += "x"
        return text
    }

    @Test(arguments: CommandTextPolicyTests.forbiddenScalars)
    func rejectsEveryNonPrintableOrNonASCIIScalar(_ value: UInt32) {
        let violations = CommandTextPolicy.validate(embedded(value))
        #expect(violations.contains(.disallowedCharacter(scalar: value, offset: 2)))
        #expect(!CommandTextPolicy.isValid(embedded(value)))
        #expect(!CommandTextPolicy.isValid(bytes: Array(embedded(value).utf8)))
    }

    @Test func rejectsEmptyAndEdgeSpaces() {
        #expect(CommandTextPolicy.validate("") == [.empty])
        #expect(CommandTextPolicy.validate(" ls") == [.leadingSpace])
        #expect(CommandTextPolicy.validate("ls ") == [.trailingSpace])
        #expect(CommandTextPolicy.validate(" ") == [.leadingSpace, .trailingSpace])
    }

    @Test func acceptsPlainCommands() {
        #expect(CommandTextPolicy.isValid("ls -la ~/Ano"))
        #expect(CommandTextPolicy.isValid(#"printf "a\nb""#))
        #expect(CommandTextPolicy.isValid("echo $HOME; cat a | grep 'x' && true"))
        let everyPrintable = String((0x21...0x7E).compactMap(Unicode.Scalar.init).map(Character.init))
        #expect(CommandTextPolicy.isValid(everyPrintable))
        #expect(CommandTextPolicy.isValid(bytes: Array(everyPrintable.utf8)))
    }

    @Test func countsBytesNotCharacters() {
        let limit = String(repeating: "a", count: 512)
        #expect(CommandTextPolicy.isValid(limit))
        #expect(CommandTextPolicy.validate(limit + "b") == [.tooLong(bytes: 513)])
        let multibyteEdge = String(repeating: "a", count: 511) + "ñ"
        let violations = CommandTextPolicy.validate(multibyteEdge)
        #expect(violations.contains(.tooLong(bytes: 513)))
        #expect(violations.contains(.disallowedCharacter(scalar: 0xF1, offset: 511)))
    }

    @Test func crlfIsTwoViolations() {
        let violations = CommandTextPolicy.validate("ls\r\n")
        #expect(violations == [
            .disallowedCharacter(scalar: 0x0D, offset: 2),
            .disallowedCharacter(scalar: 0x0A, offset: 3)
        ])
    }

    @Test func messagesNameTheCharacterAndPosition() {
        #expect(CommandTextViolation.disallowedCharacter(scalar: 0x200B, offset: 11).message
            == "Carácter invisible U+200B en la posición 12")
        #expect(CommandTextViolation.disallowedCharacter(scalar: 0x0A, offset: 0).message
            == "Salto de línea U+000A en la posición 1")
        #expect(CommandTextViolation.disallowedCharacter(scalar: 0xF1, offset: 4).message
            == "Carácter no ASCII U+00F1 en la posición 5")
        #expect(CommandTextViolation.disallowedCharacter(scalar: 0x1F680, offset: 0).message.contains("U+1F680"))
        #expect(CommandTextViolation.tooLong(bytes: 600).message.contains("512"))
    }

    @Test func reportsAtMostSixteenCharacters() {
        let text = String(repeating: "\u{200B}", count: 40)
        let characterViolations = CommandTextPolicy.validate(text).filter {
            if case .disallowedCharacter = $0 { return true }
            return false
        }
        #expect(characterViolations.count == CommandTextPolicy.maxReportedCharacters)
    }

    @Test func byteCheckRejectsWhatStringCheckRejects() {
        #expect(!CommandTextPolicy.isValid(bytes: [UInt8]()))
        #expect(!CommandTextPolicy.isValid(bytes: Array(" ls".utf8)))
        #expect(!CommandTextPolicy.isValid(bytes: Array("ls ".utf8)))
        #expect(!CommandTextPolicy.isValid(bytes: [0x6C, 0x73, 0x0D]))
        #expect(!CommandTextPolicy.isValid(bytes: [0x6C, 0x73, 0xC3, 0xB1]))
        #expect(!CommandTextPolicy.isValid(bytes: [UInt8](repeating: 0x61, count: 513)))
        #expect(CommandTextPolicy.isValid(bytes: Data("ls -la".utf8)))
    }
}
