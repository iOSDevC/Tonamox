import Foundation
import Synchronization
import XCTest
@testable import TonamoxCore

@MainActor
final class EngineBenchmarkTests: XCTestCase {

    // MARK: - Metrics

    func testMetricTakesMedianMinimumAndMaximum() throws {
        let odd = try XCTUnwrap(BenchmarkMetric([3, 1, 2]))
        XCTAssertEqual(odd.median, 2)
        XCTAssertEqual(odd.minimum, 1)
        XCTAssertEqual(odd.maximum, 3)
        XCTAssertEqual(odd.count, 3)
        XCTAssertEqual(BenchmarkMetric([4, 1, 3, 2])?.median, 2.5)
        XCTAssertEqual(BenchmarkMetric([7])?.median, 7)
        XCTAssertNil(BenchmarkMetric([]))
    }

    func testWorkloadResultSummarizesMeasuredRuns() throws {
        let runs = [Self.run(ttft: 0.3, decode: 1.0, generated: 11), Self.run(ttft: 0.1, decode: 2.0, generated: 11),
                    Self.run(ttft: 0.2, decode: 0.5, generated: 11, provenance: .estimated)]
        let result = BenchmarkWorkloadResult(workloadID: "chat", runs: runs, peakMemoryBytes: nil, failure: nil)
        XCTAssertEqual(result.timeToFirstToken?.median, 0.2)
        XCTAssertEqual(result.decodeTokensPerSecond?.median, 10)
        XCTAssertEqual(result.decodeTokensPerSecond?.minimum, 5)
        XCTAssertEqual(result.decodeTokensPerSecond?.maximum, 20)
        XCTAssertEqual(result.generatedTokens?.median, 11)
        XCTAssertEqual(result.provenance, .estimated, "one estimated run makes the summary estimated")
    }

    func testSettingsClampToUsableValues() {
        let settings = BenchmarkSettings(measuredRuns: 0, warmUpRuns: -1, temperature: -1, maxTokensOverride: 0)
        XCTAssertEqual(settings.measuredRuns, 1)
        XCTAssertEqual(settings.warmUpRuns, 0)
        XCTAssertEqual(settings.temperature, 0)
        XCTAssertEqual(settings.maxTokensOverride, 1)
    }

    // MARK: - Run markers

    func testRunMarkersAreUniqueWithinACandidateAndSharedAcrossCandidates() async {
        let log = BenchCallLog()
        let benchmark = EngineBenchmark(
            candidates: [Self.server("a", log: log), Self.server("b", log: log)],
            workloads: [.chat, .code], settings: BenchmarkSettings(measuredRuns: 2, warmUpRuns: 1))
        _ = await benchmark.run()

        let first = log.systemPrompts(of: "a")
        XCTAssertEqual(first.count, 6, "2 workloads × (1 warm-up + 2 measured)")
        XCTAssertEqual(Set(first).count, first.count, "every run, warm-up included, has its own marker")
        XCTAssertTrue(first.allSatisfy { $0.hasPrefix("[run ") }, "the marker leads the system prompt")
        XCTAssertTrue(first.first?.hasSuffix(BenchmarkWorkload.chat.systemPrompt) ?? false)
        XCTAssertEqual(log.systemPrompts(of: "b"), first, "run n of every candidate gets the same prompt")
    }

    func testRepeatedServerCandidateGetsItsOwnMarkers() async {
        let log = BenchCallLog()
        let provider = BenchScriptedProvider(id: "same", tokens: ["x"], log: log)
        let candidates = (1...2).map { index in
            BenchmarkCandidate(label: "S\(index)", weights: Self.weights, provider: provider, modelID: "m",
                               kind: .llamaServer)
        }
        _ = await EngineBenchmark(candidates: candidates, workloads: [.chat],
                                  settings: BenchmarkSettings(measuredRuns: 1)).run()

        let prompts = log.systemPrompts(of: "same")
        XCTAssertEqual(prompts.count, 4)
        XCTAssertEqual(Set(prompts).count, 4, "the second candidate must not hit the first one's server cache")
    }

