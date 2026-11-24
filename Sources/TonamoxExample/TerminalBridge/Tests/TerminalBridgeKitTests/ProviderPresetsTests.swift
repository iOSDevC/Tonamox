import Foundation
import Testing
@testable import TerminalBridgeKit

@Suite struct ProviderPresetTests {
    @Test func accountsAreUniqueCloudAccountsAndTheCustomIDNeverCollides() {
        let accounts = ProviderPreset.all.map(\.keychainAccount)
        #expect(Set(accounts).count == accounts.count)
        #expect(accounts.allSatisfy { $0.hasPrefix("cloud.") })
        #expect(CustomProvider.providerID.hasPrefix("custom."))
        #expect(!accounts.contains(CustomProvider.providerID))
        #expect(!accounts.contains(CustomProvider.keychainAccount))
        #expect(ProviderPreset.preset(providerID: CustomProvider.providerID) == nil)
    }

    @Test func existingAccountsAndModelKeysAreKept() {
        #expect(ProviderPreset.anthropic.keychainAccount == "cloud.anthropic")
        #expect(ProviderPreset.openAI.keychainAccount == "cloud.openai")
        #expect(ProviderPreset.anthropic.modelDefaultsKey == "remote.anthropic.model")
        #expect(ProviderPreset.openAI.modelDefaultsKey == "remote.openai.model")
        #expect(ProviderPreset.anthropic.choiceID == "remote:anthropic")
        #expect(ProviderPreset.openAI.choiceID == "remote:openai")
        #expect(CustomProvider.choiceID == "remote:server")
        #expect(CustomProvider.keychainAccount == "terminal.compatible-server")
        let keys = ProviderPreset.all.map(\.modelDefaultsKey)
        #expect(Set(keys).count == keys.count)
        let choices = ProviderPreset.all.map(\.choiceID) + [CustomProvider.choiceID]
        #expect(Set(choices).count == choices.count)
    }

    @Test func everyPresetURLIsHTTPS() {
        for preset in ProviderPreset.all {
            #expect(preset.baseURL.scheme == "https", "\(preset.id)")
            #expect(preset.baseURL.host() != nil)
        }
    }

    @Test func geminiIsTheOpenAICompatibleEndpointWithTheApprovedDefault() {
        let gemini = ProviderPreset.gemini
        #expect(gemini.baseURL.absoluteString == "https://generativelanguage.googleapis.com/v1beta/openai/")
        #expect(gemini.baseURL.appending(path: "chat/completions").absoluteString
            == "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        #expect(gemini.dialect == .openAICompatible)
        #expect(gemini.defaultModel == "gemini-3.5-flash-lite")
        #expect(gemini.keychainAccount == "cloud.gemini")
        #expect(gemini.modelDefaultsKey == "remote.gemini.model")
        #expect(gemini.choiceID == "remote:gemini")
    }

