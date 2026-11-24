import Foundation

/// What an export of saved reports carries. Not stored: every export starts from the defaults.
public struct CapabilityExportOptions: Hashable, Sendable {
    public var includeReplies: Bool
    /// Seguridad replies and any reply with a line `RiskyCommandRules` flags; off by default.
    public var includeSafetyReplies: Bool
    public var appVersion: String?

    public init(includeReplies: Bool = true, includeSafetyReplies: Bool = false, appVersion: String? = nil) {
        self.includeReplies = includeReplies
        self.includeSafetyReplies = includeSafetyReplies
        self.appVersion = appVersion
    }
}

/// Why an export leaves a saved reply out. Raw values are written to the JSON.
public enum ReplyWithholding: String, Codable, Sendable {
    /// A Seguridad probe.
    case safety
    /// The answer or its reasoning has a line `RiskyCommandRules` flags.
    case risky
    /// "Incluir respuestas" was off.
    case option
}

/// What an export shows of one result's reply.
public enum ExportedReply: Hashable, Sendable {
    /// Passed or not run: no reply is kept.
    case none
    /// Not passed, from a report saved before replies were kept.
    case notSaved
    case withheld(ReplyWithholding, rules: [RiskyRule])
    /// `marked`: a Seguridad or flagged reply the owner chose to include; exports set it apart.
    case shown(SavedProbeReply, marked: Bool)
}

/// Export copy. The share sheet gets files only, never text: nothing here reaches the pasteboard.
extension CapabilityText {
    public static let exportMenu = "Exportar"
    public static let includeReplies = "Incluir respuestas"
    public static let includeSafetyReplies = "Incluir respuestas de Seguridad y con órdenes peligrosas"
    public static let exportWarning = "Incluye respuestas del modelo; las de Seguridad contienen órdenes "
        + "peligrosas: no las pegues en una terminal."
    /// The menu cuts long rows: the full warning goes in the file.
    public static let exportMenuWarning = "No pegues las respuestas en una terminal."
    public static let exportMarkdown = "Informe en Markdown"
    public static let exportJSON = "Datos en JSON"
    public static let exportPDF = "Informe en PDF con gráficos"
    public static let exportComparisonCSV = "Exportar comparación (CSV)"
    public static let exportComparisonPDF = "Exportar comparación (PDF)"
    public static let exportTestSession = "Exportar sesión (Markdown)"
    public static let noSafetyFailures = "Sin fallos de seguridad en este nivel."
    public static let repliesNotIncluded = "(no se incluyen las respuestas)"
    public static let safetyReplyWithheld = "(no se incluye: es la respuesta de una prueba de seguridad; actívalo con "
        + "«" + includeSafetyReplies + "»)"
    public static let markedReplyNotice = "▌ Respuesta de seguridad o con una orden peligrosa: no la pegues en una "
        + "terminal."

    public static func riskyReplyWithheld(_ rules: [RiskyRule]) -> String {
        "(no se incluye: tiene una orden que la app marcaría como peligrosa: "
            + rules.map(\.title).joined(separator: ", ") + ")"
    }

    /// A row's state for a table: the owner's mark, then the grader's word in brackets.
    public static func exportState(_ result: ProbeResult) -> String {
        result.isValidatedByHand ? validatedLabel + " (evaluador: " + label(result.state) + ")" : label(result.state)
    }

    /// The verdict line of one level: «No recomendado…» or «Seguridad incompleta…», the hand-validated Seguridad
    /// probes, or why there is none; then the excluded probes, if any.
    public static func verdictLines(_ report: CapabilityReport) -> [String] {
        guard report.isComparable else { return [olderBattery] }
        var lines: [String]
        if report.level.hasSafetyProbes {
            let incomplete = safetyIncomplete(report)
            lines = report.notRecommended ? [notRecommended(report)] : (incomplete == nil ? [noSafetyFailures] : [])
            if let incomplete { lines.append(incomplete) }
            if let safety = safetyValidatedByHand(report) { lines.append(safety) }
        } else {
            lines = [noSafetyProbes]
        }
        if let excluded = excludedSummary(report) { lines.append(excluded) }
        return lines
    }
}

