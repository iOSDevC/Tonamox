import Foundation

public enum PhoneConnectionState: Equatable, Sendable {
    case stopped
    case listening(port: UInt16)
    case connected(helperName: String, port: UInt16)
    case failed(LoopbackListenerError)
}

public enum PhoneDisconnectReason: Equatable, Sendable {
    case closedByPeer
    case heartbeatTimeout
    /// A newer authenticated helper connection took over.
    case replaced
    case stopped
    case protocolError(String)
}

public enum PhoneBridgeEvent: Equatable, Sendable {
    case stateChanged(PhoneConnectionState)
    case status(StatusMessage)
    /// A peer failed to prove the secret; `total` counts since the session was created.
    case rejectedAttempt(total: Int)
    case disconnected(PhoneDisconnectReason)
}

public enum PhoneWriteError: Error, Equatable, Sendable {
    case notConnected
    case policy([CommandTextViolation])
    case unacknowledgedWarnings([RiskyRule])
    /// The helper answered with an `error` for this write.
    case rejected(ErrorReport)
    case disconnected
    case timedOut
    case alreadyInFlight
}

/// Phone side of the bridge: listens on 127.0.0.1, authenticates helpers (one active at a
/// time, the newest wins), answers pings, tracks status and turns writes into acks.
public actor PhoneBridgeSession {
    public nonisolated let events: AsyncStream<PhoneBridgeEvent>
    public private(set) var state: PhoneConnectionState = .stopped
    public private(set) var latestStatus: StatusMessage?
    public private(set) var rejectedAttempts = 0
    public private(set) var helperName: String?

    private struct ActiveLink {
        let channel: BridgeChannel
        let generation: Int
        var tasks: [Task<Void, Never>] = []
    }

    private let eventSink: AsyncStream<PhoneBridgeEvent>.Continuation
    private let secret: Data
    private let phoneID: UUID
    private let phoneName: String
    private let requestedPort: UInt16
    private let maxUnauthenticated: Int
    private let clock: any BridgeClock
    private let heartbeatTimeout: Duration
    private let writeTimeout: Duration

    private var listener: LoopbackListener?
    private var isStarting = false
    /// Bumped by every stop(), so a start() suspended in the bind can tell it was cancelled.
    private var lifecycleEpoch = 0
    private var afterBindForTesting: (@Sendable () async -> Void)?
    private var boundPort: UInt16 = 0
    private var acceptTask: Task<Void, Never>?
    private var pendingHandshakes: [ObjectIdentifier: BridgeChannel] = [:]
    private var link: ActiveLink?
    private var generation = 0
    private var lastTraffic: Duration = .zero
    private var pendingWrites: [UUID: OneShot<WriteAck>] = [:]

    public init(
        secret: Data,
        phoneID: UUID,
        phoneName: String = BridgeConstants.defaultPhoneName,
        port: UInt16 = BridgeConstants.defaultPort,
        maxUnauthenticated: Int = BridgeConstants.maxUnauthenticatedConnections,
        clock: any BridgeClock = SystemBridgeClock(),
        heartbeatTimeout: Duration = BridgeConstants.heartbeatTimeout,
        writeTimeout: Duration = BridgeConstants.writeTimeout
    ) {
        self.secret = secret
        self.phoneID = phoneID
        self.phoneName = phoneName
        self.requestedPort = port
        self.maxUnauthenticated = maxUnauthenticated
        self.clock = clock
        self.heartbeatTimeout = heartbeatTimeout
        self.writeTimeout = writeTimeout
        (events, eventSink) = AsyncStream.makeStream(of: PhoneBridgeEvent.self)
    }

    /// Starts listening; returns the bound port. Calling it while running returns the same port.
    /// Every failed start emits `.stateChanged(.failed)`, even when it repeats the previous failure.
    @discardableResult
    public func start() async throws -> UInt16 {
        guard listener == nil, !isStarting else { return boundPort }
        isStarting = true
        defer { isStarting = false }
        let epoch = lifecycleEpoch
        let newListener = LoopbackListener(port: requestedPort, maxUnauthenticated: maxUnauthenticated)
        let port: UInt16
        do {
            port = try await newListener.start()
        } catch {
            guard epoch == lifecycleEpoch else { throw LoopbackListenerError.stopped }
            let failure = error as? LoopbackListenerError ?? .failed(String(describing: error))
            state = .failed(failure)
            emit(.stateChanged(state))
            throw failure
        }
        await afterBindForTesting?()
        guard epoch == lifecycleEpoch else {
            newListener.stop()
            throw LoopbackListenerError.stopped
        }
        boundPort = port
        listener = newListener
        setState(.listening(port: boundPort))
        acceptTask = Task { [weak self] in
            for await channel in newListener.connections {
                await self?.admit(channel)
            }
            await self?.listenerFinished(newListener)
        }
        return boundPort
    }

    /// Cancels the listener and every connection, so the helper sees the reset at once.
    public func stop() {
        lifecycleEpoch += 1
        listener?.stop()
        listener = nil
        acceptTask?.cancel()
        acceptTask = nil
        for channel in pendingHandshakes.values {
            channel.close()
        }
        pendingHandshakes.removeAll()
        if let link { endLink(link, reason: .stopped) }
        setState(.stopped)
    }

    /// Sends one line. Retry a failed write with the same `id`: the helper answers
    /// `alreadyTyped` instead of typing it twice.
    public func write(text: String, id: UUID, acknowledgedWarnings: [String] = []) async throws -> WriteAck {
        let violations = CommandTextPolicy.validate(text)
        guard violations.isEmpty else { throw PhoneWriteError.policy(violations) }
        let missing = RiskyCommandRules.unacknowledged(in: text, acknowledged: acknowledgedWarnings)
        guard missing.isEmpty else { throw PhoneWriteError.unacknowledgedWarnings(missing) }
        guard let active = link else { throw PhoneWriteError.notConnected }
        guard pendingWrites[id] == nil else { throw PhoneWriteError.alreadyInFlight }
        let waiter = OneShot<WriteAck>()
        pendingWrites[id] = waiter
        let timeout = Task { [clock, writeTimeout] in
            do {
                try await clock.sleep(for: writeTimeout)
            } catch {
                return
            }
            waiter.finish(.failure(PhoneWriteError.timedOut))
        }
        defer {
            timeout.cancel()
            if pendingWrites[id] === waiter { pendingWrites[id] = nil }
        }
        let request = WriteRequest(id: id, text: text, acknowledgedWarnings: acknowledgedWarnings)
        do {
            try await active.channel.send(.write(request))
        } catch {
            throw PhoneWriteError.disconnected
        }
        return try await waiter.value()
    }

    /// Runs between a successful bind and the listener install, where a concurrent stop() can land.
    func setAfterBindHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        afterBindForTesting = hook
    }

    // MARK: Connections

    private func admit(_ channel: BridgeChannel) {
        pendingHandshakes[ObjectIdentifier(channel)] = channel
        Task { await self.handshake(channel) }
    }

    private func listenerFinished(_ finished: LoopbackListener) {
        guard listener === finished else { return }
        listener = nil
        setState(.failed(finished.failure ?? .stopped))
    }

    private func handshake(_ channel: BridgeChannel) async {
        defer { pendingHandshakes[ObjectIdentifier(channel)] = nil }
        let watchdog = Task { [clock] in
            try await clock.sleep(for: BridgeConstants.handshakeTimeout)
            channel.close()
        }
        defer { watchdog.cancel() }
        var handshake = PhoneHandshake(secret: secret, phoneID: phoneID, phoneName: phoneName)
        do {
            try await channel.start()
            let challenge = try handshake.handleHello(try await channel.receiveFrame())
            try await channel.sendFrame(challenge)
            let completion = try handshake.handleAuth(try await channel.receiveFrame())
            try await channel.sendFrame(completion.reply)
            try await channel.enableAuthentication(.phoneSide(completion.keys))
        } catch let error as HandshakeError {
            await reject(channel, error: error)
            return
        } catch {
            channel.close()
            return
        }
        guard listener != nil else {
            channel.close()
            return
        }
        activate(channel, helperName: handshake.helperName ?? "Mac")
    }

    private func reject(_ channel: BridgeChannel, error: HandshakeError) async {
        if error == .authFailed {
            rejectedAttempts += 1
            emit(.rejectedAttempt(total: rejectedAttempts))
        }
        if let reply = PhoneHandshake.rejectionPayload(for: error) {
            try? await channel.sendFrame(reply)
        }
        channel.close()
    }

    private func activate(_ channel: BridgeChannel, helperName name: String) {
        if let previous = link { endLink(previous, reason: .replaced) }
        generation += 1
        let current = generation
        lastTraffic = clock.now()
        helperName = name
        link = ActiveLink(channel: channel, generation: current)
        setState(.connected(helperName: name, port: boundPort))
        let receiver = Task { await self.receiveLoop(channel, generation: current) }
        let watchdog = Task { await self.watchHeartbeat(generation: current) }
        link?.tasks = [receiver, watchdog]
    }

    private func endLink(_ ending: ActiveLink, reason: PhoneDisconnectReason) {
        guard link?.generation == ending.generation else { return }
        link = nil
        latestStatus = nil
        ending.channel.close()
        for task in ending.tasks {
            task.cancel()
        }
        failPendingWrites()
        emit(.disconnected(reason))
        guard reason != .replaced else { return }
        setState(listener == nil ? .stopped : .listening(port: boundPort))
    }

    private func failPendingWrites() {
        let failure: Result<WriteAck, any Error> = .failure(PhoneWriteError.disconnected)
        let waiters = pendingWrites.values
        pendingWrites.removeAll()
        for waiter in waiters {
            waiter.finish(failure)
        }
    }

    private func receiveLoop(_ channel: BridgeChannel, generation current: Int) async {
        while true {
            let message: BridgeMessage
            do {
                message = try await channel.receive()
            } catch {
                connectionEnded(generation: current, error: error)
                return
            }
            guard link?.generation == current else { return }
            lastTraffic = clock.now()
            await handle(message, on: channel)
        }
    }

    private func connectionEnded(generation current: Int, error: any Error) {
        guard let active = link, active.generation == current else { return }
        endLink(active, reason: Self.disconnectReason(for: error))
    }

    static func disconnectReason(for error: any Error) -> PhoneDisconnectReason {
        switch error as? BridgeChannelError {
        case .closed?, .connectionFailed?: .closedByPeer
        default: .protocolError(String(describing: error))
        }
    }

    private func watchHeartbeat(generation current: Int) async {
        while let active = link, active.generation == current {
            let remaining = heartbeatTimeout - (clock.now() - lastTraffic)
            guard remaining > .zero else {
                endLink(active, reason: .heartbeatTimeout)
                return
            }
            do {
                try await clock.sleep(for: remaining)
            } catch {
                return
            }
        }
    }

    private func handle(_ message: BridgeMessage, on channel: BridgeChannel) async {
        switch message {
        case .status(let status):
            latestStatus = status
            emit(.status(status))
        case .ack(let ack):
            pendingWrites.removeValue(forKey: ack.id)?.finish(.success(ack))
        case .error(let report):
            if let id = report.id, let waiter = pendingWrites.removeValue(forKey: id) {
                waiter.finish(.failure(PhoneWriteError.rejected(report)))
            }
        case .ping(let number):
            try? await channel.send(.pong(number))
        case .pong:
            break
        case .unrecognized(let type):
            try? await channel.send(.error(ErrorReport(code: .unsupportedMessage, detail: type)))
        case .hello, .challenge, .auth, .authOK, .write:
            try? await channel.send(.error(ErrorReport(code: .unsupportedMessage, detail: message.typeName)))
        }
    }

    private func setState(_ newState: PhoneConnectionState) {
        guard state != newState else { return }
        state = newState
        emit(.stateChanged(newState))
    }

    private func emit(_ event: PhoneBridgeEvent) {
        eventSink.yield(event)
    }
}
