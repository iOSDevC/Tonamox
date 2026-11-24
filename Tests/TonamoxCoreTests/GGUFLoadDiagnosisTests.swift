import XCTest
import LocalLLMClient
@testable import TonamoxCore

/// Synthetic header-only GGUFs, loaded through the real llama.cpp: it rejects each of them while reading the
/// header, before any tensor or weight is touched.
@MainActor
final class GGUFLoadDiagnosisTests: XCTestCase {

    private static let loadFailure = "Failed to load model from file"

    // MARK: - Diagnosis

    func testUnknownArchitectureOnDiskRaisesTheArchitectureBlocker() throws {
        let file = try write(Self.unknownHeader(), named: "Future-27B-Q4_K_M.gguf")

        let bytes = ModelCompatibilityChecker.defaultGGUFHeaderBytes
        let header = try XCTUnwrap(GGUFLoadDiagnosis.header(at: file, byteCount: bytes))
        let blockers = GGUFLoadDiagnosis.blockers(for: header, path: file.lastPathComponent)

        XCTAssertEqual(blockers.map(\.rule), ["gguf.architecture"])
        XCTAssertTrue(blockers[0].title.contains("b12407"), blockers[0].title)
    }

    func testHeaderCutByTheReadLimitStillExplains() throws {
        let file = try write(Self.unknownHeader(vocabulary: 2000), named: "big vocab.gguf")

        let header = try XCTUnwrap(GGUFLoadDiagnosis.header(at: file, byteCount: 512))

        XCTAssertFalse(header.isComplete)
        XCTAssertEqual(GGUFLoadDiagnosis.blockers(for: header, path: "big vocab.gguf").map(\.rule),
                       ["gguf.architecture"])
    }

    func testNextNHeaderExplainsNothingSinceTheB9180Fix() throws {
        let header = try GGUFHeaderParser.parse(GGUFBytes.qwen35(nextn: 1).encoded)

        XCTAssertEqual(GGUFLoadDiagnosis.blockers(for: header, path: "Qwen3.8-27B-Q4_K_M.gguf"), [])
    }

    func testKnownArchitecturesExplainNothing() throws {
        let chat = try GGUFHeaderParser.parse(Self.header(architecture: "llama").encoded)
        let encoder = try GGUFHeaderParser.parse(Self.header(architecture: "bert").encoded)

        XCTAssertEqual(GGUFLoadDiagnosis.blockers(for: chat, path: "m.gguf"), [])
        XCTAssertEqual(GGUFLoadDiagnosis.blockers(for: encoder, path: "m.gguf"), [],
                       "llama.cpp loads bert, so 'not a chat model' is not why a load failed")
    }

    func testOnlyLocalLLMClientLoadFailuresAreExplained() async throws {
        let file = try write(Self.unknownHeader(), named: "unknown.gguf")
        let context = LLMError.invalidParameter(reason: "Failed to create context")

        let cancelled = await GGUFLoadDiagnosis.explained(CancellationError(), loading: file)
        let other = await GGUFLoadDiagnosis.explained(context, loading: file)

        XCTAssertTrue(cancelled is CancellationError)
        guard case .invalidParameter(let reason)? = other as? LLMError else { return XCTFail("got \(other)") }
        XCTAssertEqual(reason, "Failed to create context")
    }

    func testMissingFileKeepsTheOriginalError() async throws {
        let missing = try folder().appendingPathComponent("gone.gguf")

        let error = await GGUFLoadDiagnosis.explained(LLMError.failedToLoad(reason: Self.loadFailure), loading: missing)

        assertOriginalLoadFailure(error)
    }

    func testMessageCarriesTheBlockerAndTheUnderlyingError() {
        let blocker = CompatibilityFinding.blocker("gguf.architecture", "Architecture `x` is unknown to llama.cpp b12407",
                                                   "It is not in `LLM_ARCH_NAMES`.")
        let error = IncompatibleGGUFError(filename: "m.gguf", blockers: [blocker],
                                          underlyingMessage: "Failed to load model: \(Self.loadFailure)")

        XCTAssertEqual(error.localizedDescription,
                       "m.gguf failed to load. Its header shows a known blocker for the bundled llama.cpp: "
                       + "Architecture `x` is unknown to llama.cpp b12407. It is not in `LLM_ARCH_NAMES`. "
                       + "Underlying error: Failed to load model: \(Self.loadFailure)")
    }

    // MARK: - Loading through llama.cpp

