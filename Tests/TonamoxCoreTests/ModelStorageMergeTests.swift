import Foundation
import Testing
@testable import TonamoxCore

/// Merging an app's private model root into its App Group root, on temporary folders whose paths contain spaces.
struct ModelStorageMergeTests {
    private let base: URL
    private let source: URL
    private let destination: URL

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appending(path: "ModelStorageMergeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        source = base.appending(path: "Private/Library/Application Support/AuraLocal/Models", directoryHint: .isDirectory)
        destination = base.appending(path: "Group Containers/group x/Library/Application Support/AuraLocal/Models",
                                     directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: base)
    }

    @discardableResult
    private func write(_ text: String, at relative: String, under folder: URL) throws -> URL {
        let file = folder.appending(path: relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        return file
    }

    private func exists(_ relative: String, under folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appending(path: relative).path(percentEncoded: false))
    }

    private func contents(_ relative: String, under folder: URL) -> String? {
        (try? Data(contentsOf: folder.appending(path: relative))).map { String(decoding: $0, as: UTF8.self) }
    }

    private func merge(from origin: URL? = nil) -> ModelStorageMigration {
        ModelStorage.mergeTree(from: origin ?? source, to: destination, fileManager: .default)
    }

    private let snapshot = "huggingface/hub/models--org--repo/snapshots/main"

    // MARK: Moves

    @Test func movesWholeSubtreesWhenTheDestinationIsAbsent() throws {
        defer { cleanUp() }
        try write("weights", at: "models/org/repo/a.gguf", under: source)
        let partial = try write("half", at: "models/org/repo/b.gguf.partial", under: source)
        HubFileTransfer.setValidator("\"etag-1\"", of: partial)
        try write("", at: "\(snapshot)/.complete", under: source)
        try write("mlx", at: "\(snapshot)/model.safetensors", under: source)

        let report = merge()

        #expect(report.moved == ["huggingface", "models"])
        #expect(report.conflicts.isEmpty && report.failures.isEmpty && report.duplicatesRemoved.isEmpty)
        #expect(contents("models/org/repo/a.gguf", under: destination) == "weights")
        #expect(exists("\(snapshot)/.complete", under: destination))
        let moved = HubFileTransfer.partialURL(for: destination.appending(path: "models/org/repo/b.gguf"))
        #expect(HubFileTransfer.validator(of: moved) == "\"etag-1\"")
        #expect(!exists("models", under: source))
    }

    @Test func recursesIntoFoldersBothSidesHave() throws {
        defer { cleanUp() }
        try write("theirs", at: "models/org/other/b.gguf", under: destination)
        try write("mine", at: "models/org/repo/a.gguf", under: source)

        let report = merge()

        #expect(report.moved == ["models/org/repo"])
        #expect(contents("models/org/other/b.gguf", under: destination) == "theirs")
        #expect(contents("models/org/repo/a.gguf", under: destination) == "mine")
        #expect(!exists("models", under: source))
    }

    @Test func aSecondRunIsANoOp() throws {
        defer { cleanUp() }
        try write("mine", at: "models/org/repo/a.gguf", under: source)
        _ = merge()

        #expect(merge().isEmpty)
    }

    // MARK: Conflicts

    @Test func keepsAConflictingFileInTheSource() throws {
        defer { cleanUp() }
        try write("theirs", at: "models/org/repo/a.gguf", under: destination)
        try write("mine!!", at: "models/org/repo/a.gguf", under: source)

        let report = merge()

        #expect(report.conflicts == ["models/org/repo/a.gguf"])
        #expect(contents("models/org/repo/a.gguf", under: destination) == "theirs")
        #expect(contents("models/org/repo/a.gguf", under: source) == "mine!!")
    }

