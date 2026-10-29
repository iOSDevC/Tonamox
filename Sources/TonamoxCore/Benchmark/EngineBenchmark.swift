import Foundation
#if canImport(MLX)
import MLX
#endif

// MARK: - EngineBenchmark

/// Measures which engine runs a model fastest on this device: in-process Tonamox models (llama.cpp or MLX) and local
/// OpenAI-compatible servers (llama-server, Ollama, Magnitude), on the same prompts.
///
/// ```swift
/// let benchmark = EngineBenchmark(candidates: [
///     .inProcess(.qwen3_1_7b),
///     .server(llamaServerStatus, model: llamaServerStatus.models[0]),
/// ])
/// let report = await benchmark.run { event in print(event) }
/// print(report.fastestDecode(in: "chat")?.label ?? "none")
/// ```
///
/// Fairness rules the run enforces:
/// - Candidates run one after another, never concurrently. An in-process model is loaded for its own turn and
///   released (``ModelManager/release(_:)``) before the next candidate loads, so the benchmark holds one of its models
///   at a time. ``BenchmarkCandidate/inProcess(_:label:)`` loads an instance of its own, so an instance the app holds
///   is never reused or released; ModelManager may still evict the app's models to make room, as for any load. Evict
///   them first for a clean memory reading.
/// - Each workload runs ``BenchmarkSettings/warmUpRuns`` discarded runs, then ``BenchmarkSettings/measuredRuns``.
/// - Every run's system prompt starts with a run marker unique among the candidate's runs, so prompt caches (Tonamox's
///   GGUF and MLX prompt reuse, llama-server, Ollama, Magnitude) can share at most the chat template's opening and a
///   few marker tokens. Run `n` of every candidate gets the same marker, so outputs stay comparable; a server candidate
///   listed twice gets its own markers.
/// - Every candidate gets the same prompts, temperature and token budget.
/// - Cancelling the task stops the stream in flight and returns the partial report.
///
/// A failed load or run is recorded in the report and the benchmark goes on.
public struct EngineBenchmark: Sendable {
    public let candidates: [BenchmarkCandidate]
    public let workloads: [BenchmarkWorkload]
    public let settings: BenchmarkSettings

    public init(
        candidates: [BenchmarkCandidate],
        workloads: [BenchmarkWorkload] = BenchmarkWorkload.all,
        settings: BenchmarkSettings = BenchmarkSettings()
    ) {
        self.candidates = candidates
        self.workloads = workloads
        self.settings = settings
    }
}

// MARK: - BenchmarkCandidate

/// One engine to measure, with the weights it runs for display.
public struct BenchmarkCandidate: Sendable, Identifiable {

    /// How the candidate generates.
    public enum EngineSource: Sendable {
        /// A model loaded in this process. The closure receives ``BenchmarkSettings/temperature`` and returns a
        /// loaded instance; the benchmark releases it after the candidate's last run.
        case inProcess(load: @MainActor @Sendable (_ temperature: Float) async throws -> Tonamox)
        /// A model served by a local OpenAI-compatible server, timed client-side.
        case server(provider: any RemoteLLMProvider, modelID: String, kind: LocalProviderKind)
    }

    /// Identifies the candidate in the report; the benchmark appends ` #2`, ` #3`… to repeated ids.
    public let id: String
    /// The engine's name for tables, e.g. `Tonamox llama.cpp` or `Ollama`.
    public let label: String
    public let weights: BenchmarkModelIdentity
    public let engine: EngineSource

    /// An in-process candidate. `id` defaults to `label`.
    public init(
        id: String? = nil, label: String, weights: BenchmarkModelIdentity,
        load: @escaping @MainActor @Sendable (_ temperature: Float) async throws -> Tonamox
    ) {
        self.id = id ?? label
        self.label = label
        self.weights = weights
        self.engine = .inProcess(load: load)
    }

    /// A server candidate. `id` defaults to `label`.
    public init(
        id: String? = nil, label: String, weights: BenchmarkModelIdentity,
        provider: any RemoteLLMProvider, modelID: String, kind: LocalProviderKind
    ) {
        self.id = id ?? label
        self.label = label
        self.weights = weights
        self.engine = .server(provider: provider, modelID: modelID, kind: kind)
    }

