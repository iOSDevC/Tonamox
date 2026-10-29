import Foundation

extension GenerationStats.Provenance: Codable {}

// MARK: - BenchmarkReport

/// What an ``EngineBenchmark`` measured: one ``BenchmarkCandidateResult`` per candidate, in the order they ran.
public struct BenchmarkReport: Codable, Sendable, Hashable {
    public let settings: BenchmarkSettings
    /// The workloads every candidate ran, prompts included, so a report says exactly what was asked.
    public let workloads: [BenchmarkWorkload]
    public let candidates: [BenchmarkCandidateResult]
    public let startedAt: Date
    public let finishedAt: Date
    /// `true` when the task running the benchmark was cancelled; later candidates and workloads are missing.
    public let wasCancelled: Bool

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
        return BenchmarkReport(settings: settings, workloads: workloads, candidates: compared,
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
    /// This process's `phys_footprint` before the model loaded; `nil` for servers, which run in another process.
    public let memoryBeforeLoadBytes: Int?
    /// Peak `phys_footprint` from the load to the end of the candidate's last run; `nil` for servers. It covers the
    /// whole process, so subtract ``memoryBeforeLoadBytes`` for the model's share.
    public let peakMemoryBytes: Int?
    /// Load time of an in-process model, download included when the weights were not on disk; `nil` for servers.
    public let loadSeconds: Double?
    /// Why the model did not load; no workload ran.
    public let loadError: String?
    /// One result per workload the candidate ran, in workload order.
    public internal(set) var results: [BenchmarkWorkloadResult]

    public func result(for workloadID: String) -> BenchmarkWorkloadResult? {
        results.first { $0.workloadID == workloadID }
    }
}

// MARK: - BenchmarkWorkloadResult

/// One candidate's measured runs of one workload, summarized. The warm-up run is not included.
public struct BenchmarkWorkloadResult: Codable, Sendable, Hashable {
    public let workloadID: String
    public let runs: [BenchmarkRun]
    public let timeToFirstToken: BenchmarkMetric?
    public let prefillTokensPerSecond: BenchmarkMetric?
    public let decodeTokensPerSecond: BenchmarkMetric?
    public let generatedTokens: BenchmarkMetric?
    public let promptTokens: BenchmarkMetric?
    /// The least exact provenance among the runs; `nil` without runs.
    public let source: GenerationStats.Provenance?
    /// Peak `phys_footprint` during this workload's runs; `nil` for servers.
    public let peakMemoryBytes: Int?
    /// Why the runs stopped early; the runs before the failure are kept.
    public let failure: String?
    /// The first measured output compared with the reference candidate's, filled in when the report is assembled.
    public internal(set) var agreement: OutputAgreement

    init(workloadID: String, runs: [BenchmarkRun], peakMemoryBytes: Int?, failure: String?) {
        self.workloadID = workloadID
        self.runs = runs
        self.timeToFirstToken = BenchmarkMetric(runs.map(\.timeToFirstToken))
        self.prefillTokensPerSecond = BenchmarkMetric(runs.compactMap(\.prefillTokensPerSecond))
        self.decodeTokensPerSecond = BenchmarkMetric(runs.compactMap(\.decodeTokensPerSecond))
        self.generatedTokens = BenchmarkMetric(runs.map { Double($0.generatedTokens) })
        self.promptTokens = BenchmarkMetric(runs.map { Double($0.promptTokens) })
        self.source = GenerationStats.Provenance.leastExact(runs.map(\.source))
        self.peakMemoryBytes = peakMemoryBytes
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

/// One generation: timings, token counts and the text it produced.
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
/// block an in-process engine streams.
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

    /// `output` trimmed, without whitespace around `<think>` and `</think>`, and with `<think>` added before a lone
    /// leading `</think>` (a chat template that opens the block in the prompt), so an in-process
    /// `<think>\nA\n</think>\n\nB` and a server's `<think>A</think>B` compare equal.
    static func comparableText(_ output: String) -> String {
        var text = output
            .replacingOccurrences(of: #"\s*<think>\s*"#, with: "<think>", options: .regularExpression)
            .replacingOccurrences(of: #"\s*</think>\s*"#, with: "</think>", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let close = text.range(of: "</think>"),
           text.range(of: "<think>").map({ $0.lowerBound > close.lowerBound }) ?? true {
            text = "<think>" + text
        }
        return text
    }
}
