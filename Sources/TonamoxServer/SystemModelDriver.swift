#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// ``AppleModelDriver`` over `SystemLanguageModel.default`.
@available(iOS 27, macOS 27, visionOS 27, *)
@MainActor
struct SystemModelDriver: AppleModelDriver {
    let temperature: Double?

    static var isAvailable: Bool {
        guard case .available = SystemLanguageModel.default.availability else { return false }
        return true
    }

    var contextSize: Int { SystemLanguageModel.default.contextSize }

    func generate(_ plan: AppleChatPlan, snapshot: (String) -> Void) async throws -> ServedUsage? {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { throw ServedModelError.notLoaded }
        let session = LanguageModelSession(model: model, tools: [], transcript: Self.transcript(for: plan))
        let options = GenerationOptions(samplingMode: nil, temperature: temperature,
                                        maximumResponseTokens: plan.maxTokens)
        var usage: ServedUsage?
        do {
            for try await partial in session.streamResponse(to: plan.prompt, options: options) {
                try Task.checkCancellation()
                snapshot(partial.content)
                usage = Self.usage(of: partial)
            }
        } catch {
            throw Self.failure(from: error, usage: usage)
        }
        return usage
    }

    nonisolated static func transcript(for plan: AppleChatPlan) -> Transcript {
        var entries: [Transcript.Entry] = []
        if let instructions = plan.instructions {
            entries.append(.instructions(Transcript.Instructions(segments: [segment(instructions)],
                                                                 toolDefinitions: [])))
        }
        entries += plan.history.map(entry(for:))
        return Transcript(entries: entries)
    }

    nonisolated static func entry(for turn: ServedMessage) -> Transcript.Entry {
        switch turn.role {
        case .assistant:
            .response(Transcript.Response(assetIDs: [], segments: [segment(turn.content)]))
        case .user, .system:
            .prompt(Transcript.Prompt(segments: [segment(turn.content)]))
        }
    }

    nonisolated static func segment(_ text: String) -> Transcript.Segment {
        .text(Transcript.TextSegment(content: text))
    }

    /// A zero output count means the framework did not fill the snapshot's usage in.
    nonisolated static func usage(of partial: LanguageModelSession.ResponseStream<String>.Snapshot) -> ServedUsage? {
        let counts = partial.usage
        guard counts.output.totalTokenCount > 0 else { return nil }
        return ServedUsage(promptTokens: counts.input.totalTokenCount,
                           completionTokens: counts.output.totalTokenCount)
    }

    /// Anything unmapped is returned as is and served as an internal error, never with its text. `usage` is the last
    /// snapshot's, kept when the safety rules stop the answer.
    nonisolated static func failure(from error: any Error, usage: ServedUsage? = nil) -> any Error {
        switch error as? LanguageModelError {
        case .guardrailViolation?, .refusal?: return AppleContentFiltered(usage: usage)
        default: return mapped(error) ?? error
        }
    }

    /// Guardrail violations and refusals are no ``ServedModelError``: ``failure(from:usage:)`` ends the answer.
    nonisolated static func mapped(_ error: any Error) -> ServedModelError? {
        switch error {
        case let model as LanguageModelError:
            switch model {
            case .contextSizeExceeded(let exceeded): return .contextLengthExceeded(limit: exceeded.contextSize)
            case .guardrailViolation, .refusal: return nil
            case .unsupportedLanguageOrLocale: return .unsupportedLanguage
            case .rateLimited, .timeout: return .busy
            case .unsupportedCapability, .unsupportedTranscriptContent, .unsupportedGenerationGuide: return nil
            @unknown default: return nil
            }
        case let system as SystemLanguageModel.Error:
            switch system {
            case .assetsUnavailable: return .notLoaded
            @unknown default: return nil
            }
        case let session as LanguageModelSession.Error:
            switch session {
            case .concurrentRequests: return .busy
            case .transcriptMutationWhileResponding: return nil
            @unknown default: return nil
            }
        default:
            return nil
        }
    }
}
#endif
