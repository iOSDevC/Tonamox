import Foundation
import Testing
@testable import TonamoxCore

@Suite("ModelArtifact: adapters and auxiliary files are not versions of a model")
struct ModelArtifactTests {

    // MARK: The screenshot case

    @Test func loraAdapterGGUFIsNotAStandaloneModelAndOffersNoVersion() throws {
        let header = try GGUFHeaderParser.parse(Self.adapterHeader(baseURL: "https://huggingface.co/Qwen/Qwen3.8-27B").encoded)
        let snapshot = Self.snapshot(repoID: "harness-hub/Qwen3.8-27B-pi-adapter",
                                     files: [("Qwen3.8-27B-pi-lora-F16.gguf", 322_122_547)], header: header)

        let report = CompatibilityEvaluator.evaluate(snapshot, on: .iPhone6GB)

        #expect(report.artifact.kind == .adapter(base: "Qwen/Qwen3.8-27B"))
        #expect(report.artifact.signal == .ggufType)
        #expect(report.artifact.isCertain)
        #expect(report.quantFits.isEmpty)
        #expect(report.recommendedQuant == nil)
        #expect(report.bestFit == nil)
        #expect(report.suggestedEntry == nil)
        #expect(report.status == .notRunnable)
        let blocker = try #require(report.blockers.first)
        #expect(blocker.rule == "artifact")
        #expect(report.headline == blocker.title)
        #expect(blocker.detail.contains("cannot be loaded on its own"))
        #expect(blocker.detail.contains("does not apply adapters"))
        #expect(blocker.detail.contains("merged GGUF of `Qwen/Qwen3.8-27B`"))
        #expect(!report.findings.contains { $0.rule == "fit" })
        #expect(report.artifact.excludedFiles.map(\.path) == ["Qwen3.8-27B-pi-lora-F16.gguf"])
    }

    // MARK: Each signal alone

    @Test func generalTypeAloneDecides() throws {
        var file = GGUFBytes(tensorCount: 4)
        file.key("general.architecture", .string) { $0.string("llama") }
        file.key("general.type", .string) { $0.string("adapter") }
        let report = try Self.evaluate(file, files: [("m-F16.gguf", 100_000_000)])

        #expect(report.artifact.signal == .ggufType)
        #expect(report.artifact.kind == .adapter(base: nil))
        #expect(report.blockers.first?.detail.contains("the base model") == true)
    }

    @Test func adapterKeysAloneDecide() throws {
        var file = GGUFBytes(tensorCount: 4)
        file.key("general.architecture", .string) { $0.string("llama") }
        file.key("adapter.type", .string) { $0.string("lora") }
        let report = try Self.evaluate(file, files: [("m-F16.gguf", 100_000_000)])

        #expect(report.artifact.signal == .ggufAdapterKeys)
        #expect(report.quantFits.isEmpty)
    }

    @Test func loraTensorNamesInTheGGUFHeaderDecide() throws {
        var file = GGUFBytes(tensorCount: 2)
        file.key("general.architecture", .string) { $0.string("llama") }
        Self.tensorInfo(&file, name: "blk.0.attn_q.weight.lora_a")
        Self.tensorInfo(&file, name: "blk.0.attn_q.weight.lora_b")
        let header = try GGUFHeaderParser.parse(file.encoded)
        #expect(header.tensorNames == ["blk.0.attn_q.weight.lora_a", "blk.0.attn_q.weight.lora_b"])

        let report = CompatibilityEvaluator.evaluate(
            Self.snapshot(repoID: "o/m", files: [("m-F16.gguf", 100_000_000)], header: header), on: .mac32GB)
        #expect(report.artifact.signal == .loraTensorNames)
    }

    @Test func peftTensorNamesInSafetensorsDecide() {
        let listing = HFRepoInfo(repoID: "o/peft", files: [RepoFile(path: "model.safetensors", sizeBytes: 50_000_000)])
        let header = SafetensorsHeader(tensorNames: ["base_model.model.layers.0.self_attn.q_proj.lora_A.weight"],
                                       metadata: [:])
        let snapshot = RepoSnapshot(repoID: "o/peft", listing: listing, singleFileHeader: header)

        #expect(ModelArtifactClassifier.classify(snapshot).signal == .loraTensorNames)
    }

    @Test func baseModelAdapterTagAloneDecidesEvenNextToModelFiles() {
        let listing = HFRepoInfo(repoID: "o/m", files: [RepoFile(path: "m-F16.gguf", sizeBytes: 100_000_000)],
                                 tags: ["gguf", "base_model:adapter:Org/Base"])
        let artifact = ModelArtifactClassifier.classify(RepoSnapshot(repoID: "o/m", listing: listing))

        #expect(artifact.signal == .huggingFaceTags)
        #expect(artifact.isCertain)
        #expect(artifact.kind == .adapter(base: "Org/Base"))
    }

