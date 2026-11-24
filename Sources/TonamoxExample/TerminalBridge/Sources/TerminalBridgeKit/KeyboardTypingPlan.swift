import Foundation

/// Keystrokes to input reports, pressed as a person types: modifier first, released before the next key.
public enum HIDReportSequencer {
    /// Unmodified: [key], [released]. Modified: [mod], [mod+key], [mod], [released].
    public static func reports(for keystroke: HIDKeystroke) -> [HIDKeyboardReport] {
        let modifiers = keystroke.modifiers.rawValue
        let usage = keystroke.usage.rawValue
        guard modifiers != 0 else {
            return [report(0, usage), .released]
        }
        return [report(modifiers, 0), report(modifiers, usage), report(modifiers, 0), .released]
    }

    public static func reports(for keystrokes: [HIDKeystroke]) -> [HIDKeyboardReport] {
        keystrokes.flatMap { reports(for: $0) }
    }

    private static func report(_ modifiers: UInt8, _ usage: UInt8) -> HIDKeyboardReport {
        HIDKeyboardReport(modifierByte: modifiers, keyUsage: usage)
    }
}

/// Why a command was not typed. Every case is decided before the first report is sent.
public enum KeyboardTypingRefusal: Error, Hashable, Sendable {
    case policy([CommandTextViolation])
    case unacknowledgedWarnings([RiskyRule])
    case unmappable([UnmappableCharacter], layoutTitle: String)
    /// The layout differs from the one the confirmation dialog showed.
    case layoutChanged
    /// Unreachable while the tables pass their tests.
    case unsafeReport

    /// Spanish, always ends with "No se ha enviado nada."
    public var message: String {
        let reason: String
        switch self {
        case .policy(let violations):
            reason = "No se puede teclear: " + Self.list(violations.map(\.message)) + "."
        case .unacknowledgedWarnings(let rules):
            reason = "Faltan por confirmar los avisos: " + rules.map(\.title).joined(separator: ", ") + "."
        case .unmappable(let characters, let layoutTitle):
            reason = "La distribución «\(layoutTitle)» no puede escribir: "
                + Self.list(characters.map(\.message)) + "."
        case .layoutChanged:
            reason = "La distribución cambió después de confirmar."
        case .unsafeReport:
            reason = "Se generó una pulsación no permitida."
        }
        return reason + " " + Self.nothingSent
    }

    static let nothingSent = "No se ha enviado nada."

    private static func list(_ messages: [String]) -> String {
        messages.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }.joined(separator: "; ")
    }
}

/// Every report for one command, built only after every safeguard passed.
public struct KeyboardTypingPlan: Hashable, Sendable {
    public let text: String
    public let layoutID: HostKeyboardLayoutID
    public let keystrokeCount: Int
    /// Starts and ends with `.released`.
    public let reports: [HIDKeyboardReport]
    /// The layout's set, for the peripheral's last check before `updateValue`.
    public let permittedModifiers: HIDModifierSet
    public let unverifiedCharacters: [Character]
    /// A macOS plan with at least one Option chord (Terminal "Option as Meta" turns these into ESC + key).
    public let usesOptionChords: Bool

    /// Policy, unacknowledged risky rules, encoder, sequencer, then the per-layout allow-list on every report.
    public static func make(
        text: String,
        layout: HostKeyboardLayout,
        acknowledged: [String]
    ) -> Result<KeyboardTypingPlan, KeyboardTypingRefusal> {
        let violations = CommandTextPolicy.validate(text)
        guard violations.isEmpty else { return .failure(.policy(violations)) }
        let pending = RiskyCommandRules.unacknowledged(in: text, acknowledged: acknowledged)
        guard pending.isEmpty else { return .failure(.unacknowledgedWarnings(pending)) }
        let keystrokes: [HIDKeystroke]
        switch HIDTextEncoder.encode(text, layout: layout) {
        case .success(let encoded):
            keystrokes = encoded
        case .failure(.policy(let encoderViolations)):
            return .failure(.policy(encoderViolations))
        case .failure(.unmappable(let characters)):
            return .failure(.unmappable(characters, layoutTitle: layout.title))
        }
        let reports = [HIDKeyboardReport.released] + HIDReportSequencer.reports(for: keystrokes) + [.released]
        guard reports.allSatisfy({ $0.isPermitted(within: layout.permittedModifiers) }) else {
            return .failure(.unsafeReport)
        }
        let usesOption = layout.host == .macOS && keystrokes.contains { $0.modifiers.contains(.leftAlt) }
        return .success(KeyboardTypingPlan(
            text: text,
            layoutID: layout.id,
            keystrokeCount: keystrokes.count,
            reports: reports,
            permittedModifiers: layout.permittedModifiers,
            unverifiedCharacters: layout.verification.unverifiedCharacters(in: text),
            usesOptionChords: usesOption
        ))
    }
}
