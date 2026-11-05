import Foundation
import TonamoxCore

/// The Hugging Face image models the user adopted, so they are listed again after a relaunch. Files on disk stay
/// the source of truth: a record describes a model, ``CoreMLDiffusionModel/isDownloaded`` says whether it is there.
/// The built-in model is always listed and never stored.
public struct CoreMLDiffusionModelStore: @unchecked Sendable {
    /// Records in `UserDefaults.standard`, or, once ``TonamoxSharedStorage/configure(appGroup:)`` applied a group,
    /// in `AuraLocal/image-model-records.json` that every app of the group shares. The first shared access copies
    /// this app's `UserDefaults.standard` records into the file once, and leaves them there.
    public static var standard: CoreMLDiffusionModelStore { resolvedStandard }

    static let defaultsKey = "dev.auralocal.coreMLDiffusionModels"
    /// Set in `UserDefaults.standard` once its records were copied into the shared file.
    static let mergedFlagKey = "dev.auralocal.coreMLDiffusionModels.mergedIntoShared"

    private static let resolvedStandard: CoreMLDiffusionModelStore = {
        let resolution = TonamoxSharedStorage.resolution(for: .imageRecords)
        guard let file = resolution.imageRecordsFile, let lockFile = resolution.recordsLockFile else {
            return CoreMLDiffusionModelStore()
        }
        let shared = SharedRecordsFile(file: file, lockFile: lockFile)
        shared.mergeOnce(from: .standard, keys: [defaultsKey], flagKey: mergedFlagKey)
        return CoreMLDiffusionModelStore(sharedFile: shared)
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

    private enum Backing {
        case defaults(UserDefaults)
        case shared(SharedRecordsFile)
    }

    // The reason for @unchecked: UserDefaults is thread-safe per call but not marked Sendable in this SDK;
    // updates that span calls hold `lock`.
    private let store: Backing
    private let onChange: @Sendable () -> Void

    public init(defaults: UserDefaults = .standard) {
        self.init(defaults: defaults, onChange: CoreMLDiffusionModelStore.postModelsChange)
    }

    /// Records in `defaults`; `onChange` runs after a write that changed them.
    package init(defaults: UserDefaults, onChange: @escaping @Sendable () -> Void) {
        store = .defaults(defaults)
        self.onChange = onChange
    }

    /// Records in a file shared across processes.
    package init(sharedFile: SharedRecordsFile,
                 onChange: @escaping @Sendable () -> Void = CoreMLDiffusionModelStore.postModelsChange) {
        store = .shared(sharedFile)
        self.onChange = onChange
    }

    package static let postModelsChange: @Sendable () -> Void = { TonamoxSharedStorage.postChange(.models) }

    /// Stores `model` under its id, replacing an earlier record of the same folder. Call it when a download
    /// starts, so a partial download is listed after a relaunch. Ignores the built-in model.
    public func remember(_ model: CoreMLDiffusionModel) {
        guard !model.isBuiltIn, let data = try? Self.encoder.encode(model) else { return }
        changeRecords { stored in
            guard stored[model.id] != data else { return false }
            stored[model.id] = data
            return true
        }
    }

    /// Drops the record; leaves the files alone (``CoreMLDiffusionModel/delete()`` removes them).
    public func forget(_ model: CoreMLDiffusionModel) {
        changeRecords { stored in stored.removeValue(forKey: model.id) != nil }
    }

    /// The built-in model first, then every record that still decodes, by display name.
    public var all: [CoreMLDiffusionModel] {
        let stored = records().values.compactMap(Self.decode)
            .sorted { ($0.displayName, $0.id) < ($1.displayName, $1.id) }
        return [.stableDiffusion21Base] + stored
    }

    /// The built-in model or a record, by ``CoreMLDiffusionModel/id``.
    public func model(id: String) -> CoreMLDiffusionModel? {
        if id == CoreMLDiffusionModel.stableDiffusion21Base.id { return .stableDiffusion21Base }
        return Self.decode(records()[id])
    }

    // MARK: Storage

    private func records() -> [String: Data] {
        switch store {
        case .defaults(let defaults):
            Self.lock.withLock { defaults.dictionary(forKey: Self.defaultsKey) as? [String: Data] ?? [:] }
        case .shared(let file):
            file.read()
        }
    }

    /// Runs `body` on the stored records as one read-modify-write; calls `onChange` when it changed them.
    private func changeRecords(_ body: (inout [String: Data]) -> Bool) {
        let changed: Bool
        switch store {
        case .defaults(let defaults):
            changed = Self.lock.withLock {
                var stored = defaults.dictionary(forKey: Self.defaultsKey) as? [String: Data] ?? [:]
                guard body(&stored) else { return false }
                defaults.set(stored, forKey: Self.defaultsKey)
                return true
            }
        case .shared(let file):
            changed = (try? Self.lock.withLock { try file.update(body) }) ?? false
        }
        if changed { onChange() }
    }

    private static func decode(_ data: Data?) -> CoreMLDiffusionModel? {
        data.flatMap { try? decoder.decode(CoreMLDiffusionModel.self, from: $0) }
    }
}