    @Test(arguments: ["lora", "peft"])
    func adapterTagDecidesARepoWithNoModelFile(tag: String) {
        let listing = HFRepoInfo(repoID: "o/m", files: [RepoFile(path: "README.md", sizeBytes: 900)],
                                 tags: [tag])
        let artifact = ModelArtifactClassifier.classify(RepoSnapshot(repoID: "o/m", listing: listing))

        #expect(artifact.signal == .huggingFaceTags)
        #expect(artifact.kind == .adapter(base: nil))
    }

    @Test(arguments: ["lora", "peft"])
    func adapterTagWithoutAHeaderOnlySuspectsAGGUFRepo(tag: String) throws {
        let report = CompatibilityEvaluator.evaluate(Self.unreadHeaderSnapshot(repoID: "o/m-GGUF", tags: ["gguf", tag]),
                                                     on: .mac32GB)

        #expect(report.artifact.kind == .standaloneModel)
        #expect(report.artifact.isSuspectedAdapter)
        #expect(!report.artifact.isCertain)
        #expect(report.quantFits.map(\.id) == ["m-Q4_K_M.gguf", "m-Q8_0.gguf"])
        #expect(!report.blockers.contains { $0.rule == "artifact" })
        let caveat = try #require(report.caveats.first { $0.rule == "artifact" })
        #expect(caveat.title == "Might be an adapter (LoRA)")
        #expect(report.suggestedEntry != nil)
    }

    @Test(arguments: ["base_model:finetune:Org/Base", "base_model:quantized:Org/Base"])
    func otherBaseModelTagsSayNothingAboutAdapters(tag: String) {
        let artifact = ModelArtifactClassifier.classify(Self.unreadHeaderSnapshot(repoID: "o/m-GGUF", tags: ["gguf", tag]))

        #expect(artifact == .standaloneModel)
    }

    @Test func adapterFilesAloneDecide() {
        let listing = HFRepoInfo(repoID: "o/m", files: [
            RepoFile(path: "adapter_config.json", sizeBytes: 900),
            RepoFile(path: "adapter_model.safetensors", sizeBytes: 80_000_000),
        ], baseModels: ["Org/Base"])
        let report = CompatibilityEvaluator.evaluate(RepoSnapshot(repoID: "o/m", listing: listing), on: .mac32GB)

        #expect(report.artifact.signal == .adapterFiles)
        #expect(report.artifact.kind == .adapter(base: "Org/Base"))
        #expect(report.blockers.first?.rule == "artifact")
    }

    @Test func fileNameAloneIsOnlyProbable() throws {
        let report = CompatibilityEvaluator.evaluate(
            Self.snapshot(repoID: "o/m", files: [("x-lora-F16.gguf", 100_000_000)], header: nil), on: .mac32GB)

        #expect(report.artifact.signal == .nameToken)
        #expect(!report.artifact.isCertain)
        #expect(report.quantFits.isEmpty)
        #expect(report.suggestedEntry == nil)
        let blocker = try #require(report.blockers.first)
        #expect(blocker.title.hasPrefix("Probably"))
        #expect(blocker.detail.contains("Only the name says so"))
    }

    @Test func repoNameAloneKeepsTheVersionsAndOnlyWarns() throws {
        let report = CompatibilityEvaluator.evaluate(
            Self.unreadHeaderSnapshot(repoID: "o/Base-7B-Adapter", tags: ["gguf"]), on: .mac32GB)

        #expect(report.artifact.signal == .nameToken)
        #expect(report.artifact.kind == .standaloneModel)
        #expect(report.artifact.isSuspectedAdapter)
        #expect(report.quantFits.map(\.id) == ["m-Q4_K_M.gguf", "m-Q8_0.gguf"])
        #expect(report.caveats.contains { $0.rule == "artifact" })
        #expect(!report.blockers.contains { $0.rule == "artifact" })
    }

    @Test func adapterFilesNextToGGUFModelFilesOnlySuspect() {
        let listing = HFRepoInfo(repoID: "o/m", files: [
            RepoFile(path: "adapter_config.json", sizeBytes: 900), RepoFile(path: "m-Q4_K_M.gguf", sizeBytes: 5_000_000_000),
        ], tags: ["gguf"])
        let artifact = ModelArtifactClassifier.classify(RepoSnapshot(repoID: "o/m", listing: listing))

        #expect(artifact.kind == .standaloneModel)
        #expect(artifact.signal == .adapterFiles)
        #expect(!artifact.isCertain)
    }

