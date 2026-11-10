import Foundation

/// What the helper types into. The macOS implementation drives GNU screen; tests use a fake.
public protocol TerminalTextInjector: Sendable {
    /// Current target state, polled for `status` frames.
    func currentTarget() async -> TargetStatus
    /// Types already-validated `text` without Enter. Implementations re-check the target
    /// (session, single window, idle prompt, foreground shell) right before typing.
    func type(_ text: String) async -> InjectionOutcome
}

public enum InjectionOutcome: Equatable, Sendable {
    case typed(verified: Bool)
    case refused(BridgeErrorCode, detail: String)
}

/// One write attempt, handed to the journal. `text` is only there so the journal can key-hash
/// it; it must never be stored or logged as is.
public struct WriteRecord: Sendable {
    public enum Disposition: Equatable, Sendable {
        case typed
        case alreadyTyped
        case refused(BridgeErrorCode)
    }

    public let id: UUID
    public let text: String
    public let bytes: Int
    public let outcome: Disposition
    public let warnings: [String]
    public let verified: Bool

    public init(id: UUID, text: String, bytes: Int, outcome: Disposition, warnings: [String], verified: Bool) {
        self.id = id
        self.text = text
        self.bytes = bytes
        self.outcome = outcome
        self.warnings = warnings
        self.verified = verified
    }
}

public protocol WriteRecorder: Sendable {
    func record(_ write: WriteRecord) async
}

public struct HelperSessionConfiguration: Sendable {
    public var handshakeTimeout: Duration
    public var statusPollInterval: Duration
    public var heartbeatInterval: Duration
    public var heartbeatTimeout: Duration
    public var minimumWriteInterval: Duration

    public init(
        handshakeTimeout: Duration = BridgeConstants.handshakeTimeout,
        statusPollInterval: Duration = BridgeConstants.statusPollInterval,
        heartbeatInterval: Duration = BridgeConstants.heartbeatInterval,
        heartbeatTimeout: Duration = BridgeConstants.heartbeatTimeout,
        minimumWriteInterval: Duration = BridgeConstants.minimumWriteInterval
    ) {
        self.handshakeTimeout = handshakeTimeout
        self.statusPollInterval = statusPollInterval
        self.heartbeatInterval = heartbeatInterval
        self.heartbeatTimeout = heartbeatTimeout
        self.minimumWriteInterval = minimumWriteInterval
    }
}

public enum HelperSessionEnd: Equatable, Sendable {
    case closedByPeer
    case heartbeatTimeout
    /// The phone sent an unauthenticated `error` (authFailed, unsupportedProtocol). Anyone on
    /// loopback can forge it, so callers log, back off and retry; they never exit or unpair.
    case rejectedByPhone(BridgeErrorCode)
    /// The peer could not prove the secret: nothing was typed for it.
    case phoneProofInvalid
    case handshakeFailed(String)
    case protocolError(String)
}

