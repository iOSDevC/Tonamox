import Foundation

// MARK: - ModelArtifactKind

/// What a repository (or one of its files) is, before anyone asks whether it fits.
public enum ModelArtifactKind: Sendable, Equatable {
    /// Weights a runtime loads on their own and chats with.
    case standaloneModel
    /// A set of weight deltas (LoRA) for a base model; useless without that base. `base` is the base model's
    /// Hugging Face id or name, when the repo says.
    case adapter(base: String?)
    /// A file that helps a model but is not one (vision projector, importance matrix).
    case auxiliary(AuxiliaryArtifact)

    public var isStandaloneModel: Bool { self == .standaloneModel }

    public var isAdapter: Bool {
        if case .adapter = self { return true }
        return false
    }

    /// `Adapter (LoRA)`, `Vision projector`…
    public var label: String {
        switch self {
        case .standaloneModel: "Model"
        case .adapter: "Adapter (LoRA)"
        case .auxiliary(let role): role.label
        }
    }
}

/// Files shipped next to a model that are not a model.
public enum AuxiliaryArtifact: String, Sendable, CaseIterable {
    /// llama.cpp `mmproj`: the image encoder of a vision model.
    case visionProjector
    /// llama.cpp `imatrix`: calibration data used while quantizing.
    case importanceMatrix

    public var label: String {
        switch self {
        case .visionProjector: "Vision projector"
        case .importanceMatrix: "Importance matrix"
        }
    }
}

/// The evidence that decided a repo is not a standalone model, strongest first.
public enum ArtifactSignal: String, Sendable, CaseIterable {
    /// GGUF `general.type` (`adapter`, `mmproj`, `imatrix`).
    case ggufType
    /// Any GGUF `adapter.*` key (`adapter.type`, `adapter.lora.alpha`).
    case ggufAdapterKeys
    /// Tensor names ending in `.lora_a` / `.lora_b`.
    case loraTensorNames
    /// Hugging Face tags `lora`, `peft`, `adapter` or `base_model:adapter:<repo>`.
    case huggingFaceTags
    /// `adapter_config.json` / `adapter_model.safetensors` in the file list.
    case adapterFiles
    /// A `lora` / `adapter` word in a file or repo name. Alone it means "probably".
    case nameToken

    public var label: String {
        switch self {
        case .ggufType: "GGUF general.type"
        case .ggufAdapterKeys: "GGUF adapter keys"
        case .loraTensorNames: "LoRA tensor names"
        case .huggingFaceTags: "Hugging Face tags"
        case .adapterFiles: "Adapter files"
        case .nameToken: "File or repo name"
        }
    }
}

/// A GGUF file that is not offered as a version of the model, and why.
public struct ExcludedArtifactFile: Sendable, Equatable, Identifiable {
    public let path: String
    public let kind: ModelArtifactKind
    public let sizeBytes: Int64?

    public init(path: String, kind: ModelArtifactKind, sizeBytes: Int64?) {
        self.path = path
        self.kind = kind
        self.sizeBytes = sizeBytes
    }

    public var id: String { path }
}

// MARK: - ArtifactClassification

/// What a repository is, and which signal decided it.
public struct ArtifactClassification: Sendable, Equatable {
    public let kind: ModelArtifactKind
    /// The strongest signal that pointed away from a standalone model; `nil` when none did.
    public let signal: ArtifactSignal?
    /// The key, tag, file or word behind ``signal``, for display.
    public let evidence: String?
    /// GGUF files kept out of the version (quantization) list: adapters and auxiliary files.
    public let excludedFiles: [ExcludedArtifactFile]

    /// `isCertain` defaults to `false` only for a name token.
    public init(kind: ModelArtifactKind, signal: ArtifactSignal?, evidence: String?,
                excludedFiles: [ExcludedArtifactFile], isCertain: Bool? = nil) {
        self.kind = kind
        self.signal = signal
        self.evidence = evidence
        self.excludedFiles = excludedFiles
        self.isCertain = isCertain ?? (signal != .nameToken)
    }

    /// `false` when the evidence only suggests ``kind``: a name, or a tag or file that the repo's model files
    /// could not be checked against. A standalone model with an uncertain ``signal`` might be an adapter.
    public let isCertain: Bool

