import Foundation

// Pure parts of TonamoxTerminal's «Proveedores» form: the fixed cloud presets, the one «Otro compatible con OpenAI»
// entry and the rule that binds that entry's key to the origin it was typed for. No network, no keychain.

/// The cloud providers the form offers with a fixed address.
public enum ProviderPresetID: String, CaseIterable, Codable, Hashable, Sendable {
    case anthropic
    case openAI = "openai"
    case gemini
    case openRouter = "openrouter"
}

/// The request format a preset speaks.
public enum ProviderDialect: Hashable, Sendable {
    case anthropic
    case openAICompatible
}

public struct ProviderPreset: Hashable, Sendable, Identifiable {
    public let id: ProviderPresetID
    public let displayName: String
    /// Keychain account (service `dev.auralocal.remote`) and also the provider id the cost ledger prices by.
    public let keychainAccount: String
    /// Display-only for Claude and OpenAI: their requests go through the SDK's own providers.
    public let baseURL: URL
    public let dialect: ProviderDialect
    /// nil: the row stays locked until a model is chosen. Claude's and OpenAI's are the SDK's own defaults.
    public let defaultModel: String?
    public let suggestions: [String]
    /// Spanish, shown in the form and in the consent sheet.
    public let retentionNote: String
    /// Only the SDK's default model of a priced preset has a price; every other model is «Coste desconocido».
    public let isPriced: Bool
    public let modelDefaultsKey: String
    public let streaming: Bool

    /// The model sheet's row id; Claude's and OpenAI's predate the presets and are kept.
    public var choiceID: String { "remote:" + id.rawValue }

    public static let anthropic = ProviderPreset(
        id: .anthropic, displayName: "Claude (Anthropic)", keychainAccount: "cloud.anthropic",
        baseURL: url("https://api.anthropic.com"), dialect: .anthropic, defaultModel: "claude-sonnet-4-5",
        suggestions: ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5-2"],
        retentionNote: "Se envía a la API de Anthropic. Consulta su política de conservación de datos.",
        isPriced: true, modelDefaultsKey: "remote.anthropic.model", streaming: true)

    public static let openAI = ProviderPreset(
        id: .openAI, displayName: "OpenAI", keychainAccount: "cloud.openai",
        baseURL: url("https://api.openai.com/v1"), dialect: .openAICompatible, defaultModel: "gpt-4o",
        suggestions: [],
        retentionNote: "Se envía a la API de OpenAI. Consulta su política de conservación de datos.",
        isPriced: true, modelDefaultsKey: "remote.openai.model", streaming: true)

    // The app cannot tell a free key from a paid one, so the note names the free tier's terms.
    public static let gemini = ProviderPreset(
        id: .gemini, displayName: "Gemini (Google)", keychainAccount: "cloud.gemini",
        baseURL: url("https://generativelanguage.googleapis.com/v1beta/openai/"), dialect: .openAICompatible,
        defaultModel: "gemini-3.5-flash-lite",
        suggestions: ["gemini-3.8-flash", "gemini-3.6-flash", "gemini-3.1-flash-lite"],
        retentionNote: "Se envía a la API de Gemini de Google. Con una clave gratuita, Google puede usar tus mensajes "
            + "y sus respuestas para mejorar sus productos y personas revisoras pueden leerlos: no envíes datos "
            + "sensibles, confidenciales ni personales. Tonamox no puede saber si tu clave es gratuita o de pago.",
        isPriced: false, modelDefaultsKey: "remote.gemini.model", streaming: true)

    public static let openRouter = ProviderPreset(
        id: .openRouter, displayName: "OpenRouter", keychainAccount: "cloud.openrouter",
        baseURL: url("https://openrouter.ai/api/v1"), dialect: .openAICompatible, defaultModel: nil,
        suggestions: [],
        retentionNote: "Se envía a OpenRouter, que lo reenvía al proveedor del modelo que elijas. Consulta la política "
            + "de conservación de datos de OpenRouter y la de ese proveedor.",
        isPriced: false, modelDefaultsKey: "remote.openrouter.model", streaming: true)

    public static let all: [ProviderPreset] = [.anthropic, .openAI, .gemini, .openRouter]

    public static func preset(_ id: ProviderPresetID) -> ProviderPreset {
        switch id {
        case .anthropic: .anthropic
        case .openAI: .openAI
        case .gemini: .gemini
        case .openRouter: .openRouter
        }
    }

