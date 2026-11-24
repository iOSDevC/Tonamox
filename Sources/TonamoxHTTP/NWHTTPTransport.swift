import Foundation
import Network
import Synchronization

/// Network.framework listener bound to one IPv4 address. Single use: after `stop()` create a new one.
package final class NWHTTPTransport: HTTPTransport {
    package let binding: ListenerBinding
    package let requestedPort: UInt16
    package let admission: AdmissionPolicy
    package let limits: HTTPParseLimits
    package let connections: AsyncStream<any HTTPConnection>

    private struct Bookkeeping {
        var listener: NWListener?
        var hasStarted = false
        var isStopped = false
        var open: [ObjectIdentifier: NWHTTPConnection] = [:]
        var perPeer: [String: Int] = [:]
        var readingHead = 0
        var refused = 0
        var lockedPeers: Set<IPv4Literal>?
    }

    private let sink: AsyncStream<any HTTPConnection>.Continuation
    private let books = Mutex(Bookkeeping())
    private let released = OneShot<Void>()
    private let queue = DispatchQueue(label: "TonamoxHTTP.NWHTTPTransport")

    package init(binding: ListenerBinding, port: UInt16, admission: AdmissionPolicy,
                 limits: HTTPParseLimits = HTTPParseLimits()) {
        self.binding = binding
        self.requestedPort = port
        self.admission = admission
        self.limits = limits
        (connections, sink) = AsyncStream.makeStream(of: (any HTTPConnection).self)
    }

    /// Connections refused at accept (filter or caps).
    package var refusedCount: Int { books.withLock { $0.refused } }
    package var openCount: Int { books.withLock { $0.open.count } }

    /// Admits only these non-loopback peers from now on (`nil` lifts the restriction). Open connections stay.
    package func restrictPeers(to allowed: Set<IPv4Literal>?) {
        books.withLock { $0.lockedPeers = allowed }
    }

    /// The exposure filter, then the peer restriction; loopback peers are this device and pass the restriction.
    package func admits(_ peer: PeerAddress) -> Bool {
        guard admission.peers.admits(peer) else { return false }
        guard let locked = books.withLock({ $0.lockedPeers }), !peer.isLoopback else { return true }
        return peer.ipv4.map(locked.contains) ?? false
    }

    package func start() async throws -> UInt16 {
        let listener: NWListener
        do {
            listener = try NWListener(using: makeParameters())
        } catch {
            throw HTTPTransportError.failed(String(describing: error))
        }
        let isFirst = books.withLock { books in
            defer { books.hasStarted = true }
            guard !books.hasStarted else { return false }
            books.listener = listener
            return true
        }
        guard isFirst else {
            listener.cancel()
            throw HTTPTransportError.alreadyStarted
        }
        let ready = OneShot<UInt16>()
        let released = released
        let requestedPort = requestedPort
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] newState in
            switch newState {
            case .ready:
                ready.finish(.success(listener?.port?.rawValue ?? requestedPort))
            case .waiting(let error), .failed(let error):
                ready.finish(.failure(Self.map(error, port: requestedPort)))
                listener?.cancel()
                self?.finishStream()
            case .cancelled:
                ready.finish(.failure(HTTPTransportError.stopped))
                released.finish(.success(()))
                self?.finishStream()
            default:
                break
            }
        }
        listener.start(queue: queue)
        return try await ready.value()
    }

    package func stop() async {
        let (listener, open) = books.withLock { books in
            books.isStopped = true
            let open = Array(books.open.values)
            return (books.listener, open)
        }
        listener?.cancel()
        open.forEach { $0.close() }
        finishStream()
        guard listener != nil else { return }
        // Cancellation is asynchronous: without this wait an immediate rebind of the same port can get EADDRINUSE.
        let deadline = ContinuousClock.now + .seconds(1)
        while !released.isFinished, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func finishStream() {
        sink.finish()
    }

    /// Package-visible so a test can check the reuse and peer-to-peer settings directly.
    package func makeParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        let host: NWEndpoint.Host = switch binding {
        case .loopbackIPv4: .ipv4(.loopback)
        case .interface(_, let ipv4, _): .ipv4(IPv4Address(Data(ipv4.octets)) ?? .loopback)
        }
        parameters.requiredLocalEndpoint = .hostPort(host: host, port: NWEndpoint.Port(rawValue: requestedPort) ?? .any)
        // false: endpoint reuse would let another local process bind the same port.
        parameters.allowLocalEndpointReuse = false
        parameters.includePeerToPeer = false
        return parameters
    }

    static func map(_ error: NWError, port: UInt16) -> HTTPTransportError {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return .portInUse(port)
        }
        return .failed(error.debugDescription)
    }

    package static func peerAddress(of endpoint: NWEndpoint) -> PeerAddress {
        guard case .hostPort(let host, _) = endpoint else { return PeerAddress(host: "unknown") }
        switch host {
        case .ipv4(let address):
            return PeerAddress(host: IPv4Literal(octets: Array(address.rawValue)).description)
        case .ipv6(let address):
            return PeerAddress(host: address.isLoopback ? "::1" : "\(address)")
        default:
            return PeerAddress(host: "unknown")
        }
    }

    /// Package-visible so tests can hand it connections with arbitrary remote endpoints.
    package func accept(_ connection: NWConnection) {
        let peer = Self.peerAddress(of: connection.endpoint)
        guard admits(peer) else {
            refuse(connection)
            return
        }
        let admitted = books.withLock { books -> Bool in
            let fromPeer = books.perPeer[peer.host, default: 0]
            guard !books.isStopped, books.open.count < admission.maxConnections,
                  books.readingHead < admission.maxReadingHead,
                  admission.maxPerPeer.map({ fromPeer < $0 }) ?? true else { return false }
            books.perPeer[peer.host] = fromPeer + 1
            books.readingHead += 1
            return true
        }
        guard admitted else {
            refuse(connection)
            return
        }
        let wrapped = makeConnection(connection, peer: peer)
        books.withLock { $0.open[ObjectIdentifier(wrapped)] = wrapped }
        wrapped.begin()
        if case .terminated = sink.yield(wrapped) {
            wrapped.close()
        }
    }

    private func refuse(_ connection: NWConnection) {
        books.withLock { $0.refused += 1 }
        connection.cancel()
    }

    private func makeConnection(_ connection: NWConnection, peer: PeerAddress) -> NWHTTPConnection {
        NWHTTPConnection(connection: connection, peer: peer, limits: limits,
                         headDone: { [weak self] in self?.books.withLock { $0.readingHead -= 1 } },
                         closed: { [weak self] identifier in self?.forget(identifier, peer: peer) })
    }

    private func forget(_ identifier: ObjectIdentifier, peer: PeerAddress) {
        books.withLock { books in
            books.open[identifier] = nil
            let remaining = books.perPeer[peer.host, default: 1] - 1
            books.perPeer[peer.host] = remaining > 0 ? remaining : nil
        }
    }
}

/// Resolves once; later results are ignored.
final class OneShot<Value: Sendable>: Sendable {
    private let state = Mutex<(result: Result<Value, Error>?, waiter: CheckedContinuation<Value, Error>?)>((nil, nil))

    func finish(_ result: Result<Value, Error>) {
        let waiter = state.withLock { state -> CheckedContinuation<Value, Error>? in
            guard state.result == nil else { return nil }
            state.result = result
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(with: result)
    }

    var isFinished: Bool { state.withLock { $0.result != nil } }

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let ready = state.withLock { state -> Result<Value, Error>? in
                if state.result == nil { state.waiter = continuation }
                return state.result
            }
            if let ready { continuation.resume(with: ready) }
        }
    }
}
