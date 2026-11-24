import Combine
import CryptoKit
import Foundation
import Observation
import TonamoxCore
import TonamoxHTTP

/// A foreground-only local HTTP server that exposes on-device models through an OpenAI-compatible API on
/// 127.0.0.1, or on one chosen interface's IPv4 address (``ServerExposure/interface(_:)``). Every model route needs an API key issued by the host app (or the CLI) with ``issueAPIKey(label:scopes:lifetime:)``.
///
/// When the app moves to the background (iOS) the listener and every connection close and ``state`` becomes
/// ``ServerState/suspended(_:)``; on return to the foreground the same port is bound again or ``state`` reports
/// ``ServerFailure/portInUse(_:)``. Apps on macOS or visionOS call ``suspend(_:)`` and ``resume()`` from `scenePhase`.
@MainActor @Observable
public final class TonamoxServer {
    public let configuration: ServerConfiguration
    public private(set) var state: ServerState = .stopped
    /// API keys, never their secrets.
    public internal(set) var clients: [ClientInfo] = []
    /// Why the credential store could not be read at init; nil once a read succeeded. While set, ``clients`` is
    /// empty and ``issueAPIKey(label:scopes:lifetime:)`` reads the store again instead of overwriting it.
    public private(set) var credentialLoadFailure: (any Error)?
    /// Bounded log of answered requests, without content.
    public private(set) var activity: [ServerActivity] = []
    public private(set) var servedModels: [ServedModelInfo] = []
    /// Tickets for `POST /i/{ticket}` and the outputs posted with them (``ServerFeatures/ingest``).
    public let ingest: IngestInbox
    /// The browser pairing waiting for its code, as the ``PairingPresenter`` shows it.
    public internal(set) var pendingPairing: PairingRequest?
    /// Paired browsers, never their tokens. Memory only; ``stop()`` ends them all.
    public internal(set) var pairedBrowsers: [BrowserSessionInfo] = []
    /// Whether `POST /pair` is accepted right now (``openPairingWindow()``).
    public var isPairingWindowOpen: Bool {
        pairingWindowUntil.map { clock.monotonic() < $0 } ?? false
    }
    /// Interface exposure with ``PeerLock/firstPairedPeer``: the computers allowed to connect. Empty until the first
    /// pairing or API-key use; cleared by ``stop()``.
    public internal(set) var lockedPeers: [String] = []

    @ObservationIgnored var models: [ServedModel]
    @ObservationIgnored let credentials: any ServerCredentialStore
    @ObservationIgnored var keys: [StoredAPIKey]
    /// When each key's use was last written, so steady use still saves once a minute.
    @ObservationIgnored var usageSavedAt: [UUID: Date] = [:]
    @ObservationIgnored let lifecycle: BackgroundLifecycle
    @ObservationIgnored package var clock: ServerClock
    @ObservationIgnored let log: ServerLog
    @ObservationIgnored var failures: FailureBudget
    @ObservationIgnored var chatRate: KeyedTokenBuckets<UUID>
    @ObservationIgnored var ingestRate: KeyedTokenBuckets<String>
    @ObservationIgnored var scriptRate: KeyedTokenBuckets<String>
    @ObservationIgnored var inflightBody = 0
    @ObservationIgnored var generations: [UUID: GenerationControl] = [:]
    @ObservationIgnored let pairing: (any PairingPresenter)?
    @ObservationIgnored var pairingWindowUntil: ContinuousClock.Instant?
    @ObservationIgnored var pairingState: PairingSlot?
    @ObservationIgnored var pairingRate: KeyedTokenBuckets<String>
    @ObservationIgnored var pairingGlobalRate: TokenBucket
    @ObservationIgnored var pairedTokens: [BrowserToken] = [] {
        didSet { pairedBrowsers = pairedTokens.map(\.info) }
    }
    @ObservationIgnored let createdAt: Int
    @ObservationIgnored let network: ServerNetwork
    @ObservationIgnored var anotherComputerUntil: ContinuousClock.Instant?
    @ObservationIgnored var boundSubnet: IPv4Subnet?
    @ObservationIgnored var boundHost = ListenerBinding.loopbackIPv4.host
    @ObservationIgnored var lastActivity: ContinuousClock.Instant
    @ObservationIgnored var idleWatch: Task<Void, Never>?
    @ObservationIgnored var pathWatch: PathWatch?
    @ObservationIgnored private(set) var transport: NWHTTPTransport?
    @ObservationIgnored private var acceptLoop: Task<Void, Never>?
    @ObservationIgnored private var exchanges: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var boundPort: UInt16?
    @ObservationIgnored private var lifecycleWatch: AnyCancellable?
    @ObservationIgnored private var transitions: Task<Void, Never>?
    /// Set while shutting down: new connections are closed and late generations are interrupted with it.
    @ObservationIgnored var closingReason: APIError?
    @ObservationIgnored private var stateSubscribers: [UUID: AsyncStream<ServerState>.Continuation] = [:]
    @ObservationIgnored private var eventSubscribers: [UUID: AsyncStream<ServerEvent>.Continuation] = [:]