    /// The preset whose provider id (its keychain account) is `providerID`, for the consent sheet's note.
    public static func preset(providerID: String) -> ProviderPreset? {
        all.first { $0.keychainAccount == providerID }
    }

    /// The model id sent: the saved one, else the default; nil when neither exists.
    public func modelID(saved: String?) -> String? {
        modelID(saved: saved, fallback: defaultModel)
    }

    /// Same rule with the caller's default; the app passes the SDK's priced ids for Claude and OpenAI.
    public func modelID(saved: String?, fallback: String?) -> String? {
        let typed = saved?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return typed.isEmpty ? fallback : typed
    }

    private static func url(_ text: String) -> URL {
        guard let url = URL(string: text) else { preconditionFailure("Invalid preset URL: \(text)") }
        return url
    }
}

/// What the form's picker selects: a preset, or the one OpenAI-compatible server.
public enum ProviderFormChoice: Hashable, Sendable, CaseIterable, Identifiable {
    case preset(ProviderPresetID)
    case other

    public static let allCases: [ProviderFormChoice] = ProviderPresetID.allCases.map { .preset($0) } + [.other]

    public var id: String {
        switch self {
        case .preset(let preset): preset.rawValue
        case .other: "other"
        }
    }

    public var title: String {
        switch self {
        case .preset(let preset): ProviderPreset.preset(preset).displayName
        case .other: ProvidersFormText.otherTitle
        }
    }
}

/// Fixed texts of the «Proveedores» form.
public enum ProvidersFormText {
    public static let title = "Proveedores"
    public static let otherTitle = "Otro compatible con OpenAI"
    public static let savedHeader = "Guardados"
    public static let remove = "Quitar"
    public static let unknownCost = "Coste desconocido"
    public static let keyFooter = "La clave se guarda en el llavero del iPhone, compartido con las otras apps de "
        + "Tonamox; nunca en archivos ni en registros."
    public static let otherNote = "Se envía al servidor que configuraste. Tonamox no sabe qué guarda."
    public static let otherFooter = "Por ejemplo llama-server u Ollama en tu Mac: http://192.168.1.20:8080/v1, o un "
        + "servicio de internet con https://. Con http:// solo se admite una IP de tu red local; un servidor de "
        + "internet cuenta como nube. La clave es opcional y solo se envía al servidor para el que la escribiste."
    public static let copilotNote = "GitHub Copilot no aparece: no tiene una API oficial que funcione con una clave."
    public static let unpricedNote = "Tonamox no conoce su precio: la hoja de aprobación dirá «Coste desconocido» y "
        + "el límite de gasto no podrá comprobarlo."
    public static let pricedNote = "Solo el modelo por defecto tiene precio conocido; con otro, la hoja de aprobación "
        + "dirá «Coste desconocido»."
    public static let otherCostNote = "En tu red local no tiene coste. Con un servidor de internet, la hoja de "
        + "aprobación dirá «Coste desconocido» y el límite de gasto no podrá comprobarlo."
    public static let enterKey = "Escribe la clave API."
    public static let keySaveFailed = "No se pudo guardar la clave en el llavero."

    public static let linkFooter = "Claude, OpenAI, Gemini, OpenRouter o un servidor compatible con OpenAI. Cada "
        + "proveedor guardado aparece en «Selecciona un modelo»."

    public static func savedCount(_ count: Int) -> String {
        switch count {
        case 0: "Ninguno guardado"
        case 1: "1 guardado"
        default: "\(count) guardados"
        }
    }

    /// The footer under the key field: retention, then cost.
    public static func presetFooter(_ preset: ProviderPreset) -> String {
        preset.retentionNote + " " + (preset.isPriced ? pricedNote : unpricedNote)
    }

    public static func savedMessage(_ preset: ProviderPreset) -> String {
        preset.defaultModel == nil
            ? "Clave guardada. Elige un modelo con el botón de información (i) de su fila en «Selecciona un modelo»."
            : "Clave guardada. Cada mensaje te pedirá permiso antes de enviarse."
    }

    public static func removeConfirmation(_ name: String) -> String {
        "¿Quitar \(name)? Se borra su clave del llavero, también para las otras apps de Tonamox."
    }
}

/// The «Otro compatible con OpenAI» entry. v1 keeps exactly one, stored where the old «Servidor propio» lived.
public struct CustomProvider: Codable, Hashable, Sendable {
    public var address: String
    public var modelID: String
    /// Origin the stored key was typed for; nil when no key belongs to this entry.
    public var keyOrigin: String?

