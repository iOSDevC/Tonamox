import Foundation
import TerminalBridgeKit
import TonamoxAppleIntelligence
import TonamoxCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// One row of the model picker.
struct ModelChoice: Identifiable, Hashable {
    enum ChoiceKind: Hashable {
        /// Weights already on disk. GGUF entries are always `.localFile` models, so loading one cannot download.
        case onDisk(Model)
        case appleIntelligence
        #if DEBUG
        case echo
        #endif
    }

    let id: String
    let title: String
    let detail: String
    let kind: ChoiceKind
}

enum AppleModelAvailability: Equatable {
    case available
    case unavailable(String)
}

/// What the picker can offer right now.
struct CatalogListing: Equatable {
    var onDevice: [ModelChoice] = []
    var ggufFiles: [ModelChoice] = []
    var apple: AppleModelAvailability = .unavailable("Comprobando…")
    var debugChoices: [ModelChoice] = []

    /// True when there is a real model; the DEBUG echo engine does not count.
    var hasModels: Bool {
        !onDevice.isEmpty || !ggufFiles.isEmpty || apple == .available
    }

    /// Every choice that can be selected, in the order a default is picked.
    var selectable: [ModelChoice] {
        let appleRows = apple == .available ? [LocalModelCatalog.appleChoice] : []
        #if DEBUG && targetEnvironment(simulator)
        // The Simulator's Apple model depends on the Mac, so the deterministic engine is the default there.
        return onDevice + ggufFiles + debugChoices + appleRows
        #else
        return onDevice + ggufFiles + appleRows + debugChoices
        #endif
    }
}

enum CatalogError: LocalizedError {
    case notOnDevice
    case mlxInSimulator
    case appleNeedsNewerSystem

    var errorDescription: String? {
        switch self {
        case .notOnDevice: "El modelo ya no está en el dispositivo. Esta app no descarga modelos."
        case .mlxInSimulator: "Los modelos MLX no funcionan en el simulador."
        case .appleNeedsNewerSystem: "Apple Intelligence requiere iOS 26."
        }
    }
}

/// Builds the choices from what is on disk only. It never calls a download or registry-refresh API.
enum LocalModelCatalog {
    static let appleChoice = ModelChoice(
        id: "apple",
        title: "Apple Intelligence",
        detail: "Modelo del sistema",
        kind: .appleIntelligence
    )

    #if DEBUG
    static let echoChoice = ModelChoice(
        id: "echo",
        title: "Eco (sin modelo)",
        detail: "Devuelve tu texto como orden. Solo en DEBUG.",
        kind: .echo
    )
    #endif

    static func listing() -> CatalogListing {
        let disk = diskChoices()
        var listing = CatalogListing(onDevice: disk.onDevice, ggufFiles: disk.files, apple: appleAvailability())
        #if DEBUG
        listing.debugChoices = [echoChoice]
        #endif
        return listing
    }

    /// Rebuilds the catalog and checks the weights again right before a load.
    static func readyModel(for choiceID: String) throws -> Model {
        let disk = diskChoices()
        let match = (disk.onDevice + disk.files).first { $0.id == choiceID }
        guard let match, case .onDisk(let weights) = match.kind else { throw CatalogError.notOnDevice }
        switch weights.format {
        case .gguf:
            guard let file = weights.localFileURL, LocalGGUFFiles.exists(file) else { throw CatalogError.notOnDevice }
        case .mlx:
            #if targetEnvironment(simulator)
            throw CatalogError.mlxInSimulator
            #else
            // TOCTOU: if the `.complete` marker vanishes before the load, MLXBackend would fetch the snapshot.
            guard weights.isDownloaded else { throw CatalogError.notOnDevice }
            #endif
        }
        return weights
    }

    // MARK: Disk

    private static func diskChoices() -> (onDevice: [ModelChoice], files: [ModelChoice]) {
        let onDevice = Model.textModels.filter(\.isDownloaded).compactMap { catalogChoice($0) }
        var seenModelIDs = Set(onDevice.compactMap { modelID(of: $0) })
        let documents = LocalGGUFFiles.list(in: URL.documentsDirectory).compactMap { documentsChoice($0) }
        let shared = DownloadedModels.scan()
            .map(\.fileURL)
            .filter { LocalGGUFFiles.isModelFile($0) }
            .compactMap { sharedChoice($0) }
        // ModelManager caches by Model.id ("local__<filename>"), so a second file with the same name is left out.
        let files = (documents + shared).filter { choice in
            guard let id = modelID(of: choice) else { return false }
            return seenModelIDs.insert(id).inserted
        }
        return (onDevice, files)
    }