    @Test func safetensorsAdapterGetsNoFitFinding() {
        let listing = HFRepoInfo(repoID: "o/m", files: [
            RepoFile(path: "adapter_config.json", sizeBytes: 900),
            RepoFile(path: "adapter_model.safetensors", sizeBytes: 80_000_000),
        ])
        let report = CompatibilityEvaluator.evaluate(RepoSnapshot(repoID: "o/m", listing: listing), on: .mac32GB)

        #expect(report.artifact.kind.isAdapter)
        #expect(report.weightsFit == nil)
        #expect(report.bestFit == nil)
        #expect(!report.findings.contains { $0.rule == "fit" || $0.rule == "kv" || $0.rule == "moe" })
    }

    @Test func anAdapterHeaderReadFromOneFileOfAMixedRepoExcludesOnlyThatFile() throws {
        let header = try GGUFHeaderParser.parse(Self.adapterHeader(baseURL: "https://huggingface.co/Org/Base").encoded)
        let snapshot = Fixture.gguf(header: header, files: [
            ("m-lora-F16.gguf", 300_000_000), ("m-Q4_K_M.gguf", 5_000_000_000), ("m-Q8_0.gguf", 8_500_000_000),
        ])

        let report = CompatibilityEvaluator.evaluate(snapshot, on: .mac32GB)

        #expect(report.artifact.kind == .standaloneModel)
        #expect(report.quantFits.map(\.id) == ["m-Q4_K_M.gguf", "m-Q8_0.gguf"])
        #expect(report.artifact.excludedFiles.map(\.path) == ["m-lora-F16.gguf"])
        #expect(!report.blockers.contains { $0.rule == "artifact" })
    }