    @Test func removesAnIdenticalVerifiedCopy() throws {
        defer { cleanUp() }
        let digest = String(repeating: "ab", count: 32)
        FileIntegrity.recordVerified(try write("weights", at: "models/org/repo/a.gguf", under: destination),
                                     sha256: digest)
        FileIntegrity.recordVerified(try write("weights", at: "models/org/repo/a.gguf", under: source),
                                     sha256: digest)

        let report = merge()

        #expect(report.duplicatesRemoved == ["models/org/repo/a.gguf"])
        #expect(report.conflicts.isEmpty)
        #expect(!exists("models/org/repo/a.gguf", under: source))
        #expect(contents("models/org/repo/a.gguf", under: destination) == "weights")
    }

    @Test func keepsAnUnverifiedCopyEvenWhenTheBytesMatch() throws {
        defer { cleanUp() }
        try write("weights", at: "models/org/repo/a.gguf", under: destination)
        try write("weights", at: "models/org/repo/a.gguf", under: source)

        #expect(merge().conflicts == ["models/org/repo/a.gguf"])
        #expect(exists("models/org/repo/a.gguf", under: source))
    }

    @Test func neverMergesIntoACompleteSnapshot() throws {
        defer { cleanUp() }
        try write("", at: "\(snapshot)/.complete", under: destination)
        try write("new", at: "\(snapshot)/model.safetensors", under: destination)
        try write("old", at: "\(snapshot)/model-00002.safetensors", under: source)

        let report = merge()

        #expect(report.conflicts == [snapshot])
        #expect(!exists("\(snapshot)/model-00002.safetensors", under: destination))
        #expect(exists("\(snapshot)/model-00002.safetensors", under: source))
    }

    @Test func neverMergesTwoUnfinishedSnapshots() throws {
        defer { cleanUp() }
        try write("a", at: "\(snapshot)/model.safetensors.partial", under: destination)
        try write("b", at: "\(snapshot)/config.json", under: source)

        #expect(merge().conflicts == [snapshot])
        #expect(!exists("\(snapshot)/config.json", under: destination))
    }

    @Test func movesAFolderDownloadBesideAnotherAndKeepsAConflictingOne() throws {
        defer { cleanUp() }
        try write("r1", at: "\(snapshot)/split/.revision", under: destination)
        try write("x", at: "\(snapshot)/split/unet.bin", under: destination)
        try write("y", at: "\(snapshot)/split/unet.bin.partial", under: source)
        try write("r1", at: "\(snapshot)/original/.complete", under: source)
        try write("z", at: "\(snapshot)/original/unet.bin", under: source)

        let report = merge()

        #expect(report.moved == ["\(snapshot)/original"])
        #expect(report.conflicts == ["\(snapshot)/split"])
        #expect(exists("\(snapshot)/original/unet.bin", under: destination))
        #expect(!exists("\(snapshot)/split/unet.bin.partial", under: destination))
    }

    @Test func removesACompleteFolderWithTheSameRevisionAndFiles() throws {
        defer { cleanUp() }
        for root in [source, destination] {
            try write("r1", at: "\(snapshot)/split/.revision", under: root)
            try write("r1", at: "\(snapshot)/split/.complete", under: root)
            try write("unet", at: "\(snapshot)/split/unet.bin", under: root)
        }

        let report = merge()

        #expect(report.duplicatesRemoved == ["\(snapshot)/split"])
        #expect(!exists("\(snapshot)/split", under: source))
        #expect(exists("\(snapshot)/split/unet.bin", under: destination))
    }

    @Test func keepsACompleteFolderFromAnotherRevision() throws {
        defer { cleanUp() }
        try write("r1", at: "\(snapshot)/split/.complete", under: destination)
        try write("unet", at: "\(snapshot)/split/unet.bin", under: destination)
        try write("r2", at: "\(snapshot)/split/.complete", under: source)
        try write("unet", at: "\(snapshot)/split/unet.bin", under: source)

        #expect(merge().conflicts == ["\(snapshot)/split"])
    }

    @Test func atomicPathsMoveWholeOrStay() throws {
        defer { cleanUp() }
        try write("t", at: "multilingual-e5-small/tokenizer.json", under: destination)
        try write("w", at: "multilingual-e5-small/model.mlpackage", under: source)
        try write("w", at: "other-bundle/model.mlpackage", under: source)

        let report = ModelStorage.mergeTree(from: source, to: destination, isAtomic: { !$0.contains("/") },
                                            fileManager: .default)

        #expect(report.moved == ["other-bundle"])
        #expect(report.conflicts == ["multilingual-e5-small"])
        #expect(!exists("multilingual-e5-small/model.mlpackage", under: destination))
    }