public enum CapabilityExport {
    // MARK: File names

    public static func fileName(modelTitle: String, exportedAt: Date, fileExtension: String) -> String {
        "tonamox-capacidades-" + ExportText.slug(modelTitle) + "-" + ExportText.timestamp(exportedAt) + "."
            + fileExtension
    }

    public static func comparisonFileName(exportedAt: Date, fileExtension: String) -> String {
        "tonamox-capacidades-comparacion-" + ExportText.timestamp(exportedAt) + "." + fileExtension
    }

    // MARK: Replies

    /// The rule every export follows; the same one `ValidatedRepliesExport` applies to the copy button, plus the
    /// reasoning, which exports also carry.
    public static func reply(for result: ProbeResult, options: CapabilityExportOptions) -> ExportedReply {
        guard result.state != .passed, result.state != .notRun else { return .none }
        // A probe this build no longer knows is treated as Seguridad: its area cannot be checked.
        let isSafety = CapabilityBattery.probe(withID: result.probeID).map { $0.area == .seguridad } ?? true
        return reply(result.savedReply, isSafety: isSafety, options: options)
    }

    /// The same rule for any saved reply; Test Mode's Seguridad group passes `isSafety`.
    public static func reply(
        _ saved: SavedProbeReply?,
        isSafety: Bool,
        options: CapabilityExportOptions
    ) -> ExportedReply {
        guard options.includeReplies else { return .withheld(.option, rules: []) }
        guard let saved else { return .notSaved }
        let found = Set(ManualValidationPolicy.riskyRules(in: saved.answer)
            + ManualValidationPolicy.riskyRules(in: saved.reasoning ?? ""))
        let rules = RiskyRule.allCases.filter(found.contains)
        guard isSafety || !rules.isEmpty else { return .shown(saved, marked: false) }
        guard options.includeSafetyReplies else { return .withheld(isSafety ? .safety : .risky, rules: rules) }
        return .shown(saved, marked: true)
    }

    /// The text that stands for a reply that is not shown; nil when it is shown or there is none.
    public static func replacementText(_ reply: ExportedReply) -> String? {
        switch reply {
        case .none, .shown: nil
        case .notSaved: CapabilityText.replyNotSaved
        case .withheld(.option, _): CapabilityText.repliesNotIncluded
        case .withheld(.safety, _): CapabilityText.safetyReplyWithheld
        case .withheld(.risky, let rules): CapabilityText.riskyReplyWithheld(rules)
        }
    }

    /// `▌ ` before every line of an included Seguridad or flagged reply.
    public static func markedLines(_ text: String) -> String {
        text.components(separatedBy: "\n").map { "▌ " + $0 }.joined(separator: "\n")
    }

    // MARK: Order

    /// Levels in level order, whatever order they come in.
    static func inLevelOrder(_ reports: [CapabilityReport]) -> [CapabilityReport] {
        reports.sorted { $0.level.number < $1.level.number }
    }

    /// The report's rows in its level's probe order, then any row this build does not know, as stored.
    public static func orderedResults(_ report: CapabilityReport) -> [ProbeResult] {
        let known = report.level.probes.compactMap { report.result(for: $0.id) }
        let knownIDs = Set(known.map(\.probeID))
        return known + report.results.filter { !knownIDs.contains($0.probeID) }
    }

    /// ``orderedResults(_:)`` with each row's number on the app page: its place in the level, so an excluded probe
    /// leaves a gap instead of renumbering the rest. Rows the level does not know follow, numbered after it.
    public static func numberedResults(_ report: CapabilityReport) -> [(number: Int, result: ProbeResult)] {
        let place = Dictionary(report.level.probes.enumerated().map { ($0.element.id, $0.offset + 1) }) { first, _ in
            first
        }
        var next = report.level.probes.count
        return orderedResults(report).map { result in
            if let number = place[result.probeID] { return (number, result) }
            next += 1
            return (next, result)
        }
    }

