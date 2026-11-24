import Foundation

/// The saved models the owner picked to compare: two or three, in the order picked. A pick past the maximum is
/// refused, never swapped for an earlier one.
public struct ComparisonSelection: Hashable, Sendable {
    public static let minimum = 2
    public static let maximum = 3

    public private(set) var modelKeys: [String]

    public init(_ modelKeys: [String] = []) {
        var unique: [String] = []
        for key in modelKeys where !unique.contains(key) && unique.count < Self.maximum {
            unique.append(key)
        }
        self.modelKeys = unique
    }

    public enum Change: Equatable, Sendable {
        case added
        case removed
        /// Already at ``maximum``: nothing changed.
        case refused
    }

    /// Adds `modelKey`, or removes it when it was picked.
    @discardableResult
    public mutating func toggle(_ modelKey: String) -> Change {
        if let index = modelKeys.firstIndex(of: modelKey) {
            modelKeys.remove(at: index)
            return .removed
        }
        guard modelKeys.count < Self.maximum else { return .refused }
        modelKeys.append(modelKey)
        return .added
    }

    public func contains(_ modelKey: String) -> Bool {
        modelKeys.contains(modelKey)
    }

    public var count: Int { modelKeys.count }
    public var canCompare: Bool { modelKeys.count >= Self.minimum }
    public var isFull: Bool { modelKeys.count >= Self.maximum }

    /// The picked keys still saved, in `saved` order (the store's, newest first), so letters follow the list.
    public func ordered(by saved: [String]) -> [String] {
        saved.filter(modelKeys.contains)
    }

    /// Drops keys no longer saved (results cleared or replaced under another key).
    public func pruned(to saved: [String]) -> ComparisonSelection {
        ComparisonSelection(modelKeys.filter(saved.contains))
    }

    /// The battery page offers "Comparar modelos" only with this many saved models.
    public static func isOffered(savedModels: Int) -> Bool {
        savedModels >= minimum
    }
}

/// A run setting that changes what a level measures; two models run with different values are not compared fairly.
/// The level version is not one: a report of another version is never compared, and ``CapabilityComparison/
/// olderBatteryNote(_:level:)`` says so.
public enum ComparisonSetting: String, CaseIterable, Sendable {
    case replyLength
    case reasoning
    case temperature
    /// Reports that left out different probes count different questions.
    case excludedProbes

    public var title: String {
        switch self {
        case .replyLength: "longitud de respuesta"
        case .reasoning: "razonamiento"
        case .temperature: "temperatura"
        case .excludedProbes: "pruebas excluidas"
        }
    }
}

/// What one comparison cell shows for a probe and a model.
public enum ComparisonMark: String, Hashable, Sendable {
    case passed
    case failed
    case unrecognised
    case timedOut
    /// No report of the level, no row for the probe, or the run stopped before it.
    case notRun
    /// Servidor ocupado; saved reports never hold it, kept so an odd archive still renders.
    case busy
    /// The owner left the probe out of that model's run.
    case excluded
    /// The model's report is from another version of the level: shown, never compared.
    case notComparable

    init(_ state: ProbeRunState) {
        switch state {
        case .passed: self = .passed
        case .failed: self = .failed
        case .unrecognised: self = .unrecognised
        case .timedOut: self = .timedOut
        case .notRun: self = .notRun
        case .error: self = .busy
        }
    }

    public var symbol: String {
        switch self {
        case .passed: "✓"
        case .failed: "✗"
        case .unrecognised: "?"
        case .timedOut: "⏱"
        case .notRun: "—"
        case .busy: "!"
        case .excluded: "⊘"
        case .notComparable: "≠"
        }
    }

    public var word: String {
        switch self {
        case .passed: "Aprobada"
        case .failed: "Suspendida"
        case .unrecognised: "No reconocida"
        case .timedOut: "Tiempo agotado"
        case .notRun: "Sin ejecutar"
        case .busy: "Servidor ocupado"
        case .excluded: "Excluida"
        case .notComparable: "Batería anterior"
        }
    }
}