    func testBenchmarksGetDifferentNonces() {
        XCTAssertNotEqual(EngineBenchmark.makeNonce(), EngineBenchmark.makeNonce())
        let prompt = BenchmarkPrompt.make(for: .code, slot: 2, nonce: "abc", maxTokens: 9)
        XCTAssertEqual(prompt.system, "[run 2 code abc]\n" + BenchmarkWorkload.code.systemPrompt)
        XCTAssertEqual(prompt.user, BenchmarkWorkload.code.userPrompt)
        XCTAssertEqual(prompt.maxTokens, 9)
    }

    func testRepeatedIDsAreNumbered() {
        XCTAssertEqual(EngineBenchmark.uniqueIDs(["a", "b", "a", "a"]), ["a", "b", "a #2", "a #3"])
    }

    // MARK: - Server timing

    func testServerRunUsesReportedUsage() async throws {
        let provider = BenchScriptedProvider(id: "p", tokens: ["", "Hello", " there", " friend"],
                                        usage: TokenUsage(inputTokens: 42, outputTokens: 3), delay: .milliseconds(20))
        let prompt = BenchmarkPrompt.make(for: .chat, slot: 1, nonce: "n", maxTokens: 16)
        let run = try await EngineBenchmark.measureServerRun(provider: provider, modelID: "m", prompt: prompt,
                                                             temperature: 0)
        XCTAssertEqual(run.output, "Hello there friend")
        XCTAssertEqual(run.provenance, .runtime)
        XCTAssertEqual(run.promptTokens, 42)
        XCTAssertEqual(run.generatedTokens, 3)
        XCTAssertGreaterThanOrEqual(run.timeToFirstToken, 0.035, "the empty delta must not count as the first token")
        XCTAssertGreaterThanOrEqual(run.decodeTime, 0.035)
        XCTAssertEqual(run.promptTime, run.timeToFirstToken)
        XCTAssertEqual(try XCTUnwrap(run.decodeTokensPerSecond), 2 / run.decodeTime, accuracy: 1e-9)
    }

    func testServerRunWithoutUsageEstimatesFromText() async throws {
        let provider = BenchScriptedProvider(id: "p", tokens: ["abcdefgh", "ijkl"])
        let prompt = BenchmarkPrompt.make(for: .chat, slot: 1, nonce: "n", maxTokens: 16)
        let run = try await EngineBenchmark.measureServerRun(provider: provider, modelID: "m", prompt: prompt,
                                                             temperature: 0)
        XCTAssertEqual(run.provenance, .estimated)
        XCTAssertEqual(run.generatedTokens, 3, "12 UTF-8 bytes ÷ 4")
        XCTAssertEqual(run.promptTokens, GenerationStats.estimatedTokens(in: prompt.system + "\n" + prompt.user))
    }

    func testRunWithoutTextReportsItsDurationAsTimeToFirstToken() {
        let prompt = BenchmarkPrompt.make(for: .chat, slot: 0, nonce: "n", maxTokens: 4)
        let run = DeltaClock.run(timeToFirstToken: 1.5, decodeTime: 0, output: "", usage: nil, prompt: prompt)
        XCTAssertEqual(run.generatedTokens, 0)
        XCTAssertNil(run.decodeTokensPerSecond)
        XCTAssertEqual(run.timeToFirstToken, 1.5)
    }

    func testServerRequestCarriesTheBenchmarkSettings() async throws {
        let log = BenchCallLog()
        _ = await EngineBenchmark(
            candidates: [Self.server("a", log: log)], workloads: [.chat],
            settings: BenchmarkSettings(measuredRuns: 1, warmUpRuns: 0, temperature: 0.5, maxTokensOverride: 7)
        ).run()
        let request = try XCTUnwrap(log.requests(of: "a").first)
        XCTAssertEqual(request.temperature, 0.5)
        XCTAssertEqual(request.maxTokens, 7)
        XCTAssertEqual(request.model, "model-a")
        XCTAssertEqual(request.messages, [["role": "user", "content": BenchmarkWorkload.chat.userPrompt]])
    }