    func testFailedLoadOfAnUnknownArchitectureIsExplained() async throws {
        let file = try write(Self.unknownHeader(), named: "Future-27B-Q4_K_M.gguf")

        let error = await loadError(file)

        let explained = try XCTUnwrap(error as? IncompatibleGGUFError, "got \(String(describing: error))")
        XCTAssertEqual(explained.blockers.map(\.rule), ["gguf.architecture"])
        let message = explained.localizedDescription
        for expected in ["Future-27B-Q4_K_M.gguf", "futurearch", "b12407", Self.loadFailure] {
            XCTAssertTrue(message.contains(expected), "\(expected) missing from: \(message)")
        }
    }

    func testFailedLoadOfAnUnknownArchitectureWithNativeToolCallsIsExplained() async throws {
        let file = try write(Self.unknownHeader(chatTemplate: Self.nativeToolTemplate), named: "native tools.gguf")
        let tools: [any LLMTool] = [NoOpTool()]
        let plan = await GGUFTurnEngines.plan(url: file, tools: tools)
        XCTAssertFalse(plan.ownsContext, "the load must go through LocalLLMClient's LlamaClient")

        let error = await loadError(file, tools: tools)

        let explained = try XCTUnwrap(error as? IncompatibleGGUFError, "got \(String(describing: error))")
        XCTAssertEqual(explained.blockers.map(\.rule), ["gguf.architecture"])
    }

    func testTruncatedGGUFOfAKnownArchitectureKeepsTheOriginalError() async throws {
        let full = Self.header(architecture: "llama").encoded
        let file = try write(full.prefix(full.count - 3), named: "truncated llama.gguf")

        assertOriginalLoadFailure(await loadError(file))
    }

    func testNonGGUFFileKeepsTheOriginalError() async throws {
        let file = try write(Data("not a GGUF file at all".utf8), named: "plain text.gguf")

        assertOriginalLoadFailure(await loadError(file))
    }

    // MARK: - Helpers

    /// GGUF v3, no tensors, an architecture llama.cpp does not list.
    private static func unknownHeader(chatTemplate: String? = nil, vocabulary: Int = 0) -> Data {
        var file = header(architecture: "futurearch")
        if let chatTemplate {
            file.key("tokenizer.chat_template", .string) { $0.string(chatTemplate) }
        }
        file.key("tokenizer.ggml.tokens", .array) {
            $0.array(of: .string, (0..<vocabulary).map { GGUFBytes.stringValue("token-\($0)") })
        }
        return file.encoded
    }

    /// Supports tools but writes calls as `<call>name</call>`, not `<tool_call>` JSON.
    private static let nativeToolTemplate = "{%- if tools %}{{- 'TOOLS|' }}{%- endif %}"
        + "{%- for message in messages %}{%- if message.tool_calls %}{%- for tool_call in message.tool_calls %}"
        + "{{- '<call>' + tool_call.function.name + '</call>' }}{%- endfor %}{%- else %}{{- message.content }}"
        + "{%- endif %}{%- endfor %}"

    private static func header(architecture: String) -> GGUFBytes {
        var file = GGUFBytes()
        file.key("general.architecture", .string) { $0.string(architecture) }
        file.key("\(architecture).block_count", .uint32) { $0.int(UInt32(32)) }
        file.key("general.name", .string) { $0.string("synthetic") }
        return file
    }

    /// A fresh folder whose path contains a space, removed after the test.
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GGUF load \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ data: Data, named name: String) throws -> URL {
        let url = try folder().appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func loadError(_ file: URL, tools: [any LLMTool] = []) async -> (any Error)? {
        guard let model = Model.from(.localFile(file)) else {
            XCTFail("\(file.lastPathComponent) is not a local GGUF model")
            return nil
        }
        do {
            try await LlamaCppBackend(model: model, tools: tools).load { _ in }
            XCTFail("\(file.lastPathComponent) loaded")
            return nil
        } catch {
            return error
        }
    }

    private func assertOriginalLoadFailure(_ error: (any Error)?, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failedToLoad(let reason)? = error as? LLMError else {
            return XCTFail("expected LocalLLMClient's load failure, got \(String(describing: error))",
                           file: file, line: line)
        }
        XCTAssertEqual(reason, Self.loadFailure, file: file, line: line)
    }
}

private struct NoOpTool: LLMTool {
    let name = "noop"
    let description = "Does nothing."
    struct Arguments: Decodable, ToolSchemaGeneratable {
        static var argumentsSchema: LLMToolArgumentsSchema { [:] }
    }
    func call(arguments: Arguments) async throws -> ToolOutput { ToolOutput(data: [:]) }
}