    static let activityLimit = 100

    /// `pairing` shows browser pairing codes; without one, `POST /pair` stays closed.
    public convenience init(configuration: ServerConfiguration, models: [ServedModel],
                            pairing: (any PairingPresenter)? = nil,
                            credentials: any ServerCredentialStore = InMemoryServerCredentials()) {
        self.init(configuration: configuration, models: models, credentials: credentials, lifecycle: .shared,
                  clock: .live, log: .system, pairing: pairing)
    }

    package init(configuration: ServerConfiguration, models: [ServedModel], credentials: any ServerCredentialStore,
                 lifecycle: BackgroundLifecycle, clock: ServerClock, log: ServerLog,
                 pairing: (any PairingPresenter)? = nil, network: ServerNetwork = .live) {
        self.pairing = pairing
        self.network = network
        self.configuration = configuration
        self.models = models
        self.credentials = credentials
        self.lifecycle = lifecycle
        self.clock = clock
        self.log = log
        let now = clock.monotonic()
        self.lastActivity = now
        self.failures = FailureBudget(limits: configuration.limits, perIPEnabled: configuration.exposure != .loopback,
                                      now: now)
        self.chatRate = KeyedTokenBuckets(capacity: configuration.limits.chatRequestsPerMinute, per: .seconds(60))
        self.ingestRate = KeyedTokenBuckets(capacity: configuration.limits.ingestPostsPerMinute, per: .seconds(60))
        self.scriptRate = KeyedTokenBuckets(capacity: configuration.limits.scriptFetchesPerMinute, per: .seconds(60))
        self.pairingRate = KeyedTokenBuckets(capacity: configuration.limits.pairingRequestsPerMinutePerIP,
                                             per: .seconds(60))
        self.pairingGlobalRate = TokenBucket(capacity: configuration.limits.pairingRequestsPerMinute,
                                             per: .seconds(60), now: now)
        self.ingest = IngestInbox(limits: configuration.limits, clock: clock)
        self.createdAt = Int(clock.wall().timeIntervalSince1970)
        var loadFailure: (any Error)?
        do {
            self.keys = try credentials.loadKeys()
        } catch {
            self.keys = []
            loadFailure = error
            log.record("credential store could not be read")
        }
        self.credentialLoadFailure = loadFailure
        self.clients = keys.map(\.info)
        self.servedModels = models.map(\.info)
    }

    // MARK: - Lifecycle

    /// Binds 127.0.0.1, or the chosen interface's address, on the configured port and starts answering. Fails with
    /// ``ServerFailure/interfaceUnavailable(_:)`` when that interface no longer has that address.
    public func start() async throws -> ServerEndpoint {
        try await enqueue { try await self.startNow() }.value
    }

