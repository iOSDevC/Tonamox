import CryptoKit
import Foundation
import Security

/// A random secret with a printable form and the SHA-256 digest that is stored instead of it.
package struct SecretToken: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    package let text: String

    private init(text: String) {
        self.text = text
    }

    /// `bits` of CSPRNG output in base64url without padding, after `prefix`.
    package static func random(bits: Int, prefix: String = "") -> SecretToken {
        SecretToken(text: prefix + base64URL(randomBytes(count: (bits + 7) / 8)))
    }

    package var storedHash: SHA256.Digest { SHA256.hash(data: Data(text.utf8)) }

    package var description: String { "SecretToken(redacted)" }
    package var debugDescription: String { description }

    /// Hashes `presented` and compares every byte of both digests, so timing does not depend on where they differ.
    package static func matches(_ presented: some StringProtocol, storedHash: SHA256.Digest) -> Bool {
        let candidate = SHA256.hash(data: Data(presented.utf8))
        return constantTimeEqual(Array(candidate), Array(storedHash))
    }

    package static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    package static func randomBytes(count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return bytes
    }

    package static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Crockford base32 codes typed by people: `XXXX-XXXX`, case-insensitive, I/L read as 1 and O as 0.
package enum CrockfordCode {
    package static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    package static func random(length: Int) -> String {
        String(SecretToken.randomBytes(count: length).map { alphabet[Int($0 & 31)] })
    }

    /// Canonical form of typed input, or `nil` when it holds a character outside the alphabet.
    package static func normalize(_ input: String) -> String? {
        let mapped = input.uppercased().compactMap(canonical)
        guard mapped.count == input.filter({ $0 != "-" }).count else { return nil }
        return String(mapped)
    }

    private static func canonical(_ character: Character) -> Character? {
        switch character {
        case "-": nil
        case "I", "L": "1"
        case "O": "0"
        default: alphabet.contains(character) ? character : nil
        }
    }
}
