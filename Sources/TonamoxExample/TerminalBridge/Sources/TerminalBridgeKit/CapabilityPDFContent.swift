import Foundation

/// One bar of a PDF chart. `series` is what the legend names; `annotation` is printed on the bar, so no series
/// depends on colour alone.
public struct CapabilityChartBar: Hashable, Sendable, Identifiable {
    public let category: String
    public let series: String
    public let value: Double
    public let annotation: String

    public var id: String { category + "\u{1F}" + series }
}

/// A model in the comparison PDF, under the letter its bars carry.
public struct ComparedModel: Hashable, Sendable {
    public let letter: String
    public let title: String
    public let modelKey: String
    /// In level order.
    public let reports: [CapabilityReport]

    public func report(_ level: CapabilityLevel) -> CapabilityReport? {
        reports.first { $0.level == level }
    }

    public var safetyFiltersRemoved: Bool { CapabilityExport.safetyFiltersRemoved(reports) }

    /// The title, plus «Sin filtros» for a model whose safety training was removed.
    public var markedTitle: String {
        safetyFiltersRemoved ? title + " · " + ModifiedModelHeuristic.shortLabel : title
    }
}

/// What the PDFs say and chart, without any rendering, so the content is tested in the kit.
public enum CapabilityPDFContent {
    public static let passedSeries = "Aprobadas"
    public static let gradedSeries = "Evaluadas"
    public static let comparisonTitle = "Comparación de modelos"
    public static let summaryTitle = "Resumen"
    public static let byCapabilityTitle = "Aprobadas y evaluadas por capacidad"
    public static let byLevelTitle = "Aprobadas y evaluadas por nivel"
    public static let donutByLevelTitle = "Resultado por nivel"
    public static let donutByCapabilityTitle = "Resultado por capacidad (aprobadas, incluidas las validadas a mano)"
    public static let donutComparisonHeading = "resultado de cada modelo"
    public static let donutComparisonTableTitle = "aprobadas por capacidad"
    public static let probesTitle = "Todas las pruebas"
    public static let notPassedTitle = "Pruebas no aprobadas"
    public static let verdictTitle = "Veredicto por nivel"
    public static let settingsTitle = "Ajustes de cada ejecución"
    public static let paperNote = "Tamaño A4."
    public static let noComparableReports = "Ningún nivel guardado se puede comparar con esta batería."

    public static let probeColumns = ["#", "Prueba", "Capacidad", "Estado", "Tiempo", "A mano", "Motivo"]
    public static let verdictColumns = ["", "Modelo"] + CapabilityLevel.allCases.map(\.label)
    public static let settingsColumns = ["", "Nivel", "Versión", "Longitud", "Razonamiento", "Temperatura"]

    public static func pageFooter(page: Int, of total: Int) -> String {
        "Página \(page) de \(total)"
    }

    /// "Nivel 2 · Terminal · versión 1".
    public static func levelHeading(_ report: CapabilityReport) -> String {
        report.level.label + " · versión \(report.batteryVersion)"
    }

    /// Settings of one run, one line each, for the cover.
    public static func settingsLines(_ report: CapabilityReport) -> [String] {
        [ReplyLength.reportText(report.answerLength), ReasoningSetting.reportText(report.reasoning),
         "Temperatura: " + CapabilityExport.temperatureText(report.temperature) + "."]
    }

    // MARK: Single model

    /// Two bars per capability of a comparable report; empty otherwise.
    public static func capabilityBars(_ report: CapabilityReport) -> [CapabilityChartBar] {
        guard report.isComparable else { return [] }
        return report.tallies.flatMap { tally in
            pair(category: tally.area.title, passed: tally.passed, graded: tally.graded)
        }
    }

    /// Two bars per comparable level.
    public static func levelBars(_ reports: [CapabilityReport]) -> [CapabilityChartBar] {
        CapabilityExport.inLevelOrder(reports).filter(\.isComparable).flatMap { report in
            pair(category: report.level.label, passed: report.totalPassed, graded: report.totalGraded)
        }
    }

    private static func pair(category: String, passed: Int, graded: Int) -> [CapabilityChartBar] {
        [CapabilityChartBar(category: category, series: passedSeries, value: Double(passed),
                            annotation: "\(passed)"),
         CapabilityChartBar(category: category, series: gradedSeries, value: Double(graded),
                            annotation: "\(graded)")]
    }

    /// Short state for a table cell: the long «No reconocida — …» does not fit.
    public static func shortState(_ result: ProbeResult) -> String {
        if result.isValidatedByHand { return "Válida a mano (era: " + shortState(result.state) + ")" }
        return shortState(result.state)
    }

    public static func shortState(_ state: ProbeRunState) -> String {
        switch state {
        case .passed: "Aprobada"
        case .failed: "Suspendida"
        case .unrecognised: "No reconocida"
        case .timedOut: "Tiempo agotado"
        case .notRun: "Sin ejecutar"
        case .error: "Servidor ocupado"
        }
    }

