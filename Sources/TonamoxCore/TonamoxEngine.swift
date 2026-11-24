import Foundation
import LocalLLMClientCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - TonamoxEngine

/// Unified internal engine that delegates inference to an ``InferenceBackend``.
///
/// By default uses ``MLXBackend`` for models in MLX format.
/// ``BackendRouter`` can select alternative backends (llama.cpp, layer-streaming)
/// based on model format and device capabilities.
@MainActor
final class TonamoxEngine {

    // MARK: - State

    let backend: any InferenceBackend
    let model: Model
    /// Copied from the backend when a call returns and cleared when one starts, so a call that throws before
    /// decoding cannot leave the previous call's numbers behind.
    private(set) var lastGenerationStats: GenerationStats?
    /// Kept the same way as ``lastGenerationStats``.
    private(set) var lastContextOverflow: ContextWindowOverflow?
    let appLifecycle: BackgroundLifecycle
    /// Opt-in guard checked before and during every generation; `nil` is off.
    var deviceGuard: DeviceConditions?
    /// Forwarded to a backend that runs the tool loop; others ignore it.
    var toolLoop = ToolLoopOptions.default {
        didSet { if let host = backend as? any ToolLoopHost { host.toolLoop = toolLoop } }
    }
    var onToolEvent: (@MainActor (ToolEvent) -> Void)? {
        didSet { if let host = backend as? any ToolLoopHost { host.onToolEvent = onToolEvent } }
    }
    /// Kept the same way as ``lastGenerationStats``.
    private(set) var lastToolTurn: ToolTurnSummary?
    /// What text generations without explicit options reason with; backends without reasoning control ignore it.
    var reasoning = ReasoningOptions.automatic
    /// Kept the same way as ``lastGenerationStats``.
    private(set) var lastReasoningTurn: ReasoningTurn?
    /// The backend was built with tools, so a prompt can make it call them.
    let toolsEnabled: Bool

    // MARK: - Init

    init(model: Model, sampling: SamplingSettings? = nil, tools: [any LLMTool] = [],
         lifecycle: BackgroundLifecycle = .shared) {
        self.model = model
        self.backend = BackendRouter.selectBackend(for: model, sampling: sampling, tools: tools)
        self.appLifecycle = lifecycle
        self.toolsEnabled = !tools.isEmpty
    }

    /// Create an engine with a specific backend (used by BackendRouter for GGUF models).
    init(model: Model, backend: any InferenceBackend, lifecycle: BackgroundLifecycle = .shared,
         toolsEnabled: Bool = false) {
        self.model = model
        self.backend = backend
        self.appLifecycle = lifecycle
        self.toolsEnabled = toolsEnabled
    }

    // MARK: - Load

    func load(onProgress: @escaping @MainActor (String) -> Void) async throws {
        appLifecycle.startObserving()
        try await backend.load(onProgress: onProgress)
    }

    // MARK: - Generate (text-only)

    func generate(
        prompt: String,
        systemPrompt: String? = nil,
        maxTokens: Int = 1024,
        constraint: GenerationConstraint? = nil,
        reasoning explicit: ReasoningOptions? = nil,
        onToken: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let reasoning = explicit ?? self.reasoning
        return try await recordingStats(onToken: onToken) { [self] onToken in
            if let constraint {
                return try await backend.generate(
                    prompt: prompt,
                    systemPrompt: systemPrompt,
                    maxTokens: maxTokens,
                    constraint: constraint,
                    onToken: onToken
                )
            }
            if let host = backend as? any ReasoningControlHost {
                return try await host.generate(prompt: prompt, systemPrompt: systemPrompt, maxTokens: maxTokens,
                                               reasoning: reasoning, onToken: onToken)
            }
            return try await backend.generate(
                prompt: prompt,
                systemPrompt: systemPrompt,
                maxTokens: maxTokens,
                onToken: onToken
            )
        }
    }

    // MARK: - Generate (vision)

    func generate(
        prompt: String,
        image: PlatformImage?,
        maxTokens: Int = 800,
        onToken: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        try await recordingStats(onToken: onToken) { [self] onToken in
            try await backend.generate(
                prompt: prompt,
                image: image,
                maxTokens: maxTokens,
                onToken: onToken
            )
        }
    }

    // MARK: - Generate (multi-turn messages)

    func generate(
        messages: [[String: String]],
        maxTokens: Int = 1024,
        reasoning explicit: ReasoningOptions? = nil,
        onToken: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let reasoning = explicit ?? self.reasoning
        return try await recordingStats(onToken: onToken) { [self] onToken in
            if let host = backend as? any ReasoningControlHost {
                return try await host.generate(messages: messages, maxTokens: maxTokens, reasoning: reasoning,
                                               onToken: onToken)
            }
            return try await backend.generate(
                messages: messages,
                maxTokens: maxTokens,
                onToken: onToken
            )
        }
    }

    private func recordingStats(
        onToken: @escaping @MainActor (String) -> Void,
        _ body: @escaping @MainActor (_ onToken: @escaping @MainActor (String) -> Void) async throws -> String
    ) async throws -> String {
        lastGenerationStats = nil
        lastContextOverflow = nil
        lastToolTurn = nil
        lastReasoningTurn = nil
        let reply = try await supervised(onToken: onToken, body)
        lastGenerationStats = backend.lastGenerationStats
        lastContextOverflow = backend.lastContextOverflow
        lastToolTurn = (backend as? any ToolLoopHost)?.lastToolTurn
        lastReasoningTurn = (backend as? any ReasoningControlHost)?.lastReasoningTurn
        return reply
    }

    var reasoningSupport: ReasoningCapabilities {
        (backend as? any ReasoningControlHost)?.reasoningSupport ?? .unsupported
    }

    /// A host's `nil` is an answer (thinking disabled closes the block in the prompt), not a reason to fall back.
    func promptOpenedReasoningTag(for options: ReasoningOptions) -> String? {
        if let host = backend as? any ReasoningControlHost { return host.promptOpenedReasoningTag(for: options) }
        return (backend as? any PromptReasoningReporting)?.promptOpenedReasoningTag
    }

    // MARK: - Cleanup

    func unload() {
        backend.unload()
    }
}
