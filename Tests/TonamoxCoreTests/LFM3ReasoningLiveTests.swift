import LocalLLMClient
@testable import LocalLLMClientLlama
import XCTest
@testable import TonamoxCore

/// Opt-in: `TONAMOX_LFM3_GGUF=/path/to/LFM3-1.7B-…gguf swift test --filter LFM3ReasoningLiveTests`. LFM3's template
/// reads `enable_thinking` and opens `<think>` in the prompt, and the model can reason past any small budget.
@MainActor
final class LFM3ReasoningLiveTests: XCTestCase {
    private static let question = "¿Qué número octal de chmod corresponde a rwxr-xr--? Solo el número."

    func testTemplateCanDisableThinking() async throws {
        let renderer = await GGUFTurnEngines.renderer(for: try modelURL(), tools: [])
        let profile = GGUFReasoningProfile(renderer: renderer)

        XCTAssertTrue(profile.canDisableThinking)
        XCTAssertEqual(profile.openedTag, "<think>")
        XCTAssertNil(profile.openedTagWithoutThinking)
        let off = try renderer.thinking(disabled: true).render([.user("Hi")])
        XCTAssertTrue(off.hasSuffix("<think></think>"), off)
    }

    func testThinkingOffAnswersDirectly() async throws {
        let (engine, profile) = try await makeEngine()
        var text = ""
        let reply = try await engine.respond(to: [.user(Self.question)], maxTokens: 64,
                                             reasoning: profile.plan(for: .disabled), shouldStop: nil) { text += $0 }
        let split = ReasoningSplitter.split(text)
        print("---- thinking off: \(reply.reasoning.map(String.init(describing:)) ?? "-")\n\(text)\n----")

        XCTAssertFalse(split.hasReasoning, text)
        XCTAssertFalse(split.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertEqual(reply.reasoning?.renderedWithoutThinking, true)
        XCTAssertEqual(reply.reasoning?.wasCut, false)
    }

    func testBudgetClosesTheReasoningAndTheAnswerFollows() async throws {
        let (engine, profile) = try await makeEngine()
        var text = ""
        let reply = try await engine.respond(to: [.user(Self.question)], maxTokens: 128,
                                             reasoning: profile.plan(for: .budgeted(256)), shouldStop: nil) {
            text += $0
        }
        var splitter = ReasoningSplitter()
        _ = splitter.consume("<think>")
        _ = splitter.consume(text)
        _ = splitter.finish()
        let turn = try XCTUnwrap(reply.reasoning)
        print("---- budget 256: \(turn)\n\(splitter.answer)\n----")

        XCTAssertFalse(splitter.isReasoningUnterminated, text)
        XCTAssertFalse(splitter.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text)
        XCTAssertLessThanOrEqual(turn.reasoningTokens, 257)
        XCTAssertLessThanOrEqual(turn.answerTokens, 128)
        if turn.wasCut { XCTAssertFalse(text.contains("Considering the limited time"), text) }
    }

    func testBackendReportsTheWindowItLoadedWith() async throws {
        let url = try modelURL()
        let model = try XCTUnwrap(Model.from(.localFile(url)))
        let llm = Tonamox(model: model)
        XCTAssertNil(llm.contextWindow)
        try await llm.engine.load { _ in }
        let backend = try XCTUnwrap(llm.engine.backend as? LlamaCppBackend)
        addTeardownBlock { @MainActor in
            llm.engine.unload()
            await backend.awaitRelease()
        }
        let engine = try XCTUnwrap(backend.turnEngine as? LlamaTurnEngine)
        _ = try await engine.respond(to: [.user("Hola")], maxTokens: 1, shouldStop: nil) { _ in }
        try await engine.waitForDecoder()
        let window = try XCTUnwrap(llm.contextWindow)
        print("---- contextWindow: \(window)")
        XCTAssertEqual(window, engine.contextForTesting?.parameter.context)
        backend.unload()
        XCTAssertNil(llm.contextWindow)
    }

    /// The Terminal chat bounds a turn's budgets with one token per two UTF-8 bytes plus 128 for the template
    /// (`ReplyBudget.estimatedPromptTokens`); this measures that bound against LFM3's own tokenizer.
    func testTerminalPromptEstimateIsAnUpperBound() async throws {
        let (engine, _) = try await makeEngine()
        let empty = try await promptTokens([.user("")], on: engine)
        for sample in [Self.prose, Self.shellOutput] {
            let alone = try await promptTokens([.user(sample)], on: engine) - empty
            print("---- alone: \(sample.utf8.count) bytes, \(alone) tokens")
            let tokens = try await promptTokens([.system(Self.prose), .user(sample)], on: engine)
            let bytes = Self.prose.utf8.count + sample.utf8.count
            print("---- with system: \(bytes) bytes, \(tokens) tokens")
            XCTAssertLessThanOrEqual(tokens, (bytes + 1) / 2 + 128)
        }
    }

    private func promptTokens(_ messages: [LlamaChatMessage], on engine: LlamaTurnEngine) async throws -> Int {
        _ = try await engine.respond(to: messages, maxTokens: 1, shouldStop: nil) { _ in }
        try await engine.waitForDecoder()
        return Int(try XCTUnwrap(engine.contextForTesting?.position))
    }

    private static let prose = """
        Eres un asistente de terminal para un Mac con Apple Silicon. El shell es zsh y las herramientas son las \
        versiones BSD que trae macOS (por ejemplo sed -i '', stat -f, date -v); no uses opciones que solo existen \
        en GNU. Responde en español con una o dos frases cortas. Pon las órdenes en un único bloque de código que \
        empiece exactamente con la línea ```bash. No uses sudo salvo que el usuario lo pida. Prefiere órdenes de \
        solo lectura. Si algo borra o sobrescribe, muestra antes una orden que enseñe qué se verá afectado.
        """

    private static let shellOutput = """
        <<<SALIDA-1a2b3c4d
        total 1688
        drwxr-xr-x  12 devuser     staff     384 19 nov 10:02 .
        drwxr-xr-x+ 48 devuser     staff    1536 18 nov 22:41 ..
        -rw-r--r--@  1 devuser     staff   10244 19 nov 09:58 .DS_Store
        -rwxr-xr-x   1 devuser     staff    2201 12 nov 17:30 init.sh
        -rw-r--r--   1 devuser     staff  812345 19 nov 10:01 build-2026-11-19T10:01:22Z.log
        PID   TTY           TIME CMD
        61234 ttys001    0:00.21 -zsh
        61302 ttys001    0:12.87 swift-build --configuration debug -j 10
        error: /Users/devuser/Developer/x/Sources/A/B.swift:42:17: cannot find 'fooBar' in scope
        SALIDA-1a2b3c4d>>>
        """

    private func modelURL() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["TONAMOX_LFM3_GGUF"], !path.isEmpty else {
            throw XCTSkip("TONAMOX_LFM3_GGUF is not set")
        }
        return URL(fileURLWithPath: path)
    }

    private func makeEngine() async throws -> (LlamaTurnEngine, GGUFReasoningProfile) {
        let url = try modelURL()
        let parameter = LlamaClient.Parameter(context: 4096, batch: 2048, temperature: 0.2, topP: 0.95)
        let core = try await LlamaTurnCore.load(url: url, parameter: parameter)
        let renderer = await GGUFTurnEngines.renderer(for: url, tools: [])
        return (LlamaTurnEngine(renderer: renderer, core: core), GGUFReasoningProfile(renderer: renderer))
    }
}