    /// A model, but some evidence says it might be an adapter.
    public var isSuspectedAdapter: Bool { kind.isStandaloneModel && signal != nil }

    public static let standaloneModel = ArtifactClassification(kind: .standaloneModel, signal: nil, evidence: nil,
                                                               excludedFiles: [])
}

// MARK: - ModelArtifactClassifier

/// Decides what a repo is from data the checker already fetched: the listing (files, tags, card), the sampled
/// GGUF header and any tensor names. Pure, so tests drive it with inline snapshots.
public enum ModelArtifactClassifier {

    static let adapterTags: Set<String> = ["lora", "peft", "adapter", "qlora"]
    static let adapterFileNames: Set<String> = [
        "adapter_config.json", "adapter_model.safetensors", "adapter_model.bin", "adapters.safetensors",
    ]
    static let adapterWords: Set<String> = ["lora", "qlora", "adapter", "adapters"]
    /// Words that mark a LoRA already merged into its base: a standalone model despite the name.
    static let mergedWords: Set<String> = ["merged", "merge", "fused"]

    public static func classify(_ snapshot: RepoSnapshot) -> ArtifactClassification {
        let files = snapshot.listing?.files ?? []
        let ggufs = files.filter(\.isGGUF)
        var byName: [String: ModelArtifactKind] = [:]
        for file in ggufs {
            if let kind = nameKind(of: file.path) { byName[file.path] = kind }
        }
        let header = snapshot.ggufMetadata
        let sample = snapshot.ggufSamplePath
        let base = baseModel(snapshot)

        if let header, let sample, let role = auxiliaryRole(ofType: header.generalType) {
            byName[sample] = .auxiliary(role)
        }

        // Header evidence describes the sampled file only: other model files keep the repo a model.
        if let decided = sampleAdapterSignal(header: header, sample: sample) {
            let others = sample.map { path in ggufs.filter { $0.path != path && byName[$0.path] == nil } } ?? []
            guard let sample, !others.isEmpty else {
                return adapter(ggufs, byName: byName, base: base, decision: decided)
            }
            byName[sample] = .adapter(base: base)
            return ArtifactClassification(kind: .standaloneModel, signal: nil, evidence: nil,
                                          excludedFiles: excluded(ggufs, byName: byName, base: base))
        }
        if header?.generalType?.lowercased() != "model",
           let tensor = safetensorsTensorNames(snapshot).first(where: isLoRATensor) {
            return adapter(ggufs, byName: byName, base: base,
                           decision: Decision(signal: .loraTensorNames, evidence: "tensor `\(tensor)`"))
        }

        let candidates = ggufs.filter { byName[$0.path] == nil }
        let nameAdapters = ggufs.filter { byName[$0.path]?.isAdapter == true }
        let confirmedModel = confirmsModel(snapshot, header: header)
        var suspicion: Decision?
        if !confirmedModel, let decided = repoAdapterSignal(snapshot) {
            // Without a header or tensor names, a `lora` tag or a PEFT file next to model files may just be
            // provenance; only `base_model:adapter:` or a repo with nothing else decides.
            let hasModelFiles = !candidates.isEmpty || files.contains {
                $0.isSafetensors && !adapterFileNames.contains($0.filename.lowercased())
            }
            if decided.isDecisive || !hasModelFiles {
                return adapter(ggufs, byName: byName, base: base, decision: decided)
            }
            suspicion = decided
        }

        // A header read from a name-marked file that proves a model clears the name of every such file.
        let sampleWasNameAdapter = sample.map { path in nameAdapters.contains { $0.path == path } } ?? false
        let keepsNameAdapters = confirmedModel && sampleWasNameAdapter
        let excludedFiles = excluded(ggufs, byName: byName, base: base, keepingNameAdapters: keepsNameAdapters)

        guard !confirmedModel else {
            return ArtifactClassification(kind: .standaloneModel, signal: nil, evidence: nil,
                                          excludedFiles: excludedFiles)
        }
        if candidates.isEmpty, let named = nameAdapters.first {
            return ArtifactClassification(kind: .adapter(base: base), signal: .nameToken,
                                          evidence: "`\(named.filename)`", excludedFiles: excludedFiles)
        }
        if let suspicion {
            return ArtifactClassification(kind: .standaloneModel, signal: suspicion.signal,
                                          evidence: suspicion.evidence, excludedFiles: excludedFiles, isCertain: false)
        }
        if let repoName = snapshot.repoID.split(separator: "/").last.map(String.init), hasAdapterWord(repoName) {
            return ArtifactClassification(kind: .standaloneModel, signal: .nameToken,
                                          evidence: "repo name `\(repoName)`", excludedFiles: excludedFiles)
        }
        if candidates.isEmpty, case .auxiliary(let role)? = excludedFiles.first?.kind {
            let fromHeader = auxiliaryRole(ofType: header?.generalType) != nil
            return ArtifactClassification(kind: .auxiliary(role), signal: fromHeader ? .ggufType : nil,
                                          evidence: nil, excludedFiles: excludedFiles)
        }
        return ArtifactClassification(kind: .standaloneModel, signal: nil, evidence: nil, excludedFiles: excludedFiles)
    }