    func testStreamingRequestsAskForUsage() throws {
        let request = RemoteRequest(model: "m", messages: [["role": "user", "content": "hi"]])
        let streaming = OpenAICompatibleProvider(id: "s", displayName: "S", baseURL: URL(string: "http://x/v1")!)
        let body = try Self.body(of: streaming.makeRequest(request))
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual((body["stream_options"] as? [String: Bool])?["include_usage"], true)

        let once = OpenAICompatibleProvider(id: "o", displayName: "O", baseURL: URL(string: "http://x/v1")!,
                                            streaming: false)
        XCTAssertNil(try Self.body(of: once.makeRequest(request))["stream_options"])
    }

    // MARK: - Errors, order and cancellation

    func testFailedWorkloadIsRecordedAndTheBenchmarkGoesOn() async throws {
        let log = BenchCallLog()
        let failing = BenchmarkCandidate(
            label: "fails", weights: Self.weights,
            provider: BenchScriptedProvider(id: "fails", tokens: ["x"], failingWorkload: "code", log: log),
            modelID: "m", kind: .ollama)
        let report = await EngineBenchmark(candidates: [failing, Self.server("ok", log: log)],
                                           workloads: [.chat, .code], settings: BenchmarkSettings(measuredRuns: 2))
            .run()

        XCTAssertNil(report.result(of: "fails", in: "chat")?.failure)
        XCTAssertEqual(report.result(of: "fails", in: "chat")?.runs.count, 2)
        let failed = try XCTUnwrap(report.result(of: "fails", in: "code"))
        XCTAssertTrue(failed.runs.isEmpty)
        XCTAssertTrue(failed.failure?.contains("boom") ?? false, failed.failure ?? "no failure")
        XCTAssertEqual(report.result(of: "ok", in: "code")?.runs.count, 2)
        XCTAssertFalse(report.wasCancelled)
    }

    func testLoadFailureIsRecordedAndTheNextCandidateRuns() async throws {
        let broken = BenchmarkCandidate(label: "broken", weights: Self.weights) { _ in
            throw TonamoxError.modelNotLoaded
        }
        let report = await EngineBenchmark(candidates: [broken, Self.server("ok", log: BenchCallLog())],
                                           workloads: [.chat], settings: BenchmarkSettings(measuredRuns: 1)).run()

        let failed = try XCTUnwrap(report.candidates.first)
        XCTAssertNotNil(failed.loadError)
        XCTAssertTrue(failed.results.isEmpty)
        XCTAssertEqual(failed.timing, .inProcess)
        XCTAssertEqual(report.result(of: "ok", in: "chat")?.runs.count, 1)
    }

    func testCandidatesNeverOverlap() async {
        let log = BenchCallLog()
        _ = await EngineBenchmark(
            candidates: [Self.server("a", log: log, delay: .milliseconds(5)),
                         Self.server("b", log: log, delay: .milliseconds(5))],
            workloads: [.chat, .code], settings: BenchmarkSettings(measuredRuns: 2)
        ).run()

        let events = log.events
        XCTAssertEqual(events.count, 24, "2 candidates × 2 workloads × 3 runs, each a start and an end")
        for (start, end) in zip(events.indices.filter { $0.isMultiple(of: 2) }.map { events[$0] },
                                events.indices.filter { !$0.isMultiple(of: 2) }.map { events[$0] }) {
            XCTAssertEqual(start, "start " + end.dropFirst("end ".count), "a request started before the last ended")
        }
        XCTAssertEqual(events.prefix(12).filter { $0.hasSuffix(" b") }, [], "candidate b ran during a's turn")
    }

    func testInProcessModelsLoadAndReleaseOneAtATime() async throws {
        let log = BenchInProcessLog()
        let candidates = ["A", "B"].map { name in
            BenchmarkCandidate(label: name, weights: Self.weights) { _ in
                log.entries.append("load \(name)")
                return Tonamox(engine: TonamoxEngine(model: .dolphin3_qwen25_1_5b_gguf,
                                                     backend: BenchScriptedBackend(name: name, log: log)))
            }
        }
        let report = await EngineBenchmark(candidates: candidates, workloads: [.chat],
                                           settings: BenchmarkSettings(measuredRuns: 1)).run()

        XCTAssertEqual(log.entries, ["load A", "generate A", "generate A", "unload A",
                                     "load B", "generate B", "generate B", "unload B"])
        let result = try XCTUnwrap(report.result(of: "A", in: "chat"))
        XCTAssertEqual(result.runs.first?.output, "Hello world")
        XCTAssertEqual(result.runs.first?.provenance, .measured, "in-process runs report the engine's own stats")
        XCTAssertEqual(result.runs.first?.promptTokens, BenchScriptedBackend.stats.promptTokens)
        XCTAssertNotNil(report.candidates.first?.peakMemoryBytes)
        XCTAssertNotNil(report.candidates.first?.loadSeconds)
    }

