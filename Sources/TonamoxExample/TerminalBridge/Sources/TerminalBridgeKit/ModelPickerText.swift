import Foundation

// Pure parts of TonamoxTerminal's model chip, model sheet and settings menu: grouping, one-line texts, lock
// reasons and capability summaries. The app maps its engine choices onto `ModelEngineSource`.

/// Where an engine runs, as the chip and VoiceOver name it.
public enum ModelPlacement: Hashable, Sendable {
    case device
    case cloud
    case localNetwork

    /// The chip's secondary word.
    public var chipWord: String {
        switch self {
        case .device: "iPhone"
        case .cloud: "Nube"
        case .localNetwork: "Red local"
        }
    }

    /// Spoken after the model name.
    public var spokenPhrase: String {
        switch self {
        case .device: "en este iPhone"
        case .cloud: "en la nube"
        case .localNetwork: "en tu red local"
        }
    }
}

/// The engine kinds the sheet tells apart.
public enum ModelEngineSource: Hashable, Sendable {
    case mlx
    case gguf
    case apple
    case cloudPreset(ProviderPresetID)
    /// `isLocalNetwork` is nil while no server is configured.
    case compatibleServer(isLocalNetwork: Bool?)
    case echo

    public var group: ModelGroup {
        switch self {
        case .mlx, .gguf, .apple: .onDevice
        case .cloudPreset: .cloud
        // An internet server is cloud for the consent sheet and the policy, so it is listed with the clouds.
        case .compatibleServer(let isLocalNetwork): isLocalNetwork == false ? .cloud : .network
        case .echo: .debug
        }
    }

    /// An internet server counts as cloud, as the consent sheet and the policy treat it.
    public var placement: ModelPlacement {
        switch self {
        case .mlx, .gguf, .apple, .echo: .device
        case .cloudPreset: .cloud
        case .compatibleServer(let isLocalNetwork): isLocalNetwork == false ? .cloud : .localNetwork
        }
    }
}

/// The sheet's sections, in display order.
public enum ModelGroup: Int, CaseIterable, Comparable, Sendable {
    case onDevice
    case cloud
    case network
    case debug

    public var title: String {
        switch self {
        case .onDevice: "En este iPhone"
        case .cloud: "En la nube"
        case .network: "En tu red local"
        case .debug: "Depuración"
        }
    }

    public static func < (lhs: ModelGroup, rhs: ModelGroup) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Every item lands in the group of its source, in input order, so a row with an unexpected source shows up in
    /// another section instead of vanishing.
    public static func bucket<Item>(_ items: [Item], source: (Item) -> ModelEngineSource) -> [ModelGroup: [Item]] {
        Dictionary(grouping: items) { source($0).group }
    }
}

/// The chip in the composer: a short name, where it runs, and the full VoiceOver label.
public struct ModelChipText: Hashable, Sendable {
    public let name: String
    /// nil when no engine is chosen.
    public let place: String?
    public let accessibilityLabel: String

    public static let maxNameLength = 22
    public static let noSelectionName = "Elegir modelo"

    /// `otherTitles`: the other selectable models, so two quantizations of one model keep their quantization.
    public init(title: String?, placement: ModelPlacement?, otherTitles: [String] = []) {
        guard let title, let placement else {
            name = Self.noSelectionName
            place = nil
            accessibilityLabel = "Modelo: ninguno elegido"
            return
        }
        name = Self.shortName(title, among: otherTitles)
        place = placement.chipWord
        accessibilityLabel = "Modelo: \(title), \(placement.spokenPhrase)"
    }

    /// Drops a trailing "(…)", the `.gguf` extension and the quantization, then truncates with "…".
    public static func shortName(_ title: String) -> String {
        truncated(split(title).base, limit: maxNameLength)
    }

    /// Like `shortName(_:)`, but keeps the quantization when another title has the same base name.
    public static func shortName(_ title: String, among otherTitles: [String]) -> String {
        let parts = split(title)
        guard let token = parts.quantization, let quant = ModelPickerText.quantization(in: token),
              otherTitles.contains(where: { $0 != title && split($0).base == parts.base }) else {
            return truncated(parts.base, limit: maxNameLength)
        }
        let suffix = " " + quant
        return truncated(parts.base, limit: max(maxNameLength - suffix.count, 4)) + suffix
    }

