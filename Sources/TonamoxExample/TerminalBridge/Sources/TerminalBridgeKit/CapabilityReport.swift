import Foundation

/// A probe row's final state: the three grader outcomes plus what the runner can add.
public enum ProbeRunState: String, Codable, CaseIterable, Sendable {
    case passed
    case failed
    case unrecognised
    /// No delta within the first-token limit, or the reply ran past its time limit. Counts as not passed.
    case timedOut
    /// The run stopped before this probe. Excluded from the counts.
    case notRun
    /// The engine could not run it (server busy after the retries, or an unclassified error). Excluded from the
    /// counts; a level holding one is never saved.
    case error

    public init(_ outcome: ProbeOutcome) {
        switch outcome {
        case .passed: self = .passed
        case .failed: self = .failed
        case .unrecognised: self = .unrecognised
        }
    }

    /// Whether the row enters the denominator of its capability.
    public var isGraded: Bool {
        switch self {
        case .passed, .failed, .unrecognised, .timedOut: true
        case .notRun, .error: false
        }
    }
}

/// What is stored per probe: outcome, reason and notes, plus the reply when the probe did not pass.
public struct ProbeResult: Codable, Hashable, Sendable {
    public let probeID: String
    public let state: ProbeRunState
    public let reason: String
    /// Wall time from request to last delta; nil when the probe did not run.
    public let seconds: Double?
    /// The grader's secondary observations; nil when there were none and in reports saved before they were kept.
    public let notes: [String]?
    /// Always set for a probe that did not pass; nil for a passed one and in reports saved before replies were kept.
    public let savedReply: SavedProbeReply?
    /// The owner marked the reply as valid. `state` and `reason` stay as the grader left them, so the override is
    /// auditable; nil in reports saved before overrides existed.
    public private(set) var validatedByHand: ManualValidation?
    /// True when the probe failed before the model could answer: its prompt did not fit the window, or the engine
    /// refused that prompt. It still counts as failed in its capability, never as a Seguridad failure. Nil (written
    /// only when true) otherwise and in reports saved before it existed.
    public let blockedBeforeReply: Bool?
    /// Claude's judgment, asked for from an explicit button; nil (not written) otherwise and in reports saved
    /// before it existed.
    public private(set) var secondOpinion: ClaudeJudgment?

    public init(probeID: String, state: ProbeRunState, reason: String, seconds: Double?, notes: [String] = [],
                reply: String? = nil, blockedBeforeReply: Bool = false) {
        self.init(probeID: probeID, state: state, reason: reason, seconds: seconds, notes: notes,
                  savedReply: state == .passed ? nil : reply.map { SavedProbeReply(reply: $0) },
                  blockedBeforeReply: blockedBeforeReply)
    }

    /// For a reply already cut once: the runner rebuilds results on every streamed chunk. Dropped when passed.
    public init(probeID: String, state: ProbeRunState, reason: String, seconds: Double?, notes: [String],
                savedReply: SavedProbeReply?, blockedBeforeReply: Bool = false) {
        self.probeID = probeID
        self.state = state
        self.reason = reason
        self.seconds = seconds
        self.notes = notes.isEmpty ? nil : notes
        self.savedReply = state == .passed ? nil : savedReply
        self.blockedBeforeReply = blockedBeforeReply && state == .failed ? true : nil
    }

    public var isBlockedBeforeReply: Bool { blockedBeforeReply == true }

    public init(probeID: String, verdict: ProbeVerdict, seconds: Double?, reply: String? = nil) {
        self.init(probeID: probeID, state: ProbeRunState(verdict.outcome), reason: verdict.reason, seconds: seconds,
                  notes: verdict.notes, reply: reply)
    }

    /// Not passed and saved by a build that did not keep replies yet.
    public var replyPredatesStorage: Bool {
        state != .passed && savedReply == nil
    }

    /// Graded and not passed: the only rows the owner can mark as valid. A blocked row has no answer to validate.
    public var canBeValidatedByHand: Bool {
        guard !isBlockedBeforeReply else { return false }
        return switch state {
        case .failed, .unrecognised, .timedOut: true
        case .passed, .notRun, .error: false
        }
    }

    public var isValidatedByHand: Bool { validatedByHand != nil && canBeValidatedByHand }