    @Test func openRouterIsPinnedToItsEndpointAndAccount() {
        let openRouter = ProviderPreset.openRouter
        #expect(openRouter.baseURL.absoluteString == "https://openrouter.ai/api/v1")
        #expect(openRouter.baseURL.appending(path: "chat/completions").absoluteString
            == "https://openrouter.ai/api/v1/chat/completions")
        #expect(openRouter.dialect == .openAICompatible)
        #expect(openRouter.keychainAccount == "cloud.openrouter")
        #expect(openRouter.modelDefaultsKey == "remote.openrouter.model")
        #expect(openRouter.choiceID == "remote:openrouter")
    }

    @Test func geminiNoteNamesTheFreeTierTerms() {
        let note = ProviderPreset.gemini.retentionNote
        #expect(note.contains("clave gratuita"))
        #expect(note.contains("revisoras"))
        #expect(note.contains("tus mensajes y sus respuestas"))
        #expect(note.contains("no envíes datos sensibles, confidenciales ni personales"))
        #expect(note.contains("no puede saber"))
    }

    @Test func onlyClaudeAndOpenAIArePriced() {
        #expect(ProviderPreset.all.filter(\.isPriced).map(\.id) == [.anthropic, .openAI])
        #expect(ProvidersFormText.presetFooter(.gemini).contains(ProvidersFormText.unknownCost))
        #expect(ProvidersFormText.presetFooter(.openRouter).contains(ProvidersFormText.unknownCost))
        #expect(!ProvidersFormText.presetFooter(.gemini).contains("$0"))
    }

    @Test func otherEntryNoteSaysLocalIsFreeAndInternetUnknown() {
        #expect(ProvidersFormText.otherCostNote.contains("red local no tiene coste"))
        #expect(ProvidersFormText.otherCostNote.contains(ProvidersFormText.unknownCost))
    }

    @Test func openRouterHasNoDefaultModel() {
        #expect(ProviderPreset.openRouter.defaultModel == nil)
        #expect(ProviderPreset.openRouter.modelID(saved: nil) == nil)
        #expect(ProviderPreset.openRouter.modelID(saved: "  ") == nil)
        #expect(ProviderPreset.openRouter.modelID(saved: " vendor/model ") == "vendor/model")
        #expect(ProviderPreset.gemini.modelID(saved: "") == "gemini-3.5-flash-lite")
        #expect(ProvidersFormText.savedMessage(.openRouter).contains("Elige un modelo"))
    }

    @Test func callerFallbackReplacesThePresetDefault() {
        #expect(ProviderPreset.anthropic.modelID(saved: nil, fallback: "sdk-default") == "sdk-default")
        #expect(ProviderPreset.anthropic.modelID(saved: " \n", fallback: "sdk-default") == "sdk-default")
        #expect(ProviderPreset.anthropic.modelID(saved: " chosen ", fallback: "sdk-default") == "chosen")
        #expect(ProviderPreset.openRouter.modelID(saved: "", fallback: nil) == nil)
    }

    @Test func presetLookupsAgree() {
        for preset in ProviderPreset.all {
            #expect(ProviderPreset.preset(preset.id) == preset)
            #expect(ProviderPreset.preset(providerID: preset.keychainAccount) == preset)
        }
        #expect(ProviderPreset.all.map(\.id) == ProviderPresetID.allCases)
    }

    @Test func savedCountReadsAsSpanish() {
        #expect(ProvidersFormText.savedCount(0) == "Ninguno guardado")
        #expect(ProvidersFormText.savedCount(1) == "1 guardado")
        #expect(ProvidersFormText.savedCount(3) == "3 guardados")
    }

    @Test func formOffersThePresetsThenOther() {
        #expect(ProviderFormChoice.allCases.map(\.title)
            == ["Claude (Anthropic)", "OpenAI", "Gemini (Google)", "OpenRouter", "Otro compatible con OpenAI"])
        #expect(Set(ProviderFormChoice.allCases.map(\.id)).count == ProviderFormChoice.allCases.count)
        #expect(!ProviderFormChoice.allCases.map(\.title).contains { $0.localizedCaseInsensitiveContains("copilot") })
    }
}

@Suite struct CustomProviderTests {
    private func defaults() -> UserDefaults {
        let name = "CustomProviderTests." + UUID().uuidString
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        return store
    }

    @Test func codableRoundTrip() throws {
        let entry = CustomProvider(address: "https://api.example.com/v1", modelID: "m", keyOrigin: "https://api.example.com:443")
        let decoded = try JSONDecoder().decode(CustomProvider.self, from: JSONEncoder().encode(entry))
        #expect(decoded == entry)
    }