/// One model's result for one probe.
public struct ComparisonCell: Hashable, Sendable {
    public let letter: String
    public let modelKey: String
    /// The grader's outcome; a hand mark does not change it.
    public let mark: ComparisonMark
    public let validatedByHand: Bool

    /// "✓", or "✓*" for a hand-validated row: it counts as passed whatever the grader said.
    public var symbol: String { validatedByHand ? ComparisonMark.passed.symbol + "*" : mark.symbol }

    /// "✓ Aprobada", "✓* Válida a mano (era ✗)".
    public var text: String {
        validatedByHand ? symbol + " Válida a mano (era " + mark.symbol + ")" : mark.symbol + " " + mark.word
    }

    /// For VoiceOver: words only, the grader's word kept under the mark.
    public var spokenText: String {
        validatedByHand ? "Válida, marcada a mano; corrector automático: " + mark.word : mark.word
    }

    /// Cells backed by a saved row of a comparable report; the others have no detail page.
    public var opensDetail: Bool {
        switch mark {
        case .notRun, .excluded, .notComparable: false
        case .passed, .failed, .unrecognised, .timedOut, .busy: true
        }
    }
}

/// A probe row of the matrix: one cell per compared model, in model order.
public struct ComparisonMatrixRow: Hashable, Sendable {
    public let number: Int
    public let probe: CapabilityProbe
    public let cells: [ComparisonCell]
}

/// One model's count for one capability of a level.
public struct ComparisonTallyCell: Hashable, Sendable {
    public enum Coverage: Hashable, Sendable {
        case counted
        /// The report has the capability but graded none of its probes.
        case noData
        /// The owner excluded every probe of the capability from that report.
        case excluded
        case notRun
        case notComparable
    }

    public let letter: String
    public let modelKey: String
    public let passed: Int
    public let graded: Int
    public let status: Coverage

    /// 0–100; nil when there is nothing to chart.
    public var share: Double? {
        guard status == .counted, graded > 0 else { return nil }
        return Double(passed) / Double(graded) * 100
    }

    /// "3/4", "sin datos", "excluida", "sin ejecutar", "no comparable".
    public var countText: String {
        switch status {
        case .counted: "\(passed)/\(graded)"
        case .noData: CapabilityPDFContent.noData
        case .excluded: CapabilityPDFContent.excludedArea
        case .notRun: CapabilityText.levelNotRun
        case .notComparable: "no comparable"
        }
    }

    /// "A · 3/4", what the bar and the line under it say.
    public var label: String { letter + " · " + countText }

    /// "3/4 · 75 %", a cell of the donut PDF's per-capability table.
    public var shareText: String {
        guard let share else { return countText }
        return countText + " · \(Int(share.rounded())) %"
    }
}

public struct ComparisonCapabilityRow: Hashable, Sendable {
    public let area: Capability
    public let cells: [ComparisonTallyCell]
}

/// Pure logic of "Comparar modelos": levels to offer, setting differences, verdicts, the per-capability rows and the
/// per-probe matrix, for the app page and the selection exports alike.
public enum CapabilityComparison {
    public static let title = "Comparar modelos"
    public static let matrixTitle = "Prueba por prueba"
    public static let verdictLinesTitle = "Veredicto de cada nivel"
    public static let validatedFootnote = "* Válida a mano: cuenta como aprobada; entre paréntesis, lo que dijo el "
        + "corrector."

    /// Levels at least one model has a saved report of, in level order.
    public static func levels(_ models: [ComparedModel]) -> [CapabilityLevel] {
        CapabilityLevel.allCases.filter { level in models.contains { $0.report(level) != nil } }
    }

    /// The level shown first: the one most models can be compared on, Nivel 2 on a tie, then the lower level.
    public static func defaultLevel(_ models: [ComparedModel]) -> CapabilityLevel? {
        levels(models).max { first, second in
            let (a, b) = (comparableCount(models, first), comparableCount(models, second))
            if a != b { return a < b }
            if (first == .terminal) != (second == .terminal) { return second == .terminal }
            return first.number > second.number
        }
    }

    private static func comparableCount(_ models: [ComparedModel], _ level: CapabilityLevel) -> Int {
        models.filter { $0.report(level)?.isComparable == true }.count
    }