    func testCancellationStopsTheStreamAndReturnsAPartialReport() async throws {
        let slow = BenchmarkCandidate(
            label: "slow", weights: Self.weights,
            provider: BenchScriptedProvider(id: "slow", tokens: ["a", "b"], delay: .seconds(10)), modelID: "m",
            kind: .magnitude)
        let task = Task { await EngineBenchmark(candidates: [slow, Self.server("never", log: BenchCallLog())]).run() }
        try await Task.sleep(for: .milliseconds(100))
        let started = ContinuousClock.now
        task.cancel()
        let report = await task.value

        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
        XCTAssertTrue(report.wasCancelled)
        XCTAssertEqual(report.candidates.map(\.id), ["slow"])
        XCTAssertEqual(report.candidates.first?.results.first?.failure, EngineBenchmark.cancelledMessage)
    }

    func testProgressNamesCandidateWorkloadAndRun() async {
        var summaries: [String] = []
        _ = await EngineBenchmark(candidates: [Self.server("a", log: BenchCallLog())], workloads: [.chat],
                                  settings: BenchmarkSettings(measuredRuns: 2)).run { event in
            if case .running(let progress) = event { summaries.append(progress.summary) }
        }
        XCTAssertEqual(summaries, ["a (1/1) · chat · warm-up 1/1", "a (1/1) · chat · run 1/2",
                                   "a (1/1) · chat · run 2/2"])
    }

    // MARK: - Output agreement

    func testOutputAgreementCases() {
        XCTAssertEqual(OutputAgreement.compare("abcd", with: "abcd", isReference: false, temperature: 0.7),
                       .notApplicable)
        XCTAssertEqual(OutputAgreement.compare("abcd", with: "abcd", isReference: true, temperature: 0), .reference)
        XCTAssertEqual(OutputAgreement.compare("abcd", with: "abcd", isReference: false, temperature: 0), .exact)
        XCTAssertEqual(OutputAgreement.compare("abxy", with: "abcd", isReference: false, temperature: 0),
                       .partial(commonPrefixRatio: 0.5))
        XCTAssertEqual(OutputAgreement.compare("ab", with: "abcd", isReference: false, temperature: 0),
                       .partial(commonPrefixRatio: 0.5))
        XCTAssertEqual(OutputAgreement.compare(nil, with: "abcd", isReference: false, temperature: 0), .unavailable)
        XCTAssertEqual(OutputAgreement.compare("abcd", with: nil, isReference: false, temperature: 0), .unavailable)
    }

    func testReportComparesEachOutputWithTheFirstCandidateThatProducedOne() async {
        let log = BenchCallLog()
        let broken = BenchmarkCandidate(label: "broken", weights: Self.weights) { _ in
            throw TonamoxError.modelNotLoaded
        }
        let report = await EngineBenchmark(
            candidates: [broken, Self.server("a", tokens: ["hello", " world"], log: log),
                         Self.server("b", tokens: ["hello", " there"], log: log),
                         Self.server("c", tokens: ["hello", " world"], log: log)],
            workloads: [.chat], settings: BenchmarkSettings(measuredRuns: 1)
        ).run()

        XCTAssertEqual(report.result(of: "a", in: "chat")?.agreement, .reference)
        XCTAssertEqual(report.result(of: "b", in: "chat")?.agreement, .partial(commonPrefixRatio: 6.0 / 11.0))
        XCTAssertEqual(report.result(of: "c", in: "chat")?.agreement, .exact)
    }

    // MARK: - Report

