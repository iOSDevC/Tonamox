import Foundation

extension GenerationStats.Provenance: Codable {}

// MARK: - BenchmarkReport

/// What an ``EngineBenchmark`` measured: one ``BenchmarkCandidateResult`` per candidate, in the order they ran.
public struct BenchmarkReport: Codable, Sendable, Hashable {
    public let settings: BenchmarkSettings
    /// The workloads every candidate ran, prompts included, so a report says exactly what was asked.
    public let workloads: [BenchmarkWorkload]
    /// The marker every run's system prompt starts with, before the workload's own: `{slot}` counts a workload's runs
    /// from 0, warm-up runs first, `{workload}` is the workload id and `{nonce}` the candidate's
    /// ``BenchmarkCandidateResult/runMarkerNonce``.
    public let runMarkerFormat: String
    public let candidates: [BenchmarkCandidateResult]
    public let startedAt: Date
    public let finishedAt: Date
    /// `true` when the task running the benchmark was cancelled; later candidates and workloads are missing.
    public let wasCancelled: Bool

    /// `true` when at least one candidate has a measured run.
    public var hasMeasuredRuns: Bool {
        candidates.contains { candidate in candidate.results.contains { !$0.runs.isEmpty } }
    }

    /// The candidate's result for one workload; `nil` when it did not run it.
    public func result(of candidateID: String, in workloadID: String) -> BenchmarkWorkloadResult? {
        candidates.first { $0.id == candidateID }?.result(for: workloadID)
    }

    /// The candidate with the highest median decode speed in a workload; `nil` when none has one.
    public func fastestDecode(in workloadID: String) -> BenchmarkCandidateResult? {
        ranked(in: workloadID) { $0.decodeTokensPerSecond?.median }.max { $0.value < $1.value }?.candidate
    }

    /// The candidate with the lowest median time to first token in a workload; `nil` when none ran it.
    public func fastestTimeToFirstToken(in workloadID: String) -> BenchmarkCandidateResult? {
        ranked(in: workloadID) { $0.timeToFirstToken?.median }.min { $0.value < $1.value }?.candidate
    }

    /// `true` when two or more candidates have measured runs in the workload and they do not all report the same
    /// format, quantization and model name (see ``BenchmarkModelIdentity/matches(_:)``). Matching labels do not prove
    /// identical files.
    public func modelsDiffer(in workloadID: String) -> Bool {
        let measured = candidates.filter { $0.result(for: workloadID)?.runs.isEmpty == false }
        guard measured.count > 1, let first = measured.first else { return false }
        return !measured.allSatisfy { $0.weights.matches(first.weights) }
    }

    /// Candidates whose exact (runtime) prompt count is under 70 % of the largest one in the workload: a sign a
    /// server cut the prompt to fit a smaller context (Ollama's `num_ctx`). Only exact counts are compared;
    /// tokenizers usually differ by less than that margin.
    public func promptTruncationSuspects(in workloadID: String) -> [String] {
        let counts = candidates.compactMap { candidate -> (id: String, tokens: Double)? in
            guard let result = candidate.result(for: workloadID), result.source == .runtime,
                  let tokens = result.promptTokens?.median else { return nil }
            return (candidate.id, tokens)
        }
        guard let largest = counts.map(\.tokens).max() else { return [] }
        return counts.filter { $0.tokens < largest * 0.7 }.map(\.id)
    }

    func ranked(
        in workloadID: String, by metric: (BenchmarkWorkloadResult) -> Double?
    ) -> [(candidate: BenchmarkCandidateResult, value: Double)] {
        candidates.compactMap { candidate in
            candidate.result(for: workloadID).flatMap(metric).map { (candidate, $0) }
        }
    }

