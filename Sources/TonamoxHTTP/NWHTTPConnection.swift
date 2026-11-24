import Foundation
import Network
import Synchronization

final class NWHTTPConnection: HTTPConnection {
    static let receiveSize = 64 * 1024
    static let lingerBytes = 64 * 1024
    static let lingerTime = Duration.seconds(2)

    let peer: PeerAddress
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "TonamoxHTTP.NWHTTPConnection")
    private let headDone: @Sendable () -> Void
    private let closed: @Sendable (ObjectIdentifier) -> Void

    private struct Progress {
        var parser: HTTPRequestParser
        var received = Data()
        var leftover = Data()
        var headReported = false
        var closeReported = false
        var timedOut = false
        var isClosed = false
    }

    private let progress: Mutex<Progress>
    /// The one reader after the request: the disconnect watcher and the lingering close share it, so two receives
    /// never compete for the peer's end of stream.
    private let peerCloseReader = Mutex<Task<Void, Never>?>(nil)

    init(connection: NWConnection, peer: PeerAddress, limits: HTTPParseLimits,
         headDone: @escaping @Sendable () -> Void, closed: @escaping @Sendable (ObjectIdentifier) -> Void) {
        self.connection = connection
        self.peer = peer
        self.headDone = headDone
        self.closed = closed
        self.progress = Mutex(Progress(parser: HTTPRequestParser(limits: limits)))
    }

    func begin() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            // A failed NWConnection keeps its resources until it is cancelled.
            case .failed: self?.close()
            case .cancelled: self?.reportClosed()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    // MARK: - Reading

    func readHead(deadline: ContinuousClock.Instant) async throws -> HTTPRequestHead {
        defer { reportHeadDone() }
        return try await withDeadline(deadline) { try await self.collectHead() }
    }

    private func collectHead() async throws -> HTTPRequestHead {
        var outcome = HTTPParseOutcome.needMoreData
        repeat {
            guard let chunk = try await receiveChunk(maximum: Self.receiveSize) else { throw HTTPConnectionError.closed }
            outcome = parse(chunk)
        } while outcome == .needMoreData
        switch outcome {
        case .head(let head, let consumed):
            progress.withLock { $0.leftover = $0.received.dropFirst(consumed); $0.received = Data() }
            return head
        case .reject(let rejection):
            throw HTTPConnectionError.rejected(rejection)
        case .needMoreData:
            throw HTTPConnectionError.closed
        }
    }

    private func parse(_ chunk: Data) -> HTTPParseOutcome {
        progress.withLock { state in
            state.received.append(chunk)
            return state.parser.feed(chunk)
        }
    }

    func readBody(length: Int, deadline: ContinuousClock.Instant) async throws -> Data {
        let start = progress.withLock { state -> Data in
            defer { state.leftover = Data() }
            return Data(state.leftover.prefix(length))
        }
        guard start.count < length else { return start }
        return try await withDeadline(deadline) { try await self.collectBody(start, length: length) }
    }

    private func collectBody(_ start: Data, length: Int) async throws -> Data {
        var body = start
        while body.count < length {
            guard let chunk = try await receiveChunk(maximum: min(Self.receiveSize, length - body.count)) else {
                throw HTTPConnectionError.closed
            }
            body.append(chunk.prefix(length - body.count))
        }
        return body
    }

    func waitForPeerClose() async {
        let reader = peerCloseReader.withLock { reader -> Task<Void, Never> in
            if let reader { return reader }
            let started = Task { await self.discardUntilPeerClose() }
            reader = started
            return started
        }
        await reader.value
    }

    private func discardUntilPeerClose() async {
        var discarded = 0
        while discarded < Self.lingerBytes {
            guard let chunk = try? await receiveChunk(maximum: Self.receiveSize) else { return }
            discarded += chunk.count
        }
    }

    /// `nil` at end of stream.
    private func receiveChunk(maximum: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    // MARK: - Writing

    func sendContinue() async throws {
        try await sendBytes(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
    }

    func send(_ head: HTTPResponseHead, body: Data) async {
        var bytes = head.serialized
        bytes.append(body)
        do {
            try await sendBytes(bytes)
            await lingerAndClose(halfClose: false)
        } catch {
            close()
        }
    }

    func openEventStream(_ head: HTTPResponseHead, stallTimeout: Duration) async throws -> EventStreamWriter {
        try await sendWithin(stallTimeout, head.serialized)
        return EventStreamWriter(
            write: { [self] bytes in try await sendWithin(stallTimeout, bytes) },
            finish: { [self] in await lingerAndClose(halfClose: true) })
    }

    private func sendWithin(_ timeout: Duration, _ bytes: Data) async throws {
        do {
            try await withDeadline(.now + timeout) { try await self.sendBytes(bytes) }
        } catch HTTPConnectionError.deadlineExceeded {
            throw HTTPConnectionError.stalled
        }
    }

    private func sendBytes(_ bytes: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if error != nil {
                    continuation.resume(throwing: HTTPConnectionError.closed)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Drains what the peer still sends (bounded) before closing, so an early error reaches the client instead of
    /// being lost to the RST that closing with unread bytes triggers. A sized response lets the peer close first:
    /// a server-side TIME_WAIT on loopback made later connects to the server fail with EADDRINUSE (measured, macOS).
    /// A close-delimited event stream has to send its FIN first.
    private func lingerAndClose(halfClose: Bool) async {
        if halfClose {
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
        }
        _ = try? await withDeadline(.now + Self.lingerTime) { await self.waitForPeerClose() }
        close()
    }

    func close() {
        let first = progress.withLock { state -> Bool in
            defer { state.isClosed = true }
            return !state.isClosed
        }
        guard first else { return }
        connection.cancel()
        reportClosed()
    }

    // MARK: - Bookkeeping

    private func withDeadline<T>(_ deadline: ContinuousClock.Instant,
                                 _ body: @escaping () async throws -> T) async throws -> T {
        let delay = max(0, ContinuousClock.now.duration(to: deadline).seconds)
        let timer = DispatchWorkItem { [weak self] in self?.expire() }
        queue.asyncAfter(deadline: .now() + delay, execute: timer)
        defer { timer.cancel() }
        do {
            return try await body()
        } catch {
            if progress.withLock({ $0.timedOut }) { throw HTTPConnectionError.deadlineExceeded }
            throw error
        }
    }

    private func expire() {
        progress.withLock { $0.timedOut = true }
        close()
    }

    private func reportHeadDone() {
        let first = progress.withLock { state -> Bool in
            defer { state.headReported = true }
            return !state.headReported
        }
        if first { headDone() }
    }

    private func reportClosed() {
        reportHeadDone()
        let first = progress.withLock { state -> Bool in
            defer { state.closeReported = true }
            return !state.closeReported
        }
        if first { closed(ObjectIdentifier(self)) }
    }
}
