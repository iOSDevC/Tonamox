import LocalLLMClient

/// Recognises a failed `llama_decode` for modules that do not link LocalLLMClient.
package enum LlamaDecodeFailure {
    /// `true` when llama.cpp refused a decode for a reason other than a full window (``GGUFPromptFitter`` owns
    /// that case): the model could not run the turn, which the request did not cause.
    package static func matches(_ error: any Error) -> Bool {
        guard case .failedToDecode? = error as? LLMError else { return false }
        return GGUFPromptFitter.overflowedTokens(in: error, windowSize: 0) == nil
    }
}
