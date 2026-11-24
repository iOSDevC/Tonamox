import Foundation
import Testing
@testable import TonamoxCore
@testable import TonamoxServer

@Suite("Reasoning fields of the chat request")
struct ReasoningRequestDecodingTests {
    private static func decoded(_ extra: String,
                                limits: ServerLimits = ServerLimits()) throws(APIError) -> ChatCompletionRequest {
        try ChatCompletionDecoder.decode(Data(Bodies.chat(extra: extra).utf8), limits: limits)
    }

    private static func failure(_ extra: String) -> APIError? {
        do throws(APIError) {
            _ = try decoded(extra)
            return nil
        } catch {
            return error
        }
    }

    @Test func absentFieldsReasonWithTheDefaultBudget() throws {
        #expect(try Self.decoded("").reasoning == .budgeted(1024))
        var limits = ServerLimits()
        limits.defaultReasoningBudget = 300
        #expect(try Self.decoded("", limits: limits).reasoning == .budgeted(300))
        #expect(try Self.decoded(#""reasoning_effort":null"#).reasoning == .budgeted(1024))
    }

    @Test(arguments: [("none", ReasoningOptions.disabled), ("minimal", .budgeted(256)), ("low", .budgeted(256)),
                      ("medium", .budgeted(1024)), ("high", .budgeted(4096))])
    func effortMapsToABudget(_ effort: String, _ expected: ReasoningOptions) throws {
        #expect(try Self.decoded(#""reasoning_effort":"\#(effort)""#).reasoning == expected)
    }

    @Test func budgetsStayUnderTheCeiling() throws {
        var limits = ServerLimits()
        limits.maxReasoningBudget = 2000
        limits.defaultReasoningBudget = 5000
        #expect(try Self.decoded(#""reasoning_effort":"high""#, limits: limits).reasoning == .budgeted(2000))
        #expect(try Self.decoded("", limits: limits).reasoning == .budgeted(2000))
    }

    @Test func enableThinkingFalseDisablesThinkingWhateverTheEffort() throws {
        #expect(try Self.decoded(#""chat_template_kwargs":{"enable_thinking":false}"#).reasoning == .disabled)
        #expect(try Self.decoded(#""reasoning_effort":"high","chat_template_kwargs":{"enable_thinking":false}"#)
            .reasoning == .disabled)
        #expect(try Self.decoded(#""reasoning_effort":"low","chat_template_kwargs":{"enable_thinking":true}"#)
            .reasoning == .budgeted(256))
    }

    @Test func otherTemplateArgumentsAreIgnoredAndReported() throws {
        let request = try Self.decoded(#""chat_template_kwargs":{"enable_thinking":true,"preserve_thinking":true}"#)
        #expect(request.reasoning == .budgeted(1024))
        #expect(request.ignored == ["chat_template_kwargs.preserve_thinking"])
        #expect(!request.ignored.contains("reasoning_effort"))
    }

    @Test func invalidValuesAreRejected() {
        #expect(Self.failure(#""reasoning_effort":"max""#)?.code == "invalid_reasoning_effort")
        #expect(Self.failure(#""reasoning_effort":3"#)?.param == "reasoning_effort")
        #expect(Self.failure(#""chat_template_kwargs":[]"#)?.param == "chat_template_kwargs")
        #expect(Self.failure(#""chat_template_kwargs":{"enable_thinking":"no"}"#)?.param
            == "chat_template_kwargs.enable_thinking")
        #expect(Self.failure(#""reasoning_effort":"none","chat_template_kwargs":{"enable_thinking":true}"#)?.code
            == "conflicting_reasoning")
    }
}

@MainActor
private func endlessModel(answer: [String] = ["7", "5", "4"]) -> ScriptedChatModel {
    let model = ScriptedChatModel(pieces: answer)
    model.endlessReasoning = "hmm "
    return model
}

private func message(_ response: RawResponse) -> [String: Any] {
    let choices = json(response.body)["choices"] as? [[String: Any]]
    return choices?.first?["message"] as? [String: Any] ?? [:]
}

private func chunks(_ response: RawResponse) -> [[String: Any]] {
    events(response.text).filter { $0 != "[DONE]" }.map { json(Data($0.utf8)) }
}