    /// Fills in each result's ``BenchmarkWorkloadResult/agreement`` against the first candidate that produced
    /// output for that workload.
    static func assemble(
        settings: BenchmarkSettings, workloads: [BenchmarkWorkload], candidates: [BenchmarkCandidateResult],
        startedAt: Date, wasCancelled: Bool
    ) -> BenchmarkReport {
        var compared = candidates
        for workload in workloads {
            let reference = compared.firstIndex { $0.result(for: workload.id)?.runs.first != nil }
            let referenceOutput = reference.flatMap { compared[$0].result(for: workload.id)?.runs.first?.output }
            for index in compared.indices {
                guard let slot = compared[index].results.firstIndex(where: { $0.workloadID == workload.id }) else {
                    continue
                }
                compared[index].results[slot].agreement = OutputAgreement.compare(
                    compared[index].results[slot].runs.first?.output, with: referenceOutput,
                    isReference: index == reference, temperature: settings.temperature)
            }
        }
        return BenchmarkReport(settings: settings, workloads: workloads,
                               runMarkerFormat: BenchmarkPrompt.runMarkerFormat, candidates: compared,
                               startedAt: startedAt, finishedAt: Date(), wasCancelled: wasCancelled)
    }
}

// MARK: - BenchmarkTiming

/// Where a candidate's timings come from.
public enum BenchmarkTiming: String, Codable, Sendable, Hashable {
    /// ``Tonamox/lastGenerationStats`` of an in-process model.
    case inProcess
    /// Tonamox's clock around a server's stream: time to first token runs from the request to the first non-empty
    /// delta, reasoning included, so it includes the HTTP round trip and any queueing on the server.
    case clientSide
}

// MARK: - BenchmarkMemory

/// One reading of this process's memory, or the peak of each figure over a stretch of readings.
///
/// The two figures count a model's weights differently, so neither compares llama.cpp with MLX on its own:
/// llama.cpp maps a GGUF file into memory, and its clean file-backed pages count toward ``residentBytes`` but not
/// ``footprintBytes``; MLX copies its weights into memory that ``footprintBytes`` counts.
public struct BenchmarkMemory: Codable, Sendable, Hashable {
    /// `phys_footprint`: what iOS counts toward an app's memory limit.
    public let footprintBytes: Int
    /// `resident_size`: the process's pages in RAM, clean file-backed and shared ones included.
    public let residentBytes: Int

    public init(footprintBytes: Int, residentBytes: Int) {
        self.footprintBytes = footprintBytes
        self.residentBytes = residentBytes
    }

    /// This process now; `nil` when the kernel does not report it.
    static func current() -> BenchmarkMemory? {
        HardwareProfile.processMemoryBytes().map {
            BenchmarkMemory(footprintBytes: $0.footprint, residentBytes: $0.resident)
        }
    }

    /// The higher value of each figure; the two peaks may come from different readings.
    func peak(with other: BenchmarkMemory?) -> BenchmarkMemory {
        guard let other else { return self }
        return BenchmarkMemory(footprintBytes: max(footprintBytes, other.footprintBytes),
                               residentBytes: max(residentBytes, other.residentBytes))
    }
}

// MARK: - BenchmarkCandidateResult

/// One candidate's results across the workloads.
public struct BenchmarkCandidateResult: Codable, Sendable, Hashable, Identifiable {
    /// ``BenchmarkCandidate/id``, made unique within the report.
    public let id: String
    public let label: String
    public let timing: BenchmarkTiming
    /// The server's kind; `nil` for an in-process model.
    public let serverKind: LocalProviderKind?
    public let weights: BenchmarkModelIdentity
    /// The `{nonce}` of this candidate's run markers (``BenchmarkReport/runMarkerFormat``): shared by every
    /// candidate, with `-2`, `-3`… appended for a server and model already benchmarked.
    public let runMarkerNonce: String
    /// This process's memory before the model loaded; `nil` for servers, which run in another process.
    public let memoryBeforeLoad: BenchmarkMemory?
    /// Peak memory from the load to the end of the candidate's last run, warm-up runs included; `nil` for servers.
    /// It covers the whole process: compare it with ``memoryBeforeLoad`` for the model's share.
    public let peakMemory: BenchmarkMemory?
    /// Load time of an in-process model, download included when the weights were not on disk; `nil` for servers.
    public let loadSeconds: Double?
    /// ``loadSeconds`` plus the time to first token of the candidate's first run (a warm-up run unless there were
    /// none): the wait from a cold start to the first token. For a server it is that first run's time to first token,
    /// which includes loading the model only when the server had not loaded it yet. `nil` when no run finished.
    public let coldTimeToFirstToken: TimeInterval?
    /// Why the model did not load; no workload ran.
    public let loadError: String?
    /// One result per workload the candidate ran, in workload order.
    public internal(set) var results: [BenchmarkWorkloadResult]

