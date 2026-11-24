import Foundation
import FoundationModels

// MARK: - AISessionError

@available(iOS 27, macOS 27, visionOS 27, *)
public enum AISessionError: LocalizedError, Equatable {
    case modelUnavailable(reason: String)
    /// The on-device model's assets are missing or still downloading.
    case assetsUnavailable(String)
    case guardrailViolation(String)
    case refusal(String)
    case contextWindowExceeded(limit: Int, tokenCount: Int)
    /// The language of the prompt or the locale is not supported; carries the language code.
    case unsupportedLanguage(String)
    case rateLimited(resetDate: Date?)
    case timeout
    case concurrentRequest
    case generationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable(let reason):
            return "Apple Intelligence unavailable: \(reason)"
        case .assetsUnavailable:
            return "The on-device model is not ready yet. Try again later."
        case .guardrailViolation(let detail):
            return "Content triggered safety filters: \(detail)"
        case .refusal(let detail):
            return "The model declined the request: \(detail)"
        case .contextWindowExceeded(let limit, let tokenCount):
            return "Context window exceeded (\(tokenCount) of \(limit) tokens). Try a shorter prompt or start a new session."
        case .unsupportedLanguage(let language):
            return "The language or locale is not supported (\(language))."
        case .rateLimited:
            return "Too many requests. Please wait a moment."
        case .timeout:
            return "The model took too long to answer."
        case .concurrentRequest:
            return "Another request is already in progress."
        case .generationFailed(let detail):
            return "Generation failed: \(detail)"
        }
    }

    /// Maps the FoundationModels OS 27 errors into `AISessionError`; any other error (a tool's
    /// `ToolCallError`, `CancellationError`) is returned unchanged.
    static func mapped(_ error: any Error) -> any Error {
        switch error {
        case let model as LanguageModelError:
            return mapped(model)
        case let system as SystemLanguageModel.Error:
            switch system {
            case .assetsUnavailable(let detail): return AISessionError.assetsUnavailable(detail.debugDescription)
            @unknown default: return AISessionError.generationFailed(String(describing: system))
            }
        case let session as LanguageModelSession.Error:
            switch session {
            case .concurrentRequests, .transcriptMutationWhileResponding: return AISessionError.concurrentRequest
            @unknown default: return AISessionError.generationFailed(String(describing: session))
            }
        case let parsing as GeneratedContent.ParsingError:
            return AISessionError.generationFailed(parsing.debugDescription)
        default:
            return error
        }
    }

    private static func mapped(_ error: LanguageModelError) -> AISessionError {
        switch error {
        case .contextSizeExceeded(let exceeded):
            return .contextWindowExceeded(limit: exceeded.contextSize, tokenCount: exceeded.tokenCount)
        case .guardrailViolation(let detail):
            return .guardrailViolation(detail.debugDescription)
        case .refusal(let detail):
            return .refusal(detail.debugDescription)
        case .unsupportedLanguageOrLocale(let detail):
            return .unsupportedLanguage(detail.languageCode.identifier)
        case .rateLimited(let detail):
            return .rateLimited(resetDate: detail.resetDate)
        case .timeout:
            return .timeout
        case .unsupportedCapability(let detail):
            return .generationFailed(detail.debugDescription)
        case .unsupportedTranscriptContent(let detail):
            return .generationFailed(detail.debugDescription)
        case .unsupportedGenerationGuide(let detail):
            return .generationFailed(detail.debugDescription)
        @unknown default:
            return .generationFailed(error.debugDescription)
        }
    }
}

// MARK: - AISession
//
// Wraps LanguageModelSession with a clean API aligned with Tonamox conventions.
// Requires iOS 27 / macOS 27 / visionOS 27 with Apple Intelligence enabled.
//
// §Fix #20: Validates availability before creating session.
// §Fix #21: Maps the OS 27 FoundationModels errors to typed AISessionError.
// §Fix #22: Stream emits deltas instead of accumulated content.

@available(iOS 27, macOS 27, visionOS 27, *)
public final class AISession: @unchecked Sendable {

    // MARK: - Public state

    /// True while the model is generating a response.
    public var isResponding: Bool { session.isResponding }

    /// Full conversation transcript — use to restore sessions.
    public var transcript: Transcript { session.transcript }

    // MARK: - Private

    private let session: LanguageModelSession

