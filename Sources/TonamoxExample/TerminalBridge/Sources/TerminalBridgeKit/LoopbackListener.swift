import Foundation
import Network
import Synchronization

public enum LoopbackListenerError: Error, Equatable, Sendable {
    case portInUse(UInt16)
    case failed(String)
    case alreadyStarted
    case stopped
}

/// 127.0.0.1 only and single use: after `stop()` create a new one. Non-loopback peers and
/// connections beyond the unauthenticated cap are cancelled on arrival.
public final class LoopbackListener: Sendable {
    public let requestedPort: UInt16
    public let maxUnauthenticated: Int
    /// Accepted connections, not started yet. Finishes when the listener stops or fails.
    public let connections: AsyncStream<BridgeChannel>

    private struct Bookkeeping {
        var listener: NWListener?
        var unauthenticated = 0
        var refused = 0
        var failure: LoopbackListenerError?
        var hasStarted = false
    }

    private let channelSink: AsyncStream<BridgeChannel>.Continuation
    private let state = Mutex(Bookkeeping())
    private let queue = DispatchQueue(label: "TerminalBridgeKit.LoopbackListener")

    public init(
        port: UInt16 = BridgeConstants.defaultPort,
        maxUnauthenticated: Int = BridgeConstants.maxUnauthenticatedConnections
    ) {
        requestedPort = port
        self.maxUnauthenticated = maxUnauthenticated
        (connections, channelSink) = AsyncStream.makeStream(of: BridgeChannel.self)
    }

    /// Connections waiting for the handshake right now.
    public var unauthenticatedCount: Int { state.withLock { $0.unauthenticated } }
    /// Connections cancelled for being over the cap or not loopback.
    public var refusedCount: Int { state.withLock { $0.refused } }
    /// Why the listener stopped, if it failed after starting.
    public var failure: LoopbackListenerError? { state.withLock { $0.failure } }

    /// Binds and starts listening; returns the bound port (useful with port 0).
    public func start() async throws -> UInt16 {
        let listener: NWListener
        do {
            listener = try NWListener(using: Self.makeParameters(port: requestedPort))
        } catch {
            throw LoopbackListenerError.failed(String(describing: error))
        }
        let isFirstStart = state.withLock { state in
            defer { state.hasStarted = true }
            guard !state.hasStarted else { return false }
            state.listener = listener
            return true
        }
        guard isFirstStart else {
            listener.cancel()
            throw LoopbackListenerError.alreadyStarted
        }
        let ready = OneShot<UInt16>()
        let requestedPort = requestedPort
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] newState in
            switch newState {
            case .ready:
                ready.finish(.success(listener?.port?.rawValue ?? requestedPort))
            case .waiting(let error), .failed(let error):
                let mapped = Self.map(error, port: requestedPort)
                ready.finish(.failure(mapped))
                self?.terminate(with: mapped)
            case .cancelled:
                ready.finish(.failure(LoopbackListenerError.stopped))
                self?.terminate(with: nil)
            default:
                break
            }
        }
        listener.start(queue: queue)
        return try await ready.value()
    }

    /// Cancels the listener. Accepted channels are owned by their consumers and stay open.
    public func stop() {
        let listener = state.withLock { $0.listener }
        listener?.cancel()
        channelSink.finish()
    }

    static func makeParameters(port: UInt16) -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port) ?? .any
        )
        // false: SO_REUSEPORT-style sharing would let another local process bind the same port.
        parameters.allowLocalEndpointReuse = false
        parameters.includePeerToPeer = false
        // true made the simulator drop the Mac helper's 127.0.0.1 connection ("Ignoring non-local connection");
        // the 127.0.0.1 bind and accept()'s isLoopback check are what keep peers local.
        parameters.acceptLocalOnly = false
        return parameters
    }

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback
        default: return false
        }
    }

    static func map(_ error: NWError, port: UInt16) -> LoopbackListenerError {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return .portInUse(port)
        }
        return .failed(error.debugDescription)
    }

    private func terminate(with error: LoopbackListenerError?) {
        state.withLock { state in
            if state.failure == nil { state.failure = error }
            state.listener = nil
        }
        channelSink.finish()
    }

    /// Internal so tests can hand it connections with arbitrary remote endpoints.
    func accept(_ connection: NWConnection) {
        guard Self.isLoopback(connection.endpoint) else {
            state.withLock { $0.refused += 1 }
            connection.cancel()
            return
        }
        let isAdmitted = state.withLock { state in
            guard state.unauthenticated < maxUnauthenticated else {
                state.refused += 1
                return false
            }
            state.unauthenticated += 1
            return true
        }
        guard isAdmitted else {
            connection.cancel()
            return
        }
        let ticket = AdmissionTicket { [weak self] in
            self?.state.withLock { $0.unauthenticated -= 1 }
        }
        let channel = BridgeChannel(connection: connection, admission: ticket)
        if case .terminated = channelSink.yield(channel) {
            channel.close()
        }
    }
}