@MainActor
@Suite(.serialized)
struct ServerReasoningControlTests {
    @Test func requestReasoningReachesTheModel() async throws {
        let model = ScriptedChatModel()
        let harness = try await ServerHarness.started(model: model)
        _ = try await harness.chat(Bodies.chat())
        _ = try await harness.chat(Bodies.chat(extra: #""reasoning_effort":"none""#))
        #expect(model.requests.map(\.reasoning) == [.budgeted(1024), .disabled])
        await harness.server.stop()
    }

    @Test func endlessReasoningIsCutAtTheBudgetAndTheAnswerFollows() async throws {
        let harness = try await ServerHarness.started(model: endlessModel())
        let response = try await harness.chat(Bodies.chat(extra: #""reasoning_effort":"low","max_tokens":16"#))
        #expect(response.status == 200)
        #expect(message(response)["content"] as? String == "754")
        let reasoning = try #require(message(response)["reasoning_content"] as? String)
        #expect(reasoning.hasPrefix("hmm hmm "))
        // The model reads the budget sentence; the reader is not shown it as the model's own words.
        #expect(!reasoning.contains("Considering the limited time"))
        #expect(!reasoning.contains("</think>"))
        let tonamox = json(response.body)["tonamox"] as? [String: Any]
        let cut = tonamox?["reasoning"] as? [String: Any]
        #expect(cut?["cut"] as? Bool == true)
        #expect(cut?["tokens"] as? Int == 256)
        #expect((json(response.body)["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String == "stop")
        await harness.server.stop()
    }

    @Test func streamCarriesTheCutOnTheFinalChunk() async throws {
        let harness = try await ServerHarness.started(model: endlessModel())
        let response = try await harness.chat(Bodies.stream(extra: #""reasoning_effort":"low""#))
        let all = chunks(response)
        let deltas = all.compactMap { ($0["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any] }
        #expect(deltas.compactMap { $0["content"] as? String }.joined() == "754")
        #expect(deltas.compactMap { $0["reasoning_content"] as? String }.joined().hasPrefix("hmm "))
        let marked = all.filter { $0["tonamox"] != nil }
        #expect(marked.count == 1)
        let final = try #require(marked.first)
        #expect((final["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String == "stop")
        #expect(((final["tonamox"] as? [String: Any])?["reasoning"] as? [String: Any])?["tokens"] as? Int == 256)
        await harness.server.stop()
    }

    @Test func thinkingOffAnswersWithoutReasoning() async throws {
        let harness = try await ServerHarness.started(model: endlessModel())
        let response = try await harness.chat(Bodies.chat(extra: #""chat_template_kwargs":{"enable_thinking":false}"#))
        #expect(message(response)["content"] as? String == "754")
        #expect(message(response)["reasoning_content"] == nil)
        #expect(json(response.body)["tonamox"] == nil)
        await harness.server.stop()
    }

    @Test func maxTokensLimitsTheAnswerAfterTheBudget() async throws {
        let harness = try await ServerHarness.started(model: endlessModel(answer: ["a", "b", "c", "d"]))
        let response = try await harness.chat(Bodies.chat(extra: #""reasoning_effort":"low","max_tokens":2"#))
        #expect(message(response)["content"] as? String == "ab")
        #expect((json(response.body)["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String == "length")
        await harness.server.stop()
    }

    @Test func localModelReportsTheCutAndCountsOnlyTheAnswerAgainstMaxTokens() {
        let stats = GenerationStats(backend: .llamaCpp, source: .measured, promptTokens: 4, generatedTokens: 300,
                                    promptTime: 0, timeToFirstToken: 0, decodeTime: 0)
        let cut = ReasoningTurn(renderedWithoutThinking: false, budget: 256, reasoningTokens: 256, answerTokens: 40,
                                wasCut: true)
        #expect(LocalServedModel.summary(stats, reasoning: cut, maxTokens: 64).0 == .stop)
        #expect(LocalServedModel.summary(stats, reasoning: nil, maxTokens: 64).0 == .length)
        let full = ReasoningTurn(renderedWithoutThinking: false, budget: 256, reasoningTokens: 10, answerTokens: 64,
                                 wasCut: false)
        #expect(LocalServedModel.summary(stats, reasoning: full, maxTokens: 64).0 == .length)
    }

    @Test func replyThatUsedEveryPieceTheBudgetAllowsIsCut() {
        let stats = GenerationStats(backend: .llamaCpp, source: .measured, promptTokens: 4, generatedTokens: 321,
                                    promptTime: 0, timeToFirstToken: 0, decodeTime: 0)
        let reopened = ReasoningTurn(renderedWithoutThinking: false, budget: 256, reasoningTokens: 311,
                                     answerTokens: 10, wasCut: true)
        #expect(LocalServedModel.summary(stats, reasoning: reopened, maxTokens: 64).0 == .length)
        let shorter = GenerationStats(backend: .llamaCpp, source: .measured, promptTokens: 4, generatedTokens: 320,
                                      promptTime: 0, timeToFirstToken: 0, decodeTime: 0)
        #expect(LocalServedModel.summary(shorter, reasoning: reopened, maxTokens: 64).0 == .stop)
    }
}

/// A GGUF-like backend whose template opens `<think>` and reads `enable_thinking`: with thinking off it answers
/// alone; otherwise it reasons, and the budget reports a cut.
@MainActor
final class ReasoningFakeBackend: InferenceBackend, ReasoningControlHost {
    private(set) var isLoaded = true
    private(set) var lastReasoningTurn: ReasoningTurn?
    private(set) var requested: [ReasoningOptions] = []
    let reasoningSupport = ReasoningCapabilities(canDisableThinking: true, enforcesBudget: true)

    func promptOpenedReasoningTag(for options: ReasoningOptions) -> String? {
        options.thinking == .disabled ? nil : "<think>"
    }

    func load(onProgress: @escaping @MainActor (String) -> Void) async throws {}

    func generate(prompt: String, systemPrompt: String?, maxTokens: Int,
                  onToken: @escaping @MainActor (String) -> Void) async throws -> String {
        try await generate(messages: [], maxTokens: maxTokens, reasoning: .automatic, onToken: onToken)
    }

    func generate(prompt: String, systemPrompt: String?, maxTokens: Int, constraint: GenerationConstraint,
                  onToken: @escaping @MainActor (String) -> Void) async throws -> String { "" }

    func generate(prompt: String, image: PlatformImage?, maxTokens: Int,
                  onToken: @escaping @MainActor (String) -> Void) async throws -> String { "" }

    func generate(messages: [[String: String]], maxTokens: Int,
                  onToken: @escaping @MainActor (String) -> Void) async throws -> String {
        try await generate(messages: messages, maxTokens: maxTokens, reasoning: .automatic, onToken: onToken)
    }

    func generate(prompt: String, systemPrompt: String?, maxTokens: Int, reasoning: ReasoningOptions,
                  onToken: @escaping @MainActor (String) -> Void) async throws -> String {
        try await generate(messages: [], maxTokens: maxTokens, reasoning: reasoning, onToken: onToken)
    }

    func generate(messages: [[String: String]], maxTokens: Int, reasoning: ReasoningOptions,
                  onToken: @escaping @MainActor (String) -> Void) async throws -> String {
        requested.append(reasoning)
        let off = reasoning.thinking == .disabled
        let text = off ? "754" : "x\n\nConsidering…\n</think>\n\n754"
        onToken(text)
        lastReasoningTurn = ReasoningTurn(renderedWithoutThinking: off, budget: reasoning.budget,
                                          reasoningTokens: off ? 0 : 8, answerTokens: 1, wasCut: !off)
        return text
    }

    func unload() { isLoaded = false }
}

@MainActor
@Suite struct LocalServedModelReasoningControlTests {
    private static func served(_ backend: ReasoningFakeBackend) throws -> LocalServedModel {
        let lifecycle = BackgroundLifecycle(notificationCenter: NotificationCenter(), didEnterBackground: nil,
                                            willEnterForeground: nil)
        let engine = TonamoxEngine(model: .dolphin3_qwen25_1_5b_gguf, backend: backend, lifecycle: lifecycle)
        return try LocalServedModel(Tonamox(engine: engine), id: "local", displayName: "Local",
                                    turnstile: GenerationTurnstile())
    }

    private static func events(_ backend: ReasoningFakeBackend, _ reasoning: ReasoningOptions,
                               stream: Bool) async throws -> [ServedChatEvent] {
        let request = ServedChatRequest(messages: [ServedMessage(role: .user, content: "U")], maxTokens: 64,
                                        client: ClientIdentity(clientID: nil, label: "t", peer: "127.0.0.1"),
                                        stream: stream, reasoning: reasoning)
        var received: [ServedChatEvent] = []
        for try await event in try served(backend).respond(to: request).events { received.append(event) }
        return received
    }

    @Test(arguments: [true, false])
    func thinkingOffAnswerIsTextNotReasoning(_ stream: Bool) async throws {
        let backend = ReasoningFakeBackend()
        let received = try await Self.events(backend, .disabled, stream: stream)
        #expect(received.filter { if case .finished = $0 { false } else { true } } == [.text("754")])
        #expect(backend.requested == [.disabled])
    }

    @Test(arguments: [true, false])
    func budgetCutIsReportedBeforeFinished(_ stream: Bool) async throws {
        let backend = ReasoningFakeBackend()
        let received = try await Self.events(backend, .budgeted(8), stream: stream)
        let reasoning = received.compactMap { if case .reasoning(let text) = $0 { text } else { nil } }.joined()
        let text = received.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined()
        #expect(reasoning.hasPrefix("x"))
        #expect(text == "754")
        let cut = try #require(received.firstIndex(of: .reasoningCut(tokens: 8)))
        let finished = try #require(received.firstIndex { if case .finished = $0 { true } else { false } })
        #expect(cut < finished)
    }
}

/// As the real GGUF backends: the automatic tag is also reported the old way, which must not win over `nil`.
extension ReasoningFakeBackend: PromptReasoningReporting {
    var promptOpenedReasoningTag: String? { "<think>" }
}
