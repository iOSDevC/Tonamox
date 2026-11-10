import CryptoKit
import Foundation

/// Hex digests of command text. The ack carries the SHA-256 so the phone can confirm the
/// helper saw the same bytes; the journal must use the keyed variant, never the bare hash.
public enum BridgeDigest {
    private static let hexDigits: [Character] = Array("0123456789abcdef")

    public static func sha256Hex(_ text: String) -> String {
        hex(SHA256.hash(data: Data(text.utf8)))
    }

    /// HMAC-SHA256 of `text` with a local key: short commands cannot be recovered by dictionary.
    public static func hmacSHA256Hex(_ text: String, key: SymmetricKey) -> String {
        hex(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key))
    }

    public static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        var output = ""
        for byte in bytes {
            output.append(digit(byte >> 4))
            output.append(digit(byte & 0x0F))
        }
        return output
    }

    private static func digit(_ nibble: UInt8) -> Character {
        hexDigits[Int(nibble)]
    }
}