    @Test func leavesLockFilesBehind() throws {
        defer { cleanUp() }
        try write("theirs", at: "models/org/repo/b.gguf", under: destination)
        try write("", at: "models/org/repo/a.gguf.lock", under: source)
        try write("mine", at: "models/org/repo/a.gguf", under: source)

        let report = merge()

        #expect(report.moved == ["models/org/repo/a.gguf"])
        #expect(!exists("models/org/repo/a.gguf.lock", under: destination))
        #expect(exists("models/org/repo/a.gguf.lock", under: source))
    }

    @Test func concurrentMergesFromTwoSourcesOverwriteNothing() throws {
        defer { cleanUp() }
        let other = base.appending(path: "Other App/Library/Application Support/AuraLocal/Models",
                                   directoryHint: .isDirectory)
        try write("first", at: "models/org/repo/x.gguf", under: source)
        try write("second", at: "models/org/repo/x.gguf", under: other)
        try write("only", at: "models/org/repo/y.gguf", under: other)
        let origins = [source, other]
        let target = destination

        DispatchQueue.concurrentPerform(iterations: origins.count) { index in
            _ = ModelStorage.mergeTree(from: origins[index], to: target, fileManager: .default)
        }

        let winner = try #require(contents("models/org/repo/x.gguf", under: destination))
        let loser = winner == "first" ? other : source
        #expect(["first", "second"].contains(winner))
        #expect(contents("models/org/repo/x.gguf", under: loser) == (winner == "first" ? "second" : "first"))
        #expect(contents("models/org/repo/y.gguf", under: destination) == "only")
    }

    // MARK: Private data

    private var privateSupport: URL { base.appending(path: "Private/Library/Application Support") }
    private var groupSupport: URL { base.appending(path: "Group Containers/group x/Library/Application Support") }
    private let bundle = "AuraLocal/embeddings/multilingual-e5-small"

    private func mergePrivateData() {
        ModelStorage.mergePrivateData(from: privateSupport, into: groupSupport, privateRoot: source,
                                      root: destination, fileManager: .default)
    }

    @Test func privateDataMergeMovesModelsAndDropsAnEmbeddingBundleTheGroupAlreadyHas() throws {
        defer { cleanUp() }
        try write("weights", at: "models/org/repo/a.gguf", under: source)
        try write("model", at: "\(bundle)/model.mlpackage/weights.bin", under: privateSupport)
        try write("vocab", at: "\(bundle)/tokenizer.json", under: privateSupport)
        try write("model", at: "\(bundle)/model.mlpackage/weights.bin", under: groupSupport)
        try write("vocab", at: "\(bundle)/tokenizer.json", under: groupSupport)

        mergePrivateData()

        #expect(contents("models/org/repo/a.gguf", under: destination) == "weights")
        #expect(!exists(bundle, under: privateSupport))
        #expect(contents("\(bundle)/tokenizer.json", under: groupSupport) == "vocab")
    }

    @Test func privateDataMergeKeepsAnEmbeddingBundleWhoseFilesDiffer() throws {
        defer { cleanUp() }
        try write("model v1", at: "\(bundle)/model.mlpackage/weights.bin", under: privateSupport)
        try write("model", at: "\(bundle)/model.mlpackage/weights.bin", under: groupSupport)

        mergePrivateData()

        #expect(contents("\(bundle)/model.mlpackage/weights.bin", under: privateSupport) == "model v1")
        #expect(contents("\(bundle)/model.mlpackage/weights.bin", under: groupSupport) == "model")
    }

    @Test func privateDataMergeMovesAnEmbeddingBundleTheGroupLacks() throws {
        defer { cleanUp() }
        try write("vocab", at: "\(bundle)/tokenizer.json", under: privateSupport)

        mergePrivateData()

        #expect(!exists(bundle, under: privateSupport))
        #expect(contents("\(bundle)/tokenizer.json", under: groupSupport) == "vocab")
    }