    private static func catalogChoice(_ catalogModel: Model) -> ModelChoice? {
        switch catalogModel.format {
        case .mlx:
            #if targetEnvironment(simulator)
            return nil
            #else
            return ModelChoice(
                id: "mlx:" + catalogModel.id,
                title: catalogModel.displayName,
                detail: "MLX · en este dispositivo",
                kind: .onDisk(catalogModel)
            )
            #endif
        case .gguf:
            guard let file = catalogModel.resolvedFileURL else { return nil }
            return fileChoice(file, title: catalogModel.displayName, detail: "GGUF · en este dispositivo")
        }
    }

    private static func documentsChoice(_ file: URL) -> ModelChoice? {
        fileChoice(file, title: file.lastPathComponent, detail: "GGUF · Documentos de esta app")
    }

    private static func sharedChoice(_ file: URL) -> ModelChoice? {
        fileChoice(file, title: file.lastPathComponent, detail: "GGUF · almacenamiento compartido")
    }

    private static func fileChoice(_ file: URL, title: String, detail: String) -> ModelChoice? {
        guard let local = Model.from(.localFile(file), displayName: title) else { return nil }
        return ModelChoice(
            id: "file:" + file.standardizedFileURL.path(percentEncoded: false),
            title: title,
            detail: detail,
            kind: .onDisk(local)
        )
    }

    private static func modelID(of choice: ModelChoice) -> String? {
        guard case .onDisk(let weights) = choice.kind else { return nil }
        return weights.id
    }

    // MARK: Apple

    static func appleAvailability() -> AppleModelAvailability {
        guard #available(iOS 26, *) else { return .unavailable("Requiere iOS 26.") }
        switch AIAvailability.status {
        case .available:
            #if targetEnvironment(simulator)
            return SimulatorAppleProbe.shared.result ?? .unavailable("Comprobando con una respuesta de prueba…")
            #else
            return .available
            #endif
        case .unavailable(let reason):
            return .unavailable(describeAppleReason(reason))
        }
    }

    /// Simulator only: runs the trial generation once when the system claims the model is available.
    static func checkAppleModelIfNeeded(then refresh: @escaping () -> Void) {
        #if targetEnvironment(simulator)
        guard #available(iOS 26, *), AIAvailability.status == .available else { return }
        SimulatorAppleProbe.shared.start(then: refresh)
        #endif
    }

    private static func describeAppleReason(_ reason: String) -> String {
        if reason.contains("appleIntelligenceNotEnabled") {
            return "Apple Intelligence no está activado en este dispositivo."
        }
        if reason.contains("deviceNotEligible") {
            return "Este dispositivo no es compatible con Apple Intelligence."
        }
        if reason.contains("modelNotReady") {
            return "El modelo de Apple aún no está listo."
        }
        return "No disponible (\(reason))."
    }
}

#if targetEnvironment(simulator)
/// The Simulator reports the system model as available even when generation fails, because it borrows
/// the Mac's Apple Intelligence; one short trial generation decides instead.
final class SimulatorAppleProbe {
    static let shared = SimulatorAppleProbe()
    static let failureReason = "En el simulador, Apple Intelligence usa el de la Mac y no respondió a una prueba."

    private(set) var result: AppleModelAvailability?
    private var isRunning = false

    func start(then refresh: @escaping () -> Void) {
        guard result == nil, !isRunning else { return }
        isRunning = true
        Task {
            result = await Self.trial()
            isRunning = false
            refresh()
        }
    }

    private static func trial() async -> AppleModelAvailability {
        guard #available(iOS 26, *) else { return .unavailable("Requiere iOS 26.") }
        do {
            let session = try AISession(instructions: "Responde solo: ok")
            #if canImport(FoundationModels)
            _ = try await session.respond(to: "ok", options: GenerationOptions(maximumResponseTokens: 4))
            #else
            _ = try await session.respond(to: "ok")
            #endif
            return .available
        } catch {
            return .unavailable(failureReason)
        }
    }
}
#endif