    /// `model` loaded by ``ModelManager`` as an instance of its own: weights that are not on disk yet are downloaded
    /// and the memory budget applies, as in ``ModelManager/load(_:tools:temperature:topP:onProgress:)``, but the
    /// instance is never taken from or added to the cache, so the load is always timed and the app's instances are
    /// untouched. Labelled `Tonamox llama.cpp` or `Tonamox MLX`.
    public static func inProcess(_ model: Model, label: String? = nil) -> BenchmarkCandidate {
        let engineName = model.format == .mlx ? "Tonamox MLX" : "Tonamox llama.cpp"
        return BenchmarkCandidate(label: label ?? engineName, weights: BenchmarkModelIdentity(model: model)) {
            temperature in
            try await ModelManager.shared.loadUncached(model, temperature: temperature)
        }
    }

    /// `model` on a detected server, through ``OpenAICompatibleProvider/from(_:)``. Labelled with the server's name.
    public static func server(
        _ status: LocalProviderStatus, model: LocalProviderModel, label: String? = nil
    ) -> BenchmarkCandidate {
        BenchmarkCandidate(
            label: label ?? status.kind.displayName,
            weights: BenchmarkModelIdentity(served: model, by: status.kind),
            provider: OpenAICompatibleProvider.from(status), modelID: model.name, kind: status.kind)
    }
}

// MARK: - BenchmarkModelIdentity

/// The weights a candidate runs, as far as Tonamox can tell, so a UI can warn when engines ran different models.
public struct BenchmarkModelIdentity: Codable, Sendable, Hashable {
    /// A GGUF file name, an MLX repository id or a server's model id.
    public let name: String
    /// `nil` when unknown (Magnitude does not say).
    public let format: ModelFormat?
    /// `Q4_K_M`, `4bit`…; `nil` when unknown.
    public let quantization: String?

    public init(name: String, format: ModelFormat?, quantization: String?) {
        self.name = name
        self.format = format
        self.quantization = quantization
    }

    /// A Tonamox model: its GGUF file name and the quantization in it, or its MLX repository and bit width.
    public init(model: Model) {
        switch model.format {
        case .gguf:
            name = model.ggufFilename ?? model.displayName
            quantization = model.ggufFilename.flatMap(HuggingFaceRepo.quantLabel(for:))
        case .mlx:
            name = model.repoID
            quantization = Self.mlxQuantization(in: model.repoID)
        }
        format = model.format
    }

    /// A server's model: Ollama's quantization level, otherwise one read from the id (llama-server reports the
    /// file name). llama-server and Ollama serve GGUF; Magnitude's format is left unknown.
    public init(served model: LocalProviderModel, by kind: LocalProviderKind) {
        name = model.name
        format = kind == .magnitude ? nil : .gguf
        let lastComponent = model.name.split(separator: "/").last.map(String.init) ?? model.name
        quantization = model.quantization ?? HuggingFaceRepo.quantLabel(for: lastComponent)
    }

    /// `true` when both report the same format and quantization (all known) and the same name once paths,
    /// extensions, quantization tags and punctuation are stripped: `Qwen3-4B-Q4_K_M.gguf` matches Ollama's
    /// `qwen3:4b` at `Q4_K_M`.
    public func matches(_ other: BenchmarkModelIdentity) -> Bool {
        guard let format, format == other.format,
              let quantization, quantization.lowercased() == other.quantization?.lowercased() else { return false }
        return normalizedName == other.normalizedName
    }