    private func startNow() async throws -> ServerEndpoint {
        switch state {
        case .listening(let endpoint): return endpoint
        case .starting, .suspended: throw ServerFailure.alreadyRunning
        case .stopped, .failed: break
        }
        setState(.starting)
        watchLifecycle()
        guard !lifecycle.isPaused else {
            setState(.stopped)
            throw ServerFailure.listener("The app is in the background.")
        }
        do {
            switch configuration.port {
            case .fixed(let port):
                return try await bind(port)
            case .ephemeral:
                return try await bind(0)
            case .preferred(let port):
                do {
                    return try await bind(port)
                } catch ServerFailure.portInUse {
                    return try await bind(0)
                }
            }
        } catch let failure as ServerFailure {
            setState(.failed(failure))
            throw failure
        }
    }

    /// Closes the listener and every connection, ends running generations, every ingest ticket, every browser
    /// session and any pending pairing. Keys stay in the credential store.
    public func stop() async {
        _ = try? await enqueue { await self.stopNow() }.value
    }

    private func stopNow() async {
        guard state != .stopped else { return }
        lifecycleWatch = nil
        await shutDown(reason: .modelUnavailable)
        await ingest.cancelAll()
        closePairing()
        disconnectAllSessions()
        resetPeerLock()
        boundPort = nil
        setState(.stopped)
        log.record("stopped")
    }

    /// Closes the listener and every connection; running streams end with `app_backgrounded`.
    public func suspend(_ reason: SuspendReason) async {
        _ = try? await enqueue { await self.suspendNow(reason) }.value
    }

    private func suspendNow(_ reason: SuspendReason) async {
        guard case .listening = state else { return }
        setState(.suspended(reason))
        await shutDown(reason: .appBackgrounded)
        log.record("suspended")
    }

    /// Binds the port used before the suspension again; fails with ``ServerFailure/portInUse(_:)`` if it was taken,
    /// which also ends every ingest ticket (their URLs name the lost port), or with
    /// ``ServerFailure/interfaceUnavailable(_:)`` if the chosen interface no longer has its address.
    public func resume() async throws {
        try await enqueue { try await self.resumeNow() }.value
    }

    private func resumeNow() async throws {
        guard case .suspended = state, let port = boundPort else { return }
        do {
            _ = try await bind(port)
        } catch let failure as ServerFailure {
            await ingest.cancelAll()
            setState(.failed(failure))
            throw failure
        }
    }

    private func bind(_ port: UInt16) async throws -> ServerEndpoint {
        let limits = configuration.limits
        let binding = try resolvedBinding()
        let admission: AdmissionPolicy
        switch binding {
        case .loopbackIPv4:
            admission = AdmissionPolicy(maxConnections: limits.maxConnections, maxPerPeer: nil,
                                        maxReadingHead: limits.maxConnectionsReadingHead, peers: .loopbackOnly)
        case .interface(_, _, let subnet):
            admission = AdmissionPolicy(maxConnections: limits.maxConnections, maxPerPeer: limits.maxConnectionsPerPeer,
                                        maxReadingHead: limits.maxConnectionsReadingHead, peers: .onLink(subnet))
        }
        let listener = NWHTTPTransport(binding: network.listensOnLoopback ? .loopbackIPv4 : binding, port: port,
                                       admission: admission)
        listener.restrictPeers(to: transportPeerRestriction)
        let bound: UInt16
        do {
            bound = try await listener.start()
        } catch HTTPTransportError.portInUse(let taken) {
            throw ServerFailure.portInUse(taken)
        } catch {
            throw ServerFailure.listener(String(describing: error))
        }
        transport = listener
        closingReason = nil
        boundPort = bound
        boundHost = binding.host
        if case .interface(_, _, let subnet) = binding { boundSubnet = subnet } else { boundSubnet = nil }
        acceptLoop = Task { [weak self] in
            for await connection in listener.connections {
                self?.spawn(connection)
            }
        }
        let endpoint = ServerEndpoint(host: binding.host, port: bound, exposure: configuration.exposure)
        setState(.listening(endpoint))
        watchInterface()
        log.record("listening on port \(bound)")
        return endpoint
    }