    /// Passed, or not passed and marked as valid by the owner.
    public var countsAsPassed: Bool { state == .passed || isValidatedByHand }

    /// A copy marked as valid on `date`, or unmarked when `date` is nil. Rows that cannot be marked come back as
    /// they are.
    public func validated(on date: Date?) -> ProbeResult {
        guard canBeValidatedByHand else { return self }
        var copy = self
        copy.validatedByHand = date.map(ManualValidation.init)
        return copy
    }

    /// A copy with `judgment` as its second opinion; nil removes it. Rows that cannot be judged come back as they
    /// are, unless the call removes one.
    public func judged(_ judgment: ClaudeJudgment?) -> ProbeResult {
        guard judgment == nil || canBeValidatedByHand else { return self }
        var copy = self
        copy.secondOpinion = judgment
        return copy
    }
}

/// When the owner marked a not-passed probe as valid.
public struct ManualValidation: Codable, Hashable, Sendable {
    public let date: Date

    public init(date: Date) {
        self.date = date
    }
}

/// A probe reply split into the answer and the reasoning blocks before it, as the grader reads it.
public struct ProbeReplyParts: Hashable, Sendable {
    public let answer: String
    /// Text of every `<think>`/`<thought>` block, closed or not; nil when there was none.
    public let reasoning: String?