    // MARK: - Init

    /// Create a session with optional system instructions and tools.
    ///
    /// §Fix #20: Checks `SystemLanguageModel.default.availability` before creating
    /// the session. Throws `AISessionError.modelUnavailable` if not available.
    public init(
        instructions: String? = nil,
        tools: [any Tool] = [],
        useCase: SystemLanguageModel.UseCase? = nil
    ) throws {
        // §Fix #20: Always verify availability before session creation
        let availability = SystemLanguageModel.default.availability
        guard case .available = availability else {
            let reason: String
            if case .unavailable(let r) = availability {
                reason = String(describing: r)
            } else {
                reason = "Unknown"
            }
            throw AISessionError.modelUnavailable(reason: reason)
        }

        let model = useCase.map { SystemLanguageModel(useCase: $0) } ?? SystemLanguageModel.default
        if let instructions {
            self.session = LanguageModelSession(model: model, tools: tools) { instructions }
        } else {
            self.session = LanguageModelSession(model: model, tools: tools)
        }
    }

    /// Restore a session from a saved transcript.
    public init(transcript: Transcript, tools: [any Tool] = []) throws {
        let availability = SystemLanguageModel.default.availability
        guard case .available = availability else {
            let reason: String
            if case .unavailable(let r) = availability {
                reason = String(describing: r)
            } else {
                reason = "Unknown"
            }
            throw AISessionError.modelUnavailable(reason: reason)
        }

        self.session = LanguageModelSession(
            model:      SystemLanguageModel.default,
            tools:      tools,
            transcript: transcript
        )
    }

    // MARK: - Plain text

