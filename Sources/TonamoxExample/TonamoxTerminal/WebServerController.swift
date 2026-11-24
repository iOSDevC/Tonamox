import Foundation
import Observation
import TerminalBridgeKit
import TonamoxCore
import TonamoxServer
import TonamoxUI
import UIKit

/// Where the server listens for one start. Never stored: the next launch starts from `.loopback` and stopped.
enum ListenChoice: Hashable {
    case loopback
    case network(ServerInterface)
}

/// One output a computer posted with an ingest ticket. Untrusted: it reaches the model only through the paste
/// preview, after the user reviews and sends it.
nonisolated struct ReceivedOutput: Identifiable, Sendable {
    let id = UUID()
    let ticketID: UUID
    let label: String
    let peer: String
    let receivedAt: Date
    let byteCount: Int
    let exitStatus: Int32?
    let peerMatchesLock: Bool
    let invalidSequences: Int
    let text: String

    func facts(laterPostRefused: Bool) -> IncomingOutputFacts {
        IncomingOutputFacts(label: label, peer: peer, receivedBytes: byteCount, exitStatus: exitStatus,
                            invalidSequences: invalidSequences, peerMatchesLock: peerMatchesLock,
                            laterPostRefused: laterPostRefused)
    }
}

/// A ticket made for one command line, with the suffix to append to it.
enum LineTicketResult {
    case made(IngestTicket, suffix: String)
    case refused(String)
}

/// Shows a browser's pairing request; the screen presents a sheet while `request` is set.
@MainActor @Observable
final class BrowserPairingPresenter: PairingPresenter {
    private(set) var request: PairingRequest?

    func present(_ request: PairingRequest) async {
        // The SDK calls this from an unstructured task, so it can land after the request ended.
        guard request.expiresAt > Date() else { return }
        self.request = request
    }

    func dismiss(_ id: PairingRequest.ID) {
        if request?.id == id { request = nil }
    }

    func clear() {
        request = nil
    }
}

/// The TonamoxTerminal web server for this launch: started only by "Iniciar", never restored. It serves the chat's
/// selected on-device model (ModelManager's cached, tool-free instance, so no second copy of the weights, or Apple
/// Intelligence) and shares the chat's turnstile.
@MainActor @Observable
final class WebServerController {
    /// The chat's turns wait here too.
    let turnstile = GenerationTurnstile()
    let pairing = BrowserPairingPresenter()
    private(set) var server: TonamoxServer?
    /// Why the selected engine cannot be served; nil when it can. Load failures go to `startError`.
    private(set) var modelProblem: String?
    private(set) var servedTitle: String?
    private(set) var isPreparing = false
    private(set) var preparingText = ""
    private(set) var startError: String?
    /// Shown once, then dropped with `forgetIssuedKey()`.
    private(set) var issuedKey: IssuedAPIKey?
    /// Tickets made on this screen; tickets for a command line are tracked by the chat.
    private(set) var tickets: [IngestTicket] = []
    /// Received outputs waiting for the paste preview. Kept after a stop: they already arrived.
    private(set) var arrivals = IncomingOutputQueue<ReceivedOutput>()
    /// Bumped on every arrival, so the chat screen can try to open the preview.
    private(set) var arrivalCount = 0
    private(set) var pairingWindowUntil: Date?
    /// Tickets the server refused a post for (raced or already used); kept for the whole launch.
    private(set) var refusedTickets: Set<UUID> = []
    /// Bumped on every refusal, so the chat can flag the line and an open preview.
    private(set) var refusalCount = 0

    var listenChoice: ListenChoice = .loopback
    var portText = String(WebServerPort.defaultPort)
    var servesBrowserPage = true
    var acceptsIngest = false
    var servesScripts = false
    /// Persisted, unlike the options above: it is about this phone, not about one run of the server.
    var keepsScreenAwake = WebServerScreenAwake.isEnabled(
        stored: UserDefaults.standard.object(forKey: WebServerScreenAwake.defaultsKey) as? Bool
    ) {
        didSet {
            UserDefaults.standard.set(keepsScreenAwake, forKey: WebServerScreenAwake.defaultsKey)
            refreshScreenAwake()
        }
    }