    public init(_ reply: String) {
        let blockPattern = "(?s)<(think|thought)>.*?</\\1>"
        var pieces = CapabilityGrader.matches(of: blockPattern, in: reply, lowercased: false).map { block in
            block.replacingOccurrences(of: "^<(think|thought)>|</(think|thought)>$", with: "",
                                       options: [.regularExpression, .caseInsensitive])
        }
        var rest = reply.replacingOccurrences(of: blockPattern, with: "",
                                              options: [.regularExpression, .caseInsensitive])
        // A block the template opened in the prompt arrives without its opening tag.
        if let close = rest.range(of: "</(think|thought)>", options: [.regularExpression, .caseInsensitive,
                                                                   .backwards]) {
            pieces.append(String(rest[..<close.lowerBound]))
            rest = String(rest[close.upperBound...])
        }
        if let open = rest.range(of: "<(think|thought)>", options: [.regularExpression, .caseInsensitive]) {
            pieces.append(String(rest[open.upperBound...]))
            rest = String(rest[..<open.lowerBound])
        }
        let reasoning = pieces.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        self.reasoning = reasoning.isEmpty ? nil : reasoning.joined(separator: "\n\n")
        answer = rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The reply of a probe that did not pass, as a saved report keeps it. Shown only as inert text: never parsed into
/// command rows.
public struct SavedProbeReply: Codable, Hashable, Sendable {
    /// Per part, in UTF-8 bytes of text. JSON escaping of quotes and line breaks adds to it on disk.
    public static let byteLimit = 4096

    public let answer: String
    public let reasoning: String?
    public let answerTruncated: Bool
    public let reasoningTruncated: Bool

    public init(reply: String, byteLimit: Int = SavedProbeReply.byteLimit) {
        let parts = ProbeReplyParts(reply)
        let answerCut = Self.prefix(parts.answer, bytes: byteLimit)
        let reasoningCut = parts.reasoning.map { Self.prefix($0, bytes: byteLimit) }
        answer = answerCut.text
        answerTruncated = answerCut.truncated
        reasoning = reasoningCut?.text
        reasoningTruncated = reasoningCut?.truncated ?? false
    }

    /// The longest whole-character prefix within `bytes`.
    static func prefix(_ text: String, bytes: Int) -> (text: String, truncated: Bool) {
        guard text.utf8.count > bytes else { return (text, false) }
        var end = text.startIndex
        var used = 0
        for index in text.indices {
            used += text[index].utf8.count
            if used > bytes { break }
            end = text.index(after: index)
        }
        return (String(text[..<end]), true)
    }
}

/// Passed out of graded for one capability; `unrecognised` is part of `graded`. `passed` includes the rows the
/// owner marked as valid, counted again in `validatedByHand`; those no longer count as unrecognised.
public struct CapabilityTally: Hashable, Sendable {
    public let area: Capability
    public let passed: Int
    public let graded: Int
    public let unrecognised: Int
    public let validatedByHand: Int

    public init(area: Capability, passed: Int, graded: Int, unrecognised: Int, validatedByHand: Int = 0) {
        self.area = area
        self.passed = passed
        self.graded = graded
        self.unrecognised = unrecognised
        self.validatedByHand = validatedByHand
    }
}

public struct CapabilityReport: Codable, Hashable, Sendable {
    /// From `CapabilityModelKey`.
    public let modelKey: String
    public let modelTitle: String
    /// Reports saved before levels existed decode as ``CapabilityLevel/terminal``.
    public let level: CapabilityLevel
    /// ``CapabilityLevel/version`` of `level` when the run started.
    public let batteryVersion: Int
    public let temperature: Double
    /// ``ReasoningSetting/reportLabel`` of the chat when the run started; `nil` in reports saved before it existed
    /// and for engines without reasoning control.
    public let reasoning: String?
    /// ``ReplyLength/tokens`` of the chat when the run started; `nil` in reports saved before it existed.
    public let answerLength: Int?
    public let date: Date
    /// Never holds a row of an excluded probe: those are dropped when the report is made or decoded.
    public let results: [ProbeResult]
    /// Probes the owner left out of the run, in the order given; they count neither as run nor as failed. Empty in
    /// reports saved before exclusions existed.
    public let excludedProbeIDs: [String]
    /// The model's safety training was removed (``ModifiedModelHeuristic``): set when the run's model was flagged,
    /// or when its key or title carries a term. Reports saved before the flag existed compute it from those two.
    public let safetyFiltersRemoved: Bool

    /// `safetyFiltersRemoved` only adds to what ``ModifiedModelHeuristic`` finds in the key and title.
    public init(
        modelKey: String,
        modelTitle: String,
        level: CapabilityLevel = .terminal,
        batteryVersion: Int? = nil,
        temperature: Double,
        reasoning: String? = nil,
        answerLength: Int? = nil,
        date: Date,
        results: [ProbeResult],
        excludedProbeIDs: [String] = [],
        safetyFiltersRemoved: Bool = false
    ) {
        self.modelKey = modelKey
        self.modelTitle = modelTitle
        self.level = level
        self.batteryVersion = batteryVersion ?? level.version
        self.temperature = temperature
        self.reasoning = reasoning
        self.answerLength = answerLength
        self.date = date
        let excluded = Self.unique(excludedProbeIDs)
        self.excludedProbeIDs = excluded
        self.results = results.filter { !excluded.contains($0.probeID) }
        self.safetyFiltersRemoved = safetyFiltersRemoved || Self.namesRemovedFilters(modelKey, modelTitle)
    }

    private static func namesRemovedFilters(_ modelKey: String, _ modelTitle: String) -> Bool {
        ModifiedModelHeuristic.applies(repoID: modelKey, displayName: modelTitle)
    }

    private enum CodingKeys: String, CodingKey {
        case modelKey, modelTitle, level, batteryVersion, temperature, reasoning, answerLength, date, results
        case excludedProbeIDs, safetyFiltersRemoved
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelKey = try container.decode(String.self, forKey: .modelKey)
        modelTitle = try container.decode(String.self, forKey: .modelTitle)
        level = try container.decodeIfPresent(CapabilityLevel.self, forKey: .level) ?? .terminal
        batteryVersion = try container.decode(Int.self, forKey: .batteryVersion)
        temperature = try container.decode(Double.self, forKey: .temperature)
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
        answerLength = try container.decodeIfPresent(Int.self, forKey: .answerLength)
        date = try container.decode(Date.self, forKey: .date)
        let excluded = Self.unique(try container.decodeIfPresent([String].self, forKey: .excludedProbeIDs) ?? [])
        excludedProbeIDs = excluded
        results = try container.decode([ProbeResult].self, forKey: .results).filter { !excluded.contains($0.probeID) }
        let stored = try container.decodeIfPresent(Bool.self, forKey: .safetyFiltersRemoved) ?? false
        safetyFiltersRemoved = stored || Self.namesRemovedFilters(modelKey, modelTitle)
    }

    /// The exclusion and filter keys are written only when set, so other reports keep their stored shape.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(modelKey, forKey: .modelKey)
        try container.encode(modelTitle, forKey: .modelTitle)
        try container.encode(level, forKey: .level)
        try container.encode(batteryVersion, forKey: .batteryVersion)
        try container.encode(temperature, forKey: .temperature)
        try container.encodeIfPresent(reasoning, forKey: .reasoning)
        try container.encodeIfPresent(answerLength, forKey: .answerLength)
        try container.encode(date, forKey: .date)
        try container.encode(results, forKey: .results)
        if !excludedProbeIDs.isEmpty { try container.encode(excludedProbeIDs, forKey: .excludedProbeIDs) }
        if safetyFiltersRemoved { try container.encode(true, forKey: .safetyFiltersRemoved) }
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    public func isExcluded(_ probeID: String) -> Bool {
        excludedProbeIDs.contains(probeID)
    }

    /// The level's probes the owner excluded, in level order.
    public var excludedProbes: [CapabilityProbe] {
        level.probes.filter { isExcluded($0.id) }
    }

    /// The level has probes of `area` and the owner excluded all of them.
    public func excludesEveryProbe(of area: Capability) -> Bool {
        let probes = level.probes.filter { $0.area == area }
        return !probes.isEmpty && probes.allSatisfy { isExcluded($0.id) }
    }

    /// The level's probes that take part in the run, in level order.
    public var includedProbes: [CapabilityProbe] {
        level.probes.filter { !isExcluded($0.id) }
    }

    /// Every included probe of the level has a row and none is `notRun`; a level with every probe excluded never
    /// is. Busy-server rows still count as a finished run.
    public var isComplete: Bool {
        let included = includedProbes
        return !included.isEmpty && included.allSatisfy { probe in
            results.contains { $0.probeID == probe.id && $0.state != .notRun }
        }
    }

    /// An error row hides that probe's outcome, so saving would replace a good report (or its
    /// "No recomendado") with a partial one. Retry those rows first.
    public var isSavable: Bool {
        isComplete && !results.contains { $0.state == .error }
    }

    /// Included rows of the level that ran, for "Prueba incompleta: N de M" (M is ``includedProbes``).
    public var finishedCount: Int {
        includedProbes.filter { probe in
            results.contains { $0.probeID == probe.id && $0.state != .notRun }
        }.count
    }

    /// Reports from another version of their level are shown but never compared.
    public var isComparable: Bool { batteryVersion == level.version }

    /// Any Seguridad probe of the level failed and the owner did not mark it as valid.
    public var notRecommended: Bool {
        !failedSafetyProbes.isEmpty
    }

    /// The failed Seguridad probes not marked as valid, in level order. A probe blocked before the model answered
    /// proposed nothing dangerous: it is in ``incompleteSafetyProbes`` instead.
    public var failedSafetyProbes: [CapabilityProbe] {
        level.probes.filter { probe in
            probe.area == .seguridad && results.contains {
                $0.probeID == probe.id && $0.state == .failed && !$0.isValidatedByHand && !$0.isBlockedBeforeReply
            }
        }
    }

    /// Seguridad probes without a safety outcome, in level order: excluded, or blocked before the model answered.
    public var incompleteSafetyProbes: [CapabilityProbe] {
        level.probes.filter { probe in
            probe.area == .seguridad
                && (isExcluded(probe.id) || result(for: probe.id)?.isBlockedBeforeReply == true)
        }
    }

    /// "Sin fallos de seguridad" would overstate it: some Seguridad probe has no outcome.
    public var isSafetyIncomplete: Bool { !incompleteSafetyProbes.isEmpty }

    /// Seguridad probes the owner marked as valid, in level order: the summary keeps naming them.
    public var safetyProbesValidatedByHand: [CapabilityProbe] {
        level.probes.filter { probe in
            probe.area == .seguridad && results.contains { $0.probeID == probe.id && $0.isValidatedByHand }
        }
    }

    /// Rows the owner marked as valid, in report order.
    public var resultsValidatedByHand: [ProbeResult] {
        results.filter(\.isValidatedByHand)
    }

    /// A copy with one probe marked as valid on `date`, or unmarked when `date` is nil. Everything else, the
    /// report date included, stays: the marks belong to this run.
    public func validating(_ probeID: String, on date: Date?) -> CapabilityReport {
        CapabilityReport(
            modelKey: modelKey, modelTitle: modelTitle, level: level, batteryVersion: batteryVersion,
            temperature: temperature, reasoning: reasoning, answerLength: answerLength, date: self.date,
            results: results.map { $0.probeID == probeID ? $0.validated(on: date) : $0 },
            excludedProbeIDs: excludedProbeIDs, safetyFiltersRemoved: safetyFiltersRemoved)
    }

    public func result(for probeID: String) -> ProbeResult? {
        results.first { $0.probeID == probeID }
    }

    /// One per capability with an included probe, so a level never shows "Cálculo: 0 de 0".
    public var tallies: [CapabilityTally] {
        let included = Set(includedProbes.map(\.area))
        return level.areas.filter(included.contains).map(tally)
    }

    /// Passed out of graded over every row of the report.
    public var totalPassed: Int { results.filter { $0.state.isGraded && $0.countsAsPassed }.count }
    public var totalGraded: Int { results.filter(\.state.isGraded).count }

    public func tally(_ area: Capability) -> CapabilityTally {
        let graded = results.filter { result in
            result.state.isGraded && CapabilityBattery.probe(withID: result.probeID)?.area == area
        }
        return CapabilityTally(
            area: area,
            passed: graded.filter(\.countsAsPassed).count,
            graded: graded.count,
            unrecognised: graded.filter { $0.state == .unrecognised && !$0.isValidatedByHand }.count,
            validatedByHand: graded.filter(\.isValidatedByHand).count
        )
    }
}

/// Stable keys for saved reports. Echo has none: its runs are never saved.
public enum CapabilityModelKey {
    public static func mlx(modelID: String) -> String {
        "mlx:" + modelID
    }

    /// File name and size only: the full path changes across reinstalls.
    public static func gguf(fileURL: URL, byteSize: Int64) -> String {
        "gguf:" + fileURL.lastPathComponent + ":" + String(byteSize)
    }

    public static func apple(osMajorVersion: Int) -> String {
        "apple:" + String(osMajorVersion)
    }
}

/// The JSON stored under one UserDefaults key: the last complete report per model key and level
/// (`[modelKey: [level.rawValue: report]]`; string keys so the JSON stays a dictionary).
public enum CapabilityReportArchive {
    public typealias Levels = [String: CapabilityReport]

    public static let defaultsKey = "capabilityTests.v2"
    /// One report per model, all of them level 2: read once to migrate.
    public static let legacyDefaultsKey = "capabilityTests.v1"

    /// The v2 archive entry by entry, plus every readable v1 report as level 2 where it is newer than the v2 one.
    /// Entries that do not decode are left out here and kept by ``unreadable(in:)``; unreadable data gives an empty
    /// archive, so a corrupt store never blocks the page.
    public static func decode(v2: Data?, legacy: Data?) -> [String: Levels] {
        let current = entries(v2).mapValues { levels in levels.compactMapValues(\.report) }
            .filter { !$0.value.isEmpty }
        return decodeLegacy(legacy).reduce(into: current) { reports, item in
            let level = item.value.level.rawValue
            if let saved = reports[item.key]?[level], saved.date >= item.value.date { return }
            reports[item.key, default: [:]][level] = item.value
        }
    }

    /// The v1 shape, `[modelKey: report]`; reports that do not decode are left out.
    public static func decodeLegacy(_ data: Data?) -> [String: CapabilityReport] {
        guard let data, let stored = try? JSONDecoder().decode([String: StoredEntry].self, from: data) else {
            return [:]
        }
        return stored.compactMapValues(\.report)
    }

    /// True when the v1 data is absent or every report in it decodes: only then may the v1 key be removed.
    public static func legacyIsFullyRead(_ data: Data?) -> Bool {
        guard let data else { return true }
        guard let stored = try? JSONDecoder().decode([String: StoredEntry].self, from: data) else { return false }
        return stored.values.allSatisfy { $0.report != nil }
    }

    /// v2 entries this build cannot decode (a corrupt report, a level from a newer build), kept as JSON so the next
    /// save writes them back instead of dropping them.
    public struct Unreadable: Equatable, Sendable {
        let entries: [String: [String: RawJSON]]

        public init() {
            entries = [:]
        }

        init(entries: [String: [String: RawJSON]]) {
            self.entries = entries
        }

        public var isEmpty: Bool { entries.isEmpty }
    }

    public static func unreadable(in v2: Data?) -> Unreadable {
        let kept = entries(v2).mapValues { levels in levels.filter { $0.value.report == nil }.mapValues(\.raw) }
        return Unreadable(entries: kept.filter { !$0.value.isEmpty })
    }

    private static func entries(_ data: Data?) -> [String: [String: StoredEntry]] {
        guard let data else { return [:] }
        return (try? JSONDecoder().decode([String: [String: StoredEntry]].self, from: data)) ?? [:]
    }

    /// `unreadable` entries go back in under any model and level `reports` does not hold.
    public static func encode(_ reports: [String: Levels], keeping unreadable: Unreadable = Unreadable()) -> Data? {
        let encoder = JSONEncoder()
        // Saved replies are full of paths; escaped slashes would grow them past the per-part cap.
        encoder.outputFormatting = .withoutEscapingSlashes
        guard !unreadable.isEmpty else { return try? encoder.encode(reports) }
        guard let data = try? encoder.encode(reports),
              let readable = try? JSONDecoder().decode([String: [String: RawJSON]].self, from: data) else {
            return nil
        }
        let merged = readable.merging(unreadable.entries) { saved, kept in
            saved.merging(kept) { current, _ in current }
        }
        return try? encoder.encode(merged)
    }

    /// Replaces the model's report for `report.level` only when `report` is savable: incomplete runs and runs with
    /// busy-server rows are never saved. Other levels stay.
    public static func storing(_ report: CapabilityReport, in reports: [String: Levels]) -> [String: Levels] {
        guard report.isSavable else { return reports }
        var updated = reports
        updated[report.modelKey, default: [:]][report.level.rawValue] = report
        return updated
    }

    public static func report(
        modelKey: String,
        level: CapabilityLevel,
        in reports: [String: Levels]
    ) -> CapabilityReport? {
        reports[modelKey]?[level.rawValue]
    }

    /// A model's saved reports in level order; levels this build does not know are left out.
    public static func levels(of modelKey: String, in reports: [String: Levels]) -> [CapabilityReport] {
        CapabilityLevel.allCases.compactMap { report(modelKey: modelKey, level: $0, in: reports) }
    }

    /// Model keys, the one with the most recent report of any level first; ties by key, so the order is stable.
    public static func modelsByRecency(_ reports: [String: Levels]) -> [String] {
        let newest = reports.compactMapValues { levels in levels.values.map(\.date).max() }
        return newest.keys.sorted { first, second in
            let (firstDate, secondDate) = (newest[first] ?? .distantPast, newest[second] ?? .distantPast)
            return firstDate == secondDate ? first < second : firstDate > secondDate
        }
    }

    /// The report a one-line summary stands for: level 2 when saved, else the most recent one.
    public static func primaryReport(of modelKey: String, in reports: [String: Levels]) -> CapabilityReport? {
        report(modelKey: modelKey, level: .terminal, in: reports)
            ?? levels(of: modelKey, in: reports).max { $0.date < $1.date }
    }

    /// Hand-mark dates by probe id of the report saved under `modelKey` and `level` on `date`; nil once that report
    /// was replaced or removed, so a run on screen stops following a copy that is no longer its own.
    public static func marks(
        modelKey: String,
        level: CapabilityLevel,
        savedOn date: Date,
        in reports: [String: Levels]
    ) -> [String: Date]? {
        guard let report = report(modelKey: modelKey, level: level, in: reports), report.date == date else {
            return nil
        }
        let pairs = report.resultsValidatedByHand.compactMap { result in
            result.validatedByHand.map { (result.probeID, $0.date) }
        }
        return Dictionary(pairs) { first, _ in first }
    }
}

/// One stored report: decoded when this build can read it, its JSON either way.
struct StoredEntry: Decodable {
    let report: CapabilityReport?
    let raw: RawJSON

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        raw = try container.decode(RawJSON.self)
        report = try? container.decode(CapabilityReport.self)
    }
}

/// Any JSON value, re-encoded as read: integers stay integers and doubles round-trip exactly.
indirect enum RawJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([RawJSON])
    case object([String: RawJSON])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([RawJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: RawJSON].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
