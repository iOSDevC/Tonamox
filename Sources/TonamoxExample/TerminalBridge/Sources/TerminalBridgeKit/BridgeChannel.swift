import Foundation
import Network
import Synchronization

public enum BridgeChannelError: Error, Equatable, Sendable {
    case closed
    case connectionFailed(String)
    case frame(FrameError)
    case authentication(FrameAuthenticationError)
    case notAuthenticated
    case alreadyAuthenticated
    case malformedMessage
}

/// Releases a listener's unauthenticated-connection slot exactly once.
public final class AdmissionTicket: Sendable {
    private let released = Mutex(false)
    private let onRelease: @Sendable () -> Void

    public init(onRelease: @escaping @Sendable () -> Void) {
        self.onRelease = onRelease
    }

    public func release() {
        let isFirst = released.withLock { released in
            defer { released = true }
            return !released
        }
        if isFirst { onRelease() }
    }
}

/// Framed, then HMAC-authenticated, messages over one NWConnection (loopback TCP or a usbmux
/// tunnel). One reader at a time: call `receiveFrame()`/`receive()` from a single task.
public actor BridgeChannel {
    public nonisolated let connection: NWConnection
    private let queue = DispatchQueue(label: "TerminalBridgeKit.BridgeChannel")
    private let closedFlag = Mutex(false)
    private let admission: AdmissionTicket?
    private var reader: FrameReader
    private var authenticator: FrameAuthenticator?
    private var hasStarted = false

    /// `bufferedBytes` are stream bytes already read by whoever set the connection up.
    public init(connection: NWConnection, bufferedBytes: Data = Data(), admission: AdmissionTicket? = nil) {
        self.connection = connection
        self.admission = admission
        self.reader = FrameReader(bufferedBytes: bufferedBytes)
    }

    /// A TCP client to 127.0.0.1:`port`, used by the helper in simulator mode.
    public static func loopbackClient(port: UInt16) -> BridgeChannel {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        return BridgeChannel(connection: NWConnection(to: endpoint, using: parameters))
    }

    public nonisolated var isClosed: Bool {
        closedFlag.withLock { $0 }
    }

    public nonisolated var remoteEndpoint: NWEndpoint {
        connection.endpoint
    }

    public var isAuthenticated: Bool {
        authenticator != nil
    }

    /// Waits until the connection is ready. A `.waiting` state (for example connection refused)
    /// counts as a failure so callers can back off and retry with a new channel.
    public func start() async throws {
        guard !isClosed else { throw BridgeChannelError.closed }
        guard !hasStarted else { return }
        hasStarted = true
        let ready = OneShot<Void>()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.finish(.success(()))
            case .waiting(let error), .failed(let error):
                ready.finish(.failure(BridgeChannelError.connectionFailed(error.debugDescription)))
            case .cancelled:
                ready.finish(.failure(BridgeChannelError.closed))
            default:
                break
            }
        }
        switch connection.state {
        case .setup:
            connection.start(queue: queue)
        case .ready:
            ready.finish(.success(()))
        default:
            break
        }
        do {
            try await ready.value()
        } catch {
            close()
            throw error
        }
    }

    /// Cancels the connection. Safe to call from anywhere, any number of times.
    public nonisolated func close() {
        let isFirst = closedFlag.withLock { closed in
            defer { closed = true }
            return !closed
        }
        guard isFirst else { return }
        connection.cancel()
        admission?.release()
    }

    // MARK: Handshake phase (raw JSON bodies)

    public func sendFrame(_ payload: Data) async throws {
        guard authenticator == nil else { throw BridgeChannelError.alreadyAuthenticated }
        try await transmit(payload)
    }

    public func receiveFrame() async throws -> Data {
        guard authenticator == nil else { throw BridgeChannelError.alreadyAuthenticated }
        return try await nextFrame()
    }

    /// Switches to the authenticated phase and frees the listener's unauthenticated slot.
    public func enableAuthentication(_ frameAuthenticator: FrameAuthenticator) throws {
        guard authenticator == nil else { throw BridgeChannelError.alreadyAuthenticated }
        authenticator = frameAuthenticator
        admission?.release()
    }

    // MARK: Authenticated phase

    public func send(_ message: BridgeMessage) async throws {
        guard var sealer = authenticator else { throw BridgeChannelError.notAuthenticated }
        let body: Data
        do {
            body = try BridgeMessageCoder.encode(message)
        } catch {
            throw BridgeChannelError.malformedMessage
        }
        let sealed: Data
        do {
            sealed = try sealer.seal(body)
        } catch {
            close()
            throw BridgeChannelError.authentication(error)
        }
        authenticator = sealer
        // Sealing and enqueueing happen without a suspension in between, so frames leave in counter order.
        try await transmit(sealed)
    }

    public func receive() async throws -> BridgeMessage {
        guard authenticator != nil else { throw BridgeChannelError.notAuthenticated }
        let frame = try await nextFrame()
        guard var opener = authenticator else { throw BridgeChannelError.notAuthenticated }
        let body: Data
        do {
            body = try opener.open(frame)
        } catch {
            authenticator = opener
            close()
            throw BridgeChannelError.authentication(error)
        }
        authenticator = opener
        do {
            return try BridgeMessageCoder.decode(body)
        } catch {
            close()
            throw BridgeChannelError.malformedMessage
        }
    }

    // MARK: I/O

    private func transmit(_ payload: Data) async throws {
        guard !isClosed else { throw BridgeChannelError.closed }
        let framed: Data
        do {
            framed = try FrameCodec.encode(payload)
        } catch {
            throw BridgeChannelError.frame(error)
        }
        let completion = OneShot<Void>()
        connection.send(content: framed, completion: .contentProcessed { error in
            if let error {
                completion.finish(.failure(BridgeChannelError.connectionFailed(error.debugDescription)))
            } else {
                completion.finish(.success(()))
            }
        })
        try await completion.value()
    }

    private func nextFrame() async throws -> Data {
        while true {
            if let frame = try bufferedFrame() { return frame }
            guard !isClosed else { throw BridgeChannelError.closed }
            reader.append(try await receiveChunk())
        }
    }

    private func bufferedFrame() throws -> Data? {
        do {
            return try reader.nextFrame()
        } catch {
            close()
            throw BridgeChannelError.frame(error)
        }
    }

    private func receiveChunk() async throws -> Data {
        let chunk = OneShot<Data>()
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
            if let content, !content.isEmpty {
                chunk.finish(.success(content))
            } else if let error {
                chunk.finish(.failure(BridgeChannelError.connectionFailed(error.debugDescription)))
            } else if isComplete {
                chunk.finish(.failure(BridgeChannelError.closed))
            } else {
                chunk.finish(.success(Data()))
            }
        }
        do {
            return try await chunk.value()
        } catch {
            close()
            throw error
        }
    }
}
