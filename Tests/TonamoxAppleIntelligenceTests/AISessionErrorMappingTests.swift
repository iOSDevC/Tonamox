import Foundation
import Testing
import FoundationModels
@testable import TonamoxAppleIntelligence

@Suite struct AISessionErrorMappingTests {
    @Test func currentModelErrorsMapToSessionErrors() {
        guard #available(macOS 27, iOS 27, visionOS 27, *) else { return }
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let exceeded = LanguageModelError.ContextSizeExceeded(contextSize: 4096, tokenCount: 5000, debugDescription: "t")
        let cases: [(any Error, AISessionError)] = [
            (LanguageModelError.contextSizeExceeded(exceeded), .contextWindowExceeded(limit: 4096, tokenCount: 5000)),
            (LanguageModelError.guardrailViolation(.init(debugDescription: "g")), .guardrailViolation("g")),
            (LanguageModelError.refusal(.init(explanation: "no", debugDescription: "r")), .refusal("r")),
            (LanguageModelError.unsupportedLanguageOrLocale(.init(languageCode: .init("xx"), debugDescription: "t")),
             .unsupportedLanguage("xx")),
            (LanguageModelError.rateLimited(.init(resetDate: reset, debugDescription: "t")), .rateLimited(resetDate: reset)),
            (LanguageModelError.timeout(.init(debugDescription: "t")), .timeout),
            (LanguageModelError.unsupportedGenerationGuide(.init(schemaName: nil, debugDescription: "guide")),
             .generationFailed("guide")),
            (SystemLanguageModel.Error.assetsUnavailable(.init(debugDescription: "a")), .assetsUnavailable("a")),
            (LanguageModelSession.Error.concurrentRequests, .concurrentRequest),
            (LanguageModelSession.Error.transcriptMutationWhileResponding, .concurrentRequest),
            (GeneratedContent.ParsingError(rawContent: "{", debugDescription: "p"), .generationFailed("p"))
        ]
        for (error, expected) in cases {
            #expect(AISessionError.mapped(error) as? AISessionError == expected)
        }
    }

    @Test func otherErrorsPassThroughUnmapped() {
        guard #available(macOS 27, iOS 27, visionOS 27, *) else { return }
        #expect(AISessionError.mapped(CancellationError()) is CancellationError)
        let mapped = AISessionError.mapped(AISessionError.timeout)
        #expect(mapped as? AISessionError == .timeout)
    }

    @Test func contextWindowDescriptionNamesTheLimit() {
        guard #available(macOS 27, iOS 27, visionOS 27, *) else { return }
        let description = AISessionError.contextWindowExceeded(limit: 4096, tokenCount: 5000).errorDescription
        #expect(description?.contains("4096") == true)
        #expect(description?.contains("5000") == true)
    }
}
