import Foundation
import TonamoxCore

/// Serves an on-device GGUF or MLX model loaded through Tonamox, with the full message history and its roles. A
/// leading `<think>`/`<thought>` block in the output is served as reasoning, apart from the answer; so is the start
/// of the output when the GGUF's template opens the block in the prompt (``Tonamox/promptOpenedReasoningTag``).
/// Without streaming the whole output is split once, so a lone closing tag needs no retraction.
@MainActor
public final class LocalServedModel: ServedChatModel {
    public nonisolated let info: ServedModelInfo
    public nonisolated let turnstile: GenerationTurnstile?
    public let displayName: String
    private let llm: Tonamox

    /// Throws ``ServedModelError/toolsNotAllowed`` when `llm` was loaded with tools: a served prompt must never drive
    /// the app's on-device tools. `contextLength` defaults to the loaded window (``Tonamox/contextWindow``), else the
    /// model's own ceiling, when it declares one.
    public init(_ llm: Tonamox, id: String, displayName: String, turnstile: GenerationTurnstile,
                contextLength: Int? = nil) throws {
        guard !llm.isToolEnabled else { throw ServedModelError.toolsNotAllowed }
        self.llm = llm
        self.displayName = displayName
        self.turnstile = turnstile
        self.info = ServedModelInfo(id: id, ownedBy: "tonamox",
                                    contextLength: contextLength ?? llm.contextWindow ?? llm.model.maxContextLength,
                                    egress: .onDevice)
    }

    public var served: ServedModel { ServedModel(self) }

    package nonisolated func respond(to request: ServedChatRequest) -> ServedResponse {
        ServedResponse.producing { continuation in await self.generate(request, into: continuation) }
    }

    /// Calls the backend in this task (not through a stream), so the task ends only when the decode has stopped.
    private func generate(_ request: ServedChatRequest,
                          into continuation: AsyncThrowingStream<ServedChatEvent, Error>.Continuation) async {
        let turns = request.messages.map { message in
            ["role": message.role.rawValue,
             "content": message.role == .assistant ? Self.answer(of: message.content) : message.content]
        }
        var relay = ReasoningRelay()
        if let opened = llm.promptOpenedReasoningTag(for: request.reasoning) { _ = relay.consume(opened) }
        var whole = ""
        do {
            try await llm.generateMessages(turns, maxTokens: request.maxTokens,
                                           reasoning: request.reasoning) { piece in
                if request.stream {
                    for event in relay.consume(piece) { continuation.yield(event) }
                } else {
                    whole += piece
                }
            }
            for event in relay.consume(whole) + relay.finish() { continuation.yield(event) }
            let turn = llm.lastReasoningTurn
            if let turn, turn.wasCut { continuation.yield(.reasoningCut(tokens: turn.reasoningTokens)) }
            let (reason, usage) = Self.summary(llm.lastGenerationStats, reasoning: turn, maxTokens: request.maxTokens)
            continuation.yield(.finished(reason, usage))
            continuation.finish()
        } catch let stop as GenerationInterrupted {
            continuation.finish(throwing: ServedModelError.interrupted(partial: stop.partialText))
        } catch TonamoxError.modelNotLoaded {
            continuation.finish(throwing: ServedModelError.notLoaded)
        } catch {
            continuation.finish(throwing: error)
        }
    }

    /// A client that sent a reply back with its reasoning inline (a streamed template-opened reply arrives that way)
    /// must not feed that reasoning to the model again.
    nonisolated static func answer(of content: String) -> String {
        let split = ReasoningSplitter.split(content)
        return split.hasReasoning ? split.answer : content
    }

    /// Reason and usage from the backend's counts; usage stays `nil` when the backend reported none. With a
    /// reasoning budget only the answer counts against `maxTokens`, and a reply that used every piece the budget
    /// allows (reasoning that reopened after its close) is cut too; completion tokens still count both.
    nonisolated static func summary(_ stats: GenerationStats?, reasoning: ReasoningTurn? = nil,
                                    maxTokens: Int) -> (FinishReason, ServedUsage?) {
        guard let stats else { return (.stop, nil) }
        let usage = ServedUsage(promptTokens: stats.promptTokens, completionTokens: stats.generatedTokens)
        guard let budget = reasoning?.budget, let reasoning else {
            return (stats.generatedTokens >= maxTokens ? .length : .stop, usage)
        }
        let limit = ReasoningPlan.pieceLimit(maxTokens: maxTokens, budget: budget)
        let cut = reasoning.answerTokens >= maxTokens || stats.generatedTokens >= limit
        return (cut ? .length : .stop, usage)
    }
}
