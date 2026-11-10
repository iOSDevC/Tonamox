import SwiftUI
import TonamoxCore

/// Read-only view of what the App Group shares with this app: the storage scope, the models on disk and whether
/// a Hugging Face token is stored. No downloads and no model loads.
struct SharedModelsView: View {
    @State private var ggufFiles: [DownloadedGGUF] = []
    @State private var mlxSnapshots: [DownloadedSnapshot] = []
    @State private var hasToken = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Almacenamiento") {
                    LabeledContent("Ámbito", value: scopeText)
                    LabeledContent("Carpeta de modelos") {
                        Text(ModelStorage.rootDirectory.path(percentEncoded: false))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    LabeledContent("Token de Hugging Face", value: hasToken ? "Guardado" : "No guardado")
                }

                Section("Modelos GGUF") {
                    if ggufFiles.isEmpty {
                        Text("Ninguno").foregroundStyle(.secondary)
                    }
                    ForEach(ggufFiles) { file in
                        LabeledContent(file.displayName, value: file.sizeText)
                    }
                }

                Section("Instantáneas MLX") {
                    if mlxSnapshots.isEmpty {
                        Text("Ninguno").foregroundStyle(.secondary)
                    }
                    ForEach(mlxSnapshots) { snapshot in
                        LabeledContent(snapshot.repoID, value: snapshot.isComplete ? "Completa" : "Parcial")
                    }
                }
            }
            .navigationTitle("Modelos compartidos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                        .accessibilityIdentifier("sharedModels.done")
                }
            }
            .refreshable { rescan() }
        }
        .onAppear(perform: rescan)
        .onSharedStorageChange([.models]) { rescan() }
    }

    private var scopeText: String {
        switch TonamoxSharedStorage.scope {
        case .standard: "Solo esta app"
        case .appGroup(let identifier, _): "App Group \(identifier)"
        case .userWide(let identifier): "Todo el usuario (\(identifier))"
        }
    }

    private func rescan() {
        ggufFiles = DownloadedModels.scan()
        mlxSnapshots = DownloadedModels.scanSnapshots()
        hasToken = KeychainDownloadAuth.hasHuggingFaceToken
    }
}
