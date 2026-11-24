import Foundation

/// In-session cache of remote answers, so an identical escalation isn't paid for twice. ``HybridEscalator`` keys it
/// on the provider's ``RemoteLLMProvider/cacheIdentity``, the model, the whole ``EscalationPayload`` and a
/// non-default temperature. Bounded, FIFO-evicted.
/// In-memory only (cleared on relaunch) — a persistent cache is a later step.
@MainActor
public final class ResponseCache {
    public static let shared = ResponseCache()
    public init(capacity: Int = 64) { self.capacity = capacity }

    private let capacity: Int
    private var store: [String: String] = [:]
    private var order: [String] = []

    public var count: Int { store.count }

    /// Return a cached answer for this exact request, if present.
    public func lookup(provider: String, model: String, prompt: String) -> String? {
        store[Self.key(provider, model, prompt)]
    }

    /// Return a cached answer for this exact payload: its messages, the system prompt included, and `maxTokens`.
    /// A non-nil `temperature` is part of the key; nil keys as before it existed.
    public func lookup(
        provider: String, model: String, payload: EscalationPayload, temperature: Float? = nil
    ) -> String? {
        store[Self.key(provider, model, payload, temperature)]
    }

    /// Store an answer for this request (FIFO-evicts the oldest past capacity).
    public func insert(_ answer: String, provider: String, model: String, prompt: String) {
        insert(answer, forKey: Self.key(provider, model, prompt))
    }

    /// Store an answer for this exact payload and `temperature` (FIFO-evicts the oldest past capacity).
    public func insert(
        _ answer: String, provider: String, model: String, payload: EscalationPayload, temperature: Float? = nil
    ) {
        insert(answer, forKey: Self.key(provider, model, payload, temperature))
    }

    public func clear() {
        store.removeAll()
        order.removeAll()
    }

    private func insert(_ answer: String, forKey key: String) {
        if store[key] == nil {
            order.append(key)
            while order.count > capacity, let oldest = order.first {
                order.removeFirst()
                store[oldest] = nil
            }
        }
        store[key] = answer
    }

    private static func key(_ provider: String, _ model: String, _ prompt: String) -> String {
        "\(provider)\u{1}\(model)\u{1}\(prompt)"
    }

    /// The leading NUL keeps these apart from `prompt:` keys, and the system prompt's length keeps its boundary with
    /// the user message unambiguous; `nil` sends no system message, so it differs from "".
    private static func key(
        _ provider: String, _ model: String, _ payload: EscalationPayload, _ temperature: Float?
    ) -> String {
        let system = payload.systemPrompt.map { "\($0.utf8.count):\($0)" } ?? "-"
        // The bit pattern, not a decimal rendering, so 0.2 never collides with a value that prints alike.
        let sampling = temperature.map { "t\($0.bitPattern)" } ?? ""
        return key(provider, model, "\u{0}\(payload.maxTokens)\(sampling)\u{1}\(system)\u{1}\(payload.userMessage)")
    }
}