    // MARK: Roots

    @Test func readRootsPutTheGroupFirstThenThePrivateRootThenCaches() {
        let locations = StorageLocations(root: destination, legacyRoot: base.appending(path: "Caches"),
                                         privateRoot: source)

        #expect(locations.readRoots == [destination, source, base.appending(path: "Caches")])
        #expect(locations.ownedFallbackRoots == [source])

        let standard = StorageLocations(root: destination, legacyRoot: base.appending(path: "Caches"), privateRoot: nil)
        #expect(standard.readRoots == [destination, base.appending(path: "Caches")])
        #expect(standard.ownedFallbackRoots.isEmpty)
    }

    @Test func deleteRemovesTheWholePrivateCopyButOnlyTheSnapshotInCaches() throws {
        defer { cleanUp() }
        let caches = base.appending(path: "Caches", directoryHint: .isDirectory)
        let model = try #require(Model.mlxModels.first)
        let repo = "huggingface/hub/models--\(model.repoID.replacingOccurrences(of: "/", with: "--"))"
        try write("w", at: "\(repo)/snapshots/main/model.safetensors", under: source)
        try write("blob", at: "\(repo)/blobs/abc", under: source)
        try write("w", at: "\(repo)/snapshots/main/model.safetensors", under: caches)
        try write("blob", at: "\(repo)/blobs/abc", under: caches)

        try ModelDownloads.delete(model, root: destination, ownedFallbackRoots: [source], legacyRoot: caches)

        #expect(!exists(repo, under: source))
        #expect(!exists("\(repo)/snapshots/main", under: caches))
        #expect(exists("\(repo)/blobs/abc", under: caches))
    }

    @Test func lockedGGUFDeleteRemovesTheFoldersItLeavesEmpty() throws {
        defer { cleanUp() }
        let model = try #require(Model.ggufModels.first { $0.ggufFilename?.contains("/") == false })
        let target = try ModelDownloads.ggufTarget(for: model, root: destination).file
        let relative = String(target.path(percentEncoded: false)
            .dropFirst(destination.path(percentEncoded: false).count))
        try write("w", at: relative, under: destination)
        try write("w", at: relative, under: source)
        let org = "models/\(model.repoID.split(separator: "/")[0])"

        try ModelDownloads.delete(model, root: destination, ownedFallbackRoots: [source], legacyRoot: base)

        #expect(!exists(org, under: destination))
        #expect(!exists(org, under: source))
        #expect(exists("models", under: destination))
    }

    @Test func lockedFolderDeleteRemovesTheRepoOnceTheLockFileIsGone() throws {
        defer { cleanUp() }
        try write("w", at: "\(snapshot)/compiled/model.bin", under: destination)
        let hub = destination.appending(path: "huggingface/hub")

        try ModelDownloads.whileNotDownloading(destination.appending(path: snapshot), removingEmptyFoldersUpTo: hub) {
            try ModelDownloads.deleteFolder(repoID: "org/repo", folder: "compiled", root: destination)
        }

        #expect(!exists("huggingface/hub/models--org--repo", under: destination))
        #expect(exists("huggingface/hub", under: destination))
    }

    @Test func deleteIsRefusedWhileADownloadHoldsTheLock() async throws {
        defer { cleanUp() }
        let file = try write("w", at: "models/org/repo/a.gguf", under: destination)
        let registry = DownloadLockRegistry()
        let lock = try await DownloadFileLock.acquire(for: file, retryInterval: .milliseconds(10), registry: registry)
        defer { lock.release() }

        #expect(throws: ModelFilesInUseError(name: "a.gguf")) {
            try ModelDownloads.whileNotDownloading(file) { Issue.record("ran while locked") }
        }
        #expect(exists("models/org/repo/a.gguf", under: destination))
        var ran = false
        try ModelDownloads.whileNotDownloading(destination.appending(path: "models/absent/repo/b.gguf")) { ran = true }
        #expect(ran)
    }
}