    init(
        id: String, label: String, timing: BenchmarkTiming, serverKind: LocalProviderKind?,
        weights: BenchmarkModelIdentity, runMarkerNonce: String, memoryBeforeLoad: BenchmarkMemory?,
        peakMemory: BenchmarkMemory?, loadSeconds: Double?, loadError: String?, results: [BenchmarkWorkloadResult]
    ) {
        self.id = id
        self.label = label
        self.timing = timing
        self.serverKind = serverKind
        self.weights = weights
        self.runMarkerNonce = runMarkerNonce
        self.memoryBeforeLoad = memoryBeforeLoad
        self.peakMemory = peakMemory
        self.loadSeconds = loadSeconds
        self.loadError = loadError
        self.results = results
        let firstRun = results.first.flatMap { $0.warmUpRuns.first ?? $0.runs.first }
        coldTimeToFirstToken = firstRun.map { (loadSeconds ?? 0) + $0.timeToFirstToken }
    }

    public func result(for workloadID: String) -> BenchmarkWorkloadResult? {
        results.first { $0.workloadID == workloadID }
    }

    /// `true` when the runtime timed prefill and counted the prompt itself: an in-process MLX model
    /// (``GenerationStats/Provenance/runtime``). Otherwise prefill tok/s is approximate: llama.cpp in process divides
    /// an estimated prompt count by the time to first token, and a server's is its prompt count over the
    /// client-side time to first token, HTTP round trip included. Compare engines on time to first token.
    public func hasExactPrefill(in workloadID: String) -> Bool {
        timing == .inProcess && result(for: workloadID)?.source == .runtime
    }
}

// MARK: - BenchmarkWorkloadResult

/// One candidate's runs of one workload. The metrics summarize the measured runs only.
public struct BenchmarkWorkloadResult: Codable, Sendable, Hashable {
    public let workloadID: String
    public let runs: [BenchmarkRun]
    /// The warm-up runs before ``runs``, which no metric includes. The first one carries the cold-start cost
    /// (``BenchmarkCandidateResult/coldTimeToFirstToken``).
    public let warmUpRuns: [BenchmarkRun]
    public let timeToFirstToken: BenchmarkMetric?
    /// See ``BenchmarkCandidateResult/hasExactPrefill(in:)`` before comparing it across engines.
    public let prefillTokensPerSecond: BenchmarkMetric?
    public let decodeTokensPerSecond: BenchmarkMetric?
    public let generatedTokens: BenchmarkMetric?
    public let promptTokens: BenchmarkMetric?
    /// The least exact provenance among the measured runs; `nil` without them.
    public let source: GenerationStats.Provenance?
    /// Peak memory during the measured runs; `nil` for servers, and when no measured run started.
    public let peakMemory: BenchmarkMemory?
    /// Why the runs stopped early; the runs before the failure are kept.
    public let failure: String?
    /// The first measured output compared with the reference candidate's, filled in when the report is assembled.
    public internal(set) var agreement: OutputAgreement

    init(
        workloadID: String, runs: [BenchmarkRun], warmUpRuns: [BenchmarkRun] = [], peakMemory: BenchmarkMemory?,
        failure: String?
    ) {
        self.workloadID = workloadID
        self.runs = runs
        self.warmUpRuns = warmUpRuns
        self.timeToFirstToken = BenchmarkMetric(runs.map(\.timeToFirstToken))
        self.prefillTokensPerSecond = BenchmarkMetric(runs.compactMap(\.prefillTokensPerSecond))
        self.decodeTokensPerSecond = BenchmarkMetric(runs.compactMap(\.decodeTokensPerSecond))
        self.generatedTokens = BenchmarkMetric(runs.map { Double($0.generatedTokens) })
        self.promptTokens = BenchmarkMetric(runs.map { Double($0.promptTokens) })
        self.source = GenerationStats.Provenance.leastExact(runs.map(\.source))
        self.peakMemory = peakMemory
        self.failure = failure
        self.agreement = .unavailable
    }
}

