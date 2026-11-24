import SwiftUI
import TerminalBridgeKit
import TonamoxCore

/// «Proveedores»: one picker, one key field, and the address and model only for «Otro compatible con OpenAI».
/// Each saved provider becomes a row of the model sheet.
struct ProvidersForm: View {
    let onChange: () -> Void

    @State private var choice: ProviderFormChoice
    @State private var key = ""
    @State private var address = ""
    @State private var modelID = ""
    @State private var message: String?
    @State private var saved = SavedProviders.read()
    @State private var pendingRemoval: ProviderFormChoice?
    @AppStorage(ClaudeJudgeModel.defaultsKey) private var judgeModel: ClaudeJudgeModel = .standard

    private static let judgeModelFooter = "Lo usa «Evaluar con Claude» en las pruebas de capacidades y en Modo Test, "
        + "con esta misma clave. Opus 5.5 es el más fiable y el más caro; Haiku 5.5, el más barato."

    init(initial: ProviderFormChoice = .preset(.anthropic), onChange: @escaping () -> Void) {
        self.onChange = onChange
        _choice = State(initialValue: initial)
        let entry = CustomProvider.stored(in: .standard)
        _address = State(initialValue: entry?.address ?? "")
        _modelID = State(initialValue: entry?.modelID ?? "")
    }

    var body: some View {
        Form {
            Section {
                Picker("Proveedor", selection: $choice) {
                    ForEach(ProviderFormChoice.allCases) { option in
                        Text(verbatim: option.title).tag(option)
                    }
                }
                .accessibilityIdentifier("providers.picker")
            } footer: {
                Text(verbatim: ProvidersFormText.copilotNote)
            }

            if choice == .other {
                Section {
                    TextField("Dirección", text: $address, prompt: Text(verbatim: "http://192.168.1.20:8080/v1"))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("server.url")
                    TextField("Modelo", text: $modelID, prompt: Text("Modelo (por ejemplo qwen3-8b)"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("server.model")
                } header: {
                    Text("Servidor")
                } footer: {
                    Text(verbatim: ProvidersFormText.otherFooter)
                }
            }

            Section {
                SecureField(keyLabel, text: $key, prompt: Text(verbatim: keyPrompt))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("providers.key")
                Button("Guardar", action: save)
                    .disabled(choice != .other && APIKeyInput.normalized(key) == nil)
                    .accessibilityIdentifier("providers.save")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: noteText)
                        .accessibilityIdentifier("providers.note")
                    Text(verbatim: ProvidersFormText.keyFooter)
                }
            }

            if choice == .preset(.anthropic) {
                Section {
                    ClaudeJudgeModelPicker(model: $judgeModel)
                } footer: {
                    Text(verbatim: Self.judgeModelFooter)
                }
            }

            if let message {
                Section {
                    Text(verbatim: message)
                        .font(.callout)
                        .accessibilityIdentifier("providers.message")
                }
            }

            if !saved.isEmpty {
                Section {
                    ForEach(saved) { entry in
                        savedRow(entry)
                    }
                } header: {
                    Text(verbatim: ProvidersFormText.savedHeader)
                }
            }
        }
        .navigationTitle(ProvidersFormText.title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: choice) {
            key = ""
            message = nil
        }
        .confirmationDialog(
            ProvidersFormText.removeConfirmation(pendingRemoval?.title ?? ""),
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { entry in
            Button(ProvidersFormText.remove, role: .destructive) { remove(entry) }
        }
    }

    private var hasStoredKey: Bool {
        switch choice {
        case .preset(let id): RemoteTargets.hasKey(.preset(id))
        case .other: KeychainStore.hasKey(for: CustomProvider.keychainAccount)
        }
    }

    private var keyLabel: String { choice == .other ? "Clave API (opcional)" : "Clave API" }

    private var keyPrompt: String {
        hasStoredKey ? "Clave guardada; escribe otra para cambiarla" : keyLabel
    }

    private var noteText: String {
        switch choice {
        case .preset(let id): ProvidersFormText.presetFooter(.preset(id))
        case .other: ProvidersFormText.otherNote + " " + ProvidersFormText.otherCostNote
        }
    }

    private func savedRow(_ entry: SavedProviders.Entry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.choice.title)
                Text(verbatim: entry.detail)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
            Spacer()
            Button(ProvidersFormText.remove, role: .destructive) { pendingRemoval = entry.choice }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(verbatim: ProvidersFormText.remove + " " + entry.choice.title))
                .accessibilityIdentifier("providers.remove." + entry.choice.id)
        }
    }

    private func save() {
        switch choice {
        case .preset(let id): savePreset(.preset(id))
        case .other: saveOther()
        }
        saved = SavedProviders.read()
        onChange()
    }

    private func savePreset(_ preset: ProviderPreset) {
        guard let typed = APIKeyInput.normalized(key) else {
            message = ProvidersFormText.enterKey
            return
        }
        do {
            try KeychainStore.save(typed, for: preset.keychainAccount)
        } catch {
            message = ProvidersFormText.keySaveFailed
            return
        }
        key = ""
        message = ProvidersFormText.savedMessage(preset)
    }

    private func saveOther() {
        let defaults = UserDefaults.standard
        let result = CustomProviderSave.plan(
            address: address, model: modelID, typedKey: key,
            hasStoredKey: KeychainStore.hasKey(for: CustomProvider.keychainAccount),
            storedKeyOrigin: CustomProvider.stored(in: defaults)?.keyOrigin)
        switch result {
        case .failure(let refusal):
            message = refusal.message
        case .success(let plan):
            switch plan.keyChange {
            case .keep:
                break
            case .store(let typed):
                do {
                    try KeychainStore.save(typed, for: CustomProvider.keychainAccount)
                } catch {
                    message = ProvidersFormText.keySaveFailed
                    return
                }
            case .delete:
                KeychainStore.delete(for: CustomProvider.keychainAccount)
            }
            plan.entry.store(in: defaults)
            key = ""
            address = plan.entry.address
            modelID = plan.entry.modelID
            message = plan.message
        }
    }

    private func remove(_ entry: ProviderFormChoice) {
        switch entry {
        case .preset(let id):
            KeychainStore.delete(for: ProviderPreset.preset(id).keychainAccount)
        case .other:
            CustomProvider.clear(in: .standard)
            KeychainStore.delete(for: CustomProvider.keychainAccount)
            address = ""
            modelID = ""
        }
        if entry == choice { key = "" }
        message = "Se quitó " + entry.title + "."
        saved = SavedProviders.read()
        onChange()
    }
}