    var normalizedName: String {
        var base = (name.split(separator: "/").last.map(String.init) ?? name).lowercased()
        if base.hasSuffix(".gguf") { base.removeLast(5) }
        if let quantization { base = base.replacingOccurrences(of: quantization.lowercased(), with: "") }
        base = base.replacingOccurrences(of: "[0-9]+-?bit", with: "", options: .regularExpression)
        return String(base.unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    /// `4bit` from `mlx-community/Qwen3-4B-4bit`, `BF16` from a `-bf16` repository.
    static func mlxQuantization(in repoID: String) -> String? {
        if let range = repoID.range(of: "[0-9]+-?bit", options: [.regularExpression, .caseInsensitive]) {
            return repoID[range].lowercased().replacingOccurrences(of: "-", with: "")
        }
        let float = repoID.range(of: "(bf16|fp16|f16|fp32|f32)$", options: [.regularExpression, .caseInsensitive])
        return float.map { repoID[$0].uppercased() }
    }
}

// MARK: - BenchmarkSettings

/// How many runs each candidate makes per workload, and with what sampling.
public struct BenchmarkSettings: Codable, Sendable, Hashable {
    /// Runs that count; at least 1. Default 3.
    public let measuredRuns: Int
    /// Discarded runs before the measured ones; they absorb a server's lazy model load. Default 1.
    public let warmUpRuns: Int
    /// Sampling temperature for every candidate; 0 (the default) is greedy, which makes outputs comparable.
    public let temperature: Float
    /// Replaces every workload's ``BenchmarkWorkload/maxTokens`` when set.
    public let maxTokensOverride: Int?

    public init(measuredRuns: Int = 3, warmUpRuns: Int = 1, temperature: Float = 0, maxTokensOverride: Int? = nil) {
        self.measuredRuns = max(1, measuredRuns)
        self.warmUpRuns = max(0, warmUpRuns)
        self.temperature = max(0, temperature)
        self.maxTokensOverride = maxTokensOverride.map { max(1, $0) }
    }
}

// MARK: - Progress

/// What the benchmark is doing, for a progress display.
public enum BenchmarkEvent: Sendable {
    /// An in-process candidate's model is loading.
    case loading(candidateID: String, label: String)
    /// A run is about to start.
    case running(BenchmarkProgress)
    /// A candidate finished a workload. Its ``BenchmarkWorkloadResult/agreement`` is filled in only in the report.
    case workloadFinished(candidateID: String, result: BenchmarkWorkloadResult)
    /// A candidate finished, or failed to load.
    case candidateFinished(BenchmarkCandidateResult)
}

/// Where a run sits in the benchmark: "candidate X, workload Y, run n/N".
public struct BenchmarkProgress: Sendable, Hashable {
    public let candidateID: String
    public let candidateLabel: String
    /// 0-based.
    public let candidateIndex: Int
    public let candidateCount: Int
    public let workloadID: String
    /// 0-based.
    public let workloadIndex: Int
    public let workloadCount: Int
    public let isWarmUp: Bool
    /// 1-based within the warm-up or the measured runs.
    public let run: Int
    /// Warm-up runs while ``isWarmUp``, measured runs otherwise.
    public let runCount: Int

    /// E.g. `Ollama (2/3) · chat · run 1/3`.
    public var summary: String {
        "\(candidateLabel) (\(candidateIndex + 1)/\(candidateCount)) · \(workloadID) · "
            + (isWarmUp ? "warm-up \(run)/\(runCount)" : "run \(run)/\(runCount)")
    }
}

// MARK: - Running

/// Measures one run; in-process and server candidates differ only here.
typealias BenchmarkMeasure = @MainActor (BenchmarkPrompt) async throws -> BenchmarkRun

@MainActor
extension EngineBenchmark {

    /// Runs every candidate in order and returns what was measured. Never throws: failures are in the report.
    public func run(onEvent: @escaping @MainActor (BenchmarkEvent) -> Void = { _ in }) async -> BenchmarkReport {
        let startedAt = Date()
        let nonce = Self.makeNonce()
        let ids = Self.uniqueIDs(candidates.map(\.id))
        let salts = Self.serverSalts(candidates)
        var finished: [BenchmarkCandidateResult] = []
        for index in candidates.indices {
            if Task.isCancelled { break }
            finished.append(await runCandidate(at: index, id: ids[index], nonce: nonce + salts[index],
                                               onEvent: onEvent))
        }
        return BenchmarkReport.assemble(settings: settings, workloads: workloads, candidates: finished,
                                        startedAt: startedAt, wasCancelled: Task.isCancelled)
    }

    func runCandidate(
        at index: Int, id: String, nonce: String, onEvent: @escaping @MainActor (BenchmarkEvent) -> Void
    ) async -> BenchmarkCandidateResult {
        let result = await measureCandidate(at: index, id: id, nonce: nonce, onEvent: onEvent)
        onEvent(.candidateFinished(result))
        return result
    }

    func measureCandidate(
        at index: Int, id: String, nonce: String, onEvent: @escaping @MainActor (BenchmarkEvent) -> Void
    ) async -> BenchmarkCandidateResult {
        let candidate = candidates[index]
        let cursor = BenchmarkCursor(candidateID: id, candidateLabel: candidate.label, candidateIndex: index,
                                     candidateCount: candidates.count, nonce: nonce)
        switch candidate.engine {
        case .inProcess(let load):
            return await runInProcess(candidate, cursor: cursor, load: load, onEvent: onEvent)
        case .server(let provider, let modelID, let kind):
            let temperature = settings.temperature
            let results = await runWorkloads(cursor: cursor, sampler: nil, onEvent: onEvent) { prompt in
                try await Self.measureServerRun(provider: provider, modelID: modelID, prompt: prompt,
                                                temperature: temperature)
            }
            return BenchmarkCandidateResult(
                id: id, label: candidate.label, timing: .clientSide, serverKind: kind, weights: candidate.weights,
                memoryBeforeLoadBytes: nil, peakMemoryBytes: nil, loadSeconds: nil, loadError: nil, results: results)
        }
    }

    func runInProcess(
        _ candidate: BenchmarkCandidate, cursor: BenchmarkCursor,
        load: @MainActor @Sendable (Float) async throws -> Tonamox,
        onEvent: @escaping @MainActor (BenchmarkEvent) -> Void
    ) async -> BenchmarkCandidateResult {
        onEvent(.loading(candidateID: cursor.candidateID, label: candidate.label))
        let memoryBefore = HardwareProfile.physicalFootprintBytes()
        let sampler = FootprintSampler()
        let polling = sampler.startPolling()
        defer { polling.cancel() }
        let loadStart = ContinuousClock.now
        let instance: Tonamox
        do {
            instance = try await load(settings.temperature)
        } catch {
            return BenchmarkCandidateResult(
                id: cursor.candidateID, label: candidate.label, timing: .inProcess, serverKind: nil,
                weights: candidate.weights, memoryBeforeLoadBytes: memoryBefore, peakMemoryBytes: sampler.overallPeak,
                loadSeconds: nil, loadError: Self.describe(error), results: [])
        }
        let loadSeconds = GenerationStats.seconds(ContinuousClock.now - loadStart)
        let results = await runWorkloads(cursor: cursor, sampler: sampler, onEvent: onEvent) { prompt in
            try await Self.measureInProcessRun(instance, prompt: prompt)
        }
        let peak = sampler.overallPeak
        Self.release(instance)
        return BenchmarkCandidateResult(
            id: cursor.candidateID, label: candidate.label, timing: .inProcess, serverKind: nil,
            weights: candidate.weights, memoryBeforeLoadBytes: memoryBefore, peakMemoryBytes: peak,
            loadSeconds: loadSeconds, loadError: nil, results: results)
    }

    func runWorkloads(
        cursor: BenchmarkCursor, sampler: FootprintSampler?,
        onEvent: @escaping @MainActor (BenchmarkEvent) -> Void, measure: BenchmarkMeasure
    ) async -> [BenchmarkWorkloadResult] {
        var results: [BenchmarkWorkloadResult] = []
        for (workloadIndex, workload) in workloads.enumerated() {
            if Task.isCancelled { break }
            sampler?.beginWindow()
            let outcome = await runWorkload(workload, at: workloadIndex, cursor: cursor, onEvent: onEvent,
                                            measure: measure)
            let result = Self.summarize(workload, outcome: outcome, peakMemoryBytes: sampler?.endWindow())
            onEvent(Self.finishedEvent(cursor.candidateID, result))
            results.append(result)
        }
        return results
    }

    /// The warm-up and measured runs of one workload; stops at the first failure or cancellation.
    func runWorkload(
        _ workload: BenchmarkWorkload, at workloadIndex: Int, cursor: BenchmarkCursor,
        onEvent: @MainActor (BenchmarkEvent) -> Void, measure: BenchmarkMeasure
    ) async -> (runs: [BenchmarkRun], failure: String?) {
        let maxTokens = settings.maxTokensOverride ?? workload.maxTokens
        var runs: [BenchmarkRun] = []
        for slot in 0..<(settings.warmUpRuns + settings.measuredRuns) {
            if Task.isCancelled { return (runs, Self.cancelledMessage) }
            onEvent(progressEvent(cursor, workload: workload, at: workloadIndex, slot: slot))
            do {
                let run = try await measure(
                    BenchmarkPrompt.make(for: workload, slot: slot, nonce: cursor.nonce, maxTokens: maxTokens))
                if slot >= settings.warmUpRuns { runs.append(run) }
            } catch {
                return (runs, Self.describe(error))
            }
        }
        return (runs, nil)
    }

    func progressEvent(
        _ cursor: BenchmarkCursor, workload: BenchmarkWorkload, at workloadIndex: Int, slot: Int
    ) -> BenchmarkEvent {
        let isWarmUp = slot < settings.warmUpRuns
        return .running(BenchmarkProgress(
            candidateID: cursor.candidateID, candidateLabel: cursor.candidateLabel,
            candidateIndex: cursor.candidateIndex, candidateCount: cursor.candidateCount,
            workloadID: workload.id, workloadIndex: workloadIndex, workloadCount: workloads.count,
            isWarmUp: isWarmUp, run: isWarmUp ? slot + 1 : slot - settings.warmUpRuns + 1,
            runCount: isWarmUp ? settings.warmUpRuns : settings.measuredRuns))
    }

    /// Unloads an in-process candidate before the next one loads. MLX keeps freed buffers in its cache, which would
    /// count toward the next candidate's memory.
    static func release(_ instance: Tonamox) {
        ModelManager.shared.release(instance)
        ModelManager.shared.settleAfterRelease(instance.model)
        #if canImport(MLX)
        if instance.model.format == .mlx { MLX.Memory.clearCache() }
        #endif
    }
}

// MARK: - Helpers

/// The candidate a run belongs to, carried through the per-workload calls.
struct BenchmarkCursor {
    let candidateID: String
    let candidateLabel: String
    let candidateIndex: Int
    let candidateCount: Int
    /// The run-marker nonce: shared by every candidate, salted for a repeated server.
    let nonce: String
}

extension EngineBenchmark {

    static let cancelledMessage = "Cancelled"

    static func describe(_ error: any Error) -> String {
        error is CancellationError ? cancelledMessage : error.localizedDescription
    }

    static func summarize(
        _ workload: BenchmarkWorkload, outcome: (runs: [BenchmarkRun], failure: String?), peakMemoryBytes: Int?
    ) -> BenchmarkWorkloadResult {
        BenchmarkWorkloadResult(workloadID: workload.id, runs: outcome.runs, peakMemoryBytes: peakMemoryBytes,
                                failure: outcome.failure)
    }

    static func finishedEvent(_ candidateID: String, _ result: BenchmarkWorkloadResult) -> BenchmarkEvent {
        .workloadFinished(candidateID: candidateID, result: result)
    }

    /// Eight hex digits, fresh per benchmark, so a server's cache from an earlier benchmark cannot match either.
    static func makeNonce() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }

    /// `ids` with ` #2`, ` #3`… appended to repeats.
    static func uniqueIDs(_ ids: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return ids.map { id in
            let count = seen[id, default: 0] + 1
            seen[id] = count
            return count == 1 ? id : "\(id) #\(count)"
        }
    }

    /// A suffix for the run-marker nonce: empty, except `-2`, `-3`… for a server candidate whose provider and model
    /// already appeared, whose prompt cache would otherwise hold the earlier candidate's prompts.
    static func serverSalts(_ candidates: [BenchmarkCandidate]) -> [String] {
        var seen: [String: Int] = [:]
        return candidates.map { candidate in
            guard case .server(let provider, let modelID, _) = candidate.engine else { return "" }
            let key = "\(provider.id)|\(modelID)"
            let count = seen[key, default: 0] + 1
            seen[key] = count
            return count == 1 ? "" : "-\(count)"
        }
    }
}
