import Foundation

/// Claude's word on a reply the deterministic grader did not pass. Raw values are the JSON schema's enum.
public enum ClaudeVerdict: String, Codable, CaseIterable, Hashable, Sendable {
    case correcta
    case incorrecta
    case dudosa

    public var title: String {
        switch self {
        case .correcta: "Correcta"
        case .incorrecta: "Incorrecta"
        case .dudosa: "Dudosa"
        }
    }

    /// A value written by a newer build reads as «Dudosa», so one judgment never makes a saved report unreadable.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ClaudeVerdict(rawValue: raw) ?? .dudosa
    }
}

/// A second opinion from Claude. It never changes a grade by itself: «Aplicar» turns it into a manual validation.
public struct ClaudeJudgment: Codable, Hashable, Sendable {
    public static let reasonLimit = 240

    public let verdict: ClaudeVerdict
    /// Only ever true with ``ClaudeVerdict/correcta``: the content was right and the grader tripped on formatting.
    public let formattingOnly: Bool
    /// One line, at most ``reasonLimit`` characters.
    public let reason: String
    /// The model that produced the judgment, which can be a server-side fallback of the one requested.
    public let judgeModel: String
    public let date: Date

    public init(verdict: ClaudeVerdict, formattingOnly: Bool, reason: String, judgeModel: String, date: Date) {
        self.verdict = verdict
        self.formattingOnly = formattingOnly && verdict == .correcta
        self.reason = Self.oneLine(reason)
        self.judgeModel = judgeModel
        self.date = date
    }

    /// «Claude: Correcta (solo formato) — motivo».
    public var text: String {
        verdictText + " — " + reason
    }

    /// «Claude: Correcta (solo formato)», without the reason.
    public var verdictText: String {
        "Claude: " + verdict.title + (formattingOnly ? " (solo formato)" : "")
    }

    /// «Modelo juez: Opus 5.5»; an id this build does not know is shown as is.
    public var judgeModelText: String {
        "Modelo juez: " + (ClaudeJudgeModel(rawValue: judgeModel)?.title ?? judgeModel)
    }

    /// Whitespace runs folded to one space, cut to ``reasonLimit`` characters.
    static func oneLine(_ text: String) -> String {
        let folded = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard folded.count > reasonLimit else { return folded }
        return String(folded.prefix(reasonLimit - 1)) + "…"
    }
}

extension ProbeResult {
    /// Graded, not passed, not marked by hand, and its answer was kept: what «Evaluar con Claude» may send.
    public var canBeJudged: Bool {
        canBeValidatedByHand && !isValidatedByHand && savedReply != nil
    }

    /// «Aplicar» marks the row as valid; only a «Correcta» on a row the owner can still mark offers it.
    public var canApplySecondOpinion: Bool {
        secondOpinion?.verdict == .correcta && canBeValidatedByHand && !isValidatedByHand
    }
}

extension CapabilityReport {
    /// The rows ``ProbeResult/canBeJudged`` allows, in level order.
    public var judgeableResults: [ProbeResult] {
        CapabilityExport.orderedResults(self).filter(\.canBeJudged)
    }

    /// A copy with one probe's second opinion set, or removed when `judgment` is nil. Hand marks and the report
    /// date stay.
    public func judging(_ probeID: String, with judgment: ClaudeJudgment?) -> CapabilityReport {
        CapabilityReport(
            modelKey: modelKey, modelTitle: modelTitle, level: level, batteryVersion: batteryVersion,
            temperature: temperature, reasoning: reasoning, answerLength: answerLength, date: date,
            results: results.map { $0.probeID == probeID ? $0.judged(judgment) : $0 },
            excludedProbeIDs: excludedProbeIDs, safetyFiltersRemoved: safetyFiltersRemoved)
    }

    /// How many rows carry each verdict, for the comparison CSV.
    public func secondOpinionCount(_ verdict: ClaudeVerdict) -> Int {
        results.filter { $0.secondOpinion?.verdict == verdict }.count
    }
}

extension CapabilityReportArchive {
    /// Second opinions by probe id of the report saved under `modelKey` and `level` on `date`; nil once that report
    /// was replaced or removed, like ``marks(modelKey:level:savedOn:in:)``.
    public static func secondOpinions(
        modelKey: String,
        level: CapabilityLevel,
        savedOn date: Date,
        in reports: [String: Levels]
    ) -> [String: ClaudeJudgment]? {
        guard let report = report(modelKey: modelKey, level: level, in: reports), report.date == date else {
            return nil
        }
        let pairs = report.results.compactMap { result in result.secondOpinion.map { (result.probeID, $0) } }
        return Dictionary(pairs) { first, _ in first }
    }
}

extension TestModeOutcome {
    /// The button «Aplicar» stands for: «Correcta» validates, «Incorrecta» rejects, when the row offers it.
    public func action(applying judgment: ClaudeJudgment) -> TestModeOverrideAction? {
        let wanted: TestModeOverrideAction? = switch judgment.verdict {
        case .correcta: .validate
        case .incorrecta: .reject
        case .dudosa: nil
        }
        return wanted.flatMap { actions.contains($0) ? $0 : nil }
    }
}

extension TestModeGrade {
    /// Incorrect or «Revisar tú»: the Test Mode answers Claude may judge.
    public var canBeJudged: Bool {
        switch self {
        case .incorrect, .review: true
        case .correct, .notApplicable: false
        }
    }
}
