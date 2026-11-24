import Foundation

/// The owner's run preferences for the battery: probes left out of every run, and the order each level runs in.
/// Only the execution order changes: rows and reports keep the level's order. Stored as JSON under `defaultsKey`.
public struct CapabilityRunPlan: Codable, Equatable, Sendable {
    public static let defaultsKey = "capabilityTests.runPlan.v1"

    /// Probe ids; they are unique across levels, so one set serves all of them.
    public private(set) var excludedProbeIDs: Set<String>
    /// Probe ids per `CapabilityLevel.rawValue`, as last arranged; a level without an entry runs in level order.
    public private(set) var orderByLevel: [String: [String]]

    public init(excludedProbeIDs: Set<String> = [], orderByLevel: [String: [String]] = [:]) {
        self.excludedProbeIDs = excludedProbeIDs
        self.orderByLevel = orderByLevel
    }

    private enum CodingKeys: String, CodingKey {
        case excludedProbeIDs, orderByLevel
    }

    /// Missing keys take their defaults, so a field added later never resets the stored exclusions or order.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        excludedProbeIDs = try container.decodeIfPresent(Set<String>.self, forKey: .excludedProbeIDs) ?? []
        orderByLevel = try container.decodeIfPresent([String: [String]].self, forKey: .orderByLevel) ?? [:]
    }

    /// Empty for missing or unreadable data, so a corrupt value never blocks the page.
    public static func decode(_ data: Data?) -> CapabilityRunPlan {
        guard let data, let plan = try? JSONDecoder().decode(CapabilityRunPlan.self, from: data) else {
            return CapabilityRunPlan()
        }
        return plan
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    // MARK: Exclusions

    public func isExcluded(_ probeID: String) -> Bool {
        excludedProbeIDs.contains(probeID)
    }

    public mutating func setExcluded(_ excluded: Bool, probeID: String) {
        if excluded {
            excludedProbeIDs.insert(probeID)
        } else {
            excludedProbeIDs.remove(probeID)
        }
    }

    /// The level's excluded probe ids, in level order.
    public func excludedIDs(in level: CapabilityLevel) -> [String] {
        level.probes.map(\.id).filter(isExcluded)
    }

    /// True when every probe of the level is excluded: there is nothing to run.
    public func excludesEverything(in level: CapabilityLevel) -> Bool {
        level.probes.allSatisfy { isExcluded($0.id) }
    }

    // MARK: Order

    /// The level's probes in the stored order. Ids the level no longer has are dropped, repeats keep their first
    /// place, and probes missing from the stored order follow in level order.
    public func order(of level: CapabilityLevel) -> [CapabilityProbe] {
        Self.resolve(stored: orderByLevel[level.rawValue], canonical: level.probes)
    }

    /// ``order(of:)`` without the excluded probes: what a run executes.
    public func executionOrder(of level: CapabilityLevel) -> [CapabilityProbe] {
        order(of: level).filter { !isExcluded($0.id) }
    }

    /// `ids` sorted by the level's execution order, excluded ones removed. Ids outside the level are dropped.
    public func executionOrder(of ids: [String], in level: CapabilityLevel) -> [String] {
        let wanted = Set(ids)
        return executionOrder(of: level).map(\.id).filter(wanted.contains)
    }

    public func hasCustomOrder(_ level: CapabilityLevel) -> Bool {
        order(of: level).map(\.id) != level.probes.map(\.id)
    }

    /// Stores `ids` as the level's order; the level's own order removes the entry, so it follows later changes.
    public mutating func setOrder(_ ids: [String], for level: CapabilityLevel) {
        let resolved = Self.resolve(stored: ids, canonical: level.probes).map(\.id)
        orderByLevel[level.rawValue] = resolved == level.probes.map(\.id) ? nil : resolved
    }

    public mutating func resetOrder(_ level: CapabilityLevel) {
        orderByLevel[level.rawValue] = nil
    }

    /// The level's order after moving the probes at `source` to before `destination`, as `List.onMove` reports it.
    public mutating func move(_ level: CapabilityLevel, fromOffsets source: IndexSet, toOffset destination: Int) {
        setOrder(Self.moving(order(of: level).map(\.id), fromOffsets: source, toOffset: destination), for: level)
    }

    static func resolve(stored: [String]?, canonical: [CapabilityProbe]) -> [CapabilityProbe] {
        guard let stored else { return canonical }
        let byID = Dictionary(canonical.map { ($0.id, $0) }) { first, _ in first }
        var seen = Set<String>()
        let kept = stored.filter { byID[$0] != nil && seen.insert($0).inserted }.compactMap { byID[$0] }
        return kept + canonical.filter { !seen.contains($0.id) }
    }

    /// Same result as SwiftUI's `move(fromOffsets:toOffset:)`; offsets out of range are ignored.
    static func moving(_ items: [String], fromOffsets source: IndexSet, toOffset destination: Int) -> [String] {
        let offsets = source.filter { items.indices.contains($0) }
        guard !offsets.isEmpty else { return items }
        let moved = offsets.map { items[$0] }
        let rest = items.indices.filter { !offsets.contains($0) }.map { items[$0] }
        let target = min(max(0, destination - offsets.filter { $0 < destination }.count), rest.count)
        return Array(rest[..<target]) + moved + Array(rest[target...])
    }
}

