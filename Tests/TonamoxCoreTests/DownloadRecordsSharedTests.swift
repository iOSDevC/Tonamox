import Foundation
import os
import Testing
@testable import TonamoxCore

/// Download records in the shared JSON file, in a folder whose path has a space. Serialized: these register models
/// in the process-wide registry.
@Suite(.serialized)
final class DownloadRecordsSharedTests {
    private let root: URL
    private let file: SharedRecordsFile
    private let suiteName = "DownloadRecordsSharedTests-\(UUID().uuidString)"
    private let defaults: UserDefaults
    private var registeredIDs: [String] = []

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "DownloadRecordsSharedTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let base = root.appending(path: "Library/Application Support/AuraLocal", directoryHint: .isDirectory)
        file = SharedRecordsFile(file: base.appending(path: "download-records.json"),
                                 lockFile: base.appending(path: "records.lock"))
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    deinit {
        registeredIDs.forEach { ModelRegistry.shared.unregister(id: $0) }
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    private func makeModel(_ suffix: String) throws -> Model {
        let tag = UUID().uuidString.prefix(8).lowercased()
        let entry = CatalogEntry(
            id: "test_shared_records_\(suffix)_\(tag)", repoID: "test-org/shared-\(suffix)-\(tag)",
            displayName: "Shared \(suffix)", modelCategory: .text, weightFormat: .gguf, approximateSizeMB: 412,
            isUncensored: false, ggufFilename: "model-Q4_K_M.gguf", numLayers: 24, kvHeads: 2, headDim: 64,
            maxContextLength: 4096)
        let model = try #require(entry.decodedModel())
        registeredIDs.append(model.id)
        return model
    }

    private func counter() -> (count: @Sendable () -> Int, increment: @Sendable () -> Void) {
        let value = OSAllocatedUnfairLock(initialState: 0)
        return ({ value.withLock { $0 } }, { value.withLock { $0 += 1 } })
    }

    // MARK: Merge

    @Test func mergeCopiesStandardRecordsOnceAndKeepsThem() throws {
        defaults.set(["a": Data("legacy-a".utf8), "b": Data("legacy-b".utf8)], forKey: DownloadRecords.legacyKey)
        defaults.set(["b": Data("current-b".utf8), "c": Data("current-c".utf8)], forKey: DownloadRecords.defaultsKey)
        try file.update { records in
            records["c"] = Data("shared-c".utf8)
            return true
        }

        let added = file.mergeOnce(from: defaults, keys: [DownloadRecords.legacyKey, DownloadRecords.defaultsKey],
                                   flagKey: DownloadRecords.mergedFlagKey)

        #expect(added == 2)
        #expect(file.read() == ["a": Data("legacy-a".utf8), "b": Data("current-b".utf8), "c": Data("shared-c".utf8)])
        #expect(defaults.dictionary(forKey: DownloadRecords.defaultsKey)?.count == 2)
        #expect(defaults.dictionary(forKey: DownloadRecords.legacyKey)?.count == 2)
        #expect(defaults.bool(forKey: DownloadRecords.mergedFlagKey))

        defaults.set(["d": Data("late".utf8)], forKey: DownloadRecords.defaultsKey)
        #expect(file.mergeOnce(from: defaults, keys: [DownloadRecords.defaultsKey],
                               flagKey: DownloadRecords.mergedFlagKey) == 0)
        #expect(file.read()["d"] == nil)
    }

    // MARK: Records

    @Test func twoInstancesSeeEachOthersWritesAndNotifyOnlyOnChange() throws {
        let changes = counter()
        let first = DownloadRecords(sharedFile: file, onChange: changes.increment)
        let second = DownloadRecords(sharedFile: SharedRecordsFile(file: file.file, lockFile: file.lockFile),
                                     onChange: changes.increment)
        let model = try makeModel("notify")

        first.remember(model)
        first.remember(model)
        #expect(changes.count() == 1)
        #expect(second.models.map(\.id) == [model.id])

        second.forget(model)
        second.forget(model)
        #expect(changes.count() == 2)
        #expect(first.models.isEmpty)
    }

    @Test func sharedRecordsAreNeverPruned() throws {
        let records = DownloadRecords(sharedFile: file, onChange: {})
        let model = try makeModel("kept")
        records.remember(model)

        let listed = records.registerDownloaded(isOnDisk: { _ in false }, bytesOnDisk: { _ in 0 })

        #expect(listed.isEmpty)
        #expect(records.models.map(\.id) == [model.id])
    }

    @Test func unregisterVanishedTakesBackModelsAnotherAppDeleted() throws {
        let mine = DownloadRecords(sharedFile: file, onChange: {})
        let theirs = DownloadRecords(sharedFile: file, onChange: {})
        let deleted = try makeModel("deleted")
        let kept = try makeModel("still")
        mine.remember(deleted)
        mine.remember(kept)
        _ = mine.registerDownloaded(isOnDisk: { _ in true }, bytesOnDisk: { _ in 1 })
        #expect(ModelRegistry.shared.model(id: deleted.id) != nil)

        theirs.forget(deleted)
        let vanished = mine.unregisterVanished()

        #expect(vanished == [deleted.id])
        #expect(ModelRegistry.shared.model(id: deleted.id) == nil)
        #expect(ModelRegistry.shared.model(id: kept.id) != nil)
    }

    @Test func concurrentUpdatesKeepEveryRecord() {
        let file = file
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            _ = try? file.update { records in
                records["key-\(index)"] = Data([UInt8(index)])
                return true
            }
        }

        #expect(file.read().count == 64)
        #expect(FileManager.default.fileExists(atPath: file.lockFile.path(percentEncoded: false)))
    }

    @Test func anUndecodableFileIsMovedAsideInsteadOfOverwritten() throws {
        let folder = file.file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: file.file)

        try file.update { records in
            records["new"] = Data([1])
            return true
        }

        #expect(file.read() == ["new": Data([1])])
        let aside = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
            .filter { $0.hasPrefix("download-records.json.corrupt-") }
        #expect(aside.count == 1)
        let kept = try Data(contentsOf: folder.appending(path: try #require(aside.first)))
        #expect(String(decoding: kept, as: UTF8.self) == "{not json")
    }

    @Test func standardInstancesStillPruneAndNotify() throws {
        let changes = counter()
        let records = DownloadRecords(defaults: defaults, onChange: changes.increment)
        let model = try makeModel("pruned")
        records.remember(model)

        records.registerDownloaded(isOnDisk: { _ in false }, bytesOnDisk: { _ in 0 })

        #expect(records.models.isEmpty)
        #expect(changes.count() == 2)
    }
}