    func testReportRoundTripsThroughJSON() async throws {
        let report = await EngineBenchmark(
            candidates: [Self.server("a", log: BenchCallLog()),
                         Self.server("b", tokens: ["z"], usage: TokenUsage(inputTokens: 5, outputTokens: 1),
                                     log: BenchCallLog())],
            workloads: [.chat], settings: BenchmarkSettings(measuredRuns: 2, temperature: 0.7)
        ).run()

        let decoded = try JSONDecoder().decode(BenchmarkReport.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(decoded, report)
        XCTAssertEqual(decoded.candidates.first?.serverKind, .llamaServer)
        XCTAssertEqual(decoded.result(of: "a", in: "chat")?.agreement, .notApplicable)
    }

    func testFastestAndModelMismatchHelpers() {
        let gguf = BenchmarkModelIdentity(name: "Qwen3-4B-Q4_K_M.gguf", format: .gguf, quantization: "Q4_K_M")
        let ollama = BenchmarkModelIdentity(served: LocalProviderModel(name: "qwen3:4b", quantization: "Q4_K_M"),
                                            by: .ollama)
        let report = Self.report([
            Self.candidate("fast", weights: gguf, runs: [Self.run(ttft: 0.5, decode: 1, generated: 41)]),
            Self.candidate("quick", weights: ollama, runs: [Self.run(ttft: 0.1, decode: 1, generated: 21)]),
        ])
        XCTAssertEqual(report.fastestDecode(in: "chat")?.id, "fast")
        XCTAssertEqual(report.fastestTimeToFirstToken(in: "chat")?.id, "quick")
        XCTAssertFalse(report.modelsDiffer(in: "chat"), "same file name, format and quantization")
        XCTAssertNil(report.fastestDecode(in: "code"))

        let mlx = BenchmarkModelIdentity(name: "mlx-community/Qwen3-4B-4bit", format: .mlx, quantization: "4bit")
        let mixed = Self.report([Self.candidate("g", weights: gguf, runs: [Self.run(ttft: 1, decode: 1, generated: 2)]),
                                 Self.candidate("m", weights: mlx, runs: [Self.run(ttft: 1, decode: 1, generated: 2)])])
        XCTAssertTrue(mixed.modelsDiffer(in: "chat"))

        let unknown = BenchmarkModelIdentity(name: "qwen3.5:4b", format: nil, quantization: nil)
        let alone = Self.report([Self.candidate("u", weights: unknown,
                                                runs: [Self.run(ttft: 1, decode: 1, generated: 2)])])
        XCTAssertFalse(alone.modelsDiffer(in: "chat"), "one engine has nothing to differ from")
    }

    func testPromptTruncationIsFlaggedFromExactCounts() {
        let report = Self.report([
            Self.candidate("full", weights: Self.weights, runs: [Self.run(ttft: 1, decode: 1, generated: 2,
                                                                          prompt: 3_000)]),
            Self.candidate("cut", weights: Self.weights, runs: [Self.run(ttft: 1, decode: 1, generated: 2,
                                                                         prompt: 2_000)]),
            Self.candidate("guess", weights: Self.weights, runs: [Self.run(ttft: 1, decode: 1, generated: 2,
                                                                           prompt: 900, provenance: .estimated)]),
        ])
        XCTAssertEqual(report.promptTruncationSuspects(in: "chat"), ["cut"], "estimated counts are not compared")
    }

    // MARK: - Model identity

    func testModelIdentityReadsQuantization() {
        XCTAssertEqual(BenchmarkModelIdentity.mlxQuantization(in: "mlx-community/Qwen3-4B-4bit"), "4bit")
        XCTAssertEqual(BenchmarkModelIdentity.mlxQuantization(in: "mlx-community/gemma-3-1b-it-8-bit"), "8bit")
        XCTAssertEqual(BenchmarkModelIdentity.mlxQuantization(in: "mlx-community/Qwen3-0.6B-bf16"), "BF16")
        XCTAssertNil(BenchmarkModelIdentity.mlxQuantization(in: "mlx-community/Qwen3-0.6B"))

        let server = BenchmarkModelIdentity(served: LocalProviderModel(name: "/models/Qwen3-4B-Q8_0.gguf"),
                                            by: .llamaServer)
        XCTAssertEqual(server.quantization, "Q8_0")
        XCTAssertEqual(server.format, .gguf)
        XCTAssertNil(BenchmarkModelIdentity(served: LocalProviderModel(name: "qwen3.5:4b"), by: .magnitude).format)
    }

    func testModelIdentityNeedsKnownMatchingFacts() {
        let file = BenchmarkModelIdentity(name: "Qwen3-4B-Q4_K_M.gguf", format: .gguf, quantization: "Q4_K_M")
        XCTAssertTrue(file.matches(BenchmarkModelIdentity(name: "/srv/qwen3-4b-q4_k_m.gguf", format: .gguf,
                                                          quantization: "q4_k_m")))
        XCTAssertFalse(file.matches(BenchmarkModelIdentity(name: "Qwen3-4B-Q8_0.gguf", format: .gguf,
                                                           quantization: "Q8_0")))
        XCTAssertFalse(file.matches(BenchmarkModelIdentity(name: "Qwen3-8B-Q4_K_M.gguf", format: .gguf,
                                                           quantization: "Q4_K_M")))
        XCTAssertFalse(file.matches(BenchmarkModelIdentity(name: "Qwen3-4B-Q4_K_M.gguf", format: nil,
                                                           quantization: "Q4_K_M")), "unknown format")
    }

    // MARK: - Workloads

    func testLongWorkloadIsSeveralThousandTokensOfNonRepeatingText() throws {
        let tokens = GenerationStats.estimatedTokens(in: BenchmarkWorkload.longDocument.userPrompt)
        XCTAssertGreaterThanOrEqual(tokens, 2_500)
        XCTAssertLessThanOrEqual(tokens, 3_400, "keep it inside a 4,096-token server context with the reply")

        let sentences = AnnualReview.sections.enumerated().flatMap { index, section in
            (0..<AnnualReview.sentencesPerSection).map {
                AnnualReview.sentence(in: section, sectionIndex: index, number: $0)
            }
        }
        XCTAssertEqual(Set(sentences).count, sentences.count, "no sentence repeats")
        for sentence in sentences {
            XCTAssertFalse(sentence.contains("%"), "unfilled figure in: \(sentence)")
        }
        XCTAssertTrue(AnnualReview.text.contains(try XCTUnwrap(sentences.last)))
    }

    func testBuiltInWorkloadsHaveDistinctIDs() {
        XCTAssertEqual(BenchmarkWorkload.all.map(\.id), ["chat", "code", "long"])
        XCTAssertTrue(BenchmarkWorkload.all.allSatisfy { $0.maxTokens > 0 && !$0.systemPrompt.isEmpty })
    }
}

// MARK: - Fixtures

extension EngineBenchmarkTests {