    @Test func anUnnamedAdapterSampledNextToModelFilesExcludesOnlyThatFile() throws {
        let header = try GGUFHeaderParser.parse(Self.adapterHeader(baseURL: "https://huggingface.co/Org/Base").encoded)
        let snapshot = Fixture.gguf(header: header, files: [("pi-F16.gguf", 300_000_000), ("m-Q4_K_M.gguf", 5_000_000_000)])

        let artifact = ModelArtifactClassifier.classify(snapshot)

        #expect(artifact.kind == .standaloneModel)
        #expect(artifact.excludedFiles == [ExcludedArtifactFile(path: "pi-F16.gguf", kind: .adapter(base: "Org/Base"),
                                                                sizeBytes: 300_000_000)])
    }

    // MARK: What stays a model

    @Test func headerWithLayersClearsALoraFileName() throws {
        var file = GGUFBytes(tensorCount: 10)
        file.key("general.architecture", .string) { $0.string("llama") }
        file.key("llama.block_count", .uint32) { $0.int(UInt32(16)) }
        let report = try Self.evaluate(file, files: [("x-lora-Q4_K_M.gguf", 800_000_000)])

        #expect(report.artifact.kind == .standaloneModel)
        #expect(report.quantFits.map(\.id) == ["x-lora-Q4_K_M.gguf"])
    }

    @Test func generalTypeModelOutranksALoraTag() throws {
        var file = GGUFBytes(tensorCount: 10)
        file.key("general.architecture", .string) { $0.string("llama") }
        file.key("general.type", .string) { $0.string("model") }
        let header = try GGUFHeaderParser.parse(file.encoded)
        var snapshot = Self.snapshot(repoID: "o/m", files: [("m-Q4_K_M.gguf", 800_000_000)], header: header)
        snapshot.listing = HFRepoInfo(repoID: "o/m", files: snapshot.listing?.files ?? [], tags: ["gguf", "lora"])

        #expect(ModelArtifactClassifier.classify(snapshot).kind == .standaloneModel)
    }

    @Test(arguments: ["flora-7b-Q4_K_M.gguf", "explorer-Q4_K_M.gguf", "m-lora-merged-Q4_K_M.gguf"])
    func adapterWordsAreWordBounded(name: String) {
        #expect(ModelArtifactClassifier.nameKind(of: name) == nil)
    }

    @Test func normalMultiQuantRepoIsUnchanged() throws {
        let header = try GGUFHeaderParser.parse(GGUFBytes.qwen35(nextn: 0).encoded)
        let report = CompatibilityEvaluator.evaluate(Fixture.gguf(header: header), on: .mac32GB)

        #expect(report.artifact == .standaloneModel)
        #expect(report.quantFits.map(\.id) == ["m-Q4_K_M.gguf", "m-Q8_0.gguf"])
        #expect(report.suggestedEntry?.ggufFilename == "m-Q8_0.gguf")
        #expect(report.recommendedQuant?.id == "m-Q8_0.gguf")
        #expect(!report.findings.contains { $0.rule == "artifact" })
    }

    @Test func mixedRepoKeepsAdaptersAndAuxiliaryFilesOutOfTheVersions() throws {
        let header = try GGUFHeaderParser.parse(GGUFBytes.qwen35(nextn: 0).encoded)
        let snapshot = Fixture.gguf(header: header, files: [
            ("m-Q4_K_M.gguf", 5_000_000_000), ("m-Q8_0.gguf", 8_500_000_000), ("mmproj-m-F16.gguf", 900_000_000),
            ("m-lora-F16.gguf", 300_000_000), ("m-imatrix.gguf", 7_000_000),
        ])

        let report = CompatibilityEvaluator.evaluate(snapshot, on: .mac32GB)

        #expect(report.artifact.kind == .standaloneModel)
        #expect(report.quantFits.map(\.id) == ["m-Q4_K_M.gguf", "m-Q8_0.gguf"])
        #expect(report.suggestedEntry?.ggufFilename == "m-Q8_0.gguf")
        let kinds = Dictionary(uniqueKeysWithValues: report.artifact.excludedFiles.map { ($0.path, $0.kind) })
        #expect(kinds == ["mmproj-m-F16.gguf": .auxiliary(.visionProjector), "m-lora-F16.gguf": .adapter(base: nil),
                          "m-imatrix.gguf": .auxiliary(.importanceMatrix)])
        let note = try #require(report.findings.first { $0.rule == "artifact" })
        #expect(note.level == .info)
        #expect(note.detail.contains("m-lora-F16.gguf") && !note.detail.contains("mmproj"))
    }

    @Test func imatrixOnlyRepoHasNoModelFile() {
        let report = CompatibilityEvaluator.evaluate(
            Self.snapshot(repoID: "o/m", files: [("m-imatrix.gguf", 7_000_000)], header: nil), on: .mac32GB)

        #expect(report.artifact.kind == .auxiliary(.importanceMatrix))
        #expect(report.status == .notRunnable)
        #expect(report.blockers.first?.rule == "artifact")
    }

    @Test func checkerReadsTheHeaderOfANameMarkedFileOnlyWhenNothingElseIs() {
        let mixed = [RepoFile(path: "x-lora-F16.gguf", sizeBytes: 300), RepoFile(path: "x-Q4_K_M.gguf", sizeBytes: 5_000)]
        let mmproj = [RepoFile(path: "mmproj-x-F16.gguf", sizeBytes: 300), RepoFile(path: "x-Q8_0.gguf", sizeBytes: 5_000)]
        let loraOnly = [RepoFile(path: "x-lora-F16.gguf", sizeBytes: 300)]

        #expect(ModelCompatibilityChecker.headerSamplePath(in: mixed) == "x-Q4_K_M.gguf")
        #expect(ModelCompatibilityChecker.headerSamplePath(in: mmproj) == "x-Q8_0.gguf")
        #expect(ModelCompatibilityChecker.headerSamplePath(in: loraOnly) == "x-lora-F16.gguf")
        #expect(ModelCompatibilityChecker.headerSamplePath(in: mixed, requested: "x-lora-F16.gguf") == "x-lora-F16.gguf")
        #expect(ModelCompatibilityChecker.headerSamplePath(in: mixed, requested: "missing.gguf") == "x-Q4_K_M.gguf")
    }

    @Test func recommendationSkipsASubfolderQuantWhenATopLevelOneFits() throws {
        let header = try GGUFHeaderParser.parse(GGUFBytes.qwen35(nextn: 0).encoded)
        let snapshot = Fixture.gguf(header: header, files: [("m-Q4_K_M.gguf", 5_000_000_000),
                                                            ("extra/m-Q8_0.gguf", 8_500_000_000)])

        let report = CompatibilityEvaluator.evaluate(snapshot, on: .mac32GB)

        #expect(report.suggestedEntry?.ggufFilename == "m-Q4_K_M.gguf")
        #expect(report.recommendedQuant?.id == "m-Q4_K_M.gguf")
        #expect(!report.findings.contains { $0.rule == "entry" })
    }

    // MARK: Base model and card

    @Test func cardBaseModelParsesAsStringOrList() throws {
        let single = try #require(HFRepoInfo.parse(Data(#"{"id": "o/m", "cardData": {"base_model": "Org/A"}}"#.utf8)))
        let list = try #require(HFRepoInfo.parse(Data(#"{"id": "o/m", "cardData": {"base_model": ["Org/B"]}}"#.utf8)))
        #expect(single.baseModels == ["Org/A"])
        #expect(list.baseModels == ["Org/B"])
    }

    @Test func headerBaseNameIsTheFallback() throws {
        var file = GGUFBytes(tensorCount: 4)
        file.key("general.architecture", .string) { $0.string("llama") }
        file.key("general.type", .string) { $0.string("adapter") }
        file.key("general.base_model.0.name", .string) { $0.string("Base 7B") }
        file.key("general.base_model.0.organization", .string) { $0.string("Org") }
        let report = try Self.evaluate(file, files: [("m-F16.gguf", 100_000_000)])

        #expect(report.artifact.kind == .adapter(base: "Base 7B (Org)"))
    }

    // MARK: Quant hints

    @Test(arguments: [
        ("Q4_K_M", "balanced, common default"), ("q4_k_m", "balanced, common default"),
        ("Q4_K_S", "balanced, a little smaller"), ("IQ4_XS", "balanced, a little smaller"),
        ("Q8_0", "near-lossless, large"), ("Q6_K", "very high quality, large"), ("Q5_K_M", "high quality, larger"),
        ("F16", "unquantized, full size"), ("BF16", "unquantized, full size"), ("F32", "unquantized, full size"),
        ("Q3_K_L", "small, lower quality"), ("IQ3_XXS", "small, lower quality"),
        ("Q2_K", "smallest, lowest quality"), ("IQ1_S", "smallest, lowest quality"),
    ])
    func quantHintNamesTheTradeoff(token: String, hint: String) {
        #expect(QuantHint.text(for: token) == hint)
    }

    @Test(arguments: ["GGUF", "", "XYZ"])
    func unknownQuantTokenHasNoHint(token: String) {
        #expect(QuantHint.text(for: token) == nil)
    }

    // MARK: Helpers

    /// Shaped like the screenshot's file: qwen35 adapter, 512 tensors, 6 keys.
    static func adapterHeader(baseURL: String) -> GGUFBytes {
        var file = GGUFBytes(tensorCount: 512)
        file.key("general.architecture", .string) { $0.string("qwen35") }
        file.key("general.type", .string) { $0.string("adapter") }
        file.key("general.name", .string) { $0.string("Qwen3.8 27B pi lora") }
        file.key("general.base_model.0.repo_url", .string) { $0.string(baseURL) }
        file.key("adapter.type", .string) { $0.string("lora") }
        file.key("adapter.lora.alpha", .float32) { $0.int(Float(32).bitPattern) }
        return file
    }

    /// One GGUF tensor-info record: name, 2 dimensions, type F16, offset 0.
    static func tensorInfo(_ file: inout GGUFBytes, name: String) {
        file.string(name)
        file.int(UInt32(2))
        file.int(UInt64(16))
        file.int(UInt64(4096))
        file.int(UInt32(1))
        file.int(UInt64(0))
    }

    static func snapshot(repoID: String, files: [(String, Int64)], header: GGUFHeader?) -> RepoSnapshot {
        let listing = HFRepoInfo(repoID: repoID, files: files.map { RepoFile(path: $0.0, sizeBytes: $0.1) },
                                 tags: ["gguf"], pipelineTag: "text-generation", licenseID: "apache-2.0")
        return RepoSnapshot(repoID: repoID, listing: listing, ggufMetadata: header,
                            ggufSamplePath: header == nil ? nil : files.first?.0)
    }

    /// Two model quants whose header was not read (a 401 or a network error); Hugging Face's summary names the
    /// architecture.
    static func unreadHeaderSnapshot(repoID: String, tags: [String]) -> RepoSnapshot {
        let listing = HFRepoInfo(repoID: repoID, files: [RepoFile(path: "m-Q4_K_M.gguf", sizeBytes: 5_000_000_000),
                                                         RepoFile(path: "m-Q8_0.gguf", sizeBytes: 8_500_000_000)],
                                 tags: tags, pipelineTag: "text-generation", licenseID: "apache-2.0",
                                 ggufArchitecture: "qwen35")
        return RepoSnapshot(repoID: repoID, listing: listing)
    }

    static func evaluate(_ file: GGUFBytes, files: [(String, Int64)]) throws -> CompatibilityReport {
        let header = try GGUFHeaderParser.parse(file.encoded)
        return CompatibilityEvaluator.evaluate(Self.snapshot(repoID: "o/m", files: files, header: header), on: .mac32GB)
    }
}
