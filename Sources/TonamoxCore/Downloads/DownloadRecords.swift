import Foundation
import os

/// The sized ``Model`` behind each download from a search result, so it can be registered again after a relaunch.
/// Files on disk stay the source of truth; a record only describes them.
///
/// Record only models built by ``CatalogEntry/decodedModel()``: a ``Model/fromURL(_:displayName:)`` model has
/// size 0, which the memory guard always rates as fitting.
public struct DownloadRecords: @unchecked Sendable {
    /// Records in `UserDefaults.standard`, or, once ``TonamoxSharedStorage/configure(appGroup:)`` applied a group,
    /// in `AuraLocal/download-records.json` that every app of the group shares. The first shared access copies the
    /// records this app kept in `UserDefaults.standard` into the file once, and leaves them there.
    public static var standard: DownloadRecords { resolvedStandard }

    static let defaultsKey = "dev.auralocal.downloadRecords"
    /// Where the Model Finder example kept records before they moved to TonamoxCore.
    static let legacyKey = "downloadRecords"
    /// Set in `UserDefaults.standard` once its records were copied into the shared file.
    static let mergedFlagKey = "dev.auralocal.downloadRecords.mergedIntoShared"

    private static let resolvedStandard: DownloadRecords = {
        let resolution = TonamoxSharedStorage.resolution(for: .records)
        guard let file = resolution.downloadRecordsFile, let lockFile = resolution.recordsLockFile else {
            return DownloadRecords()
        }
        let shared = SharedRecordsFile(file: file, lockFile: lockFile)
        shared.mergeOnce(from: .standard, keys: [legacyKey, defaultsKey], flagKey: mergedFlagKey)
        return DownloadRecords(sharedFile: shared)
    }()

    /// Sorted keys, so encoding an unchanged model gives the same bytes and is not reported as a change.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private static let decoder = JSONDecoder()
    /// Every read-modify-write of the stored dictionary holds this, so concurrent writers don't drop records.
    /// Static because instances on the same `UserDefaults` share the dictionary.
    private static let lock = NSLock()
    /// Ids ``registerDownloaded()`` put in the registry, so ``unregisterVanished()`` can take back only those.
    private static let listedIDs = OSAllocatedUnfairLock(initialState: Set<String>())

    private enum Backing {
        case defaults(UserDefaults)
        case shared(SharedRecordsFile)
    }

    // The reason for @unchecked: UserDefaults is thread-safe per call but not marked Sendable in this SDK;
    // updates that span calls hold `lock`.
    private let store: Backing
    private let onChange: @Sendable () -> Void

    public init(defaults: UserDefaults = .standard) {
        self.init(defaults: defaults, onChange: Self.postModelsChange)
    }

    /// Records in `defaults`; `onChange` runs after a write that changed them.
    package init(defaults: UserDefaults, onChange: @escaping @Sendable () -> Void) {
        store = .defaults(defaults)
        self.onChange = onChange
    }

    /// Records in a file shared across processes. Never pruned: another app may hold the file in a root this
    /// process cannot read.
    package init(sharedFile: SharedRecordsFile, onChange: @escaping @Sendable () -> Void = DownloadRecords.postModelsChange) {
        store = .shared(sharedFile)
        self.onChange = onChange
    }

    package static let postModelsChange: @Sendable () -> Void = { TonamoxSharedStorage.postChange(.models) }

    // MARK: Records

    /// File identity, not model id: `gguf:<repo>/<file>` or `mlx:<repo>`. Two ids for one file share a key.
    public static func key(for model: Model) -> String {
        switch model.format {
        case .gguf: "gguf:\(model.repoID)/\(model.ggufFilename ?? "")"
        case .mlx: "mlx:\(model.repoID)"
        }
    }

    /// Stores `model` under its file key, replacing any record for the same file. Call it when a download starts,
    /// so a partial file can resume with its size after a relaunch.
    public func remember(_ model: Model) {
        guard let data = try? Self.encoder.encode(model) else { return }
        let key = Self.key(for: model)
        changeRecords { stored in
            guard stored[key] != data else { return false }
            stored[key] = data
            return true
        }
    }

    /// Drops the record for `model`'s file, if any. Leaves the files and the registry alone.
    public func forget(_ model: Model) {
        let key = Self.key(for: model)
        changeRecords { stored in stored.removeValue(forKey: key) != nil }
    }

    /// Every record that still decodes, sorted by id.
    public var models: [Model] {
        snapshot().values.compactMap(Self.decode).sorted { $0.id < $1.id }
    }

    /// The record for one file; a `nil` filename means the MLX snapshot of `repoID`.
    public func model(repoID: String, ggufFilename: String?) -> Model? {
        let key = ggufFilename.map { "gguf:\(repoID)/\($0)" } ?? "mlx:\(repoID)"
        return Self.decode(snapshot()[key])
    }

    /// Whether a record has `model`'s id. A catalog model whose file was downloaded from search keeps its own id,
    /// so it does not count as recorded.
    public func contains(_ model: Model) -> Bool {
        models.contains { $0.id == model.id }
    }