    /// The whole repo is an adapter: every GGUF is excluded, auxiliary files keep their role.
    private static func adapter(_ ggufs: [RepoFile], byName: [String: ModelArtifactKind], base: String?,
                                decision: Decision) -> ArtifactClassification {
        let all = ggufs.map { file in
            ExcludedArtifactFile(path: file.path, kind: auxiliaryKind(byName[file.path]) ?? .adapter(base: base),
                                 sizeBytes: file.sizeBytes)
        }
        return ArtifactClassification(kind: .adapter(base: base), signal: decision.signal, evidence: decision.evidence,
                                      excludedFiles: all)
    }

    private static func excluded(_ ggufs: [RepoFile], byName: [String: ModelArtifactKind], base: String?,
                                 keepingNameAdapters: Bool = false) -> [ExcludedArtifactFile] {
        ggufs.compactMap { file -> ExcludedArtifactFile? in
            guard let kind = byName[file.path], !(kind.isAdapter && keepingNameAdapters) else { return nil }
            return ExcludedArtifactFile(path: file.path, kind: kind.isAdapter ? .adapter(base: base) : kind,
                                        sizeBytes: file.sizeBytes)
        }
    }

    // MARK: Signals

    private struct Decision {
        let signal: ArtifactSignal
        let evidence: String
        /// Strong enough to call the repo an adapter even when it also holds model files.
        var isDecisive = true
    }

    /// Signals 1–3, read from the sampled GGUF: `general.type`, `adapter.*` keys, LoRA tensor names.
    private static func sampleAdapterSignal(header: GGUFHeader?, sample: String?) -> Decision? {
        guard let header else { return nil }
        let file = sample.map { " in `\(($0 as NSString).lastPathComponent)`" } ?? ""
        if let type = header.generalType?.lowercased() {
            if type == "adapter" { return Decision(signal: .ggufType, evidence: "`general.type` = `adapter`\(file)") }
            if type == "model" { return nil }
        }
        if let key = header.metadata.keys.filter({ $0.hasPrefix("adapter.") }).min() {
            return Decision(signal: .ggufAdapterKeys, evidence: "`\(key)`\(file)")
        }
        if let tensor = header.tensorNames.first(where: isLoRATensor) {
            return Decision(signal: .loraTensorNames, evidence: "tensor `\(tensor)`\(file)")
        }
        return nil
    }

    /// Signals 4–5, about the repo: tags and PEFT files. Only `base_model:adapter:` decides on its own.
    private static func repoAdapterSignal(_ snapshot: RepoSnapshot) -> Decision? {
        let tags = snapshot.listing?.tags ?? []
        if let tag = tags.first(where: { $0.hasPrefix("base_model:adapter:") }) {
            return Decision(signal: .huggingFaceTags, evidence: "tag `\(tag)`")
        }
        if let tag = tags.first(where: { adapterTags.contains($0.lowercased()) }) {
            return Decision(signal: .huggingFaceTags, evidence: "tag `\(tag)`", isDecisive: false)
        }
        if let file = snapshot.listing?.files.first(where: { adapterFileNames.contains($0.filename.lowercased()) }) {
            return Decision(signal: .adapterFiles, evidence: "`\(file.path)`", isDecisive: false)
        }
        return nil
    }