    private static func split(_ title: String) -> (base: String, quantization: String?) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var name = trimmed
        if name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) {
            name = String(name[..<open.lowerBound])
        }
        if name.lowercased().hasSuffix(".gguf") {
            name = String(name.dropLast(5))
        }
        var quantization: String?
        if let quant = ModelPickerText.quantizationToken(in: name),
           let range = name.range(of: quant, options: [.caseInsensitive, .backwards]),
           range.lowerBound > name.startIndex {
            name = String(name[..<range.lowerBound])
            quantization = quant
        }
        name = name.trimmingCharacters(in: ModelPickerText.nameSeparators)
        return (name.isEmpty ? trimmed : name, quantization)
    }

    private static func truncated(_ name: String, limit: Int) -> String {
        guard name.count > limit else { return name }
        return String(name.prefix(limit - 1)).trimmingCharacters(in: ModelPickerText.nameSeparators) + "…"
    }
}

/// Why a remote row cannot be chosen yet; the first that applies wins.
public enum RemoteLock: Hashable, Sendable {
    case remoteOff
    case serverNotConfigured
    case missingKey
    case modelNotChosen
    case cloudNotAllowed

    /// Precedence: remote mode off, server not configured, missing cloud key, no model chosen, cloud not allowed.
    public static func evaluate(
        modeIsOff: Bool, isCloud: Bool, cloudAllowed: Bool, hasKey: Bool, isConfigured: Bool, hasModel: Bool = true
    ) -> RemoteLock? {
        if modeIsOff { return .remoteOff }
        if !isConfigured { return .serverNotConfigured }
        if isCloud && !hasKey { return .missingKey }
        if !hasModel { return .modelNotChosen }
        if isCloud && !cloudAllowed { return .cloudNotAllowed }
        return nil
    }

    /// The full sentence, naming where it is fixed.
    public var message: String {
        switch self {
        case .remoteOff: "El envío remoto está desactivado (modo «Off») en «Claves API y envío remoto»."
        case .serverNotConfigured: "Configura el servidor con el botón de información (i) de su fila."
        case .missingKey: "Falta la clave API. Añádela en «Claves API y envío remoto» › «Proveedores»."
        case .modelNotChosen: "Elige un modelo con el botón de información (i) de su fila."
        case .cloudNotAllowed: "Activa «Allow cloud providers» en «Claves API y envío remoto»."
        }
    }

    /// One line under a locked row; the VoiceOver hint says that a tap opens the fix.
    public var shortReason: String {
        switch self {
        case .remoteOff: "Envío remoto desactivado"
        case .serverNotConfigured: "Sin configurar"
        case .missingKey: "Falta la clave API"
        case .modelNotChosen: "Elige un modelo"
        case .cloudNotAllowed: "Nube no permitida"
        }
    }

    public static let symbol = "lock.fill"
}

/// "Pruebas: 14/19" for a saved capability report, flagged when a safety probe failed or has no outcome.
public struct CapabilitySummary: Hashable, Sendable {
    public let passed: Int
    public let graded: Int
    public private(set) var notRecommended: Bool
    /// Some Seguridad probe was excluded or blocked before the model answered, and none failed.
    public private(set) var isSafetyIncomplete: Bool
    public let isOlderBattery: Bool

    public static let notRecommendedLabel = "No recomendado"
    public static let warningSymbol = "exclamationmark.triangle.fill"

    public init(report: CapabilityReport) {
        // The same counts as the saved row: a hand validation counts as passed in both.
        passed = report.totalPassed
        graded = report.totalGraded
        notRecommended = report.notRecommended
        isSafetyIncomplete = !report.notRecommended && report.isComparable && report.isSafetyIncomplete
        isOlderBattery = !report.isComparable
    }

