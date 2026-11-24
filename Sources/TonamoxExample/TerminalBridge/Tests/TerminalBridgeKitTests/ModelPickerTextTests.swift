import Foundation
import Testing
@testable import TerminalBridgeKit

@Suite struct ModelGroupingTests {
    @Test func sourcesLandInTheirGroups() {
        #expect(ModelEngineSource.mlx.group == .onDevice)
        #expect(ModelEngineSource.gguf.group == .onDevice)
        #expect(ModelEngineSource.apple.group == .onDevice)
        for preset in ProviderPresetID.allCases {
            #expect(ModelEngineSource.cloudPreset(preset).group == .cloud)
        }
        #expect(ModelEngineSource.compatibleServer(isLocalNetwork: true).group == .network)
        #expect(ModelEngineSource.compatibleServer(isLocalNetwork: false).group == .cloud)
        #expect(ModelEngineSource.compatibleServer(isLocalNetwork: nil).group == .network)
        #expect(ModelEngineSource.echo.group == .debug)
    }

    @Test func groupsAreOrderedWithDebugLast() {
        #expect(ModelGroup.allCases.sorted() == [.onDevice, .cloud, .network, .debug])
        #expect(ModelGroup.allCases.map(\.title) == ["En este iPhone", "En la nube", "En tu red local", "Depuración"])
    }

    @Test func bucketKeepsOrderAndLosesNothing() {
        let items: [(String, ModelEngineSource)] = [
            ("b.gguf", .gguf), ("claude", .cloudPreset(.anthropic)), ("a-mlx", .mlx), ("server", .compatibleServer(isLocalNetwork: nil)),
            ("echo", .echo), ("openai", .cloudPreset(.openAI)), ("apple", .apple),
            ("deepseek", .compatibleServer(isLocalNetwork: false)), ("gemini", .cloudPreset(.gemini)),
        ]
        let buckets = ModelGroup.bucket(items) { $0.1 }
        #expect(buckets[.onDevice]?.map(\.0) == ["b.gguf", "a-mlx", "apple"])
        #expect(buckets[.cloud]?.map(\.0) == ["claude", "openai", "deepseek", "gemini"])
        #expect(buckets[.network]?.map(\.0) == ["server"])
        #expect(buckets[.debug]?.map(\.0) == ["echo"])
        #expect(buckets.values.map(\.count).reduce(0, +) == items.count)
    }

    @Test func aMisSourcedRowShowsInAnotherGroupInsteadOfVanishing() {
        let buckets = ModelGroup.bucket(["remote:server"]) { _ in ModelEngineSource.mlx }
        #expect(buckets[.onDevice] == ["remote:server"])
    }

    @Test func internetServerRunsInTheCloud() {
        #expect(ModelEngineSource.compatibleServer(isLocalNetwork: false).placement == .cloud)
        #expect(ModelEngineSource.compatibleServer(isLocalNetwork: true).placement == .localNetwork)
        #expect(ModelEngineSource.compatibleServer(isLocalNetwork: nil).placement == .localNetwork)
        #expect(ModelEngineSource.gguf.placement == .device)
        #expect(ModelEngineSource.echo.placement == .device)
        #expect(ModelEngineSource.cloudPreset(.openAI).placement == .cloud)
        #expect(ModelEngineSource.cloudPreset(.openRouter).placement == .cloud)
    }
}

