import Foundation

package enum HTTPTransportError: Error, Equatable, Sendable {
    case portInUse(UInt16)
    case alreadyStarted
    case stopped
    case failed(String)
}

package enum HTTPConnectionError: Error, Equatable, Sendable {
    case rejected(HTTPRejection)
    case deadlineExceeded
    case stalled
    case closed
}

/// The seam between routes and the socket layer; a NIO transport would plug in here.
package protocol HTTPTransport: Sendable {
    /// Binds and starts listening; returns the bound port.
    func start() async throws -> UInt16
    /// Stops listening and closes every open connection.
    func stop() async
    var connections: AsyncStream<any HTTPConnection> { get }
}

/// One request per connection. Every response closes it.
package protocol HTTPConnection: AnyObject, Sendable {
    var peer: PeerAddress { get }
    func readHead(deadline: ContinuousClock.Instant) async throws -> HTTPRequestHead
    /// Exactly `length` bytes; bytes after them are never parsed.
    func readBody(length: Int, deadline: ContinuousClock.Instant) async throws -> Data
    func sendContinue() async throws
    /// Sends a complete response and closes the connection; unread request bytes are drained (lingering close).
    func send(_ head: HTTPResponseHead, body: Data) async
    func openEventStream(_ head: HTTPResponseHead, stallTimeout: Duration) async throws -> EventStreamWriter
    /// Returns when the peer closes or resets, or the connection is closed locally.
    func waitForPeerClose() async
    func close()
}

/// Writes close-delimited event-stream bytes. Each write waits until the bytes leave, up to the stall timeout.
package struct EventStreamWriter: Sendable {
    private let writeBytes: @Sendable (Data) async throws -> Void
    private let finishStream: @Sendable () async -> Void

    package init(write: @escaping @Sendable (Data) async throws -> Void, finish: @escaping @Sendable () async -> Void) {
        self.writeBytes = write
        self.finishStream = finish
    }

    package func write(_ bytes: Data) async throws {
        try await writeBytes(bytes)
    }

    /// Ends the stream and closes the connection.
    package func finish() async {
        await finishStream()
    }
}

extension Duration {
    package var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