extension GenerationStats.Provenance {
    /// Estimated beats measured beats runtime; `nil` for no values.
    static func leastExact(_ values: [Self]) -> Self? {
        let order: [Self] = [.runtime, .measured, .estimated]
        let rank = { (value: Self) in order.firstIndex(of: value) ?? 0 }
        return values.max { rank($0) < rank($1) }
    }
}

// MARK: - BenchmarkRun

/// One generation: timings, token counts and the text it produced. Encoded with ``decodeTokensPerSecond`` and
/// ``prefillTokensPerSecond`` too, which decoding recomputes.
public struct BenchmarkRun: Codable, Sendable, Hashable {
    public let timeToFirstToken: TimeInterval
    /// Prefill time; equals ``timeToFirstToken`` unless the runtime times prefill itself (MLX).
    public let promptTime: TimeInterval
    /// From the first generated token (or delta) to the last.
    public let decodeTime: TimeInterval
    public let promptTokens: Int
    public let generatedTokens: Int
    /// For servers: ``GenerationStats/Provenance/runtime`` when the server reported usage, otherwise
    /// ``GenerationStats/Provenance/estimated`` (UTF-8 bytes ÷ 4).
    public let source: GenerationStats.Provenance
    /// The generated text. A server's reasoning deltas lead it inside `<think>…</think>`, as in-process engines
    /// stream them.
    public let output: String

    /// Tokens after the first, divided by ``decodeTime`` (as ``GenerationStats/decodeTokensPerSecond``).
    public var decodeTokensPerSecond: Double? {
        guard generatedTokens > 1, decodeTime > 0 else { return nil }
        return Double(generatedTokens - 1) / decodeTime
    }

    /// ``promptTokens`` divided by ``promptTime``.
    public var prefillTokensPerSecond: Double? {
        guard promptTokens > 0, promptTime > 0 else { return nil }
        return Double(promptTokens) / promptTime
    }
}

extension BenchmarkRun {
    init(stats: GenerationStats, output: String) {
        self.init(timeToFirstToken: stats.timeToFirstToken, promptTime: stats.promptTime,
                  decodeTime: stats.decodeTime, promptTokens: stats.promptTokens,
                  generatedTokens: stats.generatedTokens, source: stats.source, output: output)
    }

    private enum RunKeys: String, CodingKey {
        case timeToFirstToken, promptTime, decodeTime, promptTokens, generatedTokens, source, output
        case decodeTokensPerSecond, prefillTokensPerSecond
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: RunKeys.self)
        self.init(timeToFirstToken: try container.decode(TimeInterval.self, forKey: .timeToFirstToken),
                  promptTime: try container.decode(TimeInterval.self, forKey: .promptTime),
                  decodeTime: try container.decode(TimeInterval.self, forKey: .decodeTime),
                  promptTokens: try container.decode(Int.self, forKey: .promptTokens),
                  generatedTokens: try container.decode(Int.self, forKey: .generatedTokens),
                  source: try container.decode(GenerationStats.Provenance.self, forKey: .source),
                  output: try container.decode(String.self, forKey: .output))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: RunKeys.self)
        try container.encode(timeToFirstToken, forKey: .timeToFirstToken)
        try container.encode(promptTime, forKey: .promptTime)
        try container.encode(decodeTime, forKey: .decodeTime)
        try container.encode(promptTokens, forKey: .promptTokens)
        try container.encode(generatedTokens, forKey: .generatedTokens)
        try container.encode(source, forKey: .source)
        try container.encode(output, forKey: .output)
        try container.encodeIfPresent(decodeTokensPerSecond, forKey: .decodeTokensPerSecond)
        try container.encodeIfPresent(prefillTokensPerSecond, forKey: .prefillTokensPerSecond)
    }
}

// MARK: - BenchmarkMetric

/// Median, minimum and maximum of one metric over the measured runs.
public struct BenchmarkMetric: Codable, Sendable, Hashable {
    /// The middle value; the mean of the two middle values for an even count.
    public let median: Double
    public let minimum: Double
    public let maximum: Double
    public let count: Int