@Suite struct ModelChipTextTests {
    @Test func chipNamesTheModelAndWhereItRuns() {
        let chip = ModelChipText(title: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf", placement: .device)
        #expect(chip.name == "Qwen3-4B-Instruct-2507")
        #expect(chip.place == "iPhone")
        #expect(chip.accessibilityLabel == "Modelo: Qwen3-4B-Instruct-2507-Q4_K_M.gguf, en este iPhone")
    }

    @Test func noSelectionAsksForOne() {
        let chip = ModelChipText(title: nil, placement: nil)
        #expect(chip.name == "Elegir modelo")
        #expect(chip.place == nil)
        #expect(chip.accessibilityLabel == "Modelo: ninguno elegido")
    }

    @Test func shortNameDropsProviderSuffixQuantizationAndLength() {
        #expect(ModelChipText.shortName("Claude (Anthropic)") == "Claude")
        #expect(ModelChipText.shortName("llama_Q8_0.gguf") == "llama")
        #expect(ModelChipText.shortName("Qwen3-4B-4bit") == "Qwen3-4B")
        #expect(ModelChipText.shortName("Apple Intelligence") == "Apple Intelligence")
        #expect(ModelChipText.shortName("Q4_K_M.gguf") == "Q4_K_M")
        let long = ModelChipText.shortName("Meta-Llama-3.1-8B-Instruct-abliterated-Q3_K_L.gguf")
        #expect(long == "Meta-Llama-3.1-8B-Ins…")
        #expect(long.count == ModelChipText.maxNameLength)
    }

    @Test func twoQuantizationsOfOneModelKeepTheirQuantization() {
        let titles = ["Qwen3-4B-Q4_K_M.gguf", "Qwen3-4B-Q8_0.gguf", "tiny-q4.gguf"]
        #expect(ModelChipText.shortName(titles[0], among: titles) == "Qwen3-4B Q4_K_M")
        #expect(ModelChipText.shortName(titles[1], among: titles) == "Qwen3-4B Q8_0")
        #expect(ModelChipText.shortName(titles[2], among: titles) == "tiny")
        #expect(ModelChipText(title: titles[1], placement: .device, otherTitles: titles).name == "Qwen3-4B Q8_0")
        let long = ["Meta-Llama-3.1-8B-Instruct-Q3_K_L.gguf", "Meta-Llama-3.1-8B-Instruct-Q8_0.gguf"]
        let name = ModelChipText.shortName(long[0], among: long)
        #expect(name.hasSuffix("… Q3_K_L"))
        #expect(name.count == ModelChipText.maxNameLength)
    }

    @Test func placeWords() {
        #expect(ModelPlacement.cloud.chipWord == "Nube")
        #expect(ModelPlacement.localNetwork.chipWord == "Red local")
        #expect(ModelChipText(title: "OpenAI", placement: .cloud).accessibilityLabel == "Modelo: OpenAI, en la nube")
    }
}

@Suite struct ModelDetailTextTests {
    @Test func quantizationFromFileNamesAndModelIDs() {
        #expect(ModelPickerText.quantization(in: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf") == "Q4_K_M")
        #expect(ModelPickerText.quantization(in: "gemma-3-1b-it-IQ3_XS.gguf") == "IQ3_XS")
        #expect(ModelPickerText.quantization(in: "model.Q8_0.gguf") == "Q8_0")
        #expect(ModelPickerText.quantization(in: "phi-4-f16.gguf") == "F16")
        #expect(ModelPickerText.quantization(in: "mlx-community/Qwen3-4B-4bit") == "4 bits")
        #expect(ModelPickerText.quantization(in: "Qwen3-4B.gguf") == nil)
        #expect(ModelPickerText.quantization(in: "Qwen-Instruct") == nil)
    }

    @Test func localDetailIsOneLine() {
        #expect(ModelPickerText.localDetail(format: .gguf, quantization: "Q3_K_M", byteCount: 3_200_000_000)
            == "GGUF · Q3_K_M · 3,2 GB")
        #expect(ModelPickerText.localDetail(format: .mlx, quantization: nil, byteCount: nil) == "MLX")
        #expect(ModelPickerText.localDetail(format: .gguf, quantization: "", byteCount: 0) == "GGUF")
        #expect(ModelPickerText.localDetail(format: .mlx, quantization: "4 bits", byteCount: 2_500_000_000,
                                            sizeIsApproximate: true) == "MLX · 4 bits · aprox. 2,5 GB")
    }

    @Test func sizes() {
        #expect(ModelPickerText.sizeText(950_000_000) == "950 MB")
        #expect(ModelPickerText.sizeText(1_049_000_000) == "1,0 GB")
        #expect(ModelPickerText.sizeText(12_500) == "12 KB")
        #expect(ModelPickerText.sizeText(10) == "1 KB")
    }

    @Test func serverDetailNamesInternetServers() {
        #expect(ModelPickerText.serverDetail(modelID: "qwen3-8b", hostLabel: "192.168.1.20:8080", isLocalNetwork: true)
            == "qwen3-8b · 192.168.1.20:8080")
        #expect(ModelPickerText.serverDetail(modelID: "m", hostLabel: "api.example.com", isLocalNetwork: false)
            == "m · api.example.com · internet, cuenta como nube")
    }
}

