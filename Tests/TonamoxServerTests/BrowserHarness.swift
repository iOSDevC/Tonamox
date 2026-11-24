import Foundation
import Synchronization
import Testing
import TonamoxHTTP
@testable import TonamoxServer

@MainActor
final class FakePairingPresenter: PairingPresenter {
    private(set) var presented: [PairingRequest] = []
    private(set) var dismissed: [UUID] = []

    func present(_ request: PairingRequest) async {
        presented.append(request)
    }

    func dismiss(_ id: PairingRequest.ID) {
        dismissed.append(id)
    }
}

/// An in-memory connection with any peer address: loopback tests cannot connect from a second IP.
final class FakeConnection: HTTPConnection {
    let peer: PeerAddress
    private let head: HTTPRequestHead
    private let body: Data
    private let output = Mutex(Data())

    init(peer: String, head: HTTPRequestHead, body: Data) {
        self.peer = PeerAddress(host: peer)
        self.head = head
        self.body = body
    }

    var written: Data { output.withLock { $0 } }

    func readHead(deadline: ContinuousClock.Instant) async throws -> HTTPRequestHead { head }

    func readBody(length: Int, deadline: ContinuousClock.Instant) async throws -> Data {
        guard body.count >= length else { throw HTTPConnectionError.closed }
        return body.prefix(length)
    }

    func sendContinue() async throws {}

    func send(_ head: HTTPResponseHead, body: Data) async {
        output.withLock { $0.append(head.serialized + body) }
    }

    func openEventStream(_ head: HTTPResponseHead, stallTimeout: Duration) async throws -> EventStreamWriter {
        output.withLock { $0.append(head.serialized) }
        return EventStreamWriter(write: { [self] bytes in output.withLock { $0.append(bytes) } }, finish: {})
    }

    func waitForPeerClose() async {
        try? await Task.sleep(for: .seconds(3600))
    }

    func close() {}
}

extension ServerHarness {
    static let browserFeatures: ServerFeatures = [.openAIAPI, .browserPage]

    static func browser(_ presenter: FakePairingPresenter, features: ServerFeatures = browserFeatures,
                        armed: Bool = true,
                        configure: (inout ServerConfiguration) -> Void = { _ in }) async throws -> ServerHarness {
        let harness = try await started(pairing: presenter) { configuration in
            configuration.features = features
            configuration.serverName = "Mesa de pruebas"
            configure(&configuration)
        }
        if armed { harness.server.openPairingWindow() }
        return harness
    }

    var originHeader: String { "Origin: http://\(host)" }

    func postRequest(_ path: String, _ body: String, headers: [String]? = nil,
                     contentType: String = "application/json") -> String {
        var lines = ["POST \(path) HTTP/1.1", "Host: \(host)", "Content-Type: \(contentType)",
                     "Content-Length: \(body.utf8.count)"]
        lines += headers ?? [originHeader]
        return lines.joined(separator: "\r\n") + "\r\n\r\n" + body
    }

    func post(_ path: String, _ body: String, headers: [String]? = nil,
              contentType: String = "application/json") async throws -> RawResponse {
        try await raw(postRequest(path, body, headers: headers, contentType: contentType))
    }

    /// `POST /pair`; returns the request id from the response and the code the device shows.
    func requestPairing(name: String = "portátil") async throws -> (id: String, code: String) {
        let response = try await post("/pair", #"{"name":"\#(name)"}"#)
        #expect(response.status == 200)
        let id = try #require(json(response.body)["request"] as? String)
        let code = try #require(server.pendingPairing?.code)
        return (id, code)
    }

    func claim(_ id: String, code: String) async throws -> RawResponse {
        try await post("/pair/\(id)", #"{"code":"\#(code)"}"#)
    }

    /// Pairs and returns the browser token.
    func pairBrowser() async throws -> String {
        let (id, code) = try await requestPairing()
        let response = try await claim(id, code: code)
        #expect(response.status == 200)
        return try #require(json(response.body)["token"] as? String)
    }

    func session(_ token: String?) async throws -> RawResponse {
        var lines = ["GET /api/session HTTP/1.1", "Host: \(host)"]
        if let token { lines.append("Authorization: Bearer \(token)") }
        return try await raw(lines.joined(separator: "\r\n") + "\r\n\r\n")
    }

    /// Runs one exchange through the server's pipeline on a fake connection from `peer`.
    func exchange(from peer: String, _ request: String) async throws -> RawResponse {
        var parser = HTTPRequestParser()
        let bytes = Array(request.utf8)
        guard case .head(let head, let consumed) = parser.feed(bytes) else {
            Issue.record("request did not parse")
            throw RawHTTPClient.TimedOut()
        }
        let connection = FakeConnection(peer: peer, head: head, body: Data(bytes[consumed...]))
        await server.serve(connection)
        return try #require(RawResponse(connection.written))
    }

    func shiftClock(by offset: Duration) {
        server.clock = ServerClock(monotonic: { ContinuousClock.now + offset },
                                   wall: { Date().addingTimeInterval(offset.seconds) })
    }
}

enum PageSource {
    static var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/TonamoxServer/Embedded")
    }

    static func text(_ name: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    static func bytes(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    static var html: String { (try? text("index.html")) ?? "" }
    static var script: String { (try? text("app.js")) ?? "" }
    static var stylesheet: String { (try? text("app.css")) ?? "" }
}