/// Helper side of a connection; the helper proves first. Reuse one instance across reconnections
/// so the rate limit spans them.
public actor HelperBridgeSession {
    public private(set) var phoneName: String?
    public private(set) var phoneID: UUID?

    private let secret: Data
    private let helperID: UUID
    private let helperName: String
    private let injector: any TerminalTextInjector
    private let recentWrites: RecentWriteIDs
    private let recorder: (any WriteRecorder)?
    private let clock: any BridgeClock
    private let configuration: HelperSessionConfiguration
    private let onAuthenticated: (@Sendable (_ phoneName: String, _ phoneID: UUID) -> Void)?

    private var lastTraffic: Duration = .zero
    private var lastWriteAt: Duration?
    private var lastTarget: TargetStatus?
    private var endReason: HelperSessionEnd?
    private var pingCounter = 0

    public init(
        secret: Data,
        helperID: UUID,
        helperName: String,
        injector: any TerminalTextInjector,
        recentWrites: RecentWriteIDs,
        recorder: (any WriteRecorder)? = nil,
        clock: any BridgeClock = SystemBridgeClock(),
        configuration: HelperSessionConfiguration = HelperSessionConfiguration(),
        onAuthenticated: (@Sendable (_ phoneName: String, _ phoneID: UUID) -> Void)? = nil
    ) {
        self.secret = secret
        self.helperID = helperID
        self.helperName = helperName
        self.injector = injector
        self.recentWrites = recentWrites
        self.recorder = recorder
        self.clock = clock
        self.configuration = configuration
        self.onAuthenticated = onAuthenticated
    }

    /// Serves one connection until it ends. Always closes `channel` before returning.
    public func run(on channel: BridgeChannel) async -> HelperSessionEnd {
        endReason = nil
        defer { channel.close() }
        do {
            try await channel.start()
        } catch {
            return .handshakeFailed(String(describing: error))
        }
        if let failure = await authenticate(channel) { return failure }
        lastTraffic = clock.now()
        let target = await injector.currentTarget()
        lastTarget = target
        do {
            try await channel.send(.status(.describing(target)))
        } catch {
            return .closedByPeer
        }
        return await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.pollStatus(channel) }
            group.addTask { await self.sendHeartbeats(channel) }
            let result = await self.receiveLoop(channel)
            group.cancelAll()
            return result
        }
    }

    var lastTrafficForTesting: Duration { lastTraffic }

    // MARK: Handshake

    private func authenticate(_ channel: BridgeChannel) async -> HelperSessionEnd? {
        let watchdog = Task { [clock, configuration] in
            try await clock.sleep(for: configuration.handshakeTimeout)
            channel.close()
        }
        defer { watchdog.cancel() }
        var handshake = HelperHandshake(secret: secret, helperID: helperID, helperName: helperName)
        do {
            try await channel.sendFrame(try handshake.makeHello())
            let auth = try handshake.handleChallenge(try await channel.receiveFrame())
            try await channel.sendFrame(auth)
            let keys = try handshake.handleAuthOK(try await channel.receiveFrame())
            try await channel.enableAuthentication(.helperSide(keys))
        } catch let error as HandshakeError {
            return Self.end(for: error)
        } catch {
            return .handshakeFailed(String(describing: error))
        }
        phoneName = handshake.phoneName
        phoneID = handshake.phoneID
        if let name = handshake.phoneName, let id = handshake.phoneID {
            onAuthenticated?(name, id)
        }
        return nil
    }

    static func end(for error: HandshakeError) -> HelperSessionEnd {
        switch error {
        case .rejectedByPeer(let code): .rejectedByPhone(code)
        case .authFailed: .phoneProofInvalid
        default: .handshakeFailed(String(describing: error))
        }
    }

    // MARK: Loops

    private func receiveLoop(_ channel: BridgeChannel) async -> HelperSessionEnd {
        while true {
            let message: BridgeMessage
            do {
                message = try await channel.receive()
            } catch {
                return endReason ?? Self.end(forReceiveError: error)
            }
            lastTraffic = clock.now()
            await handle(message, on: channel)
        }
    }

    static func end(forReceiveError error: any Error) -> HelperSessionEnd {
        switch error as? BridgeChannelError {
        case .closed?, .connectionFailed?: .closedByPeer
        default: .protocolError(String(describing: error))
        }
    }

    private func pollStatus(_ channel: BridgeChannel) async {
        while !Task.isCancelled {
            do {
                try await clock.sleep(for: configuration.statusPollInterval)
            } catch {
                return
            }
            await refreshStatus(channel)
        }
    }

    private func refreshStatus(_ channel: BridgeChannel) async {
        let target = await injector.currentTarget()
        guard target != lastTarget else { return }
        lastTarget = target
        try? await channel.send(.status(.describing(target)))
    }

    private func sendHeartbeats(_ channel: BridgeChannel) async {
        while !Task.isCancelled {
            do {
                try await clock.sleep(for: configuration.heartbeatInterval)
            } catch {
                return
            }
            guard clock.now() - lastTraffic < configuration.heartbeatTimeout else {
                endReason = .heartbeatTimeout
                channel.close()
                return
            }
            await sendPing(channel)
        }
    }

    private func sendPing(_ channel: BridgeChannel) async {
        pingCounter += 1
        try? await channel.send(.ping(pingCounter))
    }

    // MARK: Messages

    private func handle(_ message: BridgeMessage, on channel: BridgeChannel) async {
        switch message {
        case .write(let request):
            let reply = await process(request)
            try? await channel.send(reply)
        case .ping(let number):
            try? await channel.send(.pong(number))
        case .pong, .error, .ack, .status:
            break
        case .unrecognized(let type):
            try? await channel.send(.error(ErrorReport(code: .unsupportedMessage, detail: type)))
        case .hello, .challenge, .auth, .authOK:
            try? await channel.send(.error(ErrorReport(code: .unsupportedMessage, detail: message.typeName)))
        }
    }

    /// Steps a–k of the design, minus `seq` (the frame counter already orders writes).
    func process(_ request: WriteRequest) async -> BridgeMessage {
        let now = clock.now()
        if let lastWriteAt, now - lastWriteAt < configuration.minimumWriteInterval {
            return refusal(request, code: .rateLimited, detail: "Demasiado rápido: espera un momento.")
        }
        lastWriteAt = now
        guard case .text = request.intent else {
            return refusal(request, code: .unsupportedIntent, detail: request.intent.kind)
        }
        guard let text = request.text else {
            return refusal(request, code: .policy, detail: CommandTextViolation.empty.message)
        }
        let warnings = RiskyCommandRules.evaluate(text).map(\.rawValue)
        if recentWrites.contains(request.id) {
            await record(request, text: text, outcome: .alreadyTyped, warnings: warnings, verified: false)
            let ack = acknowledgement(
                request.id, text: text, result: .alreadyTyped, warnings: warnings, verified: false
            )
            return .ack(ack)
        }
        let violations = CommandTextPolicy.validate(text)
        guard violations.isEmpty, CommandTextPolicy.isValid(bytes: Array(text.utf8)) else {
            let detail = violations.map(\.message).joined(separator: " ")
            await record(request, text: text, outcome: .refused(.policy), warnings: warnings, verified: false)
            return refusal(request, code: .policy, detail: detail)
        }
        let missing = RiskyCommandRules.unacknowledged(in: text, acknowledged: request.acknowledgedWarnings)
        guard missing.isEmpty else {
            let outcome = WriteRecord.Disposition.refused(.unacknowledgedWarnings)
            await record(request, text: text, outcome: outcome, warnings: warnings, verified: false)
            return .error(ErrorReport(
                id: request.id,
                code: .unacknowledgedWarnings,
                detail: missing.map(\.title).joined(separator: ", "),
                warnings: missing.map(\.rawValue)
            ))
        }
        switch await injector.type(text) {
        case .typed(let verified):
            recentWrites.insert(request.id)
            await record(request, text: text, outcome: .typed, warnings: warnings, verified: verified)
            let ack = acknowledgement(request.id, text: text, result: .typed, warnings: warnings, verified: verified)
            return .ack(ack)
        case .refused(let code, let detail):
            await record(request, text: text, outcome: .refused(code), warnings: warnings, verified: false)
            return refusal(request, code: code, detail: detail)
        }
    }

    private func refusal(_ request: WriteRequest, code: BridgeErrorCode, detail: String) -> BridgeMessage {
        .error(ErrorReport(id: request.id, code: code, detail: detail))
    }

    private func acknowledgement(
        _ id: UUID,
        text: String,
        result: AckResult,
        warnings: [String],
        verified: Bool
    ) -> WriteAck {
        WriteAck(
            id: id,
            result: result,
            bytes: text.utf8.count,
            textSHA256: BridgeDigest.sha256Hex(text),
            warnings: warnings,
            verified: verified
        )
    }

    private func record(
        _ request: WriteRequest,
        text: String,
        outcome: WriteRecord.Disposition,
        warnings: [String],
        verified: Bool
    ) async {
        guard let recorder else { return }
        await recorder.record(WriteRecord(
            id: request.id,
            text: text,
            bytes: text.utf8.count,
            outcome: outcome,
            warnings: warnings,
            verified: verified
        ))
    }
}
