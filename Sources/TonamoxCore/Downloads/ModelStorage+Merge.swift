import Darwin
import Foundation

// MARK: - Tree merge

extension ModelStorage {

    /// Moves everything under `source` into `destination` without copying or overwriting, for the move of an app's
    /// private data into its App Group. Idempotent: a second run finds only what had to stay.
    ///
    /// - An entry absent at the destination is renamed as a whole subtree (`rename(2)` with `RENAME_EXCL`), so a
    ///   `.partial` keeps its resume and checksum attributes.
    /// - Two folders are merged entry by entry, unless either is a finished or in-progress download: a folder that
    ///   holds `.complete` or `.revision`, a `snapshots/main` folder or folder download that holds files, or a path
    ///   `isAtomic` names (relative to `source`). Mixing files from two downloads in one folder that loaders read
    ///   by pattern could load the wrong weights.
    /// - An entry that cannot move stays in `source` as a conflict, except an identical finished copy: same size
    ///   and same verified SHA-256 for a file, or both `.complete` with the same files and the same revision (or the
    ///   same verified weights) for a folder. That source copy is deleted. A folder `sizesSuffice` names (bundles
    ///   that carry no markers or checksums) is identical when it holds the same files with the same sizes.
    /// - `*.lock` files are never moved; folders the merge empties are removed.
    static func mergeTree(from source: URL, to destination: URL, isAtomic: @escaping (String) -> Bool = { _ in false },
                          sizesSuffice: @escaping (String) -> Bool = { _ in false },
                          fileManager: FileManager) -> ModelStorageMigration {
        var merge = TreeMerge(source: source, destination: destination, isAtomic: isAtomic,
                              sizesSuffice: sizesSuffice, fileManager: fileManager)
        merge.mergeFolder(at: "")
        return merge.report
    }

    /// `huggingface/hub/models--<org>--<repo>/snapshots/main` or a path inside it, relative to a models root.
    static func isInsideSnapshot(_ relative: String) -> Bool {
        let parts = relative.split(separator: "/").map(String.init)
        return parts.count >= 5 && parts[0] == "huggingface" && parts[1] == "hub" && parts[2].hasPrefix("models--")
            && parts[3] == "snapshots" && parts[4] == ModelDownloads.snapshotFolder
    }
}

// MARK: - TreeMerge

private struct TreeMerge {
    let source: URL
    let destination: URL
    let isAtomic: (String) -> Bool
    let sizesSuffice: (String) -> Bool
    let fileManager: FileManager

    private var moved: [String] = []
    private var conflicts: [String] = []
    private var failures: [String] = []
    private var duplicatesRemoved: [String] = []

    init(source: URL, destination: URL, isAtomic: @escaping (String) -> Bool,
         sizesSuffice: @escaping (String) -> Bool, fileManager: FileManager) {
        self.source = source
        self.destination = destination
        self.isAtomic = isAtomic
        self.sizesSuffice = sizesSuffice
        self.fileManager = fileManager
    }

    var report: ModelStorageMigration {
        ModelStorageMigration(moved: moved, conflicts: conflicts, failures: failures,
                              duplicatesRemoved: duplicatesRemoved)
    }

    /// Merges the children of the folder at `relative` ("" is the source root), then removes it if it ended empty.
    mutating func mergeFolder(at relative: String) {
        let folder = url(relative, in: source)
        let names = (try? fileManager.contentsOfDirectory(atPath: path(folder))) ?? []
        for name in names.sorted() where !isLockFile(name) {
            mergeEntry(at: relative.isEmpty ? name : "\(relative)/\(name)")
        }
        if !relative.isEmpty {
            rmdir(path(folder))
        }
    }

    private mutating func mergeEntry(at relative: String) {
        let from = url(relative, in: source)
        let to = url(relative, in: destination)
        switch ModelStorage.moveExclusively(from, to: to, fileManager: fileManager) {
        case .moved:
            moved.append(relative)
        case .vanished:
            break
        case .failed(let code):
            failures.append(relative)
            ModelStorage.log.error("could not move \(relative, privacy: .public) into the App Group: errno \(code)")
        case .conflict:
            resolveConflict(at: relative, from: from, to: to)
        }
    }

