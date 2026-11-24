import Foundation

/// A group of probes run and saved as one report. Raw values are stored in saved reports and archive keys.
public enum CapabilityLevel: String, Codable, CaseIterable, Sendable {
    case basico = "nivel1"
    case terminal = "nivel2"
    case avanzado = "nivel3"

    public var number: Int {
        switch self {
        case .basico: 1
        case .terminal: 2
        case .avanzado: 3
        }
    }

    public var title: String {
        switch self {
        case .basico: "Básico"
        case .terminal: "Terminal"
        case .avanzado: "Avanzado"
        }
    }

    /// "Nivel 2 · Terminal".
    public var label: String { "Nivel \(number) · \(title)" }

    /// Bump a level when, in that level, a prompt, fixture or grader, the area or level of a probe, or the order of
    /// its probes changes: reports do not store the area, so older ones would change without notice.
    public var version: Int {
        switch self {
        case .basico: 1
        case .terminal: 1
        case .avanzado: 1
        }
    }

    /// The level's probes in `ProbeIdentifier` order.
    public var probes: [CapabilityProbe] { CapabilityBattery.probesByLevel[self] ?? [] }

    /// The capabilities with at least one probe in this level, in `Capability` order.
    public var areas: [Capability] {
        let present = Set(probes.map(\.area))
        return Capability.allCases.filter(present.contains)
    }

    public var hasSafetyProbes: Bool { probes.contains { $0.area == .seguridad } }
}

/// What the battery page runs: one level or all of them in order. Stored under `defaultsKey`.
public enum CapabilityLevelChoice: String, CaseIterable, Sendable {
    case basico = "nivel1"
    case terminal = "nivel2"
    case avanzado = "nivel3"
    case all = "todos"

    public static let defaultsKey = "capabilityTests.level"

    /// The stored choice; Nivel 2 when nothing valid is stored.
    public static func stored(_ raw: String?) -> CapabilityLevelChoice {
        raw.flatMap(CapabilityLevelChoice.init(rawValue:)) ?? .terminal
    }

    public var levels: [CapabilityLevel] {
        switch self {
        case .basico: [.basico]
        case .terminal: [.terminal]
        case .avanzado: [.avanzado]
        case .all: CapabilityLevel.allCases
        }
    }

    public var probeCount: Int { levels.map(\.probes.count).reduce(0, +) }

    /// "Nivel 1 · Básico (6)", "Todos (37)".
    public var title: String {
        guard self != .all, let level = levels.first else { return CapabilityText.allLevels(count: probeCount) }
        return "\(level.label) (\(probeCount))"
    }
}