    @ObservationIgnored private var servedChoiceID: String?
    @ObservationIgnored private var selectedChoice: ModelChoice?
    @ObservationIgnored private var ingestWatch: Task<Void, Never>?
    @ObservationIgnored private var refusalWatch: Task<Void, Never>?
    @ObservationIgnored private var stateWatch: Task<Void, Never>?
    @ObservationIgnored private var switchTask: Task<Void, Never>?
    @ObservationIgnored private var switchGeneration = 0
    /// A foreground reload must survive a newer switch that cancels it before it ran.
    @ObservationIgnored private var forcePending = false
    @ObservationIgnored private var terminationWatch: NSObjectProtocol?
    @ObservationIgnored private var isInForeground = true
    /// Digests and metadata in this app's own keychain group, so keys survive a relaunch; memory for the launch
    /// when the group is unknown.
    @ObservationIgnored let keyStore = ServerKeyStore(accessGroup: PairingStore.ownAccessGroup)
    /// The stored keys while no server exists in this launch; a server's own `clients` take over once one does.
    private(set) var storedKeys: [ClientInfo] = []
    /// Why the stored keys could not be read or a key change was not saved; nil when all went well.
    private(set) var keyProblem: String?

    static let serverName = "Tonamox Terminal"

    init() {
        reloadStoredKeys()
        terminationWatch = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopForTermination() }
        }
    }

    // MARK: State

    var status: WebServerStatus {
        if isPreparing { return .starting }
        guard let server else { return .stopped }
        return WebServerStatus(server.state, idleMinutes: Self.idleMinutes(server.configuration))
    }

    /// The presenter's request while the server still waits for it.
    var livePairingRequest: PairingRequest? {
        guard let request = pairing.request, server?.pendingPairing?.id == request.id else { return nil }
        return request
    }

    var endpoint: ServerEndpoint? {
        guard case .listening(let endpoint) = server?.state else { return nil }
        return endpoint
    }

    /// Where a command line's suffix points; nil unless listening with ingest on.
    var ingestEndpoint: ServerEndpoint? {
        guard let endpoint, server?.configuration.features.contains(.ingest) == true else { return nil }
        return endpoint
    }

    /// The port a USB forward must carry when the ingest suffix points at 127.0.0.1.
    var loopbackIngestPort: UInt16? {
        guard let endpoint = ingestEndpoint, case .loopback = endpoint.exposure else { return nil }
        return endpoint.port
    }

    /// Identifies the server run whose tickets are alive; nil once it stopped, failed or paused for a reason that
    /// does not reopen the port by itself, since curl can no longer reach the phone.
    var ingestSession: ObjectIdentifier? {
        guard let server, server.configuration.features.contains(.ingest) else { return nil }
        switch server.state {
        case .stopped, .failed: return nil
        case .suspended(let reason):
            return WebServerSuspendReason(reason, idleMinutes: 0).reopensByItself ? ObjectIdentifier(server) : nil
        case .starting, .listening: return ObjectIdentifier(server)
        }
    }

    /// Stopped, or failed after a start: the options can change and "Iniciar" is offered.
    var canStart: Bool {
        guard !isPreparing else { return false }
        switch server?.state {
        case nil, .stopped?, .failed?: return true
        default: return false
        }
    }

    var portValidation: Result<UInt16, WebServerPortRefusal> {
        WebServerPort.validate(portText)
    }

    var keyStorage: APIKeyStorage { keyStore.storage }

    /// The keys the screen lists, with or without a server.
    var keyRows: [ClientInfo] {
        server?.clients ?? storedKeys
    }

    // MARK: Start and stop

    /// The chat's selection, kept current by the chat screen; a running server switches to it.
    func selectionChanged(to choice: ModelChoice?) {
        selectedChoice = choice
        modelProblem = Self.servingProblem(for: choice)
        guard let server, !canStart, choice?.id != servedChoiceID else { return }
        requestSwitch(on: server, force: false)
    }

    func start() async {
        guard canStart, case .success(let port) = portValidation else { return }
        startError = nil
        if let server { await server.stop() }
        // A failed run can leave tickets, a pairing request or a key behind; none belongs to the new run.
        clearSession()
        server = nil
        // Until a new server exists the list comes from the store, which the old server may have changed.
        reloadStoredKeys()
        modelProblem = Self.servingProblem(for: selectedChoice)
        guard modelProblem == nil, let choice = selectedChoice else { return }
        // The SDK treats an unreadable store as empty, and the first new key would then overwrite it.
        do {
            _ = try keyStore.loadKeys()
        } catch {
            startError = APIKeyStorageText.startRefusedUnreadable(status: ServerKeyStore.status(of: error))
            return
        }
        isPreparing = true
        preparingText = "Cargando el modelo…"
        refreshScreenAwake()
        defer {
            isPreparing = false
            preparingText = ""
            refreshScreenAwake()
        }
        let served: ServedModel
        do {
            served = try await loadInTurn(choice)
        } catch {
            startError = TerminalChatViewModel.describe(error)
            return
        }
        let created = TonamoxServer(configuration: configuration(port: port), models: [served],
                                    pairing: pairing, credentials: keyStore)
        // The store may have become unreadable during the model load (a locked phone, say).
        if let failure = created.credentialLoadFailure {
            startError = APIKeyStorageText.startRefusedUnreadable(status: ServerKeyStore.status(of: failure))
            reloadStoredKeys(keepingProblem: true)
            return
        }
        server = created
        servedChoiceID = choice.id
        servedTitle = choice.title
        watch(created)
        do {
            _ = try await created.start()
            // The selection may have changed while the model loaded.
            if selectedChoice?.id != servedChoiceID { requestSwitch(on: created, force: false) }
        } catch is ServerFailure {
            // `state` already says why; the screen shows it.
            clearSession()
        } catch {
            clearSession()
            startError = TerminalChatViewModel.describe(error)
        }
    }

    func stop() async {
        guard let server else { return }
        await server.stop()
        clearSession()
        startError = nil
        modelProblem = Self.servingProblem(for: selectedChoice)
    }

    /// Back in the foreground the chat's background eviction has unloaded the served instance; take the cached one
    /// again (the chat's next turn would load the same instance).
    func returnedToForeground() {
        isInForeground = true
        refreshScreenAwake()
        guard let server, !canStart else { return }
        requestSwitch(on: server, force: true)
    }

    /// The app switcher snapshots the screen: a key shown once must not outlive the visit.
    func enteredBackground() {
        isInForeground = false
        refreshScreenAwake()
        forgetIssuedKey()
    }

    /// Best effort: the process usually exits before this task runs, and the system closes the sockets anyway.
    private func stopForTermination() {
        guard let server else { return }
        Task { await server.stop() }
    }

    private func clearSession() {
        cancelSwitch()
        stopWatching()
        tickets = []
        issuedKey = nil
        pairingWindowUntil = nil
        pairing.clear()
        servedChoiceID = nil
        servedTitle = nil
        refreshScreenAwake()
    }

    /// Auto-Lock would background the app, and iOS closes the port there.
    private func refreshScreenAwake() {
        let holds = WebServerScreenAwake.holdsScreen(status: status, enabled: keepsScreenAwake,
                                                     inForeground: isInForeground)
        ScreenAwakeCoordinator.shared.setHeld(holds, for: .webServer)
    }

    private func configuration(port: UInt16) -> ServerConfiguration {
        var configuration = ServerConfiguration(serverName: Self.serverName)
        configuration.port = .fixed(port)
        if case .network(let interface) = listenChoice { configuration.exposure = .interface(interface) }
        var features: ServerFeatures = [.openAIAPI]
        if servesBrowserPage { features.insert(.browserPage) }
        if acceptsIngest { features.insert(.ingest) }
        if servesScripts { features.insert(.scripts) }
        configuration.features = features
        return configuration
    }

    // MARK: Model

    /// ModelManager's cached instance with the chat's sampling: the same one the chat generates with. Apple
    /// Intelligence loads nothing: each served request opens its own session.
    private func loadServedModel(_ choice: ModelChoice) async throws -> ServedModel {
        if let problem = Self.servingProblem(for: choice) { throw ServingRefusal.notServable(problem) }
        if case .appleIntelligence = choice.kind {
            guard #available(iOS 27, *) else { throw ServingRefusal.appleNeedsNewerSystem }
            return try AppleIntelligenceServedModel(id: ServedModelName.id(from: choice.title),
                                                    displayName: choice.title, turnstile: turnstile,
                                                    temperature: Double(ReplyEngines.temperature)).served
        }
        let weights = try LocalModelCatalog.readyModel(for: choice.id)
        let llm = try await ModelManager.shared.load(weights, temperature: ReplyEngines.temperature) { [weak self] in
            self?.preparingText = $0
        }
        try Task.checkCancellation()
        return try LocalServedModel(llm, id: ServedModelName.id(from: choice.title), displayName: choice.title,
                                    turnstile: turnstile).served
    }

    /// Loads holding the turnstile, so nothing decodes on the model being replaced while the next one loads (two
    /// copies of the weights in memory otherwise).
    private func loadInTurn(_ choice: ModelChoice) async throws -> ServedModel {
        while true {
            do {
                return try await turnstile.run { try await self.loadServedModel(choice) }
            } catch ServedModelError.busy {
                try await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// One switch at a time: a newer one cancels the one in progress and waits for it, so two loads never run
    /// together and only the newest selection is served.
    private func requestSwitch(on server: TonamoxServer, force: Bool) {
        let previous = switchTask
        previous?.cancel()
        forcePending = forcePending || force
        switchGeneration += 1
        let generation = switchGeneration
        switchTask = Task { [weak self] in
            await previous?.value
            guard let self, generation == self.switchGeneration else { return }
            let forced = self.forcePending
            self.forcePending = false
            await self.switchModel(on: server, force: forced, generation: generation)
        }
    }

    private func cancelSwitch() {
        switchTask?.cancel()
        switchTask = nil
        switchGeneration += 1
        forcePending = false
    }

    private func switchModel(on server: TonamoxServer, force: Bool, generation: Int) async {
        guard force || selectedChoice?.id != servedChoiceID else { return }
        // Serve nothing first: running requests on the old model end before the next one loads.
        server.setModels([])
        servedChoiceID = nil
        servedTitle = nil
        guard let choice = selectedChoice, Self.servingProblem(for: choice) == nil else { return }
        do {
            let served = try await loadInTurn(choice)
            // A newer selection, a stop or another start may have come while the model loaded.
            guard generation == switchGeneration, self.server === server, !canStart,
                  selectedChoice?.id == choice.id else { return }
            server.setModels([served])
            servedChoiceID = choice.id
            servedTitle = choice.title
        } catch {
            guard generation == switchGeneration, self.server === server else { return }
            startError = TerminalChatViewModel.describe(error)
        }
    }

    static func idleMinutes(_ configuration: ServerConfiguration) -> Int {
        Int((configuration.idleShutdown?.timeInterval ?? 0) / 60)
    }

    /// Only models that run on this iPhone are served: the SDK has no consent step for a served request.
    static func servingProblem(for choice: ModelChoice?) -> String? {
        guard let choice else { return ServingRefusal.noSelection.errorDescription }
        switch choice.kind {
        case .onDisk:
            return nil
        case .appleIntelligence:
            guard #available(iOS 27, *) else { return ServingRefusal.appleNeedsNewerSystem.errorDescription }
            guard case .unavailable(_, let full) = LocalModelCatalog.appleAvailability() else { return nil }
            return ServingRefusal.appleUnavailable(full).errorDescription
        case .remote:
            return ServingRefusal.notOnDevice.errorDescription
        #if DEBUG
        case .echo:
            return "El motor de eco no es un modelo: elige un modelo GGUF o MLX con "
                + ModelPickerText.chipReference + "."
        #endif
        }
    }

    // MARK: Pairing

    func openPairingWindow() {
        guard let server else { return }
        server.openPairingWindow()
        pairingWindowUntil = server.isPairingWindowOpen
            ? Date().addingTimeInterval(server.configuration.limits.pairingWindow.timeInterval) : nil
    }

    func denyPendingPairing() {
        guard let request = pairing.request else { return }
        server?.denyPairing(request.id)
        pairing.clear()
        pairingWindowUntil = nil
    }

    // MARK: Keys

    func issueKey(label: String) -> String? {
        guard let server else { return APIKeyStorageText.issueNeedsServer }
        let live = APIKeyStorageText.liveCount(expiries: server.clients.map(\.expiresAt), now: Date())
        if let refusal = APIKeyStorageText.issueRefusal(liveKeys: live) { return refusal }
        switch APIKeyLabel.sanitize(label) {
        case .failure(let refusal):
            return refusal.message
        case .success(let clean):
            do {
                // The SDK saves before it returns the secret: a key the keychain refused is never shown.
                issuedKey = try server.issueAPIKey(label: clean)
                keyProblem = nil
                return nil
            } catch {
                return APIKeyStorageText.issueNotSaved(status: ServerKeyStore.status(of: error))
            }
        }
    }

    /// Works with the server stopped or never started in this launch.
    func revokeKey(_ id: ClientInfo.ID) {
        revokeKeys([id], all: false)
    }

    /// Also the way out when the stored list cannot be read: an empty list replaces it.
    func revokeAllKeys() {
        revokeKeys(keyRows.map(\.id), all: true)
    }

    private func revokeKeys(_ ids: [ClientInfo.ID], all: Bool) {
        if let server {
            _ = keyStore.takeLastFailure()
            // `revoke` drops the key in memory even when the write fails; the store reports the failure.
            ids.forEach(server.revoke)
            keyProblem = keyStore.takeLastFailure().map { APIKeyStorageText.revokeNotSaved(status: $0.status) }
            return
        }
        let doomed = Set(ids)
        _ = keyStore.takeLastFailure()
        do {
            let kept = try all ? [] : keyStore.loadKeys().filter { !doomed.contains($0.id) }
            try keyStore.save(kept)
            keyProblem = nil
        } catch {
            let status = ServerKeyStore.status(of: error)
            keyProblem = keyStore.takeLastFailure() != nil
                ? APIKeyStorageText.revokeNotSaved(status: status) : APIKeyStorageText.loadFailed(status: status)
        }
        reloadStoredKeys(keepingProblem: true)
    }

    /// Reads the stored keys for the list shown before any server exists in this launch.
    func reloadStoredKeys(keepingProblem: Bool = false) {
        guard server == nil else { return }
        do {
            storedKeys = try keyStore.loadKeys().map(\.info)
            if !keepingProblem { keyProblem = nil }
        } catch {
            storedKeys = []
            keyProblem = APIKeyStorageText.loadFailed(status: ServerKeyStore.status(of: error))
        }
    }

    func forgetIssuedKey() {
        issuedKey = nil
    }

    /// Copies the header line for `curl -H @file`; it expires from the pasteboard after two minutes.
    func copyIssuedKeyHeader() {
        guard let issuedKey else { return }
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: issuedKey.headerLine]],
                                      options: [.expirationDate: Date().addingTimeInterval(120)])
    }

    // MARK: Ingest

    func makeTicket(label: String) async -> String? {
        guard let server, acceptsIngest else { return nil }
        let clean = (try? APIKeyLabel.sanitize(label).get()) ?? "salida"
        do {
            tickets.append(try await server.ingest.makeTicket(label: clean))
            return nil
        } catch IngestError.tooManyTickets(let limit) {
            return "Ya hay \(limit) enlaces abiertos. Cancela alguno."
        } catch {
            return "No se pudo crear el enlace."
        }
    }

    func cancel(_ ticket: IngestTicket) async {
        await server?.ingest.cancel(ticket.id)
        tickets.removeAll { $0.id == ticket.id }
    }

    /// A one-time ticket for one command line; the chat appends `suffix` to the line and shows it before sending.
    func makeLineTicket(label: String) async -> LineTicketResult {
        guard let server, let endpoint = ingestEndpoint else {
            return .refused("El servidor web no está escuchando con «Recepción de salida» activada.")
        }
        do {
            let ticket = try await server.ingest.makeTicket(label: label)
            // The server may have stopped or moved while the ticket was made.
            guard self.server === server, ingestEndpoint == endpoint else {
                await server.ingest.cancel(ticket.id)
                return .refused("El servidor web cambió mientras se creaba el enlace; inténtalo otra vez.")
            }
            return .made(ticket, suffix: ticket.curlSuffix(on: endpoint))
        } catch IngestError.tooManyTickets(let limit) {
            return .refused("Ya hay \(limit) enlaces abiertos. Desactiva el envío por red en alguna orden.")
        } catch {
            return .refused("No se pudo crear el enlace.")
        }
    }

    func cancelTicket(_ id: UUID) async {
        await server?.ingest.cancel(id)
    }

    func discard(_ output: ReceivedOutput) {
        arrivals.remove(output.id)
    }

    func takeArrivalForAutomaticOpen(isPresenting: Bool) -> ReceivedOutput? {
        arrivals.takeForAutomaticOpen(isPresenting: isPresenting)
    }

    func takeArrivalForTap(isPresenting: Bool) -> ReceivedOutput? {
        arrivals.takeForTap(isPresenting: isPresenting)
    }

    func takeArrival(_ id: UUID, isPresenting: Bool) -> ReceivedOutput? {
        arrivals.take(id, isPresenting: isPresenting)
    }

    private func watch(_ created: TonamoxServer) {
        stopWatching()
        if created.configuration.features.contains(.ingest) {
            let inbox = created.ingest
            ingestWatch = Task { [weak self] in
                for await output in inbox.outputs {
                    self?.receive(output)
                }
            }
            refusalWatch = Task { [weak self] in
                for await refusal in inbox.refusals {
                    self?.noteRefusal(refusal)
                }
            }
        }
        // A failure after a foreground rebind arrives here; the run's tickets, pairing and key end with it.
        stateWatch = Task { [weak self] in
            for await state in created.states() {
                guard let self, self.server === created else { continue }
                if case .failed = state { self.clearSession() }
                self.refreshScreenAwake()
            }
        }
    }

    private func stopWatching() {
        ingestWatch?.cancel()
        ingestWatch = nil
        refusalWatch?.cancel()
        refusalWatch = nil
        stateWatch?.cancel()
        stateWatch = nil
    }

    private func noteRefusal(_ refusal: IngestRefusal) {
        refusedTickets.insert(refusal.ticketID)
        refusalCount += 1
    }

    private func receive(_ output: IngestedOutput) {
        tickets.removeAll { $0.id == output.ticketID }
        arrivals.append(ReceivedOutput(
            ticketID: output.ticketID, label: output.label, peer: output.peer, receivedAt: output.receivedAt,
            byteCount: output.rawBytes.count, exitStatus: output.exitStatus, peerMatchesLock: output.peerMatchesLock,
            invalidSequences: output.replacedSequences, text: output.text
        ))
        arrivalCount += 1
    }
}

