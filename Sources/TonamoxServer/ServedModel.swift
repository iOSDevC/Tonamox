import Foundation
import TonamoxCore

/// A model the server can answer with. `package`: only SDK adapters conform, so no integrator can wrap a remote
/// provider and declare it on-device, which would serve an egress path without consent.
package protocol ServedChatModel: Sendable {
    nonisolated var info: ServedModelInfo { get }
    /// Shared with the app's own generations on the same model; `nil` runs without one.
    nonisolated var turnstile: GenerationTurnstile? { get }
    /// Must stop work when the stream is terminated (client disconnect, stall, stop, suspension).
    nonisolated func respond(to request: ServedChatRequest) -> ServedResponse
}

/// A served answer: the events, and a wait for the work behind them.
package struct ServedResponse: Sendable {
    package let events: AsyncThrowingStream<ServedChatEvent, Error>
    /// Returns once the model stopped working on this request, also after a cancellation. A cancelled consumer's
    /// iteration ends at once while the decode may still be unwinding; the turnstile is handed over only after this.
    package let settled: @Sendable () async -> Void

    /// Runs `produce` in a main-actor task that the stream's termination cancels.
    package static func producing(
        _ produce: @escaping @MainActor (AsyncThrowingStream<ServedChatEvent, Error>.Continuation) async -> Void
    ) -> ServedResponse {
        let (events, continuation) = AsyncThrowingStream.makeStream(of: ServedChatEvent.self, throwing: Error.self)
        let task = Task { @MainActor in await produce(continuation) }
        continuation.onTermination = { _ in task.cancel() }
        return ServedResponse(events: events, settled: { await task.value })
    }
}

public struct ServedModelInfo: Sendable, Hashable {
    public let id: String
    public let ownedBy: String
    /// Prompt plus completion tokens the model holds; `nil` skips the server's context check.
    public let contextLength: Int?
    public let egress: ServedModelEgress

    public init(id: String, ownedBy: String, contextLength: Int?, egress: ServedModelEgress) {
        self.id = id
        self.ownedBy = ownedBy
        self.contextLength = contextLength
        self.egress = egress
    }
}

public enum ServedModelEgress: Sendable, Hashable {
    /// Runs on this device: the server is only an ingress surface.
    case onDevice
    /// Still egress: consent applies.
    case localNetwork(host: String)
    case cloud(providerName: String, retentionNote: String)
}

/// An opaque served model, built only by SDK adapters such as ``LocalServedModel``.
public struct ServedModel: Sendable {
    package let base: any ServedChatModel

    package init(_ base: any ServedChatModel) {
        self.base = base
    }

    public var info: ServedModelInfo { base.info }
}

public enum ServedRole: String, Sendable, Hashable {
    case system, user, assistant
}

public struct ServedMessage: Sendable, Hashable {
    public let role: ServedRole
    public let content: String

    public init(role: ServedRole, content: String) {
        self.role = role
        self.content = content
    }
}

public struct ServedChatRequest: Sendable {
    public let messages: [ServedMessage]
    /// Already clamped by the server.
    public let maxTokens: Int
    public let client: ClientIdentity
    /// The client asked for a stream. Without one, a model can split reasoning from the answer on the whole output;
    /// the default keeps delivering pieces as they decode.
    public let stream: Bool
    /// How the model may reason. With a budget, `maxTokens` is the answer's and the reasoning may take the budget
    /// on top. The server decodes it from `reasoning_effort` and `chat_template_kwargs.enable_thinking`.
    public let reasoning: ReasoningOptions

    public init(messages: [ServedMessage], maxTokens: Int, client: ClientIdentity, stream: Bool = true,
                reasoning: ReasoningOptions = .automatic) {
        self.messages = messages
        self.maxTokens = maxTokens
        self.client = client
        self.stream = stream
        self.reasoning = reasoning
    }
}

public enum FinishReason: String, Sendable, Equatable {
    case stop
    case length
    /// The model's safety rules stopped the answer; the text before it is kept.
    case contentFilter = "content_filter"
}

public struct ServedUsage: Sendable, Equatable {
    public let promptTokens: Int
    public let completionTokens: Int

    public init(promptTokens: Int, completionTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

public enum ServedChatEvent: Sendable, Equatable {
    case text(String)
    case reasoning(String)
    /// The reasoning budget ran out inside the block, which was closed for the model after `tokens` reasoning
    /// tokens. Sent before ``finished(_:_:)``.
    case reasoningCut(tokens: Int)
    /// Usage is `nil` when unknown; the server never invents it.
    case finished(FinishReason, ServedUsage?)
}

public enum ServedModelError: Error, Sendable, Equatable {
    case busy
    case notLoaded
    case interrupted(partial: String)
    case unsupported(String)
    case toolsNotAllowed
    case contextLengthExceeded(limit: Int)
    /// The model does not support the request's language.
    case unsupportedLanguage
}