    /// `nil` for no values.
    public init?(_ values: [Double]) {
        let sorted = values.sorted()
        guard let low = sorted.first, let high = sorted.last else { return nil }
        let middle = sorted.count / 2
        median = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        minimum = low
        maximum = high
        count = sorted.count
    }
}

// MARK: - OutputAgreement

/// How a candidate's first measured output compares with the reference candidate's: the first candidate in the
/// report that produced output for the workload. Only meaningful at temperature 0, and only as far as the engines ran
/// the same weights. Whitespace around `<think>` and `</think>` is ignored, so a server's reasoning compares with the
/// block an in-process engine streams, and an empty block counts as none.
///
/// Encoded as `{"kind": "partial", "commonPrefixRatio": 0.5}`; the other kinds carry no ratio.
public enum OutputAgreement: Codable, Sendable, Hashable {
    /// This candidate is the reference.
    case reference
    /// Identical text.
    case exact
    /// Different text; the shared prefix's length in characters over the longer output's.
    case partial(commonPrefixRatio: Double)
    /// The benchmark sampled at a temperature above 0, so outputs are expected to differ.
    case notApplicable
    /// This candidate or the reference has no measured output.
    case unavailable

    /// Short text for a table cell.
    public var label: String {
        switch self {
        case .reference: "reference"
        case .exact: "exact"
        case .partial(let ratio): "\(Int((ratio * 100).rounded())) % prefix"
        case .notApplicable: "n/a (temperature > 0)"
        case .unavailable: "—"
        }
    }

    static func compare(_ output: String?, with reference: String?, isReference: Bool, temperature: Float)
        -> OutputAgreement {
        guard temperature == 0 else { return .notApplicable }
        guard let output else { return .unavailable }
        if isReference { return .reference }
        guard let reference else { return .unavailable }
        let text = comparableText(output), referenceText = comparableText(reference)
        if text == referenceText { return .exact }
        let shared = zip(text, referenceText).prefix { $0 == $1 }.count
        return .partial(commonPrefixRatio: Double(shared) / Double(max(text.count, referenceText.count)))
    }

    /// `output` trimmed, without whitespace around `<think>` and `</think>`, with `<think>` added before a lone
    /// leading `</think>` (a chat template that opens the block in the prompt), and without an empty block, so an
    /// in-process `<think>\nA\n</think>\n\nB` and a server's `<think>A</think>B` compare equal, as do an in-process
    /// `</think>\n\nB` and a server's `B`.
    static func comparableText(_ output: String) -> String {
        var text = output
            .replacingOccurrences(of: #"\s*<think>\s*"#, with: "<think>", options: .regularExpression)
            .replacingOccurrences(of: #"\s*</think>\s*"#, with: "</think>", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let close = text.range(of: "</think>"),
           text.range(of: "<think>").map({ $0.lowerBound > close.lowerBound }) ?? true {
            text = "<think>" + text
        }
        // Servers drop whitespace-only reasoning (llama.cpp's chat parser), so they never send an empty block.
        return text.replacingOccurrences(of: "<think></think>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension OutputAgreement {
    private enum AgreementKeys: String, CodingKey {
        case kind, commonPrefixRatio
    }

    private enum AgreementKind: String, Codable {
        case reference, exact, partial, notApplicable, unavailable
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AgreementKeys.self)
        switch try container.decode(AgreementKind.self, forKey: .kind) {
        case .reference: self = .reference
        case .exact: self = .exact
        case .partial:
            self = .partial(commonPrefixRatio: try container.decode(Double.self, forKey: .commonPrefixRatio))
        case .notApplicable: self = .notApplicable
        case .unavailable: self = .unavailable
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: AgreementKeys.self)
        switch self {
        case .reference: try container.encode(AgreementKind.reference, forKey: .kind)
        case .exact: try container.encode(AgreementKind.exact, forKey: .kind)
        case .partial(let ratio):
            try container.encode(AgreementKind.partial, forKey: .kind)
            try container.encode(ratio, forKey: .commonPrefixRatio)
        case .notApplicable: try container.encode(AgreementKind.notApplicable, forKey: .kind)
        case .unavailable: try container.encode(AgreementKind.unavailable, forKey: .kind)
        }
    }
}
