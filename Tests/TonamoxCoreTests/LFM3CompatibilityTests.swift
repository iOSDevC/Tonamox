import XCTest
@testable import TonamoxCore

/// LFM3 (llama.cpp b11938+): 24 blocks, 13 short-convolution layers with 0 KV heads, 5 of the 11 attention layers
/// sliding. The synthetic header copies the keys of AtomicChat's LFM3-1.7B-Uncensored-AD-Q4_K_M.gguf.
final class LFM3CompatibilityTests: XCTestCase {

    private static let filename = "LFM3-1.7B-Uncensored-AD-Q4_K_M.gguf"
    private static let fileBytes: Int64 = 1_132_208_000

    func testLFM3IsAKnownChatArchitectureOfThePinnedLlamaCpp() {
        XCTAssertEqual(PinnedRuntimes.llamaCppBuild, "b12407")
        XCTAssertTrue(PinnedRuntimes.llamaCppArchitectures.contains("lfm3"))
        XCTAssertNil(PinnedRuntimes.llamaCppNonChatArchitectures["lfm3"])
        XCTAssertNil(PinnedRuntimes.laterLlamaCppArchitectures["lfm3"])
    }

    func testLFM3HeaderSizesOnlyItsAttentionLayers() throws {
        let shape = try XCTUnwrap(KVCacheLayout.derive(gguf: Self.header()))

        XCTAssertEqual(shape.kvHeads, 4)
        XCTAssertEqual(shape.headDim, 128)
        XCTAssertEqual(shape.layout, KVCacheLayout(fullAttentionLayers: 6, slidingLayers: 5, slidingWindow: 0,
                                                   recurrentLayers: 13, recurrentStateBytes: 13 * 2048 * 6 * 4))
        // 11 attention layers × K and V × 4 heads × 128 × 2 B per token, plus the fixed conv state.
        XCTAssertEqual(shape.layout.cacheBytes(contextLength: 1000, kvHeads: 4, headDim: 128),
                       Double(11 * 2 * 4 * 128 * 2 * 1000 + 13 * 2048 * 6 * 4))
    }

    func testShortConvolutionWithoutASlidingPatternIsStillSplit() throws {
        var metadata = Self.metadata()
        metadata["lfm3.attention.sliding_window_pattern"] = nil

        let shape = try XCTUnwrap(KVCacheLayout.derive(gguf: LayoutFixture.header(metadata)))

        XCTAssertEqual(shape.layout.fullAttentionLayers, 11)
        XCTAssertEqual(shape.layout.slidingLayers, 0)
        XCTAssertEqual(shape.layout.recurrentLayers, 13)
    }

    func testZeroHeadLayersWithoutAShortConvolutionStayUniform() {
        var metadata = Self.metadata()
        metadata["lfm3.shortconv.l_cache"] = nil
        metadata["lfm3.attention.sliding_window_pattern"] = nil

        XCTAssertNil(KVCacheLayout.derive(gguf: LayoutFixture.header(metadata)),
                     "a Mamba-style state is not sized, so the layers keep the safe uniform estimate")
    }

    func testLFM3GGUFRunsOnAnIPhone17Pro() throws {
        let snapshot = Fixture.gguf(header: Self.header(), architecture: "lfm3",
                                    files: [(Self.filename, Self.fileBytes)])

        let report = CompatibilityEvaluator.evaluate(snapshot, on: .iPhone17Pro)

        XCTAssertTrue(report.status.isRunnable, "\(report.status): \(report.blockers)")
        XCTAssertEqual(report.blockers, [])
        XCTAssertEqual(report.suggestedEntry?.ggufFilename, Self.filename)
        XCTAssertTrue(report.findings.contains { $0.rule == "gguf.architecture" && $0.level == .info })
    }

    /// Opt-in: `TONAMOX_LFM3_GGUF=/path/to/LFM3-…gguf swift test --filter LFM3CompatibilityTests`.
    func testOnDiskLFM3HeaderRunsOnAnIPhone17Pro() throws {
        guard let path = ProcessInfo.processInfo.environment["TONAMOX_LFM3_GGUF"] else {
            throw XCTSkip("TONAMOX_LFM3_GGUF is not set")
        }
        let url = URL(fileURLWithPath: path)
        let header = try XCTUnwrap(GGUFLoadDiagnosis.header(at: url, byteCount: ModelCompatibilityChecker.defaultGGUFHeaderBytes))
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)
        let snapshot = Fixture.gguf(header: header, architecture: header.architecture,
                                    files: [(url.lastPathComponent, size.int64Value)])

        let report = CompatibilityEvaluator.evaluate(snapshot, on: .iPhone17Pro)

        XCTAssertEqual(header.architecture, "lfm3")
        XCTAssertEqual(KVCacheLayout.derive(gguf: header)?.layout.recurrentLayers, 13)
        XCTAssertTrue(report.status.isRunnable, "\(report.status): \(report.blockers)")
    }

    /// Opt-in like the test above. LocalLLMClient's swift-jinja 2.3.5 rejects `for tool in tools or []`; Tonamox
    /// renders with the root package's swift-jinja.
    func testOnDiskLFM3ChatTemplateRenders() throws {
        guard let path = ProcessInfo.processInfo.environment["TONAMOX_LFM3_GGUF"] else {
            throw XCTSkip("TONAMOX_LFM3_GGUF is not set")
        }
        // The template follows a 128k-token vocabulary, past the 4 MiB the checker reads.
        let header = try XCTUnwrap(GGUFLoadDiagnosis.header(at: URL(fileURLWithPath: path), byteCount: 16 << 20))
        let template = try XCTUnwrap(header.metadata["tokenizer.chat_template"]?.text)

        let rendered = try LlamaPromptRenderer(template: template).render([.system("Be brief."), .user("What is 2 plus 3?")])

        XCTAssertTrue(rendered.contains("Be brief."), rendered)
        XCTAssertTrue(rendered.contains("What is 2 plus 3?"), rendered)
    }

    // MARK: - Fixture

    private static func header() -> GGUFHeader {
        LayoutFixture.header(metadata())
    }

    private static func metadata() -> [String: GGUFValue] {
        let heads = (0..<24).map { GGUFValue.uint32($0 >= 2 && $0 % 2 == 0 ? 4 : 0) }
        return [
            "general.architecture": .string("lfm3"),
            "general.name": .string("LFM3-1.7B-Uncensored"),
            "lfm3.block_count": .uint32(24),
            "lfm3.context_length": .uint32(262_144),
            "lfm3.embedding_length": .uint32(2048),
            "lfm3.attention.head_count": .uint32(16),
            "lfm3.attention.head_count_kv": .array(GGUFArray(elementType: .uint32, count: 24, elements: heads)),
            "lfm3.attention.key_length": .uint32(128),
            "lfm3.attention.sliding_window": .uint32(256),
            "lfm3.attention.sliding_window_pattern": LayoutFixture.flags((0..<24).map { $0 > 0 && $0 % 4 == 0 }),
            "lfm3.shortconv.l_cache": .uint32(7),
        ]
    }
}
