import SwiftUI
import TonamoxCore

/// Read-only view of what the App Group shares with this app: the storage scope, the models on disk and whether
/// a Hugging Face token is stored. No downloads and no model loads.
struct SharedModelsView: View {
    @State private var ggufFiles: [DownloadedGGUF] = []
    @State private var mlxSnapshots: [DownloadedSnapshot] = []
    @State private var hasToken = false

    var body: some View {
        NavigationStack {
            List {
                Section("Storage") {
                    LabeledContent("Scope", value: scopeText)
                    LabeledContent("Models folder") {
                        Text(ModelStorage.rootDirectory.path(percentEncoded: false))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    LabeledContent("Hugging Face token", value: hasToken ? "Stored" : "Not stored")
                }

                Section("GGUF models") {
                    if ggufFiles.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    }
                    ForEach(ggufFiles) { file in
                        LabeledContent(file.displayName, value: file.sizeText)
                    }
                }

                Section("MLX snapshots") {
                    if mlxSnapshots.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    }
                    ForEach(mlxSnapshots) { snapshot in
                        LabeledContent(snapshot.repoID, value: snapshot.isComplete ? "Complete" : "Partial")
                    }
                }
            }
            .navigationTitle("Shared Models")
            .refreshable { rescan() }
        }
        .onAppear(perform: rescan)
        .onSharedStorageChange([.models]) { rescan() }
    }

    private var scopeText: String {
        switch TonamoxSharedStorage.scope {
        case .standard: "This app only"
        case .appGroup(let identifier, _): "App Group \(identifier)"
        case .userWide(let identifier): "User-wide (\(identifier))"
        }
    }

    private func rescan() {
        ggufFiles = DownloadedModels.scan()
        mlxSnapshots = DownloadedModels.scanSnapshots()
        hasToken = KeychainDownloadAuth.hasHuggingFaceToken
    }
}
