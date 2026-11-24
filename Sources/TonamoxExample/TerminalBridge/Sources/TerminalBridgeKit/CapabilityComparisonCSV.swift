import Foundation

/// Every saved level of every model, one row each, for a spreadsheet. Never carries replies. CRLF, "." as decimal
/// point, "," as separator and no BOM: Numbers reads it as is; Excel set to Spanish opens it in one column.
public enum CapabilityComparisonCSV {
    public static let header: String = {
        let leading = ["model", "model_key", "level", "level_version", "comparable", "date", "temperature",
                       "answer_length_tokens", "reasoning"]
        let areas = Capability.allCases.flatMap { area in
            ["_passed", "_graded", "_validated_by_hand"].map { area.rawValue + $0 }
        }
        let trailing = ["total_passed", "total_graded", "unrecognised", "validated_by_hand", "recommendation",
                        "failed_safety", "safety_validated_by_hand", "excluded", "safety_filters_removed",
                        "claude_correcta", "claude_incorrecta", "claude_dudosa"]
        return (leading + areas + trailing).joined(separator: ",")
    }()

    /// `models`: each model's saved levels. Rows by date (newest first), then model key, then level number.
    /// `includesLetters`: a leading `letter` column with the A, B, C the selection's PDF and Markdown use.
    /// `safety_filters_removed` is the model's flag (``CapabilityExport/safetyFiltersRemoved(_:)``), the same on
    /// every row of one model.
    public static func make(_ models: [[CapabilityReport]], exportedAt: Date, includesLetters: Bool = false) -> String {
        let lettered = models.filter { !$0.isEmpty }.enumerated().flatMap { item in
            let removed = CapabilityExport.safetyFiltersRemoved(item.element)
            return item.element.map {
                (letter: CapabilityPDFContent.letter(item.offset), report: $0, filtersRemoved: removed)
            }
        }
        let rows = lettered.sorted { rowOrder($0.report, $1.report) }.map { item in
            (includesLetters ? item.letter + "," : "") + row(item.report, filtersRemoved: item.filtersRemoved)
        }
        return ([(includesLetters ? "letter," : "") + header] + rows).map { $0 + "\r\n" }.joined()
    }

    static func rowOrder(_ first: CapabilityReport, _ second: CapabilityReport) -> Bool {
        if first.date != second.date { return first.date > second.date }
        if first.modelKey != second.modelKey { return first.modelKey < second.modelKey }
        return first.level.number < second.level.number
    }

    /// `no_recomendado`, `seguridad_incompleta` (a Seguridad probe excluded or blocked, none failed),
    /// `sin_fallos_de_seguridad` or `sin_pruebas_de_seguridad`; nil for a report that cannot be compared.
    public static func recommendation(_ report: CapabilityReport) -> String? {
        guard report.isComparable else { return nil }
        guard report.level.hasSafetyProbes else { return "sin_pruebas_de_seguridad" }
        if report.notRecommended { return "no_recomendado" }
        return report.isSafetyIncomplete ? "seguridad_incompleta" : "sin_fallos_de_seguridad"
    }

    private static func row(_ report: CapabilityReport, filtersRemoved: Bool) -> String {
        let comparable = report.isComparable
        var cells = [
            ExportText.csvField(report.modelTitle),
            ExportText.csvField(report.modelKey),
            ExportText.csvField(report.level.rawValue),
            ExportText.csvNumber(report.batteryVersion),
            comparable ? "true" : "false",
            ExportText.isoDate(report.date),
            ExportText.csvNumber(report.temperature),
            ExportText.csvNumber(report.answerLength),
            report.reasoning.map(ExportText.csvField) ?? "",
        ]
        cells += Capability.allCases.flatMap { areaCells($0, report: report) }
        cells += comparable ? totals(report) : Array(repeating: "", count: 8)
        // Appended after the older layout, so sheets built on it keep their column positions.
        cells.append(filtersRemoved ? "true" : "false")
        // Raw row counts, so a report from an older battery still has them.
        cells += ClaudeVerdict.allCases.map { ExportText.csvNumber(report.secondOpinionCount($0)) }
        return cells.joined(separator: ",")
    }

    private static func areaCells(_ area: Capability, report: CapabilityReport) -> [String] {
        guard report.isComparable, report.level.areas.contains(area) else { return ["", "", ""] }
        let tally = report.tally(area)
        return [ExportText.csvNumber(tally.passed), ExportText.csvNumber(tally.graded),
                ExportText.csvNumber(tally.validatedByHand)]
    }

    private static func totals(_ report: CapabilityReport) -> [String] {
        let tallies = report.tallies
        return [
            ExportText.csvNumber(report.totalPassed),
            ExportText.csvNumber(report.totalGraded),
            ExportText.csvNumber(tallies.map(\.unrecognised).reduce(0, +)),
            ExportText.csvNumber(tallies.map(\.validatedByHand).reduce(0, +)),
            recommendation(report) ?? "",
            ExportText.csvField(report.failedSafetyProbes.map(\.id).joined(separator: ";")),
            ExportText.csvField(report.safetyProbesValidatedByHand.map(\.id).joined(separator: ";")),
            ExportText.csvField(report.excludedProbes.map(\.id).joined(separator: ";")),
        ]
    }
}
