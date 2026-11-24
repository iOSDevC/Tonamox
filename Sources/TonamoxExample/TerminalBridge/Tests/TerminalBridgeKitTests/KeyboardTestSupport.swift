@testable import TerminalBridgeKit

extension HostKeyboardLayout {
    /// A test-only copy of the table that cannot type `characters`.
    func removing(_ characters: String) -> HostKeyboardLayout {
        HostKeyboardLayout(
            id: id,
            host: host,
            title: title,
            hostInputSource: hostInputSource,
            permittedModifiers: permittedModifiers,
            verification: verification,
            probeLine: probeLine,
            sources: sources,
            entries: entries.filter { !characters.unicodeScalars.contains($0.key) }
        )
    }

    /// Characters typed as a dead key followed by Space.
    var deadCharacters: Set<Character> {
        Set(entries.filter { $0.value.count == 2 && $0.key != " " }.keys.map(Character.init))
    }

    /// 0x21...0x7E without letters and digits.
    static let asciiSymbols: [Character] = printableASCII.filter { !$0.isLetter && !$0.isNumber && $0 != " " }
}

/// "S1E", "34", "O33 dead": the plan's table cell notation (S Shift, O Option, G AltGr).
func keystrokes(fromCell cell: String) -> [HIDKeystroke]? {
    let parts = cell.split(separator: " ")
    guard let code = parts.first else { return nil }
    var modifiers: HIDModifierSet = []
    var hex = Substring(code)
    switch code.first {
    case "S": modifiers = .leftShift
    case "O": modifiers = .leftAlt
    case "G": modifiers = .rightAlt
    default: break
    }
    if !modifiers.isEmpty { hex = hex.dropFirst() }
    guard let usage = UInt8(hex, radix: 16), let pressed = HIDKeystroke(modifiers: modifiers, usage: usage) else {
        return nil
    }
    guard parts.count > 1, parts[1] == "dead" else { return [pressed] }
    guard let space = HIDKeystroke(modifiers: [], usage: 0x2C) else { return nil }
    return [pressed, space]
}

/// SplitMix64, so the random-text test is reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