    /// The newest report names the model: a title can change between runs.
    static func identity(_ reports: [CapabilityReport]) -> (key: String, title: String) {
        let newest = reports.max { $0.date < $1.date }
        return (newest?.modelKey ?? "", newest?.modelTitle ?? "")
    }

    /// Any saved level flags it: the flag belongs to the model, not to one run.
    public static func safetyFiltersRemoved(_ reports: [CapabilityReport]) -> Bool {
        reports.contains(where: \.safetyFiltersRemoved)
    }

    /// «Modificado: sin filtros de seguridad.» and, when the reports have Seguridad probes, why its failures there
    /// are expected (``ModifiedModelHeuristic/expectedFailuresNote(_:)``), for the top of a report; empty for any
    /// other model.
    public static func safetyFiltersLines(_ reports: [CapabilityReport]) -> [String] {
        guard safetyFiltersRemoved(reports) else { return [] }
        let note = ModifiedModelHeuristic.expectedFailuresNote(reports)
        return [ModifiedModelHeuristic.label + "."] + [note].compactMap { $0 }
    }

    // MARK: JSON

    public static func json(
        _ reports: [CapabilityReport],
        options: CapabilityExportOptions,
        exportedAt: Date
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document(reports, options: options, exportedAt: exportedAt))
    }

    public static func document(
        _ reports: [CapabilityReport],
        options: CapabilityExportOptions,
        exportedAt: Date
    ) -> CapabilityExportDocument {
        let identity = identity(reports)
        return CapabilityExportDocument(
            exportedAt: exportedAt, appVersion: options.appVersion, modelKey: identity.key,
            modelTitle: identity.title, safetyFiltersRemoved: safetyFiltersRemoved(reports),
            levels: inLevelOrder(reports).map { CapabilityExportDocument.LevelEntry($0, options: options) })
    }

    // MARK: Markdown

    public static func markdown(
        _ reports: [CapabilityReport],
        options: CapabilityExportOptions,
        exportedAt: Date
    ) -> String {
        let identity = identity(reports)
        var lines = ["# " + CapabilityText.title + " · " + ExportText.markdownInline(identity.title), ""]
        let version = options.appVersion.map { " · Tonamox Terminal " + ExportText.markdownInline($0) } ?? ""
        lines.append("Exportado: " + ExportText.isoDate(exportedAt) + version)
        let filters = safetyFiltersLines(reports)
        if let mark = filters.first {
            lines += ["", "> **" + ExportText.markdownInline(mark) + "** "
                + filters.dropFirst().map(ExportText.markdownInline).joined(separator: " ")]
        }
        if options.includeReplies {
            lines += ["", "> " + CapabilityText.exportWarning]
        }
        lines += inLevelOrder(reports).flatMap { levelSection($0, options: options) }
        lines += ["", "---", "", CapabilityText.footer]
        return lines.joined(separator: "\n") + "\n"
    }

    /// "0,2", as the app writes it.
    public static func temperatureText(_ value: Double) -> String {
        ExportText.csvNumber(value).replacingOccurrences(of: ".", with: ",")
    }

    static func settingsLines(_ report: CapabilityReport) -> [String] {
        let version = "Versión de la batería: \(report.batteryVersion)"
            + (report.isComparable ? "" : " · " + CapabilityText.olderBattery)
        return [
            version,
            "Fecha: " + ExportText.isoDate(report.date),
            "Temperatura: " + temperatureText(report.temperature),
            ReasoningSetting.reportText(report.reasoning),
            ReplyLength.reportText(report.answerLength),
        ]
    }

    private static func levelSection(_ report: CapabilityReport, options: CapabilityExportOptions) -> [String] {
        var lines = ["", "## " + report.level.label, ""]
        lines += settingsLines(report).map { "- " + ExportText.markdownInline($0) }
        lines.append("")
        lines += CapabilityText.verdictLines(report).map { "**" + ExportText.markdownInline($0) + "**" }
        lines += ["", "### " + CapabilityText.summarySection, ""]
        if report.isComparable {
            lines.append("| Capacidad | Aprobadas | Evaluadas | No reconocidas | Validadas a mano |")
            lines.append("| --- | ---: | ---: | ---: | ---: |")
            lines += report.tallies.map(tallyRow)
        } else {
            lines.append(ExportText.markdownInline(CapabilityText.olderBattery))
        }
        let results = numberedResults(report)
        lines += ["", "### Pruebas", "", "| # | Prueba | Capacidad | Estado | Tiempo | Motivo |",
                  "| ---: | --- | --- | --- | ---: | --- |"]
        lines += results.map { probeRow(number: $0.number, result: $0.result) }
        let notPassed = results.filter { $0.result.state != .passed && $0.result.state != .notRun }
        if !notPassed.isEmpty {
            lines += ["", "### No aprobadas"]
            lines += notPassed.flatMap { item in
                notPassedSection(number: item.number, result: item.result, report: report, options: options)
            }
        }
        return lines
    }

    private static func tallyRow(_ tally: CapabilityTally) -> String {
        "| " + ExportText.markdownCell(tally.area.title) + " | \(tally.passed) | \(tally.graded) | "
            + "\(tally.unrecognised) | \(tally.validatedByHand) |"
    }

    private static func probeRow(number: Int, result: ProbeResult) -> String {
        let probe = CapabilityBattery.probe(withID: result.probeID)
        let cells = [
            "\(number)",
            ExportText.markdownCell(probe?.title ?? result.probeID),
            ExportText.markdownCell(probe?.area.title ?? "—"),
            ExportText.markdownCell(CapabilityText.exportState(result)),
            CapabilityText.secondsText(result.seconds) ?? "—",
            ExportText.markdownCell(result.reason),
        ]
        return "| " + cells.joined(separator: " | ") + " |"
    }

    private static func notPassedSection(
        number: Int,
        result: ProbeResult,
        report: CapabilityReport,
        options: CapabilityExportOptions
    ) -> [String] {
        let probe = CapabilityBattery.probe(withID: result.probeID)
        var lines = ["", "#### \(number). " + ExportText.markdownInline(probe?.title ?? result.probeID), ""]
        lines.append("Estado: " + ExportText.markdownInline(CapabilityText.exportState(result)))
        if report.isComparable, let probe {
            lines += ["", "**" + CapabilityText.askedSection + "**", "", ExportText.fenced(probe.request)]
            lines += ["", "**" + CapabilityText.expectedSection + "**", "",
                      ExportText.markdownInline(probe.expectation)]
        }
        let reply = reply(for: result, options: options)
        lines += replyLines(reply)
        lines += ["", "**" + CapabilityText.reasonSection + "**", ""]
        if !result.reason.isEmpty { lines.append(ExportText.markdownInline(result.reason)) }
        lines += (result.notes ?? []).map { "- " + ExportText.markdownInline($0) }
        lines += secondOpinionLines(result.secondOpinion, reply: reply)
        return lines
    }

    /// What stands for a judgment's reason when the reply it is about is not shown: the reason can describe or
    /// quote that reply. Nil when the reply is shown.
    public static func withheldReason(_ reply: ExportedReply) -> String? {
        guard case .shown = reply else { return replacementText(reply) ?? CapabilityText.repliesNotIncluded }
        return nil
    }

    /// The «Segunda opinión (Claude)» block; empty without one. Test Mode's export uses it too.
    static func secondOpinionLines(_ judgment: ClaudeJudgment?, reply: ExportedReply) -> [String] {
        guard let judgment else { return [] }
        let lines = ClaudeJudgeText.exportLines(judgment, withheldReason: withheldReason(reply))
            .map(ExportText.markdownInline)
        return ["", "**" + ClaudeJudgeText.secondOpinionSection + "**", ""] + lines.flatMap { ["", $0] }.dropFirst()
    }

    private static func replyLines(_ reply: ExportedReply) -> [String] {
        if case .none = reply { return [] }
        var lines = ["", "**" + CapabilityText.repliedSection + "**", ""]
        guard case .shown(let saved, let marked) = reply else {
            return lines + [replacementText(reply).map(ExportText.markdownInline) ?? ""]
        }
        if marked { lines += ["> " + CapabilityText.markedReplyNotice, ""] }
        lines.append(saved.answer.isEmpty ? CapabilityText.emptyReply : fencedReply(saved.answer, marked: marked))
        if saved.answerTruncated { lines += ["", "_" + CapabilityText.answerTruncated + "_"] }
        if let reasoning = saved.reasoning {
            lines += ["", "**" + CapabilityText.reasoningSection + "**", "", fencedReply(reasoning, marked: marked)]
            if saved.reasoningTruncated { lines += ["", "_" + CapabilityText.reasoningTruncated + "_"] }
        }
        return lines
    }

    private static func fencedReply(_ text: String, marked: Bool) -> String {
        let shown = ExportText.revealingInvisibles(text)
        return ExportText.fenced(marked ? markedLines(shown) : shown, info: "text")
    }
}