    /// The probe-table row of a result, cells in ``probeColumns`` order. `validatedOn` formats the mark's date.
    public static func probeCells(
        number: Int,
        result: ProbeResult,
        validatedOn: (Date) -> String
    ) -> [String] {
        let probe = CapabilityBattery.probe(withID: result.probeID)
        let mark = result.isValidatedByHand ? result.validatedByHand.map { validatedOn($0.date) } ?? "Sí" : "—"
        return ["\(number)", probe?.title ?? result.probeID, probe?.area.title ?? "—", shortState(result),
                CapabilityText.secondsText(result.seconds) ?? "—", mark,
                ExportText.revealingInvisibles(result.reason)]
    }

    /// The lines under «Segunda opinión (Claude)» in a not-passed section; empty without one. The reason follows the
    /// reply's withholding rule.
    public static func secondOpinionLines(_ result: ProbeResult, options: CapabilityExportOptions) -> [String] {
        guard let judgment = result.secondOpinion else { return [] }
        let withheld = CapabilityExport.withheldReason(CapabilityExport.reply(for: result, options: options))
        return ClaudeJudgeText.exportLines(judgment, withheldReason: withheld).map(ExportText.revealingInvisibles)
    }

    // MARK: Comparison

    /// A, B, … Z, AA, AB, …
    public static func letter(_ index: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var value = index
        var letters = ""
        repeat {
            letters.insert(alphabet[value % 26], at: letters.startIndex)
            value = value / 26 - 1
        } while value >= 0
        return letters
    }

    /// Models in the order given (the store's, newest first), each with a letter. Models without reports are
    /// left out.
    public static func comparedModels(_ models: [[CapabilityReport]]) -> [ComparedModel] {
        models.filter { !$0.isEmpty }.enumerated().map { item in
            let identity = CapabilityExport.identity(item.element)
            return ComparedModel(letter: letter(item.offset), title: identity.title, modelKey: identity.key,
                                 reports: CapabilityExport.inLevelOrder(item.element))
        }
    }

    /// Levels with at least one comparable report, in level order.
    public static func chartedLevels(_ models: [ComparedModel]) -> [CapabilityLevel] {
        CapabilityLevel.allCases.filter { level in
            models.contains { $0.report(level)?.isComparable == true }
        }
    }

    /// Per capability of `level`, one bar per model with a comparable report: the share passed, 0–100. Shares,
    /// not counts, because a model may have been graded on fewer probes (busy server).
    public static func comparisonBars(_ models: [ComparedModel], level: CapabilityLevel) -> [CapabilityChartBar] {
        level.areas.flatMap { area in
            models.compactMap { model in comparisonBar(model, level: level, area: area) }
        }
    }

    private static func comparisonBar(
        _ model: ComparedModel,
        level: CapabilityLevel,
        area: Capability
    ) -> CapabilityChartBar? {
        guard let report = model.report(level), report.isComparable else { return nil }
        let tally = report.tally(area)
        // A zero-length bar that says so, so "no data" never reads as "not run".
        guard tally.graded > 0 else {
            return CapabilityChartBar(category: area.title, series: model.letter, value: 0,
                                      annotation: model.letter + " · " + noData)
        }
        let share = Double(tally.passed) / Double(tally.graded) * 100
        return CapabilityChartBar(category: area.title, series: model.letter, value: share,
                                  annotation: model.letter + " · \(tally.passed)/\(tally.graded)")
    }

    public static let noData = "sin datos"
    /// Every probe of the capability was excluded from that report.
    public static let excludedArea = "excluida"

    // MARK: Chart size

    /// The renderer's bar row, the space between categories and the axes and legend; shared so the kit can check
    /// that a chart fits a page.
    public static let chartBarRow = 15.0
    public static let chartCategoryPadding = 12.0
    public static let chartChrome = 50.0
    /// More bars per category than this stop being readable, whatever the page allows.
    public static let maxModelsPerChart = 8

    public static func chartHeight(categories: Int, series: Int) -> Double {
        Double(categories * max(series, 1)) * chartBarRow + Double(categories) * chartCategoryPadding + chartChrome
    }

    /// The models with a comparable report of `level`, in groups small enough for one chart to fit `height`; a
    /// taller block would be clipped at the page end.
    public static func chartGroups(
        _ models: [ComparedModel],
        level: CapabilityLevel,
        height: Double
    ) -> [[ComparedModel]] {
        let charted = models.filter { $0.report(level)?.isComparable == true }
        let categories = Double(max(level.areas.count, 1))
        let fitting = Int((height - chartChrome - categories * chartCategoryPadding) / (categories * chartBarRow))
        let size = max(1, min(maxModelsPerChart, fitting))
        return stride(from: 0, to: charted.count, by: size).map { start in
            Array(charted[start..<min(start + size, charted.count)])
        }
    }

    /// "A · Qwen 3 4B", one per model, under every comparison chart; «· Sin filtros» after a modified model.
    public static func legendLines(_ models: [ComparedModel]) -> [String] {
        models.map { $0.letter + " · " + $0.markedTitle }
    }