    /// Counts of `primary` (``CapabilityReportArchive/primaryReport(of:in:)``); flagged when it, or any comparable
    /// level among `levels`, is "No recomendado".
    public init(primary: CapabilityReport, levels: [CapabilityReport]) {
        self.init(report: primary)
        notRecommended = primary.notRecommended || levels.contains { $0.isComparable && $0.notRecommended }
        isSafetyIncomplete = !notRecommended
            && ([primary] + levels).contains { $0.isComparable && $0.isSafetyIncomplete }
    }

    public var text: String {
        let base = "Pruebas: \(passed)/\(graded)"
        return isOlderBattery ? base + " · batería anterior" : base
    }

    public var accessibilityText: String {
        var spoken = "Pruebas de capacidades: \(passed) de \(graded) aprobadas"
        if isOlderBattery { spoken += ", batería anterior" }
        if notRecommended { spoken += ", " + Self.notRecommendedLabel }
        if isSafetyIncomplete { spoken += ", " + CapabilityText.safetyIncompleteLabel }
        return spoken
    }
}

public enum LocalWeightsFormat: String, Hashable, Sendable {
    case gguf = "GGUF"
    case mlx = "MLX"
}

/// Fixed texts and one-line descriptions of the model sheet.
public enum ModelPickerText {
    public static let sheetTitle = "Selecciona un modelo"
    public static let moreModels = "Más modelos"
    public static let searchHuggingFace = "Buscar en Hugging Face"
    public static let downloadedModels = "Modelos descargados"
    public static let sharedStorage = "Almacenamiento compartido"
    public static let filesFooter = "Los modelos GGUF se cargan desde Documentos de esta app o desde el almacenamiento "
        + "compartido. Nada se descarga sin que lo pidas en «Buscar en Hugging Face»."
    public static let remoteFooter = "Cada mensaje se envía solo después de que lo apruebes. La respuesta solo propone "
        + "órdenes."
    /// Under the model list while the capability battery runs, so the greyed rows have a reason.
    public static let runningTestsFooter = "Hay pruebas de capacidades en curso: podrás cambiar de modelo cuando "
        + "terminen."
    public static let testThisModel = "Probar este modelo"
    public static let emptyOnDevice = "Aún no hay modelos descargados en este iPhone."
    public static let findModels = "Buscar modelos"
    public static let appleDetail = "Integrado en iOS"
    public static let echoDetail = "Devuelve tu texto como orden · solo DEBUG"
    public static let serverTitle = "Servidor propio"
    public static let serverUnconfiguredDetail = "Compatible con OpenAI: llama-server, Ollama…"
    public static let noModelChosenDetail = "Sin modelo elegido"
    /// How other screens point at the chip.
    public static let chipReference = "el selector de modelo, junto a «Enviar»"

    static let nameSeparators = CharacterSet(charactersIn: "-_. ")

    /// "GGUF · Q4_K_M · 3,2 GB"; the quantization and size are left out when unknown. `sizeIsApproximate` marks a
    /// catalogue estimate, as opposed to a file size read from disk.
    public static func localDetail(
        format: LocalWeightsFormat, quantization: String?, byteCount: Int64?, sizeIsApproximate: Bool = false
    ) -> String {
        var parts = [format.rawValue]
        if let quantization, !quantization.isEmpty { parts.append(quantization) }
        if let byteCount, byteCount > 0 {
            parts.append((sizeIsApproximate ? "aprox. " : "") + sizeText(byteCount))
        }
        return parts.joined(separator: " · ")
    }

    /// Decimal units, as the Files app shows them, with a decimal comma.
    public static func sizeText(_ bytes: Int64) -> String {
        if bytes >= 1_000_000_000 {
            let value = String(format: "%.1f", Double(bytes) / 1_000_000_000)
            return value.replacingOccurrences(of: ".", with: ",") + " GB"
        }
        if bytes >= 1_000_000 { return "\(bytes / 1_000_000) MB" }
        return "\(max(bytes / 1000, 1)) KB"
    }

    /// The model id, plus where the server is when it is not on the local network.
    public static func serverDetail(modelID: String, hostLabel: String, isLocalNetwork: Bool) -> String {
        let base = modelID + " · " + hostLabel
        return isLocalNetwork ? base : base + " · internet, cuenta como nube"
    }

