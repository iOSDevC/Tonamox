import XCTest
import LocalLLMClient
@testable import TonamoxCore

/// Synthetic header-only GGUFs, loaded through the real llama.cpp: it rejects each of them while reading the
/// header, before any tensor or weight is touched.
@MainActor
final class GGUFLoadDiagnosisTests: XCTestCase {

    private static let loadFailure = "Failed to load model from file"

    // MARK: - Diagnosis

    func testNextNHeaderOnDiskRaisesTheNextNBlocker() throws {
        let file = try write(Self.nextnHeader(), named: "Qwen3.8-27B-Q4_K_M.gguf")

        let bytes = ModelCompatibilityChecker.defaultGGUFHeaderBytes
        let header = try XCTUnwrap(GGUFLoadDiagnosis.header(at: file, byteCount: bytes))
        let blockers = GGUFLoadDiagnosis.blockers(for: header, path: file.lastPathComponent)

        XCTAssertEqual(blockers.map(\.rule), ["gguf.qwen35-nextn"])
        XCTAssertTrue(blockers[0].detail.contains("b9180"), blockers[0].detail)
    }

    func testHeaderCutByTheReadLimitStillExplains() throws {
        let file = try write(GGUFBytes.qwen35(nextn: 1, vocabulary: 2000).encoded, named: "big vocab.gguf")

        let header = try XCTUnwrap(GGUFLoadDiagnosis.header(at: file, byteCount: 512))

        XCTAssertFalse(header.isComplete)
        XCTAssertEqual(GGUFLoadDiagnosis.blockers(for: header, path: "big vocab.gguf").map(\.rule),
                       ["gguf.qwen35-nextn"])
    }

    func testLaterArchitectureRaisesTheArchitectureBlocker() throws {
        let header = try GGUFHeaderParser.parse(Self.header(architecture: "qwen4exp").encoded)
        let blockers = GGUFLoadDiagnosis.blockers(for: header, path: "m.gguf")

        XCTAssertEqual(blockers.map(\.rule), ["gguf.architecture"])
        XCTAssertTrue(blockers[0].title.contains("b10660"), blockers[0].title)
    }

    func testKnownArchitecturesExplainNothing() throws {
        let chat = try GGUFHeaderParser.parse(Self.header(architecture: "llama").encoded)
        let encoder = try GGUFHeaderParser.parse(Self.header(architecture: "bert").encoded)

        XCTAssertEqual(GGUFLoadDiagnosis.blockers(for: chat, path: "m.gguf"), [])
        XCTAssertEqual(GGUFLoadDiagnosis.blockers(for: encoder, path: "m.gguf"), [],
                       "b8851 loads bert, so 'not a chat model' is not why a load failed")
    }

    func testOnlyLocalLLMClientLoadFailuresAreExplained() async throws {
        let file = try write(Self.nextnHeader(), named: "nextn.gguf")
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
        let blocker = CompatibilityFinding.blocker("gguf.qwen35-nextn", "MTP block breaks loading on b8851",
                                                   "Fixed in llama.cpp b9180.")
        let error = IncompatibleGGUFError(filename: "m.gguf", blockers: [blocker],
                                          underlyingMessage: "Failed to load model: \(Self.loadFailure)")

        XCTAssertEqual(error.localizedDescription,
                       "m.gguf failed to load. Its header shows a known blocker for the bundled llama.cpp: "
                       + "MTP block breaks loading on b8851. Fixed in llama.cpp b9180. "
                       + "Underlying error: Failed to load model: \(Self.loadFailure)")
    }

    // MARK: - Loading through llama.cpp

    func testFailedLoadOfANextNHeaderIsExplained() async throws {
        let file = try write(Self.nextnHeader(), named: "Qwen3.8-27B-Q4_K_M.gguf")

        let error = await loadError(file)

        let explained = try XCTUnwrap(error as? IncompatibleGGUFError, "got \(String(describing: error))")
        XCTAssertEqual(explained.blockers.map(\.rule), ["gguf.qwen35-nextn"])
        let message = explained.localizedDescription
        for expected in ["Qwen3.8-27B-Q4_K_M.gguf", "b8851", "b9180", Self.loadFailure] {
            XCTAssertTrue(message.contains(expected), "\(expected) missing from: \(message)")
        }
    }

    func testFailedLoadOfANextNHeaderWithNativeToolCallsIsExplained() async throws {
        let file = try write(Self.nextnHeader(chatTemplate: Self.nativeToolTemplate), named: "native tools.gguf")
        let tools: [any LLMTool] = [NoOpTool()]
        let plan = await GGUFTurnEngines.plan(url: file, tools: tools)
        XCTAssertFalse(plan.ownsContext, "the load must go through LocalLLMClient's LlamaClient")

        let error = await loadError(file, tools: tools)

        let explained = try XCTUnwrap(error as? IncompatibleGGUFError, "got \(String(describing: error))")
        XCTAssertEqual(explained.blockers.map(\.rule), ["gguf.qwen35-nextn"])
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

    /// GGUF v3, no tensors: the three keys the nextn rule reads. llama.cpp rejects it for a missing hyperparameter,
    /// not for the MTP block, so the load tests prove the wiring only.
    private static func nextnHeader(chatTemplate: String? = nil) -> Data {
        var file = GGUFBytes()
        file.key("general.architecture", .string) { $0.string("qwen35") }
        file.key("qwen35.block_count", .uint32) { $0.int(UInt32(65)) }
        file.key("qwen35.nextn_predict_layers", .uint32) { $0.int(UInt32(1)) }
        if let chatTemplate {
            file.key("tokenizer.chat_template", .string) { $0.string(chatTemplate) }
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
