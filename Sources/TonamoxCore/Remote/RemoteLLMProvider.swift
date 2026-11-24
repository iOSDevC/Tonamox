import Foundation

// MARK: - RemoteLLMProvider

/// A pluggable remote LLM the hybrid pipeline can escalate to.
///
/// Providers are `Sendable` strategy values (mirrors ``InferenceBackend`` /
/// ``BackendRouter``). Concrete conformers: `OpenAICompatibleProvider`
/// (hosted OpenAI, the user's llama-server, Ollama `/v1`) and `AnthropicProvider`.
public protocol RemoteLLMProvider: Sendable {
    /// Stable identifier, also used as the Keychain account for the API key.
    var id: String { get }
    /// Human-readable name for UI.
    var displayName: String { get }
    /// One-line data-retention note surfaced in the consent sheet.
    var retentionNote: String { get }
    /// Stream a response as a sequence of ``RemoteEvent``s. Throws on transport
    /// or non-success HTTP status.
    func stream(_ request: RemoteRequest) -> AsyncThrowingStream<RemoteEvent, Error>
    /// What ``ResponseCache`` keys answers on: ``id`` by default; the bundled providers add their endpoint, so a
    /// provider id reused for another server never answers from the old server's replies. Never holds a secret.
    var cacheIdentity: String { get }
}

extension RemoteLLMProvider {
    public var cacheIdentity: String { id }
}

/// `scheme://host:port/path` of an endpoint, without user, password, query or fragment.
enum EndpointIdentity {
    static func of(_ url: URL) -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "?" }
        let scheme = parts.scheme?.lowercased() ?? ""
        let host = parts.percentEncodedHost?.lowercased() ?? ""
        let port = parts.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : 0)
        var path = parts.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        return "\(scheme)://\(host):\(port)\(path)"
    }

    /// `id` plus the endpoint, for ``RemoteLLMProvider/cacheIdentity``.
    static func cacheIdentity(id: String, baseURL: URL) -> String {
        "\(id)@\(of(baseURL))"
    }
}

// MARK: - Wire types

/// A remote generation request. `messages` reuses TonamoxCore's `[[String: String]]`
/// shape (keys `role` / `content`), which maps 1:1 to both OpenAI and Anthropic bodies.
public struct RemoteRequest: Sendable {
    public let model: String
    public let system: String?
    public let messages: [[String: String]]
    public let maxTokens: Int
    public let temperature: Float

    public init(
        model: String,
        system: String? = nil,
        messages: [[String: String]],
        maxTokens: Int = 1024,
        temperature: Float = 0.7
    ) {
        self.model = model
        self.system = system
        self.messages = messages
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

/// A streamed event from a remote provider.
public enum RemoteEvent: Sendable {
    /// An incremental text delta.
    case token(String)
    /// An incremental reasoning ("thinking") delta that the server streams apart from the answer. It is not part of
    /// the reply: the escalation path leaves it out of the answer and only notes that output was billed.
    case reasoning(String)
    /// Final (or cumulative) token accounting, when the provider reports it.
    case usage(TokenUsage)
}

/// Token accounting for a remote call.
public struct TokenUsage: Sendable, Hashable {
    public let inputTokens: Int
    public let outputTokens: Int

    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    public var totalTokens: Int { inputTokens + outputTokens }
}

// MARK: - RemoteTarget

/// A concrete escalation target: a provider + a specific model + where it lives.
public struct RemoteTarget: Sendable {
    public let provider: any RemoteLLMProvider
    public let modelID: String
    /// Trained context length, when known (feeds the compression budget).
    public let contextLength: Int?
    public let origin: Origin

    /// Where the target runs — drives consent friction and cost.
    public enum Origin: Sendable, Hashable {
        /// A hosted cloud provider — full consent + retention disclosure.
        case cloud
        /// The user's own machine (llama-server / Ollama / Magnitude) — light-touch consent, $0.
        case localNetwork(LocalProviderKind)
    }

    public init(provider: any RemoteLLMProvider, modelID: String, contextLength: Int? = nil, origin: Origin) {
        self.provider = provider
        self.modelID = modelID
        self.contextLength = contextLength
        self.origin = origin
    }

    /// `true` when the target runs on the user's own hardware (no data leaves the trust boundary, no cost).
    public var isLocalNetwork: Bool {
        if case .localNetwork = origin { return true }
        return false
    }
}

// MARK: - Cloud presets

extension RemoteTarget {
    /// Default model of the hosted OpenAI target.
    public static let defaultOpenAIModel = "gpt-4o"
    /// Default model of the Anthropic target.
    public static let defaultAnthropicModel = "claude-sonnet-4-5"
    /// Default model of the Gemini target.
    public static let defaultGeminiModel = "gemini-3.5-flash-lite"

    /// Hosted OpenAI (`https://api.openai.com/v1`). Shared by
    /// `HybridEscalator.cloudTargets` and ``AskTargetResolver`` so they cannot drift.
    static func openAI(apiKey: String, model: String) -> RemoteTarget {
        let provider = OpenAICompatibleProvider(
            id: CloudAccount.openAI, displayName: "OpenAI",
            baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: apiKey,
            retentionNote: "Sent to OpenAI's API. See their data-retention policy.")
        return RemoteTarget(provider: provider, modelID: model, contextLength: 128_000, origin: .cloud)
    }

    /// Anthropic's Messages API. Shared like ``openAI(apiKey:model:)``.
    static func anthropic(apiKey: String, model: String) -> RemoteTarget {
        RemoteTarget(
            provider: AnthropicProvider(apiKey: apiKey),
            modelID: model, contextLength: 200_000, origin: .cloud)
    }

    /// Google's Gemini API through its OpenAI-compatible endpoint
    /// (`https://generativelanguage.googleapis.com/v1beta/openai/`, Bearer key). Shared like
    /// ``openAI(apiKey:model:)``. No `temperature` is sent: Google deprecated it on 2026-07-21. The context length is
    /// left unknown and the model is unpriced, so the cost ledger reports it as unknown.
    public static func gemini(apiKey: String, model: String) -> RemoteTarget {
        var provider = OpenAICompatibleProvider(
            id: CloudAccount.gemini, displayName: "Gemini (Google)",
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/")!, apiKey: apiKey,
            retentionNote: "Sent to Google's Gemini API. With a free-tier key Google may use prompts and responses "
                + "to improve its products and human reviewers may read them: don't send sensitive, confidential or "
                + "personal data. Apps offered in the EEA, the UK or Switzerland may use only paid keys.")
        provider.sendsTemperature = false
        return RemoteTarget(provider: provider, modelID: model, contextLength: nil, origin: .cloud)
    }
}

/// Keychain accounts (service `dev.auralocal.remote`) holding the cloud API keys.
enum CloudAccount {
    static let openAI = "cloud.openai"
    static let anthropic = "cloud.anthropic"
    static let gemini = "cloud.gemini"
}
