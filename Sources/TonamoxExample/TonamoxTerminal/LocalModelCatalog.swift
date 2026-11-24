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
        /// Sent off the device after consent on every turn; never a default choice.
        case remote(RemoteEngineKind)
        #if DEBUG
        case echo
        #endif
    }

    let id: String
    let title: String
    /// One line: format, quantization and size, or the model id for a remote engine.
    let detail: String
    let kind: ChoiceKind
    /// Decides the sheet group and the chip's "where it runs" word.
    let source: ModelEngineSource
    /// A ``ModifiedModelHeuristic`` term in the weights' names, or a catalogue entry flagged `Model.isUncensored`.
    var safetyFiltersRemoved = false
}

enum RemoteEngineKind: Hashable {
    case preset(ProviderPresetID)
    case compatibleServer
}

/// A remote engine in the picker; a locked row says why and its tap leads to what unlocks it.
struct RemoteChoiceRow: Equatable, Identifiable {
    let choice: ModelChoice
    let lock: RemoteLock?

    var id: String { choice.id }
    var blocker: String? { lock?.message }
}

enum AppleModelAvailability: Equatable {
    case available
    /// `short` fits on one line under the row; `full` is the VoiceOver hint.
    case unavailable(short: String, full: String)

    static func unavailable(_ reason: String) -> Self { .unavailable(short: reason, full: reason) }
}

/// What the picker can offer right now.
struct CatalogListing: Equatable {
    var onDevice: [ModelChoice] = []
    var ggufFiles: [ModelChoice] = []
    var apple: AppleModelAvailability = .unavailable("Comprobando…")
    var debugChoices: [ModelChoice] = []
    var remote: [RemoteChoiceRow] = []

    /// True when there is a model on this device; the DEBUG echo engine and remote engines do not count.
    var hasModels: Bool {
        !onDevice.isEmpty || !ggufFiles.isEmpty || apple == .available
    }

    /// Every choice that can be selected: the local ones, then the unblocked remote ones.
    var selectable: [ModelChoice] {
        defaultSelectable + remote.filter { $0.blocker == nil }.map(\.choice)
    }

    /// The local choices, in the order a default is picked. A remote engine is only ever chosen with a tap.
    var defaultSelectable: [ModelChoice] {
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
        case .notOnDevice: "El modelo ya no está en el dispositivo. Vuelve a descargarlo desde «Buscar en Hugging Face»."
        case .mlxInSimulator: "Los modelos MLX no funcionan en el simulador."
        case .appleNeedsNewerSystem: "Apple Intelligence requiere iOS 27."
        }
    }
}

/// Builds the local choices from what is on disk only, plus the remote rows. It never calls a download or
/// registry-refresh API.
enum LocalModelCatalog {
    static let appleChoice = ModelChoice(
        id: "apple",
        title: "Apple Intelligence",
        detail: ModelPickerText.appleDetail,
        kind: .appleIntelligence,
        source: .apple
    )

    #if DEBUG
    static let echoChoice = ModelChoice(
        id: "echo",
        title: "Eco (sin modelo)",
        detail: ModelPickerText.echoDetail,
        kind: .echo,
        source: .echo
    )
    #endif

    static func listing() -> CatalogListing {
        let disk = diskChoices()
        var listing = CatalogListing(onDevice: disk.onDevice, ggufFiles: disk.files, apple: appleAvailability())
        listing.remote = RemoteTargets.rows(policy: HybridSettings.shared.policy)
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
        let flagged = SafetyFiltersMark.flaggedCatalogueFiles()
        let onDevice = Model.textModels.filter(\.isDownloaded).compactMap { catalogChoice($0, flagged: flagged) }
        var seenModelIDs = Set(onDevice.compactMap { modelID(of: $0) })
        let documents = LocalGGUFFiles.list(in: URL.documentsDirectory)
            .compactMap { documentsChoice($0, flagged: flagged) }
        let shared = DownloadedModels.scan()
            .filter { LocalGGUFFiles.isModelFile($0.fileURL) }
            .compactMap { sharedChoice($0, flagged: flagged) }
        // ModelManager caches by Model.id ("local__<filename>"), so a second file with the same name is left out.
        let files = (documents + shared).filter { choice in
            guard let id = modelID(of: choice) else { return false }
            return seenModelIDs.insert(id).inserted
        }
        return (onDevice, files)
    }

    private static func catalogChoice(_ catalogModel: Model, flagged: Set<String>) -> ModelChoice? {
        switch catalogModel.format {
        case .mlx:
            #if targetEnvironment(simulator)
            return nil
            #else
            return ModelChoice(
                id: "mlx:" + catalogModel.id,
                title: catalogModel.displayName,
                detail: ModelPickerText.localDetail(
                    format: .mlx, quantization: ModelPickerText.quantization(in: catalogModel.id),
                    // The catalogue figure is an estimate in MiB, as MLXBackend reads it.
                    byteCount: Int64(catalogModel.approximateSizeMB) * 1_048_576, sizeIsApproximate: true),
                kind: .onDisk(catalogModel),
                source: .mlx,
                safetyFiltersRemoved: catalogModel.isUncensored || ModifiedModelHeuristic.applies(
                    repoID: catalogModel.repoID, displayName: catalogModel.displayName)
            )
            #endif
        case .gguf:
            guard let file = catalogModel.resolvedFileURL else { return nil }
            // `fileChoice` rebuilds the model as a local file, which drops `isUncensored`; `flagged` keeps it.
            return fileChoice(file, title: catalogModel.displayName, repoID: catalogModel.repoID, flagged: flagged)
        }
    }