/// The JSON of one model's saved levels, separate from the stored shape so the store can change on its own.
/// Optional facts are written as an explicit null; `request`, `expectation`, `reply` and `replyWithheld` are left
/// out when absent.
public struct CapabilityExportDocument: Encodable, Sendable {
    public static let format = "tonamox.capability-report"
    public static let formatVersion = 1

    public let exportedAt: Date
    public let appVersion: String?
    public let modelKey: String
    public let modelTitle: String
    /// Always written: true when any saved level flags the model (``CapabilityReport/safetyFiltersRemoved``).
    public let safetyFiltersRemoved: Bool
    public let levels: [LevelEntry]

    private enum CodingKeys: String, CodingKey {
        case format, formatVersion, exportedAt, appVersion, modelKey, modelTitle, safetyFiltersRemoved, levels
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.format, forKey: .format)
        try container.encode(Self.formatVersion, forKey: .formatVersion)
        try container.encode(exportedAt, forKey: .exportedAt)
        try encodeOrNull(appVersion, .appVersion, in: &container)
        try container.encode(modelKey, forKey: .modelKey)
        try container.encode(modelTitle, forKey: .modelTitle)
        try container.encode(safetyFiltersRemoved, forKey: .safetyFiltersRemoved)
        try container.encode(levels, forKey: .levels)
    }

    /// A report from another version of its level keeps only its raw rows: no counts, verdict or probe text,
    /// because the area table they come from may have changed.
    public struct LevelEntry: Encodable, Sendable {
        public let level: String
        public let levelNumber: Int
        public let levelVersion: Int
        public let comparable: Bool
        public let date: Date
        public let temperature: Double
        public let answerLength: Int?
        public let reasoning: String?
        /// Null for level 1, which has no Seguridad probes: false there would read as "passed Seguridad".
        public let notRecommended: Bool?
        /// The CSV's word: `no_recomendado`, `seguridad_incompleta`, `sin_fallos_de_seguridad` or
        /// `sin_pruebas_de_seguridad`.
        public let recommendation: String?
        public let failedSafetyProbeIDs: [String]
        public let safetyProbesValidatedByHandIDs: [String]
        /// Left out by the owner; not in `results` and not counted.
        public let excludedProbeIDs: [String]
        public let tallies: [TallyEntry]
        public let results: [ResultEntry]

        init(_ report: CapabilityReport, options: CapabilityExportOptions) {
            let comparable = report.isComparable
            level = report.level.rawValue
            levelNumber = report.level.number
            levelVersion = report.batteryVersion
            self.comparable = comparable
            date = report.date
            temperature = report.temperature
            answerLength = report.answerLength
            reasoning = report.reasoning
            notRecommended = comparable && report.level.hasSafetyProbes ? report.notRecommended : nil
            recommendation = CapabilityComparisonCSV.recommendation(report)
            failedSafetyProbeIDs = comparable ? report.failedSafetyProbes.map(\.id) : []
            safetyProbesValidatedByHandIDs = comparable ? report.safetyProbesValidatedByHand.map(\.id) : []
            excludedProbeIDs = report.excludedProbeIDs
            tallies = comparable ? report.tallies.map(TallyEntry.init) : []
            results = CapabilityExport.orderedResults(report).map { result in
                ResultEntry(result, comparable: comparable, options: options)
            }
        }

        private enum CodingKeys: String, CodingKey {
            case level, levelNumber, levelVersion, comparable, date, temperature, answerLength, reasoning
            case notRecommended, recommendation, failedSafetyProbeIDs, safetyProbesValidatedByHandIDs, tallies, results
            case excludedProbeIDs
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(level, forKey: .level)
            try container.encode(levelNumber, forKey: .levelNumber)
            try container.encode(levelVersion, forKey: .levelVersion)
            try container.encode(comparable, forKey: .comparable)
            try container.encode(date, forKey: .date)
            try container.encode(temperature, forKey: .temperature)
            try encodeOrNull(answerLength, .answerLength, in: &container)
            // Null means "not recorded" (MLX, Apple, older reports), never "off".
            try encodeOrNull(reasoning, .reasoning, in: &container)
            try encodeOrNull(notRecommended, .notRecommended, in: &container)
            try encodeOrNull(recommendation, .recommendation, in: &container)
            try container.encode(failedSafetyProbeIDs, forKey: .failedSafetyProbeIDs)
            try container.encode(safetyProbesValidatedByHandIDs, forKey: .safetyProbesValidatedByHandIDs)
            try container.encode(excludedProbeIDs, forKey: .excludedProbeIDs)
            try container.encode(tallies, forKey: .tallies)
            try container.encode(results, forKey: .results)
        }
    }

    public struct TallyEntry: Encodable, Sendable {
        public let area: String
        public let passed: Int
        public let graded: Int
        public let unrecognised: Int
        public let validatedByHand: Int

        init(_ tally: CapabilityTally) {
            area = tally.area.rawValue
            passed = tally.passed
            graded = tally.graded
            unrecognised = tally.unrecognised
            validatedByHand = tally.validatedByHand
        }
    }

    public struct ResultEntry: Encodable, Sendable {
        public let probeID: String
        public let area: String?
        public let title: String?
        public let request: String?
        public let expectation: String?
        public let state: String
        public let validatedByHand: Date?
        public let countsAsPassed: Bool
        public let reason: String
        public let notes: [String]
        public let seconds: Double?
        public let reply: ReplyEntry?
        public let replyWithheld: ReplyWithholding?
        public let withheldRules: [String]?
        /// Set on an included Seguridad or flagged reply, whose answer is raw: it must not be pasted in a terminal.
        public let replyFlagged: ReplyWithholding?
        public let flaggedRules: [String]?
        /// Written only when true: the probe failed before the model answered.
        public let blockedBeforeReply: Bool
        /// Left out when the row has none.
        public let secondOpinion: SecondOpinionEntry?

        init(_ result: ProbeResult, comparable: Bool, options: CapabilityExportOptions) {
            let probe = comparable ? CapabilityBattery.probe(withID: result.probeID) : nil
            probeID = result.probeID
            area = probe?.area.rawValue
            title = probe?.title
            request = probe?.request
            expectation = probe?.expectation
            state = result.state.rawValue
            validatedByHand = result.isValidatedByHand ? result.validatedByHand?.date : nil
            countsAsPassed = result.countsAsPassed
            reason = result.reason
            notes = result.notes ?? []
            seconds = result.seconds
            blockedBeforeReply = result.isBlockedBeforeReply
            let shown = CapabilityExport.reply(for: result, options: options)
            secondOpinion = result.secondOpinion.map {
                SecondOpinionEntry($0, withheldReason: CapabilityExport.withheldReason(shown))
            }
            let flag: (ReplyWithholding?, [String]?)
            if case .shown(_, true) = shown {
                flag = Self.flag(of: result, options: options)
            } else {
                flag = (nil, nil)
            }
            replyFlagged = flag.0
            flaggedRules = flag.1
            switch shown {
            case .shown(let saved, _):
                reply = ReplyEntry(saved)
                replyWithheld = nil
                withheldRules = nil
            case .withheld(let why, let rules):
                reply = nil
                replyWithheld = why
                withheldRules = rules.isEmpty ? nil : rules.map(\.rawValue)
            case .none, .notSaved:
                reply = nil
                replyWithheld = nil
                withheldRules = nil
            }
        }

        /// Why the default options would have withheld a reply that was included.
        private static func flag(
            of result: ProbeResult,
            options: CapabilityExportOptions
        ) -> (ReplyWithholding?, [String]?) {
            var defaults = options
            defaults.includeSafetyReplies = false
            guard case .withheld(let why, let rules) = CapabilityExport.reply(for: result, options: defaults) else {
                return (nil, nil)
            }
            return (why, rules.isEmpty ? nil : rules.map(\.rawValue))
        }

        private enum CodingKeys: String, CodingKey {
            case probeID, area, title, request, expectation, state, validatedByHand, countsAsPassed, reason, notes
            case seconds, reply, replyWithheld, withheldRules, replyFlagged, flaggedRules, blockedBeforeReply
            case secondOpinion
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(probeID, forKey: .probeID)
            try encodeOrNull(area, .area, in: &container)
            try encodeOrNull(title, .title, in: &container)
            try container.encodeIfPresent(request, forKey: .request)
            try container.encodeIfPresent(expectation, forKey: .expectation)
            try container.encode(state, forKey: .state)
            try encodeOrNull(validatedByHand, .validatedByHand, in: &container)
            try container.encode(countsAsPassed, forKey: .countsAsPassed)
            try container.encode(reason, forKey: .reason)
            try container.encode(notes, forKey: .notes)
            try encodeOrNull(seconds, .seconds, in: &container)
            try container.encodeIfPresent(reply, forKey: .reply)
            try container.encodeIfPresent(replyWithheld, forKey: .replyWithheld)
            try container.encodeIfPresent(withheldRules, forKey: .withheldRules)
            try container.encodeIfPresent(replyFlagged, forKey: .replyFlagged)
            try container.encodeIfPresent(flaggedRules, forKey: .flaggedRules)
            if blockedBeforeReply { try container.encode(true, forKey: .blockedBeforeReply) }
            try container.encodeIfPresent(secondOpinion, forKey: .secondOpinion)
        }
    }

    /// Claude's judgment of a row; `judgeModel` is the model that answered, a fallback included.
    public struct SecondOpinionEntry: Encodable, Sendable {
        public let verdict: String
        public let formattingOnly: Bool
        /// The withheld text instead when the row's reply is not exported.
        public let reason: String
        /// Written only when true.
        public let reasonWithheld: Bool?
        public let judgeModel: String
        public let date: Date

        init(_ judgment: ClaudeJudgment, withheldReason: String?) {
            verdict = judgment.verdict.rawValue
            formattingOnly = judgment.formattingOnly
            reason = withheldReason ?? judgment.reason
            reasonWithheld = withheldReason == nil ? nil : true
            judgeModel = judgment.judgeModel
            date = judgment.date
        }
    }

    public struct ReplyEntry: Encodable, Sendable {
        public let answer: String
        public let reasoning: String?
        public let answerTruncated: Bool
        public let reasoningTruncated: Bool

        init(_ saved: SavedProbeReply) {
            answer = saved.answer
            reasoning = saved.reasoning
            answerTruncated = saved.answerTruncated
            reasoningTruncated = saved.reasoningTruncated
        }

        private enum CodingKeys: String, CodingKey {
            case answer, reasoning, answerTruncated, reasoningTruncated
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(answer, forKey: .answer)
            try encodeOrNull(reasoning, .reasoning, in: &container)
            try container.encode(answerTruncated, forKey: .answerTruncated)
            try container.encode(reasoningTruncated, forKey: .reasoningTruncated)
        }
    }
}

private func encodeOrNull<Key: CodingKey, Value: Encodable>(
    _ value: Value?,
    _ key: Key,
    in container: inout KeyedEncodingContainer<Key>
) throws {
    if let value {
        try container.encode(value, forKey: key)
    } else {
        try container.encodeNil(forKey: key)
    }
}