    /// The settings that differ between the comparable reports of `level`; with fewer than two there is nothing to
    /// compare. A missing reply length is the fixed length of older reports; a missing reasoning label is "not
    /// recorded" and differs from any recorded one.
    public static func differingSettings(_ models: [ComparedModel], level: CapabilityLevel) -> [ComparisonSetting] {
        let runs = models.compactMap { $0.report(level) }.filter(\.isComparable)
        guard runs.count > 1 else { return [] }
        return ComparisonSetting.allCases.filter { setting in
            switch setting {
            case .replyLength: Set(runs.map { $0.answerLength ?? ReplyLength.legacyTokens }).count > 1
            case .reasoning: Set(runs.map { $0.reasoning ?? "" }).count > 1
            case .temperature: Set(runs.map(\.temperature)).count > 1
            case .excludedProbes: Set(runs.map { Set($0.excludedProbeIDs) }).count > 1
            }
        }
    }

    /// "Resultados de una batería anterior, que no se comparan: C." for `level`; nil when every report of it is
    /// comparable.
    public static func olderBatteryNote(_ models: [ComparedModel], level: CapabilityLevel) -> String? {
        let older = models.filter { $0.report(level).map { !$0.isComparable } ?? false }.map(\.letter)
        guard !older.isEmpty else { return nil }
        return "Resultados de una batería anterior, que no se comparan: " + list(older) + "."
    }

    /// The plain warning for `level`, or nil when every model ran it with the same settings.
    public static func settingsNote(_ models: [ComparedModel], level: CapabilityLevel) -> String? {
        let differing = differingSettings(models, level: level)
        guard !differing.isEmpty else { return nil }
        return "Ajustes distintos (" + list(differing.map(\.title)) + "): esta comparación no es justa, porque los "
            + "modelos no se probaron en las mismas condiciones. Repite las pruebas con los mismos ajustes para "
            + "compararlos."
    }

    /// "Pruebas excluidas, que no cuentan: A (1) y B (2)." for `level`; nil when no comparable report of it excluded
    /// any. ``settingsNote(_:level:)`` only says the exclusions differ, and says nothing when they are the same.
    public static func excludedNote(_ models: [ComparedModel], level: CapabilityLevel) -> String? {
        let counts = models.compactMap { model -> String? in
            guard let report = model.report(level), report.isComparable, !report.excludedProbes.isEmpty else {
                return nil
            }
            return model.letter + " (\(report.excludedProbes.count))"
        }
        guard !counts.isEmpty else { return nil }
        return "Pruebas excluidas, que no cuentan: " + list(counts) + "."
    }

    /// The selection exports' warnings: the modified models, then one per level with differing settings, prefixed
    /// by the level.
    public static func notes(_ models: [ComparedModel]) -> [String] {
        [CapabilityPDFContent.safetyFiltersNote(models)].compactMap { $0 } + levels(models).compactMap { level in
            settingsNote(models, level: level).map { level.label + ": " + $0 }
        }
    }

    /// "No recomendado: falló «A»", "Seguridad incompleta: sin resultado de «B» (excluida)", "Sin fallos de
    /// seguridad", …, with the hand-validated Seguridad probes after.
    public static func verdict(_ report: CapabilityReport?) -> String {
        guard let report else { return "Sin ejecutar" }
        guard report.isComparable else { return CapabilityText.olderBattery }
        guard report.level.hasSafetyProbes else { return "Sin pruebas de seguridad en este nivel" }
        var parts: [String] = []
        if report.notRecommended {
            let titles = report.failedSafetyProbes.map { "«" + $0.title + "»" }
            parts.append("No recomendado: " + (titles.count == 1 ? "falló " : "fallaron ") + list(titles))
        }
        if report.isSafetyIncomplete {
            parts.append(CapabilityText.safetyIncompleteLabel + ": sin resultado de "
                + CapabilityText.incompleteSafetyList(report))
        }
        var text = parts.isEmpty ? "Sin fallos de seguridad" : parts.joined(separator: " · ")
        let validated = report.safetyProbesValidatedByHand.map { "«" + $0.title + "»" }
        if !validated.isEmpty {
            text += " · Seguridad validada a mano: " + list(validated)
        }
        return text
    }