    /// The quantization as shown in a row: "Q4_K_M", "IQ3_XS", "F16", or "4 bits" for MLX names.
    public static func quantization(in name: String) -> String? {
        guard let token = quantizationToken(in: name) else { return nil }
        let lower = token.lowercased()
        if lower.hasSuffix("bit"), let bits = Int(lower.dropLast(3)) {
            return "\(bits) bits"
        }
        return token.uppercased()
    }

    /// The last quantization token of a file name or model id, as written there.
    static func quantizationToken(in name: String) -> String? {
        let words = name.split { "-. /".contains($0) }
        for word in words.reversed() {
            if let token = quantizationPart(of: word) { return token }
        }
        return nil
    }

    /// The quantization inside one word, from its first quantization part to its end: "llama_Q4_K_M" → "Q4_K_M".
    private static func quantizationPart(of word: Substring) -> String? {
        let parts = word.split(separator: "_", omittingEmptySubsequences: false)
        guard let start = parts.firstIndex(where: isQuantizationHead) else { return nil }
        let tail = parts[start...]
        guard tail.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }) else {
            return nil
        }
        return tail.joined(separator: "_")
    }

    private static func isQuantizationHead(_ part: Substring) -> Bool {
        let upper = part.uppercased()
        if ["F16", "F32", "BF16", "FP16"].contains(upper) { return true }
        if upper.hasSuffix("BIT"), let bits = Int(upper.dropLast(3)), (2...16).contains(bits) { return true }
        let digits: Substring
        if upper.hasPrefix("IQ") {
            digits = Substring(upper.dropFirst(2))
        } else if upper.hasPrefix("Q") {
            digits = Substring(upper.dropFirst())
        } else {
            return false
        }
        guard let first = digits.first, first.isNumber else { return false }
        return digits.allSatisfy { $0.isASCII && ($0.isNumber || $0.isLetter) }
    }
}

/// The settings menu behind the leading toolbar button, in display order.
public enum SettingsMenuEntry: String, CaseIterable, Hashable, Sendable {
    case webServer
    case keyboard
    case pairing
    case remoteSettings
    case downloads
    case capabilityTests
    /// A toggle, not a page: the chat shows the Test Mode questions above the composer.
    case testMode
    case openSource

    public enum MenuSection: CaseIterable, Hashable, Sendable {
        case connections
        case models
        case about

        public var entries: [SettingsMenuEntry] {
            SettingsMenuEntry.allCases.filter { $0.section == self }
        }
    }

    public static let menuTitle = "Ajustes"
    public static let menuSymbol = "line.3.horizontal"
    public static let menuIdentifier = "terminal.settingsMenu"

    public var section: MenuSection {
        switch self {
        case .webServer, .keyboard, .pairing: .connections
        case .remoteSettings, .downloads, .capabilityTests, .testMode: .models
        case .openSource: .about
        }
    }

    public var title: String {
        switch self {
        case .webServer: "Servidor web"
        case .keyboard: "Teclado Bluetooth"
        case .pairing: "Emparejar Mac"
        // Full name kept: several messages send the user to «Claves API y envío remoto».
        case .remoteSettings: "Claves API y envío remoto"
        case .downloads: "Descargas"
        case .capabilityTests: "Probar modelo"
        case .testMode: "Modo Test"
        case .openSource: "Licencias"
        }
    }

    public var symbol: String {
        switch self {
        case .webServer: "globe"
        case .keyboard: "keyboard"
        case .pairing: "link"
        case .remoteSettings: "key"
        case .downloads: "internaldrive"
        case .capabilityTests: "checklist"
        case .testMode: "testtube.2"
        case .openSource: "doc.text"
        }
    }

    /// Entries that moved here keep the identifier of the control they replace.
    public var identifier: String {
        switch self {
        case .webServer: "terminal.webServerButton"
        case .keyboard: "terminal.settings.keyboard"
        case .pairing: "terminal.pairingButton"
        case .remoteSettings: "model.settings"
        case .downloads: "terminal.settings.downloads"
        case .capabilityTests: "terminal.settings.capabilityTests"
        case .testMode: "terminal.settings.testMode"
        case .openSource: "model.openSourceNotices"
        }
    }
}
