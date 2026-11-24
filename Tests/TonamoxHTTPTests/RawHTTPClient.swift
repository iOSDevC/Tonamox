import Foundation
import Network
import Synchronization

/// Exact bytes over one TCP connection, no HTTP library in between.
final class RawHTTPClient: Sendable {
    struct TimedOut: Error {}
    struct Refused: Error {
        var detail = ""
    }

    let connection: NWConnection
    private let queue = DispatchQueue(label: "RawHTTPClient")
    private let ended = Mutex(false)

    /// `host` must be an address of this machine: the client binds its source address to it.
    init(host: String = "127.0.0.1", port: UInt16) {
        let parameters = NWParameters.tcp
        // connect's implicit bind can hand out a source port whose TIME_WAIT holds this exact 4-tuple (macOS TCP ports
        // are sequential), failing with EADDRINUSE; an explicit bind to host:0 skips ports TIME_WAIT still holds.
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: .any)
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any,
                                  using: parameters)
    }

    static func connected(host: String = "127.0.0.1", port: UInt16) async throws -> RawHTTPClient {
        let client = RawHTTPClient(host: host, port: port)
        try await client.connect()
        return client
    }

    func connect(timeout: Duration = .seconds(5)) async throws {
        try await withTimeout(timeout) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = Mutex(false)
                self.connection.stateUpdateHandler = { state in
                    let outcome: Result<Void, Error>? = switch state {
                    case .ready: .success(())
                    case .waiting(let error), .failed(let error): .failure(Refused(detail: "\(error) from \(self.localEndpoint)"))
                    case .cancelled: .failure(Refused(detail: "cancelled"))
                    default: nil
                    }
                    guard let outcome, once.withLock({ done in defer { done = true }; return !done }) else { return }
                    continuation.resume(with: outcome)
                }
                self.connection.start(queue: self.queue)
            }
        }
    }

    func send(_ text: String) async throws {
        try await send(Data(text.utf8))
    }

    func send(_ bytes: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    /// One chunk, `nil` at end of stream or on error.
    func receiveChunk() async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    if isComplete || error != nil { self.ended.withLock { $0 = true } }
                    continuation.resume(returning: isComplete || error != nil ? nil : Data())
                }
            }
        }
    }

    /// Everything until the server closes.
    func receiveAll(timeout: Duration = .seconds(10)) async throws -> Data {
        try await withTimeout(timeout) {
            var all = Data()
            while let chunk = await self.receiveChunk() {
                all.append(chunk)
            }
            return all
        }
    }

    /// One response: up to `Content-Length` when the head has it (as curl reads), else until the server closes.
    func receiveResponse(timeout: Duration = .seconds(10)) async throws -> Data {
        try await withTimeout(timeout) {
            var all = Data()
            while !Self.isComplete(all) {
                guard let chunk = await self.receiveChunk() else { break }
                all.append(chunk)
            }
            return all
        }
    }

    static func isComplete(_ data: Data) -> Bool {
        guard let response = RawResponse(data), let length = response.header("Content-Length").flatMap(Int.init) else {
            return false
        }
        return response.body.count >= length
    }

    /// Reads until `marker` appears; returns everything read so far.
    func receive(until marker: String, timeout: Duration = .seconds(10)) async throws -> Data {
        let needle = Data(marker.utf8)
        return try await withTimeout(timeout) {
            var all = Data()
            while all.range(of: needle) == nil {
                guard let chunk = await self.receiveChunk() else { break }
                all.append(chunk)
            }
            return all
        }
    }

    var sawEnd: Bool { ended.withLock { $0 } }

    var localEndpoint: String { connection.currentPath?.localEndpoint.map { "\($0)" } ?? "no local endpoint" }

    func close() {
        connection.cancel()
    }
}

func withTimeout<T: Sendable>(_ timeout: Duration, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw RawHTTPClient.TimedOut()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw RawHTTPClient.TimedOut() }
        return first
    }
}

struct RawResponse {
    let status: Int
    let headers: [(name: String, value: String)]
    let body: Data

    init?(_ data: Data) {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headText = String(decoding: data[..<split.lowerBound], as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ")
        guard statusLine.count >= 2, let status = Int(statusLine[1]) else { return nil }
        self.status = status
        self.headers = lines.compactMap(Self.header)
        self.body = Data(data[split.upperBound...])
    }

    private static func header(_ line: String) -> (name: String, value: String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        return (String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }

    func header(_ name: String) -> String? {
        headers.first { $0.name.lowercased() == name.lowercased() }?.value
    }

    var text: String { String(decoding: body, as: UTF8.self) }
}