extension ScreenAwakeReason {
    /// The web server is listening or starting with «Mantener la pantalla encendida mientras sirve» on.
    static let webServer = ScreenAwakeReason("webServer")
}

enum ServingRefusal: LocalizedError {
    case noSelection
    case notOnDevice
    case appleUnavailable(String)
    case appleNeedsNewerSystem
    case notServable(String)

    var errorDescription: String? {
        switch self {
        case .noSelection:
            "Elige un modelo con " + ModelPickerText.chipReference + ", antes de iniciar el servidor."
        case .notOnDevice:
            "El servidor web solo sirve modelos que funcionan en este iPhone (GGUF, MLX o Apple Intelligence). Toca "
                + ModelPickerText.chipReference + ", y elige uno de «En este iPhone»; los motores remotos no se sirven."
        case .appleUnavailable(let reason):
            "Apple Intelligence no se puede servir ahora: " + reason + " Elige un modelo GGUF o MLX con "
                + ModelPickerText.chipReference + "."
        case .appleNeedsNewerSystem:
            "Servir Apple Intelligence requiere iOS 27. Elige un modelo GGUF o MLX con "
                + ModelPickerText.chipReference + "."
        case .notServable(let reason):
            reason
        }
    }
}

extension WebServerStatus {
    init(_ state: ServerState, idleMinutes: Int) {
        switch state {
        case .stopped: self = .stopped
        case .starting: self = .starting
        case .listening(let endpoint):
            self = .listening(url: endpoint.baseURL.absoluteString, observableByNetwork: endpoint.isObservableByNetwork)
        case .suspended(let reason): self = .suspended(WebServerSuspendReason(reason, idleMinutes: idleMinutes))
        case .failed(let failure): self = .failed(WebServerFailure(failure))
        }
    }
}

extension WebServerSuspendReason {
    init(_ reason: SuspendReason, idleMinutes: Int) {
        switch reason {
        case .appBackgrounded: self = .appBackgrounded
        case .interfaceLost(let name): self = .interfaceLost(name)
        case .idle: self = .idle(minutes: idleMinutes)
        }
    }
}

extension WebServerFailure {
    init(_ failure: ServerFailure) {
        switch failure {
        case .portInUse(let port): self = .portInUse(port)
        case .alreadyRunning: self = .alreadyRunning
        case .listener(let detail): self = .listener(detail)
        case .interfaceUnavailable(let name): self = .interfaceUnavailable(name)
        }
    }
}

extension WebServerInterfaceKind {
    init(_ kind: InterfaceKind) {
        switch kind {
        case .wifi: self = .wifi
        case .personalHotspot: self = .personalHotspot
        case .wired: self = .wired
        case .other: self = .other
        }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
