import Foundation
import TerminalBridgeKit
import TonamoxCore

/// The remote engines' targets. Keys live only in the keychain (App Group access group, never logged); model ids and
/// the «Otro» server's address live in `UserDefaults`.
enum RemoteTargets {
    static let cloudAllowedKey = "remote.allowCloud"

    /// The SDK's defaults where it has a preset (Claude's and OpenAI's are the only ids the cost ledger prices);
    /// OpenRouter has none in the SDK.
    static func defaultModel(for preset: ProviderPreset) -> String? {
        switch preset.id {
        case .anthropic: RemoteTarget.defaultAnthropicModel
        case .openAI: RemoteTarget.defaultOpenAIModel
        case .gemini: RemoteTarget.defaultGeminiModel
        case .openRouter: preset.defaultModel
        }
    }

    /// The model id sent: the one the owner chose, or the default; nil for OpenRouter until one is chosen.
    static func modelID(for preset: ProviderPreset, defaults: UserDefaults = .standard) -> String? {
        preset.modelID(saved: defaults.string(forKey: preset.modelDefaultsKey), fallback: defaultModel(for: preset))
    }

    static func hasKey(_ preset: ProviderPreset) -> Bool {
        KeychainStore.hasKey(for: preset.keychainAccount)
    }

    /// The owner chose to keep the cloud switch across launches; every message still asks before it leaves.
    @MainActor static func restoreCloudPermission(defaults: UserDefaults = .standard) {
        HybridSettings.shared.policy.allowCloud = defaults.bool(forKey: cloudAllowedKey)
    }

    @MainActor static func saveCloudPermission(defaults: UserDefaults = .standard) {
        defaults.set(HybridSettings.shared.policy.allowCloud, forKey: cloudAllowedKey)
    }

    struct ServerConfig: Equatable {
        let address: CompatibleServerAddress
        let modelID: String
    }

    /// nil until the form saved an address that still parses and a model id.
    static func serverConfig(defaults: UserDefaults = .standard) -> ServerConfig? {
        guard let entry = CustomProvider.stored(in: defaults), entry.isConfigured,
              let address = entry.parsedAddress else { return nil }
        return ServerConfig(address: address, modelID: entry.modelID.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The saved key, only while the address still has the origin the key was saved for.
    static func serverKey(defaults: UserDefaults = .standard) -> String? {
        guard CustomProvider.stored(in: defaults)?.keyMatchesAddress == true else { return nil }
        return KeychainStore.read(for: CustomProvider.keychainAccount)
    }

    /// Claude and OpenAI always show, as before; Gemini and OpenRouter once their key is saved.
    static func rows(policy: EscalationPolicy) -> [RemoteChoiceRow] {
        let presets = ProviderPreset.all.filter { $0.id == .anthropic || $0.id == .openAI || hasKey($0) }
        return presets.map { presetRow($0, policy: policy) } + [serverRow(policy: policy)]
    }

    private static func presetRow(_ preset: ProviderPreset, policy: EscalationPolicy) -> RemoteChoiceRow {
        let model = modelID(for: preset)
        let lock = RemoteLock.evaluate(
            modeIsOff: policy.mode == .off, isCloud: true, cloudAllowed: policy.allowCloud,
            hasKey: hasKey(preset), isConfigured: true, hasModel: model != nil)
        let choice = ModelChoice(
            id: preset.choiceID, title: preset.displayName, detail: model ?? ModelPickerText.noModelChosenDetail,
            kind: .remote(.preset(preset.id)), source: .cloudPreset(preset.id))
        return RemoteChoiceRow(choice: choice, lock: lock)
    }

    private static func serverRow(policy: EscalationPolicy) -> RemoteChoiceRow {
        let config = serverConfig()
        let isCloud = !(config?.address.isLocalNetwork ?? true)
        let detail = config.map {
            ModelPickerText.serverDetail(modelID: $0.modelID, hostLabel: $0.address.hostLabel,
                                         isLocalNetwork: $0.address.isLocalNetwork)
        } ?? ModelPickerText.serverUnconfiguredDetail
        // The key is optional: local servers usually take none.
        let lock = RemoteLock.evaluate(
            modeIsOff: policy.mode == .off, isCloud: isCloud, cloudAllowed: policy.allowCloud,
            hasKey: true, isConfigured: config != nil)
        let choice = ModelChoice(
            id: CustomProvider.choiceID, title: ModelPickerText.serverTitle, detail: detail,
            kind: .remote(.compatibleServer), source: .compatibleServer(isLocalNetwork: config?.address.isLocalNetwork))
        return RemoteChoiceRow(choice: choice, lock: lock)
    }

    static func title(for kind: RemoteEngineKind) -> String {
        switch kind {
        case .preset(let id): ProviderPreset.preset(id).displayName
        case .compatibleServer: ModelPickerText.serverTitle
        }
    }

    /// Read at send time, so a key removed after the choice fails here instead of sending without it.
    static func target(for kind: RemoteEngineKind) throws -> RemoteTarget {
        switch kind {
        case .preset(let id):
            return try presetTarget(ProviderPreset.preset(id))
        case .compatibleServer:
            guard let config = serverConfig() else { throw RemoteReplyError.serverNotConfigured }
            let provider = OpenAICompatibleProvider(
                id: CustomProvider.providerID,
                displayName: "Servidor compatible (\(config.address.hostLabel))",
                baseURL: config.address.url,
                apiKey: serverKey(),
                retentionNote: ProvidersFormText.otherNote
            )
            return RemoteTarget(
                provider: provider,
                modelID: config.modelID,
                contextLength: nil,
                origin: config.address.isLocalNetwork ? .localNetwork(.llamaServer) : .cloud
            )
        }
    }

    private static func presetTarget(_ preset: ProviderPreset) throws -> RemoteTarget {
        guard let model = modelID(for: preset) else { throw RemoteReplyError.modelNotChosen(provider: preset.displayName) }
        switch preset.id {
        case .anthropic, .openAI:
            // The SDK's own providers, so the ledger keeps pricing their default models.
            guard let target = HybridEscalator.cloudTargets(
                allowCloud: true,
                anthropicModel: modelID(for: .anthropic) ?? RemoteTarget.defaultAnthropicModel,
                openAIModel: modelID(for: .openAI) ?? RemoteTarget.defaultOpenAIModel
            ).first(where: { $0.provider.id == preset.keychainAccount }) else {
                throw RemoteReplyError.missingKey(provider: preset.displayName)
            }
            return target
        case .gemini:
            guard let key = KeychainStore.read(for: preset.keychainAccount) else {
                throw RemoteReplyError.missingKey(provider: preset.displayName)
            }
            // The SDK preset, which leaves out the temperature Google deprecated.
            return RemoteTarget.gemini(apiKey: key, model: model)
        case .openRouter:
            guard let key = KeychainStore.read(for: preset.keychainAccount) else {
                throw RemoteReplyError.missingKey(provider: preset.displayName)
            }
            let provider = OpenAICompatibleProvider(
                id: preset.keychainAccount, displayName: preset.displayName, baseURL: preset.baseURL, apiKey: key,
                streaming: preset.streaming, retentionNote: preset.retentionNote)
            return RemoteTarget(provider: provider, modelID: model, contextLength: nil, origin: .cloud)
        }
    }
}