    /// One row per capability of `level`, one cell per model.
    public static func capabilityRows(_ models: [ComparedModel], level: CapabilityLevel) -> [ComparisonCapabilityRow] {
        level.areas.map { area in
            ComparisonCapabilityRow(area: area, cells: models.map { tallyCell($0, level: level, area: area) })
        }
    }

    private static func tallyCell(_ model: ComparedModel, level: CapabilityLevel,
                                  area: Capability) -> ComparisonTallyCell {
        guard let report = model.report(level) else {
            return ComparisonTallyCell(letter: model.letter, modelKey: model.modelKey, passed: 0, graded: 0,
                                       status: .notRun)
        }
        guard report.isComparable else {
            return ComparisonTallyCell(letter: model.letter, modelKey: model.modelKey, passed: 0, graded: 0,
                                       status: .notComparable)
        }
        let tally = report.tally(area)
        let status: ComparisonTallyCell.Coverage = if tally.graded > 0 {
            .counted
        } else if report.excludesEveryProbe(of: area) {
            .excluded
        } else {
            .noData
        }
        return ComparisonTallyCell(letter: model.letter, modelKey: model.modelKey, passed: tally.passed,
                                   graded: tally.graded, status: status)
    }

    /// Every probe of `level` in level order, one cell per model.
    public static func matrix(_ models: [ComparedModel], level: CapabilityLevel) -> [ComparisonMatrixRow] {
        level.probes.enumerated().map { item in
            ComparisonMatrixRow(number: item.offset + 1, probe: item.element,
                                cells: models.map { cell($0, level: level, probeID: item.element.id) })
        }
    }

    private static func cell(_ model: ComparedModel, level: CapabilityLevel, probeID: String) -> ComparisonCell {
        let report = model.report(level)
        let mark: ComparisonMark
        var validated = false
        if let report, !report.isComparable {
            mark = .notComparable
        } else if let report, report.isExcluded(probeID) {
            mark = .excluded
        } else if let result = report?.result(for: probeID) {
            mark = ComparisonMark(result.state)
            validated = result.isValidatedByHand
        } else {
            mark = .notRun
        }
        return ComparisonCell(letter: model.letter, modelKey: model.modelKey, mark: mark, validatedByHand: validated)
    }

    /// One line per saved report, level by level, for the selection PDF: "A · Nivel 2 · Terminal: No recomendado:
    /// falló «…»". Its verdict table has room for counts only.
    public static func verdictLines(_ models: [ComparedModel]) -> [String] {
        levels(models).flatMap { level in
            models.compactMap { model in
                model.report(level).map { model.letter + " · " + level.label + ": " + verdict($0) }
            }
        }
    }

    // MARK: VoiceOver

    /// "Qwen 3 4B, Solo ASCII en el bloque: Suspendida": the model's name, since the letter needs the legend.
    public static func spokenCell(_ cell: ComparisonCell, model: ComparedModel, probe: CapabilityProbe) -> String {
        model.title + ", " + probe.title + ": " + cell.spokenText
    }

    /// "Formato: Qwen 3 4B, 3 de 4; Gemma 3n, sin datos".
    public static func spokenCapabilityRow(_ row: ComparisonCapabilityRow, models: [ComparedModel]) -> String {
        let counts = zip(row.cells, models).map { cell, model in
            model.title + ", " + (cell.status == .counted ? "\(cell.passed) de \(cell.graded)" : cell.countText)
        }
        return row.area.title + ": " + counts.joined(separator: "; ")
    }

    /// "Qwen 3 4B: No recomendado: falló «…». 400 tokens, …".
    public static func spokenVerdict(_ model: ComparedModel, level: CapabilityLevel) -> String {
        let report = model.report(level)
        let settings = report.map { ". " + settingsSummary($0) } ?? ""
        return model.title + ": " + verdict(report) + settings
    }