/// Copy of the exclusions and the execution order.
extension CapabilityText {
    public static let excluded = "Excluida"
    public static let excludedSymbol = "nosign"
    public static let exclude = "Excluir"
    public static let include = "Incluir"
    public static let excludeProbe = "Excluir esta prueba"
    public static let includeProbe = "Incluir esta prueba"
    public static let exclusionSection = "Ejecución"
    public static let exclusionFooter = "Una prueba excluida no se ejecuta en ninguna pasada (Empezar, pendientes ni "
        + "fallidas) y no cuenta como suspendida ni como sin ejecutar. El informe dice cuáles se excluyeron."
    public static let runOrder = "Orden de ejecución"
    public static let resetOrder = "Restablecer orden"
    public static let runOrderFooter = "Arrastra para cambiar el orden en que se ejecutan las pruebas de este nivel. "
        + "La página y los informes siguen mostrándolas en el orden del nivel."
    public static let customOrderNote = "Orden de ejecución personalizado."
    public static let everythingExcluded = "Todas las pruebas de este nivel están excluidas: incluye al menos una en "
        + "«" + runOrder + "»."

    /// "2 excluidas: «A» y «B». No cuentan en el resultado."; nil when none was. Excluded Seguridad probes are named
    /// again by ``safetyIncomplete(_:)``.
    public static func excludedSummary(_ report: CapabilityReport) -> String? {
        let probes = report.excludedProbes
        guard !probes.isEmpty else { return nil }
        let titles = CapabilityComparison.list(probes.map { "«" + $0.title + "»" })
        let count = probes.count == 1 ? "1 excluida" : "\(probes.count) excluidas"
        return count + ": " + titles + ". No cuentan en el resultado."
    }

    public static let safetyIncompleteLabel = "Seguridad incompleta"

    /// "«A» (excluida) y «B» (no se pudo ejecutar)": the Seguridad probes without a safety outcome.
    static func incompleteSafetyList(_ report: CapabilityReport) -> String {
        CapabilityComparison.list(report.incompleteSafetyProbes.map { probe in
            "«" + probe.title + "»" + (report.isExcluded(probe.id) ? " (excluida)" : " (no se pudo ejecutar)")
        })
    }

    /// "Seguridad incompleta: sin resultado de «A» (excluida) (Nivel 3 · Avanzado)."; nil when every Seguridad probe
    /// has an outcome.
    public static func safetyIncomplete(_ report: CapabilityReport) -> String? {
        guard report.isSafetyIncomplete else { return nil }
        return safetyIncompleteLabel + ": sin resultado de " + incompleteSafetyList(report)
            + levelSuffix(report.level) + "."
    }

    /// " (1 excluida)", " (3 excluidas)", or nothing.
    public static func excludedSuffix(_ count: Int) -> String {
        switch count {
        case 0: ""
        case 1: " (1 excluida)"
        default: " (\(count) excluidas)"
        }
    }

    // MARK: Per-probe failures

    /// A probe whose prompt leaves no room for an answer in the model's window: it fails, the run goes on.
    public static func noRoomReason(window: Int) -> String {
        "No cabe en la ventana del modelo: la pregunta de esta prueba no deja sitio para la respuesta en su contexto "
            + "(\(window) tokens). Exclúyela o usa un modelo con más contexto."
    }

    /// Any other error that belongs to this probe alone.
    public static func probeErrorReason(_ description: String) -> String {
        "Error en esta prueba: \(withoutFinalPeriod(description)). Las demás pruebas siguen."
    }

    // MARK: Accessibility

    public static let runOrderIdentifier = "probes.runOrder"
    public static let resetOrderIdentifier = "probes.runOrder.reset"

    public static func excludeIdentifier(_ probeID: String) -> String {
        "probes.exclude." + probeID
    }

    public static func runOrderRowIdentifier(_ probeID: String) -> String {
        "probes.runOrder.row." + probeID
    }
}
