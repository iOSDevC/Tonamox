import CryptoKit
import Foundation

public enum PairingCodeError: Error, Equatable, Sendable {
    case invalidSecretLength(Int)
    case wrongLength(Int)
    case invalidCharacter(Character)
    case checksumMismatch
}

/// The 160-bit pairing secret and its human form: 32 Crockford base32 characters plus a
/// 4-character checksum, shown as 9 groups of 4 ("ABCD-EFGH-…").
public struct PairingCode: Hashable, Sendable, CustomStringConvertible {
    public static let groupLength = 4
    public static let characterCount = 36
    static let secretCharacterCount = 32
    static let checksumCharacterCount = 4

    public let secret: Data

    public init(secret: Data) throws(PairingCodeError) {
        guard secret.count == BridgeConstants.secretByteCount else {
            throw .invalidSecretLength(secret.count)
        }
        self.secret = secret
    }

    private init(generatedSecret: Data) {
        secret = generatedSecret
    }

    /// Accepts any case, ignores dashes and whitespace, and reads I/L as 1 and O as 0.
    public init(parsing code: String) throws(PairingCodeError) {
        let symbols = try CrockfordBase32.normalize(code)
        guard symbols.count == Self.characterCount else { throw .wrongLength(symbols.count) }
        let secretSymbols = Array(symbols.prefix(Self.secretCharacterCount))
        let checksumSymbols = Array(symbols.suffix(Self.checksumCharacterCount))
        let decoded = CrockfordBase32.decode(secretSymbols)
        guard Self.checksumSymbols(for: decoded) == checksumSymbols else { throw .checksumMismatch }
        try self.init(secret: decoded)
    }

    public static func generate() -> PairingCode {
        PairingCode(generatedSecret: BridgeRandom.bytes(BridgeConstants.secretByteCount))
    }

    /// 36 characters without separators.
    public var compact: String {
        String(CrockfordBase32.encode(secret) + Self.checksumSymbols(for: secret))
    }

    /// "XXXX-XXXX-…" in 9 groups.
    public var formatted: String {
        groups.joined(separator: "-")
    }

    public var groups: [String] {
        let symbols = Array(compact)
        return stride(from: 0, to: symbols.count, by: Self.groupLength).map { start in
            String(symbols[start..<min(start + Self.groupLength, symbols.count)])
        }
    }

    /// "ABCD-EFGH": the first 8 base32 symbols of SHA256("tonamox-fp/1" || secret).
    public var fingerprint: String {
        Self.fingerprint(of: secret)
    }

    public static func fingerprint(of secret: Data) -> String {
        let digest = labeledDigest(BridgeConstants.fingerprintLabel, secret)
        let symbols = CrockfordBase32.encodeLeadingBits(of: digest, symbolCount: 8)
        return String(symbols.prefix(4)) + "-" + String(symbols.suffix(4))
    }

    public var description: String {
        "PairingCode(fingerprint: \(fingerprint))"
    }

    static func checksumSymbols(for secret: Data) -> [Character] {
        let digest = labeledDigest(BridgeConstants.pairingChecksumLabel, secret)
        return CrockfordBase32.encodeLeadingBits(of: digest, symbolCount: checksumCharacterCount)
    }

    private static func labeledDigest(_ label: String, _ secret: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data(label.utf8))
        hasher.update(data: secret)
        return Data(hasher.finalize())
    }
}

enum CrockfordBase32 {
    static let alphabet: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let decodeTable: [Character: Int] = {
        var table = Dictionary(uniqueKeysWithValues: zip(alphabet, 0...))
        table["I"] = 1
        table["L"] = 1
        table["O"] = 0
        return table
    }()

    /// Uppercased canonical symbols with separators removed and aliases resolved.
    static func normalize(_ text: String) throws(PairingCodeError) -> [Character] {
        var symbols: [Character] = []
        for character in text.uppercased() where character != "-" && !character.isWhitespace {
            guard let value = decodeTable[character] else { throw .invalidCharacter(character) }
            symbols.append(alphabet[value])
        }
        return symbols
    }

    /// Encodes whole bytes; 20 bytes give exactly 32 symbols.
    static func encode(_ bytes: Data) -> [Character] {
        encodeLeadingBits(of: bytes, symbolCount: (bytes.count * 8 + 4) / 5)
    }

    /// The first `symbolCount * 5` bits of `bytes` as symbols, zero-padded at the end.
    static func encodeLeadingBits(of bytes: Data, symbolCount: Int) -> [Character] {
        var symbols: [Character] = []
        symbols.reserveCapacity(symbolCount)
        var accumulator: UInt32 = 0
        var bitCount = 0
        var iterator = bytes.makeIterator()
        while symbols.count < symbolCount {
            if bitCount < 5 {
                accumulator = shiftIn(byte: iterator.next() ?? 0, into: accumulator)
                bitCount += 8
            }
            symbols.append(symbol(from: accumulator, bitCount: bitCount))
            bitCount -= 5
        }
        return symbols
    }

    /// Decodes canonical symbols; trailing bits that do not fill a byte are dropped.
    static func decode(_ symbols: [Character]) -> Data {
        var bytes = Data(capacity: symbols.count * 5 / 8)
        var accumulator: UInt32 = 0
        var bitCount = 0
        for symbol in symbols {
            accumulator = shiftIn(symbol: symbol, into: accumulator)
            bitCount += 5
            if bitCount >= 8 {
                bytes.append(byte(from: accumulator, bitCount: bitCount))
                bitCount -= 8
            }
        }
        return bytes
    }

    private static func shiftIn(byte: UInt8, into accumulator: UInt32) -> UInt32 {
        (accumulator << 8) | UInt32(byte)
    }

    private static func shiftIn(symbol: Character, into accumulator: UInt32) -> UInt32 {
        (accumulator << 5) | UInt32(decodeTable[symbol] ?? 0)
    }

    private static func symbol(from accumulator: UInt32, bitCount: Int) -> Character {
        alphabet[Int((accumulator >> UInt32(bitCount - 5)) & 0x1F)]
    }

    private static func byte(from accumulator: UInt32, bitCount: Int) -> UInt8 {
        UInt8(truncatingIfNeeded: accumulator >> UInt32(bitCount - 8))
    }
}

enum BridgeRandom {
    /// Cryptographically secure on Apple platforms (arc4random_buf).
    static func bytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