    // MARK: Registry

    /// Registers each recorded model that is fully on disk, unless a registry entry already points at the same
    /// file, and drops records with nothing on disk (deleted, or purged from Caches before migration). A partial
    /// file keeps its record for Resume.
    /// Returns the models now listed under their own id.
    @discardableResult
    public func registerDownloaded() -> [Model] {
        registerDownloaded(isOnDisk: { $0.isDownloaded }, bytesOnDisk: { ModelDownloads.bytesOnDisk(for: $0) })
    }

    /// The ``registerDownloaded()`` rule for one model, after its download finished. Returns whether it is listed
    /// under its own id.
    @discardableResult
    public func registerIfDownloaded(_ model: Model) -> Bool {
        registerIfDownloaded(model, isOnDisk: { $0.isDownloaded })
    }

    /// Forgets the record and unregisters the model. A no-op for the registry when `model` comes from a catalog.
    public func remove(_ model: Model) {
        forget(model)
        ModelRegistry.shared.unregister(id: model.id)
        Self.listedIDs.withLock { _ = $0.remove(model.id) }
    }

    /// Unregisters the models ``registerDownloaded()`` listed whose record is gone, for example deleted by another
    /// app of the group. Returns their ids.
    @discardableResult
    package func unregisterVanished() -> [String] {
        let recorded = Set(models.map(\.id))
        let vanished = Self.listedIDs.withLock { listed -> [String] in
            let gone = listed.subtracting(recorded)
            listed.subtract(gone)
            return gone.sorted()
        }
        for id in vanished {
            ModelRegistry.shared.unregister(id: id)
        }
        return vanished
    }

    @discardableResult
    func registerDownloaded(isOnDisk: (Model) -> Bool, bytesOnDisk: (Model) -> Int64) -> [Model] {
        switch store {
        case .shared:
            let listed = snapshot().values.compactMap(Self.decode).filter { isOnDisk($0) && Self.list($0) }
            return listed.sorted { $0.id < $1.id }
        case .defaults(let defaults):
            let (listed, pruned) = Self.lock.withLock { () -> ([Model], Bool) in
                var stored = all(defaults)
                var listed: [Model] = []
                var pruned = false
                for (key, data) in stored {
                    guard let model = Self.decode(data) else { continue }
                    if isOnDisk(model) {
                        if Self.list(model) { listed.append(model) }
                    } else if bytesOnDisk(model) == 0 {
                        stored[key] = nil
                        pruned = true
                    }
                }
                if pruned { defaults.set(stored, forKey: Self.defaultsKey) }
                return (listed, pruned)
            }
            if pruned { onChange() }
            return listed.sorted { $0.id < $1.id }
        }
    }

    func registerIfDownloaded(_ model: Model, isOnDisk: (Model) -> Bool) -> Bool {
        guard isOnDisk(model) else { return false }
        return Self.list(model)
    }

    /// Registers `model` unless the registry already has its file: a catalog entry for the same file already loads
    /// it and shows as downloaded, and a second id would list one file twice in the pickers.
    private static func list(_ model: Model) -> Bool {
        let registry = ModelRegistry.shared
        let fileKey = key(for: model)
        if let existing = registry.models.first(where: { key(for: $0) == fileKey }) {
            guard existing.id == model.id else { return false }
            listedIDs.withLock { _ = $0.insert(model.id) }
            return true
        }
        registry.register(model)
        listedIDs.withLock { _ = $0.insert(model.id) }
        return true
    }

    // MARK: Storage

    private func snapshot() -> [String: Data] {
        switch store {
        case .defaults(let defaults): Self.lock.withLock { all(defaults) }
        case .shared(let file): file.read()
        }
    }

    /// Runs `body` on the stored records as one read-modify-write; calls `onChange` when it changed them.
    private func changeRecords(_ body: (inout [String: Data]) -> Bool) {
        let changed: Bool
        switch store {
        case .defaults(let defaults):
            changed = Self.lock.withLock {
                var stored = all(defaults)
                guard body(&stored) else { return false }
                defaults.set(stored, forKey: Self.defaultsKey)
                return true
            }
        case .shared(let file):
            do {
                changed = try Self.lock.withLock { try file.update(body) }
            } catch {
                SharedRecordsFile.log.error("could not write download records: \(error.localizedDescription, privacy: .public)")
                changed = false
            }
        }
        if changed { onChange() }
    }

    /// Call only while holding `lock`: the one-time legacy copy is a write too.
    private func all(_ defaults: UserDefaults) -> [String: Data] {
        if let stored = defaults.dictionary(forKey: Self.defaultsKey) as? [String: Data] { return stored }
        // One-time copy from the old key; the old key stays for older builds of the example.
        guard let legacy = defaults.dictionary(forKey: Self.legacyKey) as? [String: Data] else { return [:] }
        defaults.set(legacy, forKey: Self.defaultsKey)
        return legacy
    }

    private static func decode(_ data: Data?) -> Model? {
        data.flatMap { try? decoder.decode(Model.self, from: $0) }
    }
}