/// What the «Guardados» section lists: presets with a stored key, and «Otro» once it has an address or a key.
enum SavedProviders {
    struct Entry: Identifiable, Equatable {
        let choice: ProviderFormChoice
        let detail: String

        var id: String { choice.id }
    }

    static func read(defaults: UserDefaults = .standard) -> [Entry] {
        let presets = ProviderPreset.all.filter(RemoteTargets.hasKey).map { preset in
            Entry(choice: .preset(preset.id),
                  detail: RemoteTargets.modelID(for: preset, defaults: defaults) ?? ModelPickerText.noModelChosenDetail)
        }
        let stored = CustomProvider.stored(in: defaults)
        let hasOtherKey = KeychainStore.hasKey(for: CustomProvider.keychainAccount)
        guard stored != nil || hasOtherKey else { return presets }
        let detail = RemoteTargets.serverConfig(defaults: defaults).map {
            $0.modelID + " · " + $0.address.hostLabel
        } ?? ModelPickerText.serverUnconfiguredDetail
        return presets + [Entry(choice: .other, detail: detail)]
    }
}

/// Terminal's replacement for the shared settings' key rows: one link to «Proveedores».
struct ProvidersLinkSection: View {
    let onChange: () -> Void
    @State private var savedCount = 0

    var body: some View {
        Section {
            NavigationLink {
                ProvidersForm(onChange: onChange)
                    .onDisappear { savedCount = SavedProviders.read().count }
            } label: {
                LabeledContent(ProvidersFormText.title, value: ProvidersFormText.savedCount(savedCount))
            }
            .accessibilityIdentifier("settings.providers")
        } header: {
            Text("Claves API")
        } footer: {
            Text(verbatim: ProvidersFormText.linkFooter)
        }
        .onAppear { savedCount = SavedProviders.read().count }
    }
}