    /// Send a prompt and await the full response.
    /// §Fix #21: Wraps FoundationModels errors into typed AISessionError.
    public func respond(
        to prompt: String,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> String {
        do {
            let response = try await session.respond(to: prompt, options: options)
            return response.content
        } catch {
            throw AISessionError.mapped(error)
        }
    }

    /// Stream a plain-text response, yielding incremental **deltas** (not accumulated).
    /// §Fix #22: Computes deltas by tracking previous content length.
    public func stream(
        _ prompt: String,
        options: GenerationOptions = GenerationOptions()
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.streamDeltas(prompt, options: options) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // A session takes one request at a time; an abandoned response would refuse the next one.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Like ``stream(_:options:)``, but generates in the calling task and returns or throws only once the model
    /// stopped, so a caller can hold a lock for exactly the generation. Cancel the calling task to stop it.
    public func streamDeltas(
        _ prompt: String,
        options: GenerationOptions = GenerationOptions(),
        onDelta: @Sendable (String) -> Void
    ) async throws {
        do {
            var previousContent = ""
            for try await partial in session.streamResponse(to: prompt, options: options) {
                let currentContent = partial.content
                if currentContent.count > previousContent.count {
                    onDelta(String(currentContent.dropFirst(previousContent.count)))
                }
                previousContent = currentContent
            }
        } catch {
            throw AISessionError.mapped(error)
        }
    }

    // MARK: - Guided generation

    /// Generate a typed Swift value using @Generable structured output.
    public func respond<T: Generable>(
        to prompt: String,
        generating type: T.Type,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> T {
        do {
            let response = try await session.respond(
                to: prompt,
                generating: type,
                options: options
            )
            return response.content
        } catch {
            throw AISessionError.mapped(error)
        }
    }

    /// Stream a structured response, yielding partial snapshots as fields fill in.
    public func stream<T: Generable>(
        _ prompt: String,
        generating type: T.Type,
        options: GenerationOptions = GenerationOptions()
    ) -> AsyncThrowingStream<T.PartiallyGenerated, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let stream = session.streamResponse(
                        to: prompt,
                        generating: type,
                        options: options
                    )
                    for try await partial in stream {
                        nonisolated(unsafe) let value = partial.content
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AISessionError.mapped(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Prewarming

    /// Preload the model into memory before the first request.
    public func prewarm() {
        session.prewarm()
    }
}

// MARK: - AIAgent
//
// A single agent with a role, instructions, and a set of tools.
// Analogous to a CrewAI Agent — has a defined responsibility and
// can call tools to gather information before responding.

@available(iOS 27, macOS 27, visionOS 27, *)
public struct AIAgent {

    public let role:         String
    public let instructions: String
    public let tools:        [any Tool]
    public let options:      GenerationOptions

    private let session: AISession

    /// §Fix #20: init is now throwing because AISession verifies availability.
    public init(
        role:         String,
        instructions: String,
        tools:        [any Tool] = [],
        options:      GenerationOptions = GenerationOptions()
    ) throws {
        self.role         = role
        self.instructions = instructions
        self.tools        = tools
        self.options      = options
        self.session      = try AISession(instructions: instructions, tools: tools)
        self.session.prewarm()
    }

    /// Run the agent and return the full response.
    public func run(_ input: String) async throws -> String {
        try await session.respond(to: input, options: options)
    }

    /// Run the agent and stream incremental response deltas.
    public func stream(_ input: String) -> AsyncThrowingStream<String, Error> {
        session.stream(input, options: options)
    }

    /// Run the agent and produce a typed structured output.
    public func run<T: Generable>(_ input: String, generating type: T.Type) async throws -> T {
        try await session.respond(to: input, generating: type, options: options)
    }
}

// MARK: - AIPipeline
//
// Orchestrates a sequential chain of AIAgents.
// Each agent's output becomes the next agent's input.
// Analogous to CrewAI's Crew with Process.sequential.

@available(iOS 27, macOS 27, visionOS 27, *)
public final class AIPipeline: @unchecked Sendable {

    public let agents: [AIAgent]

    /// Step-by-step outputs from each agent in the last run.
    public private(set) var stepOutputs: [(role: String, output: String)] = []

    public init(agents: [AIAgent]) {
        precondition(!agents.isEmpty, "AIPipeline requires at least one agent")
        self.agents = agents
    }

    /// Execute all agents sequentially. Returns the final agent's output.
    public func run(
        input: String,
        onStep: ((String, String) -> Void)? = nil
    ) async throws -> String {
        stepOutputs = []
        var current = input
        for agent in agents {
            let output = try await agent.run(current)
            stepOutputs.append((role: agent.role, output: output))
            onStep?(agent.role, output)
            current = output
        }
        return current
    }

    /// Execute agents sequentially, streaming the final agent's output.
    /// All agents except the last run to completion first.
    public func stream(
        input: String,
        onStep: (@Sendable (String, String) -> Void)? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    self.stepOutputs = []
                    var current = input
                    for agent in self.agents.dropLast() {
                        let output = try await agent.run(current)
                        self.stepOutputs.append((role: agent.role, output: output))
                        onStep?(agent.role, output)
                        current = output
                    }
                    if let last = self.agents.last {
                        var full = ""
                        for try await token in last.stream(current) {
                            full += token
                            continuation.yield(token)
                        }
                        self.stepOutputs.append((role: last.role, output: full))
                        onStep?(last.role, full)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - AIAvailability

@available(iOS 27, macOS 27, visionOS 27, *)
public enum AIAvailability {

    public enum Status: Equatable {
        case available
        case unavailable(reason: String)
    }

    public static var status: Status {
        switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                return .unavailable(reason: String(describing: reason))
            @unknown default:
                return .unavailable(reason: "Unknown availability state")
        }
    }

    public static var isAvailable: Bool { status == .available }
}

// MARK: - AIAvailabilityGate (SwiftUI)

#if canImport(SwiftUI)
import SwiftUI

/// Gate view — shows content only when Apple Intelligence is available.
@available(iOS 27, macOS 27, visionOS 27, *)
public struct AIAvailabilityGate<Content: View>: View {
    let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        switch SystemLanguageModel.default.availability {
            case .available:
                content()
            case .unavailable(let reason):
                ContentUnavailableView {
                    Label("Apple Intelligence Unavailable", systemImage: "sparkles.slash")
                } description: {
                    Text(unavailableMessage(for: reason))
                }
            @unknown default:
                ContentUnavailableView("Unavailable", systemImage: "exclamationmark.triangle")
        }
    }

    private func unavailableMessage(
        for reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> String {
        switch reason {
            case .deviceNotEligible:
                return "This feature requires an Apple Intelligence-compatible device."
            case .appleIntelligenceNotEnabled:
                return "Enable Apple Intelligence in Settings → Apple Intelligence & Siri."
            case .modelNotReady:
                return "The on-device model is still downloading. Try again shortly."
            @unknown default:
                return "Apple Intelligence is currently unavailable."
        }
    }
}
#endif