    private func spawn(_ connection: any HTTPConnection) {
        guard closingReason == nil else { return connection.close() }
        let id = UUID()
        exchanges[id] = Task { [weak self] in
            await self?.serve(connection)
            self?.exchanges[id] = nil
        }
    }

    private func shutDown(reason: APIError) async {
        closingReason = reason
        stopWatchingInterface()
        generations.values.forEach { $0.interrupt(reason) }
        await drainExchanges(within: .seconds(1))
        let listener = transport
        transport = nil
        acceptLoop?.cancel()
        acceptLoop = nil
        await listener?.stop()
        exchanges.values.forEach { $0.cancel() }
    }

    private func drainExchanges(within limit: Duration) async {
        let pending = Array(exchanges.values)
        guard !pending.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for task in pending { await task.value }
            }
            group.addTask { try? await Task.sleep(for: limit) }
            await group.next()
            group.cancelAll()
        }
    }

    private func watchLifecycle() {
        guard lifecycleWatch == nil else { return }
        lifecycle.startObserving()
        lifecycleWatch = lifecycle.$isPaused.removeDuplicates().dropFirst().sink { [weak self] paused in
            MainActor.assumeIsolated { self?.lifecycleChanged(paused: paused) }
        }
    }

    /// Queued with the public transitions, so a quick background-foreground pair cannot rebind before the close.
    private func lifecycleChanged(paused: Bool) {
        enqueue { [weak self] in
            guard let self else { return }
            if paused {
                await self.suspendNow(.appBackgrounded)
            } else if case .suspended(.appBackgrounded) = self.state {
                try? await self.resumeNow()
            }
        }
    }

    /// Runs start, stop, suspend and resume one at a time, in call order: each awaits the listener, so two of them
    /// interleaving could leave the server listening after a stop or rebinding a port still held.
    @discardableResult
    private func enqueue<T: Sendable>(_ operation: @escaping @MainActor () async throws -> T) -> Task<T, Error> {
        let previous = transitions
        let task = Task { @MainActor in
            await previous?.value
            return try await operation()
        }
        transitions = Task { _ = try? await task.value }
        return task
    }

    var isSuspended: Bool {
        if case .suspended = state { return true }
        return false
    }

    // MARK: - Models

    /// Replaces the served models. A running request on a removed id ends with `model_changed`.
    public func setModels(_ models: [ServedModel]) {
        self.models = models
        servedModels = models.map(\.info)
        let kept = Set(models.map(\.info.id))
        generations.values.filter { !kept.contains($0.modelID) }.forEach { $0.interrupt(.modelChanged) }
    }

    /// The turnstile a served model shares with the app, so the app's own chat waits its turn too.
    public func turnstile(for modelID: String) -> GenerationTurnstile? {
        models.first { $0.info.id == modelID }?.base.turnstile
    }

    // MARK: - Keys

    /// Issues an API key; its secret is only in the returned value. Default lifetime 7 days. Throws, and issues
    /// nothing, when the store cannot save it or still cannot be read (``credentialLoadFailure``); expired keys are
    /// removed from the store in the same save.
    public func issueAPIKey(label: String, scopes: ClientScopes = [.chat, .models],
                            lifetime: Duration? = .seconds(7 * 86_400)) throws -> IssuedAPIKey {
        try reloadKeysIfUnread()
        let token = SecretToken.random(bits: 256, prefix: Self.keyPrefix)
        let now = clock.wall()
        let stored = StoredAPIKey(id: UUID(), label: SafeLabel.make(label), scopes: scopes,
                                  keyHash: Data(token.storedHash), createdAt: now,
                                  expiresAt: lifetime.map { now.addingTimeInterval($0.seconds) })
        // Expired keys are dropped here, the only place the list grows, so the store does not keep them forever.
        let live = keys.filter { $0.expiresAt.map { $0 > now } ?? true }
        try credentials.save(live + [stored])
        keys = live + [stored]
        clients = keys.map(\.info)
        emit(.keyIssued(stored.id))
        log.record("key issued \(stored.id.uuidString)")
        return IssuedAPIKey(client: stored.info, secret: token.text)
    }

    /// Revokes an API key or ends a paired browser's session.
    public func revoke(_ id: ClientInfo.ID) {
        if pairedTokens.contains(where: { $0.id == id }) { return endBrowserSession(id) }
        // Still unreadable: `keys` is empty, so nothing below saves over the stored list.
        try? reloadKeysIfUnread()
        let remaining = keys.filter { $0.id != id }
        guard remaining.count != keys.count else { return }
        keys = remaining
        do {
            try credentials.save(remaining)
        } catch {
            log.record("credential store could not be written")
        }
        clients = keys.map(\.info)
        emit(.keyRevoked(id))
        log.record("key revoked \(id.uuidString)")
    }

    /// A save from a list this server never read would replace the stored keys with it.
    private func reloadKeysIfUnread() throws {
        guard credentialLoadFailure != nil else { return }
        do {
            keys = try credentials.loadKeys()
        } catch {
            credentialLoadFailure = error
            throw error
        }
        credentialLoadFailure = nil
        clients = keys.map(\.info)
    }

    static let keyPrefix = "tnx_"

    // MARK: - Observation for non-SwiftUI hosts

    /// A new stream per call, starting with the current state.
    public func states() -> AsyncStream<ServerState> {
        let (stream, continuation) = AsyncStream.makeStream(of: ServerState.self)
        let id = UUID()
        stateSubscribers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.stateSubscribers[id] = nil }
        }
        return stream
    }

    /// A new stream per call.
    public func events() -> AsyncStream<ServerEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: ServerEvent.self)
        let id = UUID()
        eventSubscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.eventSubscribers[id] = nil }
        }
        return stream
    }

    func setState(_ newState: ServerState) {
        guard newState != state else { return }
        state = newState
        stateSubscribers.values.forEach { $0.yield(newState) }
        emit(.stateChanged(newState))
    }

    func emit(_ event: ServerEvent) {
        eventSubscribers.values.forEach { $0.yield(event) }
    }

    func record(route: String, status: Int, client: String?, modelID: String?) {
        activity.append(ServerActivity(id: UUID(), answeredAt: clock.wall(), route: route, status: status,
                                       clientLabel: client, modelID: modelID))
        if activity.count > Self.activityLimit { activity.removeFirst(activity.count - Self.activityLimit) }
    }

    var boundPortForHost: UInt16? { boundPort }
}

/// One running served request: cancelled by a client disconnect, suspension, `stop()` or a model change.
@MainActor
final class GenerationControl {
    let modelID: String
    private(set) var interruption: APIError?
    private(set) var peerGone = false
    private var consumer: Task<Void, Error>?
    private var settled: (@Sendable () async -> Void)?

    init(modelID: String) {
        self.modelID = modelID
    }

    func track(_ response: ServedResponse) -> AsyncThrowingStream<ServedChatEvent, Error> {
        settled = response.settled
        return response.events
    }

    /// Waits until the model stopped working on this request (also after a cancellation).
    func settle() async {
        await settled?()
    }

    func run(_ body: @escaping @MainActor () async throws -> Void) async throws {
        let task = Task { @MainActor in try await body() }
        consumer = task
        if interruption != nil || peerGone { task.cancel() }
        try await task.value
    }

    func interrupt(_ error: APIError) {
        if interruption == nil { interruption = error }
        consumer?.cancel()
    }

    func peerClosed() {
        peerGone = true
        consumer?.cancel()
    }
}
