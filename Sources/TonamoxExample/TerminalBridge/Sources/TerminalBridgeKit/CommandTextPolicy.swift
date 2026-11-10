import Foundation

/// Why a line cannot be typed. Messages are in Spanish for the phone UI.
public enum CommandTextViolation: Hashable, Sendable {
    case empty
    case tooLong(bytes: Int)
    case leadingSpace
    case trailingSpace
    /// `offset` counts Unicode scalars from 0.
    case disallowedCharacter(scalar: UInt32, offset: Int)

    public var message: String {
        switch self {
        case .empty:
            "La orden está vacía."
        case .tooLong(let bytes):
            "La orden ocupa \(bytes) bytes; el máximo es \(BridgeConstants.maxTextBytes)."
        case .leadingSpace:
            "Empieza con un espacio."
        case .trailingSpace:
            "Termina con un espacio."
        case .disallowedCharacter(let scalar, let offset):
            "\(Self.characterName(scalar)) \(Self.codePoint(scalar)) en la posición \(offset + 1)"
        }
    }

    static func codePoint(_ scalar: UInt32) -> String {
        let hex = String(scalar, radix: 16, uppercase: true)
        return "U+" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
    }

    static func characterName(_ value: UInt32) -> String {
        switch value {
        case 0x0A: return "Salto de línea"
        case 0x0D: return "Retorno de carro"
        case 0x09: return "Tabulador"
        case 0x1B: return "Escape"
        default: break
        }
        guard let scalar = Unicode.Scalar(value) else { return "Carácter no válido" }
        switch scalar.properties.generalCategory {
        case .control: return "Carácter de control"
        case .format: return "Carácter invisible"
        case .spaceSeparator: return "Espacio especial"
        case .lineSeparator, .paragraphSeparator: return "Separador de línea"
        default: return "Carácter no ASCII"
        }
    }
}

/// v1 text policy, enforced on both sides: one line of printable ASCII (0x20-0x7E),
/// 1...512 bytes, no leading or trailing space. It only validates, never rewrites.
public enum CommandTextPolicy {
    public static let maxBytes = BridgeConstants.maxTextBytes
    /// Enough to explain the problem without flooding the UI on a large paste.
    public static let maxReportedCharacters = 16

    public static func validate(_ text: String) -> [CommandTextViolation] {
        guard !text.isEmpty else { return [.empty] }
        var violations: [CommandTextViolation] = []
        var reported = 0
        for (offset, scalar) in text.unicodeScalars.enumerated() where !isAllowed(scalar.value) {
            if reported < maxReportedCharacters {
                violations.append(characterViolation(scalar.value, offset: offset))
            }
            reported += 1
        }
        if text.unicodeScalars.first == " " { violations.append(.leadingSpace) }
        if text.unicodeScalars.last == " " { violations.append(.trailingSpace) }
        let byteCount = text.utf8.count
        if byteCount > maxBytes { violations.append(.tooLong(bytes: byteCount)) }
        return violations
    }

    public static func isValid(_ text: String) -> Bool {
        validate(text).isEmpty
    }

    /// Byte-level check that does not go through String; the helper runs it right before stuffing.
    public static func isValid<Bytes: BidirectionalCollection>(bytes: Bytes) -> Bool where Bytes.Element == UInt8 {
        guard !bytes.isEmpty, bytes.count <= maxBytes else { return false }
        guard bytes.first != 0x20, bytes.last != 0x20 else { return false }
        return bytes.allSatisfy { (0x20...0x7E).contains($0) }
    }

    static func isAllowed(_ value: UInt32) -> Bool {
        (0x20...0x7E).contains(value)
    }

    private static func characterViolation(_ value: UInt32, offset: Int) -> CommandTextViolation {
        .disallowedCharacter(scalar: value, offset: offset)
    }
}