    /// The sampled header says model (`general.type`, or the layer count an adapter header lacks), or the tensor
    /// names were read and none is a LoRA delta.
    private static func confirmsModel(_ snapshot: RepoSnapshot, header: GGUFHeader?) -> Bool {
        if let type = header?.generalType?.lowercased() { return type == "model" }
        if header?.blockCount != nil { return true }
        let names = tensorNames(snapshot)
        return !names.isEmpty && !names.contains(where: isLoRATensor)
    }

    private static func safetensorsTensorNames(_ snapshot: RepoSnapshot) -> [String] {
        snapshot.liveWeightMap.map { Array($0.keys) } ?? snapshot.singleFileHeader?.tensorNames ?? []
    }

    static func tensorNames(_ snapshot: RepoSnapshot) -> [String] {
        safetensorsTensorNames(snapshot) + (snapshot.ggufMetadata?.tensorNames ?? [])
    }

    static func isLoRATensor(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".lora_a") || lower.hasSuffix(".lora_b")
            || lower.contains(".lora_a.") || lower.contains(".lora_b.")
    }

    private static func auxiliaryRole(ofType type: String?) -> AuxiliaryArtifact? {
        switch type?.lowercased() {
        case "mmproj"?: .visionProjector
        case "imatrix"?: .importanceMatrix
        default: nil
        }
    }

    private static func auxiliaryKind(_ kind: ModelArtifactKind?) -> ModelArtifactKind? {
        if case .auxiliary? = kind { return kind }
        return nil
    }

    // MARK: Names

    /// What a GGUF file is by its name alone; `nil` for a model candidate.
    static func nameKind(of path: String) -> ModelArtifactKind? {
        let filename = (path as NSString).lastPathComponent
        if filename.lowercased().contains("mmproj") { return .auxiliary(.visionProjector) }
        let words = Set(nameWords(filename))
        if words.contains("imatrix") { return .auxiliary(.importanceMatrix) }
        return hasAdapterWord(filename) ? .adapter(base: nil) : nil
    }

    /// Word-bounded: `flora` and `explorer` are not adapters, `x-lora-F16` is, `x-lora-merged` is not.
    static func hasAdapterWord(_ name: String) -> Bool {
        let words = Set(nameWords(name))
        return !words.isDisjoint(with: adapterWords) && words.isDisjoint(with: mergedWords)
    }

    private static func nameWords(_ name: String) -> [String] {
        let stem = name.lowercased().hasSuffix(".gguf") ? (name as NSString).deletingPathExtension : name
        return stem.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    // MARK: Base model

    /// The base model's id or name: the GGUF header's repo URL, the `base_model:adapter:` tag, the card's
    /// `base_model`, a plain `base_model:` tag, then the header's base name.
    static func baseModel(_ snapshot: RepoSnapshot) -> String? {
        let metadata = snapshot.ggufMetadata?.metadata ?? [:]
        if let url = metadata["general.base_model.0.repo_url"]?.text, let repo = huggingFaceRepo(fromURL: url) {
            return repo
        }
        let tags = snapshot.listing?.tags ?? []
        if let tag = tags.first(where: { $0.hasPrefix("base_model:adapter:") }) {
            return String(tag.dropFirst("base_model:adapter:".count))
        }
        if let card = snapshot.listing?.baseModels.first { return card }
        if let tag = tags.first(where: { $0.hasPrefix("base_model:") && $0.dropFirst("base_model:".count).contains("/")
                                             && !$0.dropFirst("base_model:".count).contains(":") }) {
            return String(tag.dropFirst("base_model:".count))
        }
        guard let name = metadata["general.base_model.0.name"]?.text, !name.isEmpty else { return nil }
        let organization = metadata["general.base_model.0.organization"]?.text
        return organization.map { "\(name) (\($0))" } ?? name
    }

    private static func huggingFaceRepo(fromURL text: String) -> String? {
        guard let url = URL(string: text), let host = url.host?.lowercased(),
              host == "huggingface.co" || host == "hf.co" else { return nil }
        let parts = url.path.split(separator: "/")
        return parts.count >= 2 ? "\(parts[0])/\(parts[1])" : nil
    }
}