    private static func documentsChoice(_ file: URL, flagged: Set<String>) -> ModelChoice? {
        fileChoice(file, title: file.lastPathComponent, flagged: flagged)
    }

    private static func sharedChoice(_ download: DownloadedGGUF, flagged: Set<String>) -> ModelChoice? {
        fileChoice(download.fileURL, title: download.fileURL.lastPathComponent, repoID: download.repoID,
                   flagged: flagged)
    }

    private static func fileChoice(
        _ file: URL, title: String, repoID: String? = nil, flagged: Set<String>
    ) -> ModelChoice? {
        guard let local = Model.from(.localFile(file), displayName: title) else { return nil }
        let detail = ModelPickerText.localDetail(
            format: .gguf, quantization: ModelPickerText.quantization(in: file.lastPathComponent),
            byteCount: fileSize(file))
        return ModelChoice(
            id: "file:" + file.standardizedFileURL.path(percentEncoded: false),
            title: title,
            detail: detail,
            kind: .onDisk(local),
            source: .gguf,
            safetyFiltersRemoved: ModifiedModelHeuristic.applies(
                fileName: file.lastPathComponent, repoID: repoID, displayName: title, flaggedFileNames: flagged)
        )
    }

    private static func fileSize(_ file: URL) -> Int64? {
        // `path(percentEncoded: false)`: the shared storage root contains a space.
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))
        return (attributes?[.size] as? NSNumber)?.int64Value
    }

    private static func modelID(of choice: ModelChoice) -> String? {
        guard case .onDisk(let weights) = choice.kind else { return nil }
        return weights.id
    }

    // MARK: Apple

    static func appleAvailability() -> AppleModelAvailability {
        guard #available(iOS 27, *) else { return .unavailable("Requiere iOS 27.") }
        switch AIAvailability.status {
        case .available:
            #if targetEnvironment(simulator)
            return SimulatorAppleProbe.shared.result
                ?? .unavailable(short: "Comprobando…", full: "Comprobando con una respuesta de prueba…")
            #else
            return .available
            #endif
        case .unavailable(let reason):
            return describeAppleReason(reason)
        }
    }

    /// Simulator only: runs the trial generation once when the system claims the model is available.
    static func checkAppleModelIfNeeded(then refresh: @escaping () -> Void) {
        #if targetEnvironment(simulator)
        guard #available(iOS 27, *), AIAvailability.status == .available else { return }
        SimulatorAppleProbe.shared.start(then: refresh)
        #endif
    }

    static func describeAppleReason(_ reason: String) -> AppleModelAvailability {
        if reason.contains("appleIntelligenceNotEnabled") {
            return .unavailable(short: "No activado en Ajustes",
                                full: "Apple Intelligence no está activado en este dispositivo.")
        }
        if reason.contains("deviceNotEligible") {
            return .unavailable(short: "No compatible con este dispositivo",
                                full: "Este dispositivo no es compatible con Apple Intelligence.")
        }
        if reason.contains("modelNotReady") {
            return .unavailable(short: "Aún no está listo", full: "El modelo de Apple aún no está listo.")
        }
        return .unavailable(short: "No disponible", full: "Apple Intelligence no está disponible (\(reason)).")
    }
}

/// Spanish text for the Apple Intelligence errors the chat and the capability tests show.
enum AppleSessionErrorText {
    static func message(for error: any Error) -> String? {
        guard #available(iOS 27, *), let session = error as? AISessionError else { return nil }
        return message(for: session)
    }

    @available(iOS 27, *)
    static func message(for error: AISessionError) -> String {
        switch error {
        case .modelUnavailable(let reason):
            guard case .unavailable(_, let full) = LocalModelCatalog.describeAppleReason(reason) else {
                return "Apple Intelligence no está disponible."
            }
            return full
        case .assetsUnavailable:
            return "El modelo de Apple aún no está listo en este dispositivo (se está descargando o le faltan "
                + "recursos). Prueba más tarde."
        case .guardrailViolation:
            return "Los filtros de seguridad de Apple Intelligence bloquearon la petición. Reformula el mensaje."
        case .refusal:
            return "Apple Intelligence se negó a responder a esta petición. Reformula el mensaje."
        case .contextWindowExceeded(let limit, let tokenCount):
            return "El mensaje no cabe en la ventana de contexto de Apple Intelligence (\(tokenCount) de \(limit) "
                + "tokens). Acórtalo o pega menos salida."
        case .unsupportedLanguage(let language):
            return "Apple Intelligence no admite este idioma o región (\(language))."
        case .rateLimited(let resetDate):
            guard let resetDate else {
                return "Apple Intelligence recibió demasiadas peticiones. Espera un momento y vuelve a enviar."
            }
            return "Apple Intelligence recibió demasiadas peticiones. Vuelve a enviar después de las "
                + "\(resetDate.formatted(date: .omitted, time: .shortened))."
        case .timeout:
            return "Apple Intelligence tardó demasiado en responder. Vuelve a enviar."
        case .concurrentRequest:
            return "Apple Intelligence ya está respondiendo otra petición. Espera a que termine."
        case .generationFailed(let detail):
            return "Apple Intelligence no pudo generar la respuesta (\(detail))."
        }
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
        guard #available(iOS 27, *) else { return .unavailable("Requiere iOS 27.") }
        do {
            let session = try AISession(instructions: "Responde solo: ok")
            #if canImport(FoundationModels)
            _ = try await session.respond(to: "ok", options: GenerationOptions(maximumResponseTokens: 4))
            #else
            _ = try await session.respond(to: "ok")
            #endif
            return .available
        } catch {
            return .unavailable(short: "No responde en el simulador", full: failureReason)
        }
    }
}
#endif