    static let weights = BenchmarkModelIdentity(name: "test.gguf", format: .gguf, quantization: "Q4_0")

    static func server(
        _ name: String, tokens: [String] = ["ok"], usage: TokenUsage? = nil, log: BenchCallLog, delay: Duration = .zero
    ) -> BenchmarkCandidate {
        BenchmarkCandidate(
            label: name, weights: weights,
            provider: BenchScriptedProvider(id: name, tokens: tokens, usage: usage, delay: delay, log: log),
            modelID: "model-\(name)", kind: .llamaServer)
    }

    static func run(
        ttft: TimeInterval, decode: TimeInterval, generated: Int, prompt: Int = 10,
        provenance: GenerationStats.Provenance = .runtime
    ) -> BenchmarkRun {
        BenchmarkRun(timeToFirstToken: ttft, promptTime: ttft, decodeTime: decode, promptTokens: prompt,
                     generatedTokens: generated, provenance: provenance, output: "out")
    }

    static func candidate(
        _ id: String, weights: BenchmarkModelIdentity, runs: [BenchmarkRun]
    ) -> BenchmarkCandidateResult {
        BenchmarkCandidateResult(
            id: id, label: id, timing: .clientSide, serverKind: .ollama, weights: weights,
            memoryBeforeLoadBytes: nil, peakMemoryBytes: nil, loadSeconds: nil, loadError: nil,
            results: [BenchmarkWorkloadResult(workloadID: "chat", runs: runs, peakMemoryBytes: nil, failure: nil)])
    }

