import Foundation

/// The Terminal chat's reasoning choice ("Razonamiento" in the model sheet), kept in UserDefaults. Applies to local
/// GGUF models only: MLX, Apple Intelligence and remote engines ignore it.
public enum ReasoningSetting: String, CaseIterable, Sendable {
    /// The template is rendered with thinking off; where it cannot be, any reasoning block is closed at once.
    case disabled
    /// This and the next two: thinking as the template sets it, closed after ``budget`` tokens.
    case short
    case medium
    case long

    public static let defaultsKey = "terminal.reasoning"
    /// Stored by builds whose only budget was today's ``medium``.
    static let legacyAutomatic = "automatic"

    public static let sectionTitle = "Razonamiento"
    public static let footer = "Solo para modelos locales GGUF. El modelo razona hasta el límite elegido, que se suma "
        + "a la longitud de respuesta, y después responde. Desactivado: se le pide que responda directamente; si su "
        + "plantilla no lo permite, el razonamiento se cierra nada más empezar."

    /// The stored value; ``medium`` when nothing valid is stored.
    public static func stored(_ raw: String?) -> ReasoningSetting {
        if raw == legacyAutomatic { return .medium }
        return raw.flatMap(ReasoningSetting.init(rawValue:)) ?? .medium
    }

    /// The value to write back for one stored by an older build, so the picker shows it; `nil` when none is needed.
    public static func migratedRawValue(_ raw: String?) -> String? {
        raw == legacyAutomatic ? ReasoningSetting.medium.rawValue : nil
    }

    public static func migrate(_ defaults: UserDefaults) {
        if let value = migratedRawValue(defaults.string(forKey: defaultsKey)) {
            defaults.set(value, forKey: defaultsKey)
        }
    }

    /// Reasoning tokens on top of the answer's limit; `nil` when disabled. At LFM3's ~50 tokens/s on an iPhone 17
    /// Pro the medium budget is about 10 s; enough for a short plan, not for the loops small models fall into.
    public var budget: Int? {
        switch self {
        case .disabled: nil
        case .short: 256
        case .medium: 512
        case .long: 1024
        }
    }

    public var title: String {
        switch self {
        case .disabled: "Desactivado"
        case .short: "Corto (256 tokens)"
        case .medium: "Medio (512 tokens)"
        case .long: "Largo (1024 tokens)"
        }
    }

    /// What a ``CapabilityReport`` records, so runs with different settings are not mistaken for each other.
    public var reportLabel: String {
        budget.map { "auto:\($0)" } ?? "off"
    }

    /// The line the results page shows for a report's ``CapabilityReport/reasoning``.
    public static func reportText(_ label: String?) -> String {
        guard let label else { return "Razonamiento: sin dato (informe anterior o motor sin control)." }
        if label == ReasoningSetting.disabled.reportLabel { return "Razonamiento: desactivado." }
        if label.hasPrefix("auto:"), let tokens = Int(label.dropFirst(5)) {
            return "Razonamiento: hasta \(tokens) tokens."
        }
        return "Razonamiento: \(label)."
    }
}