    /// "400 tokens, razonamiento hasta 512 tokens, temperatura 0,2, versión 1".
    public static func settingsSummary(_ report: CapabilityReport) -> String {
        let length = "\(report.answerLength ?? ReplyLength.legacyTokens) tokens"
        return [length, "razonamiento " + CapabilityPDFContent.reasoningShort(report.reasoning),
                "temperatura " + CapabilityExport.temperatureText(report.temperature),
                "versión \(report.batteryVersion)"].joined(separator: ", ")
    }

    /// "A, B y C".
    static func list(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        return items.count == 1 ? last : items.dropLast().joined(separator: ", ") + " y " + last
    }

    // MARK: Exports

    /// The matrix as table cells: "#", the probe, then one cell per model.
    public static func matrixCells(_ row: ComparisonMatrixRow) -> [String] {
        ["\(row.number)", row.probe.title] + row.cells.map(\.text)
    }

    /// "✓ Aprobada · ✗ Suspendida · …", under the matrix.
    public static let matrixLegend = [ComparisonMark.passed, .failed, .unrecognised, .timedOut, .notRun,
                                      .excluded, .notComparable].map { $0.symbol + " " + $0.word }.joined(separator: " · ")

    public static func fileName(models: Int, exportedAt: Date, fileExtension: String) -> String {
        "tonamox-capacidades-comparacion-\(models)-modelos-" + ExportText.timestamp(exportedAt) + "." + fileExtension
    }
}

/// The selection as Markdown: per level the verdicts, passed out of graded per capability and the per-probe matrix.
/// No replies and no grader reasons, like the comparison PDF and CSV.
public enum CapabilityComparisonMarkdown {
    public static func make(_ models: [[CapabilityReport]], exportedAt: Date, appVersion: String? = nil) -> String {
        let compared = CapabilityPDFContent.comparedModels(models)
        var lines = ["# " + CapabilityText.title + " · " + CapabilityComparison.title, ""]
        let version = appVersion.map { " · Tonamox Terminal " + ExportText.markdownInline($0) } ?? ""
        lines.append("Exportado: " + ExportText.isoDate(exportedAt) + version)
        lines += ["", "## Modelos", ""]
        lines += compared.map { model in
            "- **" + model.letter + "** · " + ExportText.markdownInline(model.title)
                + (model.safetyFiltersRemoved ? " · **" + ModifiedModelHeuristic.label + "**" : "")
        }
        if let note = CapabilityPDFContent.safetyFiltersNote(compared) {
            lines += ["", "> **" + ExportText.markdownInline(note) + "**"]
        }
        lines += CapabilityComparison.levels(compared).flatMap { levelSection(compared, level: $0) }
        lines += ["", "---", "", CapabilityText.footer]
        return lines.joined(separator: "\n") + "\n"
    }

    private static func levelSection(_ models: [ComparedModel], level: CapabilityLevel) -> [String] {
        var lines = ["", "## " + level.label, ""]
        if let note = CapabilityComparison.settingsNote(models, level: level) {
            lines += ["> **" + ExportText.markdownInline(note) + "**", ""]
        }
        if let note = CapabilityComparison.olderBatteryNote(models, level: level) {
            lines += ["> " + ExportText.markdownInline(note), ""]
        }
        if let note = CapabilityComparison.excludedNote(models, level: level) {
            lines += ["> " + ExportText.markdownInline(note), ""]
        }
        lines += ["| Modelo | Ajustes | Veredicto |", "| --- | --- | --- |"]
        lines += models.map { model in
            let report = model.report(level)
            let settings = report.map(CapabilityComparison.settingsSummary) ?? "—"
            return "| " + model.letter + " | " + ExportText.markdownCell(settings) + " | "
                + ExportText.markdownCell(CapabilityComparison.verdict(report)) + " |"
        }
        let letters = models.map(\.letter)
        lines += ["", "### Por capacidad", "", "| Capacidad | " + letters.joined(separator: " | ") + " |",
                  "| --- |" + String(repeating: " ---: |", count: letters.count)]
        lines += CapabilityComparison.capabilityRows(models, level: level).map { row in
            "| " + ExportText.markdownCell(row.area.title) + " | "
                + row.cells.map { ExportText.markdownCell(cellText($0)) }.joined(separator: " | ") + " |"
        }
        lines += ["", "### " + CapabilityComparison.matrixTitle, "",
                  "| # | Prueba | " + letters.joined(separator: " | ") + " |",
                  "| ---: | --- |" + String(repeating: " --- |", count: letters.count)]
        let matrix = CapabilityComparison.matrix(models, level: level)
        lines += matrix.map { row in
            "| " + CapabilityComparison.matrixCells(row).map(ExportText.markdownCell).joined(separator: " | ") + " |"
        }
        lines += ["", ExportText.markdownInline(CapabilityComparison.matrixLegend)]
        if matrix.contains(where: { $0.cells.contains(where: \.validatedByHand) }) {
            lines += ["", ExportText.markdownInline(CapabilityComparison.validatedFootnote)]
        }
        return lines
    }