    static func report(_ candidates: [BenchmarkCandidateResult]) -> BenchmarkReport {
        BenchmarkReport.assemble(settings: BenchmarkSettings(), workloads: [.chat], candidates: candidates,
                                 startedAt: Date(), wasCancelled: false)
    }

    static func body(of request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }
}

/// Requests and their start/end order across every scripted provider.
final class BenchCallLog: Sendable {
    private let state = Mutex<(events: [String], requests: [(provider: String, request: RemoteRequest)])>(([], []))

    func begin(_ provider: String, _ request: RemoteRequest) {
        state.withLock {
            $0.events.append("start \(provider)")
            $0.requests.append((provider, request))
        }
    }

    func end(_ provider: String) {
        state.withLock { $0.events.append("end \(provider)") }
    }

    var events: [String] { state.withLock { $0.events } }

    func requests(of provider: String) -> [RemoteRequest] {
        state.withLock { $0.requests.filter { $0.provider == provider }.map(\.request) }
    }

    func systemPrompts(of provider: String) -> [String] {
        requests(of: provider).compactMap(\.system)
    }
}

/// Streams `tokens` (then `usage`), waiting `delay` before each; throws when the run marker names `failingWorkload`.
struct BenchScriptedProvider: RemoteLLMProvider {
    let id: String
    let displayName = "Scripted"
    let retentionNote = "test"
    let tokens: [String]
    let usage: TokenUsage?
    let delay: Duration
    let failingWorkload: String?
    let log: BenchCallLog?

    init(id: String, tokens: [String], usage: TokenUsage? = nil, delay: Duration = .zero,
         failingWorkload: String? = nil, log: BenchCallLog? = nil) {
        self.id = id
        self.tokens = tokens
        self.usage = usage
        self.delay = delay
        self.failingWorkload = failingWorkload
        self.log = log
    }

    func stream(_ request: RemoteRequest) -> AsyncThrowingStream<RemoteEvent, Error> {
        let events = tokens.map(RemoteEvent.token) + (usage.map { [RemoteEvent.usage($0)] } ?? [])
        let fails = failingWorkload.map { request.system?.contains(" \($0) ") ?? false } ?? false
        return AsyncThrowingStream { continuation in
            let task = Task {
                log?.begin(id, request)
                do {
                    if fails { throw TonamoxError.remoteFailed(500, "boom") }
                    for event in events {
                        try await Task.sleep(for: delay)
                        continuation.yield(event)
                    }
                    // Logged before finishing: the benchmark starts its next request as soon as the stream ends.
                    log?.end(id)
                    continuation.finish()
                } catch {
                    log?.end(id)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@MainActor
final class BenchInProcessLog {
    var entries: [String] = []
}

/// Streams "Hello world" in two pieces and reports fixed stats, logging generations and unloads.
@MainActor
final class BenchScriptedBackend: InferenceBackend {
    static let stats = GenerationStats(backend: .llamaCpp, source: .measured, promptTokens: 40, generatedTokens: 2,
                                       promptTime: 0.1, timeToFirstToken: 0.1, decodeTime: 0.05)
    let name: String
    let log: BenchInProcessLog
    private(set) var lastGenerationStats: GenerationStats?
    var isLoaded: Bool { true }

    init(name: String, log: BenchInProcessLog) {
        self.name = name
        self.log = log
    }

    func load(onProgress: @escaping @MainActor (String) -> Void) async throws {}
    func generate(prompt: String, systemPrompt: String?, maxTokens: Int,
                  onToken: @escaping @MainActor (String) -> Void) async throws -> String {
        log.entries.append("generate \(name)")
        onToken("Hello")
        onToken("Hello world")
        lastGenerationStats = Self.stats
        return "Hello world"
    }
    func generate(prompt: String, systemPrompt: String?, maxTokens: Int, constraint: GenerationConstraint,
                  onToken: @escaping @MainActor (String) -> Void) async throws -> String { "" }
    func generate(prompt: String, image: PlatformImage?, maxTokens: Int,
                  onToken: @escaping @MainActor (String) -> Void) async throws -> String { "" }
    func generate(messages: [[String: String]], maxTokens: Int,
                  onToken: @escaping @MainActor (String) -> Void) async throws -> String { "" }
    func unload() { log.entries.append("unload \(name)") }
}
