import Foundation
import TonamoxCore

/// What one served request hands the system model: the system messages as instructions, the earlier turns as a
/// transcript and the last user message as the prompt.
package struct AppleChatPlan: Sendable, Equatable {
    package var instructions: String?
    /// User and assistant turns before the prompt, in order; assistant turns without inline reasoning.
    package var history: [ServedMessage]
    package var prompt: String
    package var maxTokens: Int

    package init(instructions: String?, history: [ServedMessage], prompt: String, maxTokens: Int) {
        self.instructions = instructions
        self.history = history
        self.prompt = prompt
        self.maxTokens = maxTokens
    }
}

/// The FoundationModels calls behind ``AppleIntelligenceServedModel``, so tests can stand in for the system model.
@MainActor
package protocol AppleModelDriver {
    var contextSize: Int { get }
    /// Generates in the calling task and returns or throws only once the model stopped. `snapshot` receives the
    /// whole text so far each time. Model failures are thrown as ``ServedModelError`` where one fits, and the safety
    /// rules stopping the answer as ``AppleContentFiltered``.
    func generate(_ plan: AppleChatPlan, snapshot: (String) -> Void) async throws -> ServedUsage?
}

/// The system model's safety rules declined the request or stopped its answer. Served as a normal end with
/// ``FinishReason/contentFilter``, never as an error; `usage` is the last snapshot's, when the framework gave one.
package struct AppleContentFiltered: Error, Equatable {
    package let usage: ServedUsage?

    package init(usage: ServedUsage? = nil) {
        self.usage = usage
    }
}

/// Serves Apple Intelligence (the on-device `SystemLanguageModel` of FoundationModels) with the full message
/// history: one fresh session per request, since HTTP is stateless. The model does not reason, so reasoning options
/// are ignored and no reasoning is ever served.
@MainActor
public final class AppleIntelligenceServedModel: ServedChatModel {
    public static let defaultID = "apple-intelligence"
    public static let defaultDisplayName = "Apple Intelligence"

    public nonisolated let info: ServedModelInfo
    public nonisolated let turnstile: GenerationTurnstile?
    public let displayName: String
    private let driver: any AppleModelDriver

    #if canImport(FoundationModels)
    /// Throws ``ServedModelError/notLoaded`` when the system model is not available right now. `temperature` `nil`
    /// keeps the model's default.
    @available(iOS 27, macOS 27, visionOS 27, *)
    public convenience init(id: String = defaultID, displayName: String = defaultDisplayName,
                            turnstile: GenerationTurnstile, temperature: Double? = nil) throws {
        guard SystemModelDriver.isAvailable else { throw ServedModelError.notLoaded }
        self.init(driver: SystemModelDriver(temperature: temperature), id: id, displayName: displayName,
                  turnstile: turnstile)
    }
    #endif

    package init(driver: any AppleModelDriver, id: String, displayName: String, turnstile: GenerationTurnstile?) {
        self.driver = driver
        self.displayName = displayName
        self.turnstile = turnstile
        self.info = ServedModelInfo(id: id, ownedBy: "apple", contextLength: driver.contextSize, egress: .onDevice)
    }

    public var served: ServedModel { ServedModel(self) }

    package nonisolated func respond(to request: ServedChatRequest) -> ServedResponse {
        ServedResponse.producing { continuation in await self.generate(request, into: continuation) }
    }

    private func generate(_ request: ServedChatRequest,
                          into continuation: AsyncThrowingStream<ServedChatEvent, Error>.Continuation) async {
        do {
            let plan = try Self.plan(for: request)
            var sent = ""
            var latest = ""
            var usage: ServedUsage?
            var finish = FinishReason.stop
            do {
                usage = try await driver.generate(plan) { text in
                    latest = text
                    guard request.stream, let delta = Self.delta(from: sent, to: text) else { return }
                    sent = text
                    continuation.yield(.text(delta))
                }
                finish = Self.finishReason(usage, maxTokens: request.maxTokens)
            } catch let filtered as AppleContentFiltered {
                usage = filtered.usage
                finish = .contentFilter
            }
            try Task.checkCancellation()
            if !request.stream, !latest.isEmpty { continuation.yield(.text(latest)) }
            continuation.yield(.finished(finish, usage))
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    /// Throws ``ServedModelError/unsupported(_:)`` for `messages` unless the conversation ends with a user message:
    /// the system model answers a prompt and has no assistant prefill.
    nonisolated static func plan(for request: ServedChatRequest) throws -> AppleChatPlan {
        let system = request.messages.filter { $0.role == .system && !$0.content.isEmpty }.map(\.content)
        let turns = request.messages.filter { $0.role != .system }
        guard let last = turns.last, last.role == .user else { throw ServedModelError.unsupported("messages") }
        return AppleChatPlan(instructions: system.isEmpty ? nil : system.joined(separator: "\n\n"),
                             history: turns.dropLast().map(withoutReasoning), prompt: last.content,
                             maxTokens: request.maxTokens)
    }

    nonisolated static func withoutReasoning(_ message: ServedMessage) -> ServedMessage {
        guard message.role == .assistant else { return message }
        return ServedMessage(role: .assistant, content: LocalServedModel.answer(of: message.content))
    }

    /// The text `snapshot` adds to `sent`; `nil` when it adds nothing or does not extend it. Compared by Unicode
    /// scalar: a combining mark appended to the last character changes that `Character`, not the scalars before it.
    nonisolated static func delta(from sent: String, to snapshot: String) -> String? {
        let old = sent.unicodeScalars
        let new = snapshot.unicodeScalars
        guard new.count > old.count, new.starts(with: old) else { return nil }
        return String(new.dropFirst(old.count))
    }

    nonisolated static func finishReason(_ usage: ServedUsage?, maxTokens: Int) -> FinishReason {
        guard let usage else { return .stop }
        return usage.completionTokens >= maxTokens ? .length : .stop
    }
}