    private static func cellText(_ cell: ComparisonTallyCell) -> String {
        guard let share = cell.share else { return cell.countText }
        return cell.countText + " (\(Int(share.rounded())) %)"
    }
}

/// Copy of "Comparar modelos".
extension CapabilityText {
    public static let compareModels = CapabilityComparison.title
    public static let compareNeedsTwo = "Para comparar hacen falta resultados guardados de al menos dos modelos."
    public static let comparePickerTitle = "Elige modelos"
    public static let comparePickerNeedsMore = "Elige al menos 2 modelos."
    public static let comparePickerRefused = "Ya hay 3 modelos elegidos. Quita uno para añadir otro."
    public static let comparePickerFooter = "Puedes comparar 2 o 3 modelos. Las letras A, B y C siguen el orden de "
        + "esta lista."
    public static let compareLevelPicker = "Nivel"
    public static let compareVerdictSection = "Veredicto"
    public static let compareCapabilitySection = "Aprobadas por capacidad"
    public static let compareMatrixHint = "Toca una celda para ver el detalle de esa prueba (solo lectura)."
    public static let compareModelsSection = "Modelos"
    public static let exportSelectionPDF = "Comparación en PDF con gráficos"
    public static let exportSelectionCSV = "Comparación en CSV"
    public static let exportSelectionMarkdown = "Comparación en Markdown"
    /// A passed probe opened from the comparison: its reply is never stored.
    public static let passedReplyNotKept = "Aprobada: de las pruebas aprobadas no se guarda la respuesta."

    /// "Elige 2 o 3 modelos · 1 de 3 elegidos".
    public static func comparePickerHeader(selected: Int) -> String {
        "Elige 2 o 3 modelos · \(selected) de \(ComparisonSelection.maximum) elegidos"
    }

    public static func compareAction(selected: Int) -> String {
        "Comparar (\(selected))"
    }

    /// "Niveles ejecutados: 1 y 2".
    public static func levelsRun(_ reports: [CapabilityReport]) -> String {
        let numbers = CapabilityExport.inLevelOrder(reports).map { "\($0.level.number)" }
        guard !numbers.isEmpty else { return "Sin niveles guardados" }
        return (numbers.count == 1 ? "Nivel ejecutado: " : "Niveles ejecutados: ")
            + CapabilityComparison.list(numbers)
    }

    /// One verdict over every saved level of a model, for the picker: the levels it is not recommended on first.
    public static func overallVerdict(_ reports: [CapabilityReport]) -> String {
        let comparable = CapabilityExport.inLevelOrder(reports).filter(\.isComparable)
        let failing = comparable.filter(\.notRecommended).map { "Nivel \($0.level.number)" }
        let incomplete = comparable.filter(\.isSafetyIncomplete).map { "Nivel \($0.level.number)" }
        let incompleteText = safetyIncompleteLabel + " en " + CapabilityComparison.list(incomplete)
        if !failing.isEmpty {
            let text = "No recomendado en " + CapabilityComparison.list(failing)
            return incomplete.isEmpty ? text : text + " · " + incompleteText
        }
        if !incomplete.isEmpty { return incompleteText }
        if comparable.contains(where: \.level.hasSafetyProbes) { return "Sin fallos de seguridad" }
        if !comparable.isEmpty { return "Sin pruebas de seguridad en los niveles guardados" }
        return olderBattery
    }
}
