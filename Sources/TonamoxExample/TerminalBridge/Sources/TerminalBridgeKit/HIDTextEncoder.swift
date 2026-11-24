import Foundation

/// A character the selected layout cannot type.
public struct UnmappableCharacter: Hashable, Sendable {
    public let scalar: UInt32
    /// Unicode scalars from 0, as `CommandTextViolation`.
    public let offset: Int

    init(scalar: UInt32, offset: Int) {
        self.scalar = scalar
        self.offset = offset
    }

    /// "«|» U+007C en la posición 4"
    public var message: String {
        let glyph = Unicode.Scalar(scalar).map { String(Character($0)) } ?? "?"
        return "«\(glyph)» \(CommandTextViolation.codePoint(scalar)) en la posición \(offset + 1)"
    }
}

public enum HIDEncodingFailure: Error, Hashable, Sendable {
    case policy([CommandTextViolation])
    case unmappable([UnmappableCharacter])
}

/// Text to keystrokes for one layout: the whole text or a refusal, never part of it.
public enum HIDTextEncoder {
    public static func encode(
        _ text: String,
        layout: HostKeyboardLayout
    ) -> Result<[HIDKeystroke], HIDEncodingFailure> {
        let violations = CommandTextPolicy.validate(text)
        guard violations.isEmpty else { return .failure(.policy(violations)) }
        var keystrokes: [HIDKeystroke] = []
        var unmappable: [UnmappableCharacter] = []
        for (offset, scalar) in text.unicodeScalars.enumerated() {
            guard let entry = layout.keystrokes(for: scalar), !entry.isEmpty else {
                if unmappable.count < CommandTextPolicy.maxReportedCharacters {
                    unmappable.append(unmappableCharacter(scalar, offset: offset))
                }
                continue
            }
            keystrokes.append(contentsOf: entry)
        }
        guard unmappable.isEmpty else { return .failure(.unmappable(unmappable)) }
        return .success(keystrokes)
    }

    private static func unmappableCharacter(_ scalar: Unicode.Scalar, offset: Int) -> UnmappableCharacter {
        UnmappableCharacter(scalar: scalar.value, offset: offset)
    }
}
