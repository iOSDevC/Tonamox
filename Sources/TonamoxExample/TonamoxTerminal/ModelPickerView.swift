import SwiftUI

/// Only what is already on disk, plus Apple's model when the system offers it. No download buttons.
struct ModelPickerView: View {
    @ObservedObject var chat: TerminalChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showsSharedModels = false

    static let filesFooter = "Se cargan desde Documentos de esta app o desde el almacenamiento compartido. "
        + "Esta app no descarga modelos."

    var body: some View {
        NavigationStack {
            List {
                Section("Apple Intelligence") {
                    appleRow
                }

                Section("En este dispositivo") {
                    if chat.catalog.onDevice.isEmpty {
                        Text("Ninguno").foregroundStyle(.secondary)
                    }
                    ForEach(chat.catalog.onDevice) { choice in
                        row(for: choice)
                    }
                }

                Section {
                    if chat.catalog.ggufFiles.isEmpty {
                        Text("Ninguno").foregroundStyle(.secondary)
                    }
                    ForEach(chat.catalog.ggufFiles) { choice in
                        row(for: choice)
                    }
                } header: {
                    Text("Archivos GGUF")
                } footer: {
                    Text(verbatim: Self.filesFooter)
                }

                #if DEBUG
                Section("Depuración") {
                    ForEach(chat.catalog.debugChoices) { choice in
                        row(for: choice)
                    }
                }
                #endif

                if !chat.catalog.hasModels {
                    Section {
                        Text(verbatim: TerminalChatView.noModelsText)
                            .accessibilityIdentifier("model.empty")
                    }
                }

                Section {
                    Button("Ver almacenamiento compartido") {
                        showsSharedModels = true
                    }
                    .accessibilityIdentifier("model.sharedStorage")
                }
            }
            .navigationTitle("Modelo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                        .accessibilityIdentifier("model.done")
                }
            }
            .sheet(isPresented: $showsSharedModels) {
                SharedModelsView()
            }
        }
        .onAppear(perform: chat.refreshCatalog)
    }

    @ViewBuilder
    private var appleRow: some View {
        switch chat.catalog.apple {
        case .available:
            row(for: LocalModelCatalog.appleChoice)
        case .unavailable(let reason):
            VStack(alignment: .leading, spacing: 2) {
                Text("Apple Intelligence")
                Text(verbatim: reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("model.choice.apple")
        }
    }

    private func row(for choice: ModelChoice) -> some View {
        Button {
            chat.selectedChoiceID = choice.id
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: choice.title)
                        .foregroundStyle(.primary)
                    Text(verbatim: choice.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if choice.id == chat.selectedChoiceID {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .accessibilityAddTraits(choice.id == chat.selectedChoiceID ? .isSelected : [])
        .accessibilityIdentifier("model.choice." + choice.id)
    }
}