    private mutating func resolveConflict(at relative: String, from: URL, to: URL) {
        let bothFolders = isFolder(from) && isFolder(to)
        if bothFolders, !isAtomicFolder(relative, from: from, to: to) {
            mergeFolder(at: relative)
        } else if bothFolders ? identicalFolders(from, to, at: relative) : identicalFiles(from, to) {
            do {
                try fileManager.removeItem(at: from)
                duplicatesRemoved.append(relative)
            } catch {
                conflicts.append(relative)
            }
        } else {
            conflicts.append(relative)
        }
    }

    // MARK: Rules

    private func isAtomicFolder(_ relative: String, from: URL, to: URL) -> Bool {
        if isAtomic(relative) || holdsMarker(from) || holdsMarker(to) { return true }
        return ModelStorage.isInsideSnapshot(relative) && (holdsFiles(from) || holdsFiles(to))
    }

    private func holdsMarker(_ folder: URL) -> Bool {
        [ModelDownloads.completeMarker, ModelDownloads.revisionMarker].contains { marker in
            fileManager.fileExists(atPath: path(folder.appending(path: marker)))
        }
    }

    /// Any entry besides folders and lock files: weights, configs, `.partial` files.
    private func holdsFiles(_ folder: URL) -> Bool {
        let names = (try? fileManager.contentsOfDirectory(atPath: path(folder))) ?? []
        return names.contains { name in !isLockFile(name) && !isFolder(folder.appending(path: name)) }
    }

    private func identicalFiles(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let size = HubFileTransfer.fileSize(at: lhs), size == HubFileTransfer.fileSize(at: rhs),
              let digest = FileIntegrity.verifiedSHA256(of: lhs) else { return false }
        return digest == FileIntegrity.verifiedSHA256(of: rhs)
    }

    private func identicalFolders(_ lhs: URL, _ rhs: URL, at relative: String) -> Bool {
        if sizesSuffice(relative) {
            let files = fileSizes(in: lhs)
            return !files.isEmpty && files == fileSizes(in: rhs)
        }
        let marker = ModelDownloads.completeMarker
        guard fileManager.fileExists(atPath: path(lhs.appending(path: marker))),
              fileManager.fileExists(atPath: path(rhs.appending(path: marker))) else { return false }
        let files = fileSizes(in: lhs)
        guard !files.isEmpty, files == fileSizes(in: rhs) else { return false }
        if let revision = recordedRevision(in: lhs), revision == recordedRevision(in: rhs) { return true }
        let weights = files.keys.filter { $0.lowercased().hasSuffix(".safetensors") }
        return !weights.isEmpty && weights.allSatisfy { identicalFiles(lhs.appending(path: $0), rhs.appending(path: $0)) }
    }

    /// `.revision`, else a non-empty `.complete` (folder downloads write the revision into both).
    private func recordedRevision(in folder: URL) -> String? {
        let revision = ModelDownloads.recordedRevision(in: folder, marker: ModelDownloads.revisionMarker)
            ?? ModelDownloads.recordedRevision(in: folder, marker: ModelDownloads.completeMarker)
        return revision?.isEmpty == false ? revision : nil
    }

    /// Relative path to size of every regular file under `folder`, lock files excluded.
    private func fileSizes(in folder: URL) -> [String: Int] {
        guard let enumerator = fileManager.enumerator(atPath: path(folder)) else { return [:] }
        var sizes: [String: Int] = [:]
        while let relative = enumerator.nextObject() as? String {
            let attributes = enumerator.fileAttributes
            guard !isLockFile(relative), attributes?[.type] as? FileAttributeType == .typeRegular else { continue }
            sizes[relative] = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        }
        return sizes
    }

    // MARK: Paths

    private func url(_ relative: String, in root: URL) -> URL {
        relative.isEmpty ? root : root.appending(path: relative)
    }

    private func path(_ url: URL) -> String {
        url.path(percentEncoded: false)
    }

    private func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path(url), isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func isLockFile(_ name: String) -> Bool {
        name.hasSuffix(".lock")
    }
}
