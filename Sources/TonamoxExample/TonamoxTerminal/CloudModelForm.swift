import SwiftUI
import TerminalBridgeKit
import TonamoxCore

/// Which model id a cloud preset's key is used with. The id is sent as typed; the provider rejects one it does not know.
struct CloudModelForm: View {
    let preset: ProviderPreset
    let onChange: () -> Void
    @AppStorage private var model: String

    init(preset: ProviderPreset, onChange: @escaping () -> Void) {
        self.preset = preset
        self.onChange = onChange
        _model = AppStorage(wrappedValue: "", preset.modelDefaultsKey)
    }

    static let footer = "El identificador se envía tal cual. Si el proveedor no lo conoce, el mensaje falla y lo verás "
        + "en el chat."

    var body: some View {
        Form {
            let fallback = RemoteTargets.defaultModel(for: preset)
            let typed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            let options = (fallback.map { [$0] } ?? []) + preset.suggestions.filter { $0 != fallback }
            let isCustom = !typed.isEmpty && !options.contains(typed)
            if !options.isEmpty {
                Section {
                    ForEach(options, id: \.self) { option in
                        optionRow(option, isDefault: option == fallback,
                                  isSelected: typed.isEmpty ? option == fallback : option == typed) {
                            model = option == fallback ? "" : option
                        }
                    }
                } header: {
                    Text(verbatim: preset.displayName)
                }
            }
            Section {
                TextField("Identificador del modelo", text: $model)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Identificador del modelo")
                    .accessibilityIdentifier("cloudModel." + preset.id.rawValue)
                    .accessibilityAddTraits(isCustom ? .isSelected : [])
            } header: {
                Text(options.isEmpty ? "Identificador" : "Otro identificador")
            } footer: {
                Text(verbatim: Self.footer + " " + (preset.isPriced
                    ? ProvidersFormText.pricedNote : ProvidersFormText.unpricedNote))
            }
        }
        .navigationTitle("Modelo de " + ModelChipText.shortName(preset.displayName))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: model) { onChange() }
    }

    /// The default first, then the suggestions, each with a checkmark when in use.
    private func optionRow(
        _ option: String, isDefault: Bool, isSelected: Bool, select: @escaping () -> Void
    ) -> some View {
        Button(action: select) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: option)
                        .font(.body.monospaced())
                        .foregroundStyle(Color.primary)
                    if isDefault {
                        Text("Por defecto")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
