import Foundation
import LocalLLMClient

// MARK: - IncompatibleGGUFError

/// A GGUF the bundled llama.cpp failed to load, with the compatibility blocker its header raises. Thrown in place of
/// LocalLLMClient's generic "Failed to load model from file", which drops llama.cpp's own reason: the blocker comes
/// from the header alone, so a file that is also broken in another way names it too. A separate type rather than a
/// ``TonamoxError`` case, like ``ModelDownloadError``, so exhaustive switches over ``TonamoxError`` keep compiling.
public struct IncompatibleGGUFError: LocalizedError, Equatable, Sendable {
    /// The file's name.
    public let filename: String
    /// The `gguf.architecture` blockers the file's header raised.
    public let blockers: [CompatibilityFinding]
    /// The load error llama.cpp reported through LocalLLMClient.
    public let underlyingMessage: String

    public var errorDescription: String? {
        let reasons = blockers.map { "\($0.title). \($0.detail)" }.joined(separator: " ")
        return "\(filename) failed to load. Its header shows a known blocker for the bundled llama.cpp: \(reasons) "
            + "Underlying error: \(underlyingMessage)"
    }
}

// MARK: - GGUFLoadDiagnosis

/// Explains a GGUF load that already failed, with the rules that describe what the pinned llama.cpp cannot load.
/// It runs only after a failure, so a rule left stale by a llama.cpp bump never blocks a load that would succeed.
enum GGUFLoadDiagnosis {

    static let rules = [CompatibilityRules.ggufArchitectureRule]

    /// An ``IncompatibleGGUFError`` when `error` is LocalLLMClient's load failure and a rule blocks `url`'s header;
    /// otherwise `error` itself. `async` so the read leaves the main actor the GGUF loaders are called on.
    static func explained(_ error: any Error, loading url: URL) async -> any Error {
        guard case .failedToLoad? = error as? LLMError,
              let header = header(at: url, byteCount: ModelCompatibilityChecker.defaultGGUFHeaderBytes)
        else { return error }
        let found = blockers(for: header, path: url.lastPathComponent)
        guard !found.isEmpty else { return error }
        return IncompatibleGGUFError(filename: url.lastPathComponent, blockers: found,
                                     underlyingMessage: error.localizedDescription)
    }

    /// The header in the first `byteCount` bytes of `url`; `nil` when the file cannot be read or is not a GGUF.
    static func header(at url: URL, byteCount: Int) -> GGUFHeader? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: byteCount) else { return nil }
        return try? GGUFHeaderParser.parse(data)
    }

    /// The blockers ``rules`` raise for a local file's header.
    static func blockers(for header: GGUFHeader, path: String) -> [CompatibilityFinding] {
        // The rule does not read the target; `thisDevice()` would measure memory and resolve the host name for nothing.
        let input = RuleInput(localGGUF: header, path: path, target: .mac32GB)
        // The pinned loader accepts these, so their only blocker ("not a chat model") does not explain a failed load.
        let knownArchitecture = header.architecture.map(PinnedRuntimes.llamaCppArchitectures.contains) ?? false
        return rules.flatMap { $0.findings(for: input) }.filter { finding in
            finding.level == .blocker
                && !(knownArchitecture && finding.rule == CompatibilityRules.ggufArchitectureRule.id)
        }
    }
}
