import Foundation
import TonamoxAppleIntelligence
import TonamoxCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Produces one reply for one prompt. v1 is single-turn: no engine receives history.
protocol ReplyEngine: AnyObject {
    /// Loads whatever the engine needs, then returns the reply stream. Cancel the consuming task to stop it.
    func reply(to prompt: String, progress: @escaping @MainActor (String) -> Void) async throws
        -> AsyncThrowingStream<String, Error>
    /// Cancels a load still in progress.
    func cancelLoad()
}

enum ReplyEngines {
    static let temperature: Float = 0.2
    static let maxTokens = 400

    static func make(for choice: ModelChoice) throws -> any ReplyEngine {
        switch choice.kind {
        case .onDisk:
            return TonamoxReplyEngine(choiceID: choice.id)
        case .appleIntelligence:
            guard #available(iOS 26, *) else { throw CatalogError.appleNeedsNewerSystem }
            return AppleReplyEngine()
        #if DEBUG
        case .echo:
            return EchoReplyEngine()
        #endif
        }
    }
}

/// A model from disk through ModelManager. GGUF is a `.localFile` model: a missing file fails, never downloads.
final class TonamoxReplyEngine: ReplyEngine {
    private let choiceID: String
    private var loading: Model?

    init(choiceID: String) {
        self.choiceID = choiceID
    }

    func reply(to prompt: String, progress: @escaping @MainActor (String) -> Void) async throws
        -> AsyncThrowingStream<String, Error> {
        let weights = try LocalModelCatalog.readyModel(for: choiceID)
        loading = weights
        defer { loading = nil }
        let llm = try await ModelManager.shared.load(
            weights,
            temperature: ReplyEngines.temperature,
            onProgress: progress
        )
        // A cancelled load can still return an instance; don't generate with it.
        try Task.checkCancellation()
        return llm.stream(prompt, systemPrompt: TerminalSystemPrompt.text, maxTokens: ReplyEngines.maxTokens)
    }

    func cancelLoad() {
        guard let loading else { return }
        ModelManager.shared.cancelLoad(loading)
    }
}

@available(iOS 26, *)
final class AppleReplyEngine: ReplyEngine {
    func reply(to prompt: String, progress: @escaping @MainActor (String) -> Void) async throws
        -> AsyncThrowingStream<String, Error> {
        let session = try AISession(instructions: TerminalSystemPrompt.text)
        #if canImport(FoundationModels)
        let options = GenerationOptions(
            temperature: Double(ReplyEngines.temperature),
            maximumResponseTokens: ReplyEngines.maxTokens
        )
        return session.stream(prompt, options: options)
        #else
        return session.stream(prompt)
        #endif
    }

    func cancelLoad() {}
}

#if DEBUG
/// Deterministic engine for the end-to-end test: the prompt comes back as a one-line bash block.
final class EchoReplyEngine: ReplyEngine {
    static func echoReply(for prompt: String) -> String {
        "```bash\n" + prompt + "\n```"
    }

    func reply(to prompt: String, progress: @escaping @MainActor (String) -> Void) async throws
        -> AsyncThrowingStream<String, Error> {
        let text = Self.echoReply(for: prompt)
        return AsyncThrowingStream { continuation in
            continuation.yield(text)
            continuation.finish()
        }
    }

    func cancelLoad() {}
}
#endif