    @Test func readsTheLegacyServerEntry() {
        let store = defaults()
        #expect(CustomProvider.stored(in: store) == nil)
        store.set("http://192.168.1.20:8080/v1", forKey: "remoteServer.url")
        store.set("qwen3-8b", forKey: "remoteServer.model")
        store.set("http://192.168.1.20:8080", forKey: "remoteServer.keyOrigin")
        let entry = CustomProvider.stored(in: store)
        #expect(entry == CustomProvider(address: "http://192.168.1.20:8080/v1", modelID: "qwen3-8b",
                                        keyOrigin: "http://192.168.1.20:8080"))
        #expect(entry?.isConfigured == true)
        #expect(entry?.keyMatchesAddress == true)
        #expect(entry?.parsedAddress?.isLocalNetwork == true)
    }

    @Test func storeAndClearUseTheLegacyKeys() {
        let store = defaults()
        CustomProvider(address: "https://api.example.com/v1", modelID: "m", keyOrigin: nil).store(in: store)
        #expect(store.string(forKey: "remoteServer.url") == "https://api.example.com/v1")
        #expect(store.string(forKey: "remoteServer.model") == "m")
        #expect(store.string(forKey: "remoteServer.keyOrigin") == nil)
        CustomProvider.clear(in: store)
        #expect(CustomProvider.stored(in: store) == nil)
    }

    @Test func keyIsBoundToItsOrigin() {
        var entry = CustomProvider(address: "https://api.example.com/v1", modelID: "m",
                                   keyOrigin: "https://api.example.com:443")
        #expect(entry.keyMatchesAddress)
        entry.address = "https://evil.example.net/v1"
        #expect(!entry.keyMatchesAddress)
        entry.keyOrigin = nil
        #expect(!entry.keyMatchesAddress)
    }

    @Test func unparseableOrModellessEntryIsNotConfigured() {
        #expect(!CustomProvider(address: "http://example.com/v1", modelID: "m").isConfigured)
        #expect(!CustomProvider(address: "https://example.com/v1", modelID: " ").isConfigured)
    }
}

@Suite struct CustomProviderSaveTests {
    private func plan(_ address: String, model: String = "m", key: String = "", hasKey: Bool = false,
                      origin: String? = nil) -> Result<CustomProviderSave.Plan, CustomProviderSave.Refusal> {
        CustomProviderSave.plan(address: address, model: model, typedKey: key, hasStoredKey: hasKey,
                                storedKeyOrigin: origin)
    }

    @Test func typedKeyIsStoredForTheNewOrigin() throws {
        let saved = try plan("https://api.deepseek.com", key: " sk-test \n").get()
        #expect(saved.keyChange == .store("sk-test"))
        #expect(saved.entry.keyOrigin == "https://api.deepseek.com:443")
        #expect(saved.message.contains("cuenta como nube"))
    }

    @Test func keyIsClearedWhenTheOriginChanges() throws {
        let saved = try plan("https://other.example.com/v1", hasKey: true, origin: "https://api.example.com:443").get()
        #expect(saved.keyChange == .delete)
        #expect(saved.entry.keyOrigin == nil)
        #expect(saved.message.hasSuffix("La clave guardada era de otro servidor y se borró."))
    }

    @Test func legacyKeyWithoutOriginIsCleared() throws {
        #expect(try plan("https://api.example.com/v1", hasKey: true, origin: nil).get().keyChange == .delete)
    }

    @Test func keyIsKeptOnTheSameOriginWithAnotherPath() throws {
        let saved = try plan("https://api.example.com/v2", hasKey: true, origin: "https://api.example.com:443").get()
        #expect(saved.keyChange == .keep)
        #expect(saved.entry.keyOrigin == "https://api.example.com:443")
    }

    @Test func noKeyAnywhereKeepsNoOrigin() throws {
        let saved = try plan("http://192.168.1.20:8080/v1").get()
        #expect(saved.keyChange == .keep)
        #expect(saved.entry.keyOrigin == nil)
        #expect(saved.message == "Guardado. Cada mensaje te pedirá permiso antes de enviarse.")
    }

    @Test func refusals() {
        #expect(plan("http://example.com/v1") == .failure(.address(.plainHTTPOutsideLocalNetwork)))
        #expect(plan("https://example.com/v1", model: "  ") == .failure(.missingModel))
        #expect(plan("") == .failure(.address(.empty)))
    }

    @Test func blankKeyIsNoKey() {
        #expect(APIKeyInput.normalized(" \n\t") == nil)
        #expect(APIKeyInput.normalized("\nabc\n") == "abc")
    }
}
