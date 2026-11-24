import SwiftUI
import TonamoxCore

/// One model folder or file on disk, finished or partial.
struct DownloadedEntry: Identifiable {
    let id: String
    let title: String
    let formatLabel: String
    let detail: String
    let sizeBytes: Int64
    let isComplete: Bool
    /// `nil` when nothing on disk says which repo/file it is.
    let candidate: Model?
    /// A paused GGUF's `.partial` file.
    var partialFile: URL?
    /// A paused partial whose finished file is already on disk (an older build's, left in Caches): nothing to
    /// resume, and Delete removes only this partial, never the finished copy.
    var isLeftover = false
}

/// Every model file in ``ModelStorage/rootDirectory`` (and in Caches, where older builds downloaded), finished or
/// paused, read from disk on each refresh so it survives a relaunch: Try it, Resume, Cancel and Delete, plus the
/// keep-awake switch. Sets the title "Downloads" and brings no navigation container.
public struct DownloadedModelsList: View {
    @State private var entries: [DownloadedEntry] = []
    @State private var freeBytes: Int64?
    @State private var notice: String?
    @State private var trial: Model?
    @State private var pendingDelete: DownloadedEntry?

    public init() {}

    private var center: ModelDownloadCenter { .shared }

    public var body: some View {
        @Bindable var downloads = ModelDownloadCenter.shared
        List {
            if let notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(entries) { row(for: $0) }
            } footer: {
                footer
            }
            Section {
                Toggle(String(localized: "Keep the screen awake while downloading", bundle: .module),
                       isOn: $downloads.keepsScreenAwake)
            }
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView(String(localized: "No downloads", bundle: .module), systemImage: "arrow.down.circle",
                                       description: Text("Download a model from a search result.", bundle: .module))
            }
        }
        .navigationTitle(Text("Downloads", bundle: .module))
        .task(id: center.revision) { refresh() }
        .refreshable { refresh() }
        .sheet(item: $trial) { ModelTrialView(candidate: $0) }
    }

    // MARK: Rows

    private func row(for entry: DownloadedEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.title)
                .font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: "\(entry.formatLabel) · \(entry.detail)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                status(of: entry)
                Text(ByteText.text(entry.sizeBytes))
                Spacer()
                actions(for: entry)
            }
            .font(.caption)
            if let candidate = entry.candidate,
               case .downloading(let done, let total) = center.phase(of: candidate), total > 0 {
                ProgressView(value: Double(done), total: Double(total))
            }
            if let reason = blockerText(entry) {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
        .swipeActions { deleteButton(for: entry) }
        .contextMenu { deleteButton(for: entry) }
        .confirmationDialog(String(localized: "Delete \(entry.title)?", bundle: .module), isPresented: deletePrompt(for: entry),
                            titleVisibility: .visible) {
            Button(String(localized: "Delete, free \(ByteText.text(entry.sizeBytes))", bundle: .module), role: .destructive) {
                delete(entry)
            }
        } message: {
            Text("The files are removed from this device. Downloading again needs the network.", bundle: .module)
        }
    }

    private func status(of entry: DownloadedEntry) -> some View {
        if entry.isComplete { return Label(String(localized: "Complete", bundle: .module), systemImage: "checkmark.circle") }
        if entry.isLeftover { return Label(String(localized: "Leftover", bundle: .module), systemImage: "doc.badge.ellipsis") }
        return Label(String(localized: "Paused", bundle: .module), systemImage: "pause.circle")
    }

    @ViewBuilder private func actions(for entry: DownloadedEntry) -> some View {
        if let candidate = entry.candidate, !entry.isLeftover {
            if entry.isComplete {
                Button(String(localized: "Try it", bundle: .module)) { trial = candidate }
                    .disabled(tryItBlocker(entry) != nil)
            } else if center.activeModelID == candidate.id {
                Button(String(localized: "Cancel", bundle: .module)) { center.cancel() }
            } else {
                // Only a recorded file is recorded again: a catalog model is already registered.
                Button(String(localized: "Resume", bundle: .module)) { center.start(candidate, records: DownloadRecords.standard.contains(candidate)) }
                    .disabled(center.isBusy || center.isWritingElsewhere(candidate) || isUnsized(candidate))
            }
        }
        deleteButton(for: entry)
            .labelStyle(.titleOnly)
    }

    private func deleteButton(for entry: DownloadedEntry) -> some View {
        Button(String(localized: "Delete", bundle: .module), systemImage: "trash", role: .destructive) { pendingDelete = entry }
            .disabled(entry.candidate == nil || entry.candidate?.id == center.activeModelID)
    }

    private func deletePrompt(for entry: DownloadedEntry) -> Binding<Bool> {
        Binding(get: { pendingDelete?.id == entry.id }, set: { if !$0 { pendingDelete = nil } })
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            let total = entries.map(\.sizeBytes).reduce(0, +)
            let onDisk = ByteText.text(total)
            Text(freeBytes.map { String(localized: "On disk: \(onDisk) · \(ByteText.text($0)) free", bundle: .module) }
                 ?? String(localized: "On disk: \(onDisk)", bundle: .module))
            Text("Stored in Application Support and excluded from backups.", bundle: .module)
        }
    }

    /// Why Try it is off for this entry, or `nil` when it may run.
    private func tryItBlocker(_ entry: DownloadedEntry) -> RunBlocker? {
        guard entry.isComplete, let candidate = entry.candidate else { return nil }
        return RunBlocker.check(candidate, requiresSize: true)
    }

    /// Why Try it or Resume is off for this entry.
    private func blockerText(_ entry: DownloadedEntry) -> String? {
        if let blocker = tryItBlocker(entry) { return blocker.explanation }
        if entry.isLeftover {
            return String(localized: "A finished copy is already on disk; Delete removes only this unfinished file.",
                          bundle: .module)
        }
        guard !entry.isComplete, let candidate = entry.candidate, isUnsized(candidate) else { return nil }
        return String(localized: "Resume needs the size from a search result; resume it from Search or delete it.",
                      bundle: .module)
    }

    /// Resuming an unsized model would finish a file nothing can judge before loading.
    private func isUnsized(_ candidate: Model) -> Bool {
        candidate.approximateSizeMB <= 0
    }

    // MARK: Disk

    private func delete(_ entry: DownloadedEntry) {
        guard let candidate = entry.candidate else { return }
        do {
            if entry.isLeftover, let partial = entry.partialFile {
                try center.deleteLeftover(partial, of: candidate)
            } else {
                try center.delete(candidate)
            }
            notice = String(localized: "Deleted \(entry.title), freed \(ByteText.text(entry.sizeBytes)).", bundle: .module)
        } catch {
            notice = String(localized: "Could not delete \(entry.title): \(error.localizedDescription)", bundle: .module)
        }
    }

    private func refresh() {
        freeBytes = ModelDownloads.availableDiskBytes()
        let finished = DownloadedModels.scan().map(Self.finishedEntry)
        let modelsRoots = DownloadedModels.modelsDirectories.map { $0.standardizedFileURL.path + "/" }
        let paused = DownloadedModels.partialFiles().compactMap { partial in
            modelsRoots.first { partial.standardizedFileURL.path.hasPrefix($0) }
                .flatMap { Self.partialEntry(partial, modelsRoot: $0) }
        }
        let snapshots = DownloadedModels.scanSnapshots().map(Self.snapshotEntry)
        entries = (finished + paused + snapshots)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private static func finishedEntry(_ file: DownloadedGGUF) -> DownloadedEntry {
        DownloadedEntry(id: file.id, title: file.displayName, formatLabel: "GGUF", detail: file.filename,
                        sizeBytes: file.sizeBytes, isComplete: true,
                        candidate: ggufModel(repoID: file.repoID, filename: file.filename))
    }

    /// `<models>/<org>/<repo>/<file>.gguf.partial`; anything else is not one of ours.
    private static func partialEntry(_ partial: URL, modelsRoot: String) -> DownloadedEntry? {
        let relative = partial.standardizedFileURL.path.dropFirst(modelsRoot.count).split(separator: "/")
        guard relative.count == 3 else { return nil }
        let repoID = "\(relative[0])/\(relative[1])"
        let filename = partial.deletingPathExtension().lastPathComponent
        let size = (try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
        let candidate = ggufModel(repoID: repoID, filename: filename)
        return DownloadedEntry(id: partial.path, title: "\(relative[1]) · \(filename)", formatLabel: "GGUF",
                               detail: filename, sizeBytes: Int64(size), isComplete: false, candidate: candidate,
                               partialFile: partial, isLeftover: candidate?.isDownloaded == true)
    }

    private static func snapshotEntry(_ snapshot: DownloadedSnapshot) -> DownloadedEntry {
        DownloadedEntry(id: snapshot.id, title: snapshot.repoID, formatLabel: "MLX", detail: "snapshots/main",
                        sizeBytes: snapshot.sizeBytes, isComplete: snapshot.isComplete,
                        candidate: mlxModel(repoID: snapshot.repoID))
    }

    /// The search record, else a registry entry for the same file (catalog downloads are sized), else an unsized
    /// model that can only be deleted.
    private static func ggufModel(repoID: String, filename: String) -> Model? {
        DownloadRecords.standard.model(repoID: repoID, ggufFilename: filename)
            ?? ModelRegistry.shared.models.first {
                $0.format == .gguf && $0.repoID == repoID && $0.ggufFilename == filename && $0.localFileURL == nil
            }
            ?? Model.fromURL("https://huggingface.co/\(repoID)/resolve/main/\(filename)")
    }

    private static func mlxModel(repoID: String) -> Model? {
        DownloadRecords.standard.model(repoID: repoID, ggufFilename: nil)
            ?? ModelRegistry.shared.models.first { $0.format == .mlx && $0.repoID == repoID }
            ?? unsizedMLX(repoID)
    }

    /// Enough to delete an MLX snapshot downloaded before it was recorded; size 0 disables Try it and Resume.
    private static func unsizedMLX(_ repoID: String) -> Model? {
        CatalogEntry(id: repoID, repoID: repoID, displayName: repoID, modelCategory: .text, weightFormat: .mlx,
                     approximateSizeMB: 0, isUncensored: false, ggufFilename: nil, numLayers: 0, kvHeads: 0,
                     headDim: 0, maxContextLength: nil).decodedModel()
    }
}