    public static let choiceID = "remote:server"
    public static let keychainAccount = "terminal.compatible-server"
    /// Never a `cloud.*` id: the ledger would price it as that cloud's model.
    public static let providerID = "custom.server"
    public static let urlKey = "remoteServer.url"
    public static let modelKey = "remoteServer.model"
    public static let keyOriginKey = "remoteServer.keyOrigin"

    public init(address: String, modelID: String, keyOrigin: String? = nil) {
        self.address = address
        self.modelID = modelID
        self.keyOrigin = keyOrigin
    }

    /// The saved address, when it still parses.
    public var parsedAddress: CompatibleServerAddress? {
        if case .success(let parsed) = CompatibleServerAddress.parse(address) { return parsed }
        return nil
    }

    /// Usable: the address parses and a model id is set.
    public var isConfigured: Bool {
        parsedAddress != nil && !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The stored key may be attached only while the address keeps the origin it was typed for.
    public var keyMatchesAddress: Bool {
        guard let keyOrigin, let parsed = parsedAddress else { return false }
        return keyOrigin == parsed.origin
    }

    /// The entry under the pre-preset keys; nil when nothing was saved there.
    public static func stored(in defaults: UserDefaults) -> CustomProvider? {
        let address = defaults.string(forKey: urlKey) ?? ""
        let model = defaults.string(forKey: modelKey) ?? ""
        let origin = defaults.string(forKey: keyOriginKey)
        guard !address.isEmpty || !model.isEmpty || origin != nil else { return nil }
        return CustomProvider(address: address, modelID: model, keyOrigin: origin)
    }

    public func store(in defaults: UserDefaults) {
        defaults.set(address, forKey: Self.urlKey)
        defaults.set(modelID, forKey: Self.modelKey)
        if let keyOrigin {
            defaults.set(keyOrigin, forKey: Self.keyOriginKey)
        } else {
            defaults.removeObject(forKey: Self.keyOriginKey)
        }
    }

    public static func clear(in defaults: UserDefaults) {
        for key in [urlKey, modelKey, keyOriginKey] { defaults.removeObject(forKey: key) }
    }
}

/// Saving the «Otro» entry: what to store and what to do with the key.
public enum CustomProviderSave {
    public enum KeyChange: Hashable, Sendable {
        case keep
        case store(String)
        /// The stored key was typed for another origin and must not follow the address.
        case delete
    }

    public struct Plan: Hashable, Sendable {
        public let entry: CustomProvider
        public let keyChange: KeyChange
        public let message: String
    }

    public enum Refusal: Error, Hashable, Sendable {
        case address(ServerAddressRefusal)
        case missingModel

        public var message: String {
            switch self {
            case .address(let refusal): refusal.message
            case .missingModel: "Escribe el identificador del modelo que sirve el servidor."
            }
        }
    }

    public static func plan(
        address: String, model: String, typedKey: String, hasStoredKey: Bool, storedKeyOrigin: String?
    ) -> Result<Plan, Refusal> {
        let parsed: CompatibleServerAddress
        switch CompatibleServerAddress.parse(address) {
        case .failure(let refusal): return .failure(.address(refusal))
        case .success(let value): parsed = value
        }
        let modelID = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else { return .failure(.missingModel) }
        let key = APIKeyInput.normalized(typedKey)
        let action: KeyChange
        let origin: String?
        if let key {
            action = .store(key)
            origin = parsed.origin
        } else if hasStoredKey && storedKeyOrigin != parsed.origin {
            action = .delete
            origin = nil
        } else {
            action = .keep
            origin = hasStoredKey ? storedKeyOrigin : nil
        }
        let base = parsed.isLocalNetwork
            ? "Guardado. Cada mensaje te pedirá permiso antes de enviarse."
            : "Guardado. Es un servidor de internet: cuenta como nube y necesita «Allow cloud providers»."
        let dropped = action == .delete ? " La clave guardada era de otro servidor y se borró." : ""
        let entry = CustomProvider(address: parsed.url.absoluteString, modelID: modelID, keyOrigin: origin)
        return .success(Plan(entry: entry, keyChange: action, message: base + dropped))
    }
}

/// A pasted key loses surrounding whitespace and line breaks; an empty one is no key.
public enum APIKeyInput {
    public static func normalized(_ typed: String) -> String? {
        let key = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }
}
