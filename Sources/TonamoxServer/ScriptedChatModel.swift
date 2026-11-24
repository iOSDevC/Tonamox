import Foundation
import TonamoxCore

/// A served model that replays fixed pieces, for tests and the offline CLI smoke run. Each piece counts as one token.
@MainActor
package final class ScriptedChatModel: ServedChatModel {
    package nonisolated let info: ServedModelInfo
    package nonisolated let turnstile: GenerationTurnstile?
    package var pieces: [String]
    package var delay: Duration
    /// Reported in `.finished`; `nil` leaves usage unknown.
    package var usage: ServedUsage?
    /// Thrown after this many pieces, when set.
    package var failure: (afterPieces: Int, error: ServedModelError)?
    /// Time a cancelled generation keeps "decoding" before it ends.
    package var unwindDelay: Duration = .zero
    /// Splits a leading reasoning block out of the pieces as ``LocalServedModel`` does; off replays them as text.
    package var splitsReasoning = false
    /// Set, the model behaves like a GGUF whose template opens `<think>` and reads `enable_thinking`: it reasons
    /// with this piece until the request's reasoning budget closes the block (forever without one), then plays
    /// `pieces` as the answer. Thinking disabled plays `pieces` alone. Reasoning is always split out.
    package var endlessReasoning: String?

    package private(set) var running = 0
    package private(set) var maxConcurrent = 0
    package private(set) var started = 0
    package private(set) var cancelled = 0
    package private(set) var requests: [ServedChatRequest] = []

    package init(id: String = "scripted", pieces: [String] = ["Hello", ",", " world"], delay: Duration = .zero,
                 usage: ServedUsage? = ServedUsage(promptTokens: 5, completionTokens: 3), contextLength: Int? = nil,
                 turnstile: GenerationTurnstile? = GenerationTurnstile()) {
        self.info = ServedModelInfo(id: id, ownedBy: "tonamox", contextLength: contextLength, egress: .onDevice)
        self.turnstile = turnstile
        self.pieces = pieces
        self.delay = delay
        self.usage = usage
    }

    package var served: ServedModel { ServedModel(self) }

    package nonisolated func respond(to request: ServedChatRequest) -> ServedResponse {
        ServedResponse.producing { continuation in await self.play(request, into: continuation) }
    }

    /// The SDK's own budget logic over a source that never closes its reasoning.
    private func reason(_ piece: String, _ request: ServedChatRequest,
                        into continuation: AsyncThrowingStream<ServedChatEvent, Error>.Continuation) async {
        do {
            let cut = try await Self.decode(piece, answer: pieces, delay: delay, request, into: continuation)
            continuation.yield(.finished(cut ? .length : .stop, usage))
            continuation.finish()
        } catch is CancellationError {
            await unwind()
            cancelled += 1
            continuation.finish(throwing: CancellationError())
        } catch {
            continuation.finish(throwing: error)
        }
    }

    /// Off the main actor, so the relay and the source stay in this task. Returns whether a limit cut the answer.
    private nonisolated static func decode(
        _ piece: String, answer: [String], delay: Duration, _ request: ServedChatRequest,
        into continuation: AsyncThrowingStream<ServedChatEvent, Error>.Continuation
    ) async throws -> Bool {
        let budget = request.reasoning.budget
        let plan = ReasoningPlan(rendersWithoutThinking: false, budget: budget, openedTag: "<think>")
        var source = EndlessReasoner(piece: piece, answer: answer, delay: delay)
        var relay = ReasoningRelay()
        _ = relay.consume("<think>")
        var whole = ""
        let limit = ReasoningPlan.pieceLimit(maxTokens: request.maxTokens, budget: budget)
        let outcome = try await BudgetedDecode.run(&source, plan: plan, maxTokens: limit,
                                                   answerTokens: budget == nil ? nil : request.maxTokens) { text in
            if request.stream {
                for event in relay.consume(text) { continuation.yield(event) }
            } else {
                whole += text
            }
        }
        try Task.checkCancellation()
        for event in relay.consume(whole) + relay.finish() { continuation.yield(event) }
        if outcome.turn.wasCut { continuation.yield(.reasoningCut(tokens: outcome.turn.reasoningTokens)) }
        return budget == nil ? !outcome.endedByItself : outcome.turn.answerTokens >= request.maxTokens
    }

    /// Models a backend that needs a while to stop after a cancellation.
    private func unwind() async {
        guard unwindDelay > .zero else { return }
        let delay = unwindDelay
        await Task.detached { try? await Task.sleep(for: delay) }.value
    }

    private func play(_ request: ServedChatRequest,
                      into continuation: AsyncThrowingStream<ServedChatEvent, Error>.Continuation) async {
        requests.append(request)
        started += 1
        running += 1
        maxConcurrent = max(maxConcurrent, running)
        defer { running -= 1 }
        if let endlessReasoning, request.reasoning.thinking != .disabled {
            return await reason(endlessReasoning, request, into: continuation)
        }
        let emitted = Array(pieces.prefix(request.maxTokens))
        var relay = splitsReasoning ? ReasoningRelay() : nil
        // As LocalServedModel: without streaming the output is split once.
        var whole = ""
        do {
            for (index, piece) in emitted.enumerated() {
                if let failure, failure.afterPieces == index { throw failure.error }
                if delay > .zero { try await Task.sleep(for: delay) }
                try Task.checkCancellation()
                if relay == nil {
                    continuation.yield(.text(piece))
                } else if request.stream {
                    for event in relay?.consume(piece) ?? [] { continuation.yield(event) }
                } else {
                    whole += piece
                }
            }
            if let failure, failure.afterPieces >= emitted.count { throw failure.error }
            for event in (relay?.consume(whole) ?? []) + (relay?.finish() ?? []) { continuation.yield(event) }
            continuation.yield(.finished(pieces.count > request.maxTokens ? .length : .stop, usage))
            continuation.finish()
        } catch is CancellationError {
            await unwind()
            cancelled += 1
            continuation.finish(throwing: CancellationError())
        } catch {
            continuation.finish(throwing: error)
        }
    }
}

/// Reasons with one piece until something is forced into it, then plays the answer.
private struct EndlessReasoner: PieceSource {
    let piece: String
    var answer: [String]
    let delay: Duration
    private var answering = false

    init(piece: String, answer: [String], delay: Duration) {
        self.piece = piece
        self.answer = answer
        self.delay = delay
    }

    mutating func next() async throws -> String? {
        if delay > .zero { try await Task.sleep(for: delay) }
        try Task.checkCancellation()
        guard answering else { return piece }
        return answer.isEmpty ? nil : answer.removeFirst()
    }

    mutating func force(_ text: String, flushing: Bool) -> Bool {
        answering = true
        return true
    }
}