    /// The models whose safety training was removed; nil when none. Why their Seguridad failures are expected is
    /// added only when one of their reports has Seguridad probes, and «No recomendado» only when one carries it.
    public static func safetyFiltersNote(_ models: [ComparedModel]) -> String? {
        let modified = models.filter(\.safetyFiltersRemoved)
        guard !modified.isEmpty else { return nil }
        let single = modified.count == 1
        let note = (single ? "Modelo modificado" : "Modelos modificados") + ", sin filtros de seguridad: "
            + CapabilityComparison.list(modified.map(\.letter)) + "."
        let reports = modified.flatMap(\.reports)
        guard reports.contains(where: \.level.hasSafetyProbes) else { return note }
        let expectation = note + " Es de esperar que " + (single ? "suspenda" : "suspendan")
            + " pruebas de Seguridad, porque esas protecciones se eliminaron"
        return expectation + (reports.contains(where: \.notRecommended) ? "; «No recomendado» se mantiene." : ".")
    }

    /// A verdict-table cell: "5 de 6 · No recomendado", "sin ejecutar", "batería anterior: no comparable".
    public static func verdictCell(_ report: CapabilityReport?) -> String {
        guard let report else { return CapabilityText.levelNotRun }
        guard report.isComparable else { return "batería anterior: no comparable" }
        let verdict: String
        switch CapabilityComparisonCSV.recommendation(report) {
        case "no_recomendado": verdict = "No recomendado"
        case "seguridad_incompleta": verdict = CapabilityText.safetyIncompleteLabel
        case "sin_pruebas_de_seguridad": verdict = "Sin pruebas de seguridad"
        default: verdict = "Sin fallos de seguridad"
        }
        return "\(report.totalPassed) de \(report.totalGraded) · " + verdict
    }

    public static func verdictCells(_ model: ComparedModel) -> [String] {
        [model.letter, model.markedTitle] + CapabilityLevel.allCases.map { verdictCell(model.report($0)) }
    }

    /// Cells in ``settingsColumns`` order.
    public static func settingsCells(_ model: ComparedModel, report: CapabilityReport) -> [String] {
        let length = report.answerLength.map { "\($0) tokens" } ?? "\(ReplyLength.legacyTokens) tokens (fija)"
        return [model.letter, report.level.label, "\(report.batteryVersion)", length,
                reasoningShort(report.reasoning), CapabilityExport.temperatureText(report.temperature)]
    }

    static func reasoningShort(_ label: String?) -> String {
        guard let label else { return "sin dato" }
        if label == ReasoningSetting.disabled.reportLabel { return "desactivado" }
        if label.hasPrefix("auto:"), let tokens = Int(label.dropFirst(5)) { return "hasta \(tokens) tokens" }
        return label
    }

    /// Warnings above the comparison: modified models, runs of one level with different settings, and reports from
    /// an older battery, which are listed but never charted.
    public static func comparisonNotes(_ models: [ComparedModel]) -> [String] {
        [safetyFiltersNote(models)].compactMap { $0 }
            + CapabilityLevel.allCases.compactMap { level in settingsNote(models, level: level) }
            + [olderBatteryNote(models), excludedNote(models)].compactMap { $0 }
    }

    /// "Pruebas excluidas, que no cuentan: A (Nivel 3 · Avanzado: 1)."; nil when no report excluded any.
    public static func excludedNote(_ models: [ComparedModel]) -> String? {
        let excluded = models.flatMap { model in
            model.reports.filter { !$0.excludedProbes.isEmpty }
                .map { model.letter + " (" + $0.level.label + ": \($0.excludedProbes.count))" }
        }
        guard !excluded.isEmpty else { return nil }
        return "Pruebas excluidas, que no cuentan: " + excluded.joined(separator: ", ") + "."
    }

    /// The reports from an older battery, listed but never charted; nil when there are none.
    public static func olderBatteryNote(_ models: [ComparedModel]) -> String? {
        let older = models.flatMap { model in
            model.reports.filter { !$0.isComparable }.map { model.letter + " (" + $0.level.label + ")" }
        }
        guard !older.isEmpty else { return nil }
        return "Resultados de una batería anterior, que no se comparan: " + older.joined(separator: ", ") + "."
    }

    private struct RunSettings: Hashable {
        let temperature: Double
        let reasoning: String?
        let answerLength: Int?
    }

    private static func settingsNote(_ models: [ComparedModel], level: CapabilityLevel) -> String? {
        let runs = models.compactMap { $0.report(level) }.filter(\.isComparable)
        let distinct = Set(runs.map { RunSettings(temperature: $0.temperature, reasoning: $0.reasoning,
                                                  answerLength: $0.answerLength) })
        guard distinct.count > 1 else { return nil }
        return level.label + ": los modelos se probaron con ajustes distintos (longitud de respuesta, razonamiento "
            + "o temperatura). Compara con cuidado; los ajustes de cada uno están en la tabla."
    }
}
