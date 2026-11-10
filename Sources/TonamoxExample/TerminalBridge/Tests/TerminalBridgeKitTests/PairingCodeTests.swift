import Foundation
import Testing
@testable import TerminalBridgeKit

@Suite struct PairingCodeTests {
    // Independently computed with Python's base64.b32encode mapped to the Crockford alphabet.
    private let knownFormatted = "000G-40R4-0M30-E209-185G-R38E-1W81-24GK-041D"
    private let knownFingerprint = "SJMQ-HVBB"

    private func reparse(_ text: String) throws -> PairingCode {
        try PairingCode(parsing: text)
    }

    @Test func matchesAnIndependentVector() throws {
        let code = try PairingCode(secret: TestSecrets.primary)
        #expect(code.formatted == knownFormatted)
        #expect(code.fingerprint == knownFingerprint)
        #expect(try PairingCode(parsing: knownFormatted).secret == TestSecrets.primary)
    }

    @Test func randomSecretsRoundTrip() throws {
        for _ in 0..<1000 {
            let code = PairingCode.generate()
            #expect(try reparse(code.formatted) == code)
        }
    }

    @Test func formatIsNineGroupsOfFour() {
        let code = PairingCode.generate()
        #expect(code.groups.count == 9)
        #expect(code.groups.allSatisfy { $0.count == 4 })
        #expect(code.compact.count == PairingCode.characterCount)
        #expect(code.compact.allSatisfy { CrockfordBase32.alphabet.contains($0) })
    }

    @Test func toleratesCaseSpacesAndLookalikes() throws {
        let sloppy = knownFormatted.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "0", with: "o")
            .replacingOccurrences(of: "1", with: "l")
        #expect(try PairingCode(parsing: sloppy).secret == TestSecrets.primary)
        let withI = knownFormatted.replacingOccurrences(of: "1", with: "I")
        #expect(try PairingCode(parsing: withI).secret == TestSecrets.primary)
    }

    @Test func detectsAMistypedCharacter() {
        var characters = Array(knownFormatted)
        characters[5] = "5"
        #expect(throws: PairingCodeError.checksumMismatch) { try PairingCode(parsing: String(characters)) }
    }

    @Test func detectsAMistypedChecksum() {
        let wrongChecksum = String(knownFormatted.dropLast()) + "E"
        #expect(throws: PairingCodeError.checksumMismatch) { try PairingCode(parsing: wrongChecksum) }
    }

    @Test func rejectsWrongLengthAndInvalidCharacters() {
        let short = String(knownFormatted.dropLast())
        #expect(throws: PairingCodeError.wrongLength(35)) { try PairingCode(parsing: short) }
        #expect(throws: PairingCodeError.invalidCharacter("U")) { try PairingCode(parsing: "U" + knownFormatted) }
        #expect(throws: PairingCodeError.invalidSecretLength(16)) { try PairingCode(secret: Data(count: 16)) }
    }

    @Test func fingerprintIsStableAndDistinctFromTheChecksum() throws {
        let code = try PairingCode(secret: TestSecrets.primary)
        #expect(code.fingerprint == PairingCode.fingerprint(of: TestSecrets.primary))
        #expect(code.fingerprint.replacingOccurrences(of: "-", with: "") != String(code.compact.suffix(4)))
        #expect(try PairingCode(secret: TestSecrets.other).fingerprint != code.fingerprint)
    }

    @Test func descriptionDoesNotLeakTheSecret() throws {
        let code = try PairingCode(secret: TestSecrets.primary)
        #expect(!code.description.contains(String(code.compact.prefix(8))))
        #expect(code.description.contains(knownFingerprint))
    }
}