@Suite struct RemoteLockTests {
    @Test func locksComeInTheOrderTheUserFixesThem() {
        #expect(RemoteLock.evaluate(modeIsOff: true, isCloud: true, cloudAllowed: false, hasKey: false,
                                    isConfigured: false) == .remoteOff)
        #expect(RemoteLock.evaluate(modeIsOff: false, isCloud: true, cloudAllowed: false, hasKey: false,
                                    isConfigured: false) == .serverNotConfigured)
        #expect(RemoteLock.evaluate(modeIsOff: false, isCloud: true, cloudAllowed: false, hasKey: false,
                                    isConfigured: true) == .missingKey)
        #expect(RemoteLock.evaluate(modeIsOff: false, isCloud: true, cloudAllowed: false, hasKey: true,
                                    isConfigured: true, hasModel: false) == .modelNotChosen)
        #expect(RemoteLock.evaluate(modeIsOff: false, isCloud: true, cloudAllowed: false, hasKey: true,
                                    isConfigured: true) == .cloudNotAllowed)
        #expect(RemoteLock.evaluate(modeIsOff: false, isCloud: false, cloudAllowed: false, hasKey: false,
                                    isConfigured: true) == nil)
    }

    @Test func readinessBlockerIsTheLockMessage() {
        let lock = RemoteLock.evaluate(modeIsOff: false, isCloud: true, cloudAllowed: false, hasKey: true,
                                       isConfigured: true)
        #expect(RemoteEngineReadiness.blocker(modeIsOff: false, isCloud: true, cloudAllowed: false, hasKey: true,
                                              isConfigured: true) == lock?.message)
    }

    @Test func shortReasonsAreShortStates() {
        #expect(RemoteLock.cloudNotAllowed.shortReason == "Nube no permitida")
        #expect(RemoteLock.serverNotConfigured.shortReason == "Sin configurar")
        #expect(RemoteLock.missingKey.shortReason == "Falta la clave API")
        #expect(RemoteLock.remoteOff.shortReason == "Envío remoto desactivado")
        #expect(RemoteLock.modelNotChosen.shortReason == "Elige un modelo")
        for lock in [RemoteLock.remoteOff, .serverNotConfigured, .missingKey, .modelNotChosen, .cloudNotAllowed] {
            #expect(lock.shortReason.count <= 26)
        }
    }
}

@Suite struct CapabilitySummaryTests {
    private func report(_ states: [String: ProbeRunState], battery: Int = CapabilityLevel.terminal.version)
        -> CapabilityReport {
        let results = CapabilityLevel.terminal.probes.map { probe in
            ProbeResult(probeID: probe.id, state: states[probe.id] ?? .passed, reason: "r", seconds: 1)
        }
        return CapabilityReport(modelKey: "mlx:q", modelTitle: "Q", batteryVersion: battery, temperature: 0.2,
                                date: Date(timeIntervalSince1970: 1_800_000_000), results: results)
    }

    @Test func countsPassedOverGraded() {
        let summary = CapabilitySummary(report: report([
            "formato.solo-ascii": .failed,
            "formato.bloque-unico": .timedOut,
            "macos.ls-ocultos": .error,
        ]))
        #expect(summary.text == "Pruebas: 16/18")
        #expect(!summary.notRecommended)
        #expect(summary.accessibilityText == "Pruebas de capacidades: 16 de 18 aprobadas")
    }

    @Test func safetyFailureIsFlagged() {
        let summary = CapabilitySummary(report: report(["seguridad.inyeccion-en-salida": .failed]))
        #expect(summary.notRecommended)
        #expect(summary.text == "Pruebas: 18/19")
        #expect(summary.accessibilityText.hasSuffix(", No recomendado"))
    }

    @Test func aHandValidationCountsLikeOnTheSavedRow() {
        let report = report(["formato.solo-ascii": .failed]).validating("formato.solo-ascii", on: .now)
        #expect(CapabilitySummary(report: report).text == "Pruebas: 19/19")
        #expect(CapabilityText.savedLevelLine(.terminal, report: report).hasSuffix("19 de 19"))
    }

    @Test func olderBatteryIsNamed() {
        let summary = CapabilitySummary(report: report([:], battery: CapabilityLevel.terminal.version - 1))
        #expect(summary.text == "Pruebas: 19/19 · batería anterior")
    }
}

@Suite struct SettingsMenuEntryTests {
    @Test func entriesFollowTheRequestedOrder() {
        #expect(SettingsMenuEntry.allCases.map(\.title) == [
            "Servidor web", "Teclado Bluetooth", "Emparejar Mac", "Claves API y envío remoto",
            "Descargas", "Probar modelo", "Modo Test", "Licencias",
        ])
        let flattened = SettingsMenuEntry.MenuSection.allCases.flatMap(\.entries)
        #expect(flattened == SettingsMenuEntry.allCases)
    }

    @Test func everyEntryHasASymbolAndAUniqueIdentifier() {
        #expect(SettingsMenuEntry.allCases.allSatisfy { !$0.symbol.isEmpty })
        let identifiers = SettingsMenuEntry.allCases.map(\.identifier)
        #expect(Set(identifiers).count == identifiers.count)
        #expect(SettingsMenuEntry.webServer.identifier == "terminal.webServerButton")
        #expect(SettingsMenuEntry.pairing.identifier == "terminal.pairingButton")
    }

    @Test func noModelTextPointsAtTheChip() {
        #expect(CapabilityText.noModel == "Elige primero un modelo con el selector de modelo, junto a «Enviar».")
    }
}
