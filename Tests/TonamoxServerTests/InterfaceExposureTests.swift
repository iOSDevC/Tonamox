import Foundation
import Synchronization
import Testing
import TonamoxHTTP
@testable import TonamoxServer

/// The interface list a test server reads; tests change it to simulate a lost address.
final class InterfaceList: Sendable {
    private let entries: Mutex<[NetworkInterfaceAddress]>

    init(_ initial: [NetworkInterfaceAddress]) {
        entries = Mutex(initial)
    }

    var current: [NetworkInterfaceAddress] { entries.withLock { $0 } }

    func replace(with list: [NetworkInterfaceAddress]) {
        entries.withLock { $0 = list }
    }
}

/// Path changes a test fires by hand, in place of `NWPathMonitor`.
final class PathChanges: Sendable {
    private let callbacks = Mutex<[@MainActor @Sendable () -> Void]>([])

    @Sendable func watch(_ onChange: @escaping @MainActor @Sendable () -> Void) -> PathWatch {
        callbacks.withLock { $0.append(onChange) }
        return PathWatch { [weak self] in self?.callbacks.withLock { $0.removeAll() } }
    }

    var isWatched: Bool { callbacks.withLock { !$0.isEmpty } }

    @MainActor func fire() {
        callbacks.withLock { $0 }.forEach { $0() }
    }
}

func interfaceAddress(_ name: String, _ ipv4: String, prefix: Int = 24) -> NetworkInterfaceAddress {
    NetworkInterfaceAddress(name: name, ipv4: IPv4Literal(ipv4) ?? .loopback, prefixLength: prefix)
}

extension ServerHarness {
    static let lanAddress = "192.168.50.2"

    static func lanList() -> InterfaceList {
        InterfaceList([interfaceAddress("en0", lanAddress), interfaceAddress("pdp_ip0", "10.20.30.40")])
    }

    /// Interface exposure on an injected `en0`; the listener itself is on 127.0.0.1 (no second address in tests),
    /// and other peers are reached through ``FakeConnection``.
    static func onInterface(_ list: InterfaceList = lanList(), presenter: FakePairingPresenter? = nil,
                            features: ServerFeatures = [.openAIAPI, .browserPage],
                            configure: (inout ServerConfiguration) -> Void = { _ in }) async throws -> ServerHarness {
        let harness = try interfaceHarness(list, presenter: presenter, features: features, configure: configure)
        try await harness.start()
        harness.server.openPairingWindow()
        return harness
    }

    static func interfaceHarness(_ list: InterfaceList, presenter: FakePairingPresenter? = nil,
                                 features: ServerFeatures = [.openAIAPI, .browserPage],
                                 pathChanges: PathChanges = PathChanges(),
                                 configure: (inout ServerConfiguration) -> Void = { _ in }) throws -> ServerHarness {
        let network = ServerNetwork(interfaces: { list.current }, listensOnLoopback: true,
                                    watchPaths: pathChanges.watch)
        let chosen = try #require(ServerInterface.available(from: list.current).first)
        let harness = ServerHarness(pairing: presenter ?? FakePairingPresenter(), network: network) { configuration in
            configuration.exposure = .interface(chosen)
            configuration.features = features
            configure(&configuration)
        }
        harness.hostAddress = lanAddress
        return harness
    }

    /// What the server wrote to a fake connection from `peer`; empty when it closed without answering.
    func written(from peer: String, _ request: String) async throws -> Data {
        var parser = HTTPRequestParser()
        let bytes = Array(request.utf8)
        guard case .head(let head, let consumed) = parser.feed(bytes) else {
            Issue.record("request did not parse")
            throw RawHTTPClient.TimedOut()
        }
        let connection = FakeConnection(peer: peer, head: head, body: Data(bytes[consumed...]))
        await server.serve(connection)
        return connection.written
    }

    func modelsRequest(key: String? = nil) -> String {
        "GET /v1/models HTTP/1.1\r\nHost: \(host)\r\nAuthorization: Bearer \(key ?? secret)\r\n\r\n"
    }

    func status(from peer: String, key: String? = nil) async throws -> Int? {
        RawResponse(try await written(from: peer, modelsRequest(key: key)))?.status
    }

    /// Pairs through fake connections from `peer`; returns the claim response.
    func pair(from peer: String) async throws -> RawResponse {
        let requested = try await exchange(from: peer, postRequest("/pair", #"{"name":"portátil"}"#))
        #expect(requested.status == 200)
        let id = try #require(json(requested.body)["request"] as? String)
        let code = try #require(server.pendingPairing?.code)
        return try await exchange(from: peer, postRequest("/pair/\(id)", #"{"code":"\#(code)"}"#))
    }
}

@Suite("Interface exposure", .serialized)
@MainActor
struct InterfaceExposureTests {
    static let unknownKey = "tnx_" + String(repeating: "A", count: 43)

    @Test func interfaceCatalogExcludesCellularVPNAndPeerToPeer() {
        let list = [
            interfaceAddress("en0", "192.168.1.5"),
            interfaceAddress("bridge100", "172.20.10.1", prefix: 28),
            interfaceAddress("en5", "10.0.0.4"),
            interfaceAddress("en7", "169.254.3.3", prefix: 16),
            interfaceAddress("pdp_ip0", "10.64.2.3"),
            interfaceAddress("utun3", "10.8.0.2"),
            interfaceAddress("ipsec0", "10.9.0.2"),
            interfaceAddress("ppp0", "10.10.0.2"),
            interfaceAddress("gif0", "10.11.0.2"),
            interfaceAddress("stf0", "10.12.0.2"),
            interfaceAddress("awdl0", "169.254.9.9", prefix: 16),
            interfaceAddress("llw0", "169.254.8.8", prefix: 16),
            interfaceAddress("lo0", "127.0.0.1", prefix: 8),
            interfaceAddress("en8", "100.64.1.2", prefix: 10),
            interfaceAddress("en9", "8.8.8.8"),
            interfaceAddress("en10", "172.32.0.1"),
        ]
        let available = ServerInterface.available(from: list)
        #expect(available.map(\.name) == ["en0", "bridge100", "en5", "en7"])
        #expect(available.map(\.kind) == [.wifi, .personalHotspot, .wired, .wired])
        #expect(available.first?.id == "en0/192.168.1.5")
        #expect(available.first?.prefixLength == 24)
    }

    @Test func endpointIsObservableForInterface() async throws {
        let harness = try await ServerHarness.onInterface()
        guard case .listening(let endpoint) = harness.server.state else {
            Issue.record("not listening")
            return
        }
        #expect(endpoint.host == ServerHarness.lanAddress)
        #expect(endpoint.isObservableByNetwork)
        #expect(endpoint.baseURL.absoluteString == "http://\(ServerHarness.lanAddress):\(harness.port)")
        let loopback = try await ServerHarness.started()
        guard case .listening(let local) = loopback.server.state else {
            Issue.record("not listening")
            return
        }
        #expect(!local.isObservableByNetwork)
        await harness.server.stop()
        await loopback.server.stop()
    }

    @Test func hostAllowlistIsTheInterfaceAddressOnly() async throws {
        let harness = try await ServerHarness.onInterface()
        #expect(try await harness.get("/v1/models").status == 200)
        #expect(try await harness.get("/v1/models", host: "127.0.0.1:\(harness.port)").status == 421)
        #expect(try await harness.get("/v1/models", host: "localhost:\(harness.port)").status == 421)
        await harness.server.stop()
    }

    @Test func startFailsWhenInterfaceIsGone() async throws {
        let list = ServerHarness.lanList()
        let harness = try ServerHarness.interfaceHarness(list)
        list.replace(with: [interfaceAddress("en0", "192.168.50.77")])
        await #expect(throws: ServerFailure.interfaceUnavailable("en0")) { try await harness.server.start() }
        #expect(harness.server.state == .failed(.interfaceUnavailable("en0")))
    }

    @Test func offSubnetPeerIsRefusedPerConnection() async throws {
        let harness = try await ServerHarness.onInterface { $0.peerLockPolicy = .none }
        #expect(try await harness.written(from: "192.168.51.7", harness.modelsRequest()).isEmpty)
        #expect(try await harness.written(from: "10.0.0.3", harness.modelsRequest()).isEmpty)
        #expect(try await harness.written(from: "fe80::1", harness.modelsRequest()).isEmpty)
        #expect(try await harness.status(from: "192.168.50.9") == 200)
        await harness.server.stop()
    }

    @Test func firstPairingLocksPeer() async throws {
        let harness = try await ServerHarness.onInterface()
        let events = harness.server.events()
        let claimed = try await harness.pair(from: "192.168.50.10")
        #expect(claimed.status == 200)
        let token = try #require(json(claimed.body)["token"] as? String)
        #expect(harness.server.lockedPeers == ["192.168.50.10"])
        #expect(harness.server.transport?.admits(PeerAddress(host: "192.168.50.11")) == false)
        #expect(try await harness.written(from: "192.168.50.11", harness.modelsRequest()).isEmpty)
        #expect(try await harness.status(from: "192.168.50.10", key: token) == 200)
        #expect(try await harness.status(from: "192.168.50.10") == 200)
        var iterator = events.makeAsyncIterator()
        var sawLock = false
        while let event = await iterator.next() {
            if event == .peerLocked("192.168.50.10") { sawLock = true; break }
        }
        #expect(sawLock)
        await harness.server.stop()
        #expect(harness.server.lockedPeers.isEmpty)
    }

    @Test func firstAPIKeyUseLocksPeer() async throws {
        let harness = try await ServerHarness.onInterface()
        #expect(try await harness.status(from: "192.168.50.20") == 200)
        #expect(harness.server.lockedPeers == ["192.168.50.20"])
        #expect(try await harness.written(from: "192.168.50.21", harness.modelsRequest()).isEmpty)
        // Pairing from another computer is refused at the connection too.
        let pairing = harness.postRequest("/pair", #"{"name":"x"}"#)
        #expect(try await harness.written(from: "192.168.50.21", pairing).isEmpty)
        #expect(harness.server.pendingPairing == nil)
        await harness.server.stop()
    }

    @Test func allowAnotherComputerReopensOnce() async throws {
        let harness = try await ServerHarness.onInterface()
        #expect(try await harness.status(from: "192.168.50.10") == 200)
        harness.server.allowAnotherComputer()
        #expect(harness.server.transport?.admits(PeerAddress(host: "192.168.50.11")) == true)
        #expect(try await harness.status(from: "192.168.50.11") == 200)
        #expect(harness.server.lockedPeers == ["192.168.50.10", "192.168.50.11"])
        #expect(try await harness.written(from: "192.168.50.12", harness.modelsRequest()).isEmpty)
        #expect(harness.server.transport?.admits(PeerAddress(host: "192.168.50.12")) == false)
        #expect(try await harness.status(from: "192.168.50.10") == 200)
        #expect(try await harness.status(from: "192.168.50.11") == 200)
        await harness.server.stop()
    }

    @Test func allowAnotherComputerExpiresWithThePairingWindow() async throws {
        let harness = try await ServerHarness.onInterface()
        #expect(try await harness.status(from: "192.168.50.10") == 200)
        harness.server.allowAnotherComputer()
        harness.shiftClock(by: .seconds(121))
        #expect(try await harness.written(from: "192.168.50.11", harness.modelsRequest()).isEmpty)
        await harness.server.stop()
    }

    @Test func peerLockNoneAdmitsEveryOnLinkPeer() async throws {
        let harness = try await ServerHarness.onInterface { $0.peerLockPolicy = .none }
        #expect(try await harness.status(from: "192.168.50.10") == 200)
        #expect(try await harness.status(from: "192.168.50.11") == 200)
        #expect(harness.server.lockedPeers.isEmpty)
        await harness.server.stop()
    }

    @Test func peerLockIgnoredOnLoopback() async throws {
        let harness = try await ServerHarness.started()
        #expect(try await harness.status(from: "10.0.0.9") == 200)
        #expect(try await harness.status(from: "10.0.0.10") == 200)
        harness.server.allowAnotherComputer()
        #expect(harness.server.lockedPeers.isEmpty)
        await harness.server.stop()
    }

    @Test func perIPBlockAppliesOnlyToInterface() async throws {
        let lan = try await ServerHarness.onInterface { $0.peerLockPolicy = .none }
        var statuses: [Int?] = []
        for _ in 0..<5 { statuses.append(try await lan.status(from: "192.168.50.30", key: Self.unknownKey)) }
        #expect(statuses == Array(repeating: 401, count: 5))
        #expect(try await lan.status(from: "192.168.50.30", key: Self.unknownKey) == 429)
        #expect(try await lan.status(from: "192.168.50.30") == 429)
        #expect(try await lan.status(from: "192.168.50.31") == 200)
        await lan.server.stop()

        let loopback = try await ServerHarness.started()
        var local: [Int] = []
        for _ in 0..<7 { local.append(try await loopback.get("/v1/models", key: Self.unknownKey).status) }
        #expect(local == Array(repeating: 401, count: 7))
        #expect(try await loopback.get("/v1/models").status == 200)
        await loopback.server.stop()
    }

    @Test func interfaceLossSuspends() async throws {
        let list = ServerHarness.lanList()
        let harness = try await ServerHarness.onInterface(list)
        let port = harness.port
        await harness.server.checkBoundInterface()
        #expect(harness.server.state == .listening(ServerEndpoint(host: ServerHarness.lanAddress, port: port,
                                                                  exposure: harness.server.configuration.exposure)))
        list.replace(with: [interfaceAddress("en0", "192.168.50.99")])
        await harness.server.checkBoundInterface()
        #expect(harness.server.state == .suspended(.interfaceLost("en0")))
        await #expect(throws: RawHTTPClient.Refused.self) { _ = try await RawHTTPClient.connected(port: port) }
        await #expect(throws: ServerFailure.interfaceUnavailable("en0")) { try await harness.server.resume() }
        #expect(harness.server.state == .failed(.interfaceUnavailable("en0")))
    }

    @Test func pathChangeWithLostAddressSuspends() async throws {
        let list = ServerHarness.lanList()
        let changes = PathChanges()
        let harness = try ServerHarness.interfaceHarness(list, pathChanges: changes)
        try await harness.start()
        #expect(changes.isWatched)
        changes.fire()
        try await Task.sleep(for: .milliseconds(100))
        guard case .listening = harness.server.state else {
            Issue.record("a path change that keeps the address suspended the server: \(harness.server.state)")
            return
        }
        list.replace(with: [interfaceAddress("en0", "192.168.50.99")])
        changes.fire()
        #expect(await eventually { harness.server.state == .suspended(.interfaceLost("en0")) })
        #expect(!changes.isWatched)
        await harness.server.stop()
    }

    @Test func resumeAfterInterfaceReturnsRebindsSamePort() async throws {
        let list = ServerHarness.lanList()
        let harness = try await ServerHarness.onInterface(list)
        let port = harness.port
        let original = list.current
        list.replace(with: [])
        await harness.server.checkBoundInterface()
        #expect(harness.server.state == .suspended(.interfaceLost("en0")))
        list.replace(with: original)
        try await harness.server.resume()
        guard case .listening(let endpoint) = harness.server.state else {
            Issue.record("not listening")
            return
        }
        #expect(endpoint.port == port && endpoint.host == ServerHarness.lanAddress)
        #expect(try await harness.get("/v1/models").status == 200)
        await harness.server.stop()
    }

    @Test func idleShutdownOnlyForInterfaceExposure() async throws {
        let loopback = try await ServerHarness.started { $0.idleShutdown = .milliseconds(200) }
        let lan = try await ServerHarness.onInterface { $0.idleShutdown = .milliseconds(200) }
        #expect(await eventually(.seconds(5)) { lan.server.state == .suspended(.idle) })
        try await Task.sleep(for: .milliseconds(300))
        guard case .listening = loopback.server.state else {
            Issue.record("loopback server idled: \(loopback.server.state)")
            return
        }
        await loopback.server.stop()
        await lan.server.stop()
    }

    @Test func unauthenticatedFetchesDoNotDeferIdleShutdown() async throws {
        let lan = try await ServerHarness.onInterface { $0.idleShutdown = .milliseconds(600) }
        let deadline = ContinuousClock.now + .seconds(3)
        while lan.server.state != .suspended(.idle), ContinuousClock.now < deadline {
            _ = try? await lan.get("/app.css")
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(lan.server.state == .suspended(.idle))
        await lan.server.stop()
    }

    @Test func authenticatedRequestsDeferIdleShutdown() async throws {
        let lan = try await ServerHarness.onInterface { $0.idleShutdown = .milliseconds(600) }
        for _ in 0..<10 {
            #expect(try await lan.get("/v1/models").status == 200)
            try await Task.sleep(for: .milliseconds(100))
        }
        guard case .listening = lan.server.state else {
            Issue.record("idled while a client kept using its key: \(lan.server.state)")
            return
        }
        await lan.server.stop()
    }

    @Test func idleShutdownOffKeepsListening() async throws {
        let lan = try await ServerHarness.onInterface { $0.idleShutdown = nil }
        try await Task.sleep(for: .milliseconds(300))
        guard case .listening = lan.server.state else {
            Issue.record("server idled without an idle limit")
            return
        }
        await lan.server.stop()
    }

    @Test func helloReportsInterfaceAndObservable() async throws {
        let harness = try await ServerHarness.onInterface()
        let claimed = try await harness.pair(from: "192.168.50.10")
        let hello = try #require(json(claimed.body)["hello"] as? [String: Any])
        #expect(hello["exposure"] as? String == "interface")
        #expect(hello["observable"] as? Bool == true)
        let network = try #require(hello["interface"] as? [String: Any])
        #expect(network["name"] as? String == "en0")
        #expect(network["kind"] as? String == "wifi")
        #expect(network["address"] as? String == ServerHarness.lanAddress)
        #expect(network["peerLock"] as? String == "first_paired_peer")
        #expect(network["idleMinutes"] as? Int == 15)
        await harness.server.stop()
    }

    @Test func pageBannerIsFedByTheHello() throws {
        let script = PageSource.script
        #expect(script.contains("hello.observable === true"))
        #expect(script.contains("setText('banner-unencrypted-where'"))
        #expect(PageSource.html.contains(#"id="banner-unencrypted-where""#))
    }

    @Test func ingestRecordsWhetherThePeerMatchesTheLock() async throws {
        let harness = try await ServerHarness.onInterface(features: [.openAIAPI, .ingest])
        let early = try await harness.server.ingest.makeTicket(label: "early")
        let beforeLock = harness.ingestHead(early, length: 2) + "hi"
        _ = try await harness.written(from: "192.168.50.10", beforeLock)
        #expect(try await harness.nextOutput().peerMatchesLock == false)
        #expect(try await harness.status(from: "192.168.50.10") == 200)
        let late = try await harness.server.ingest.makeTicket(label: "late")
        _ = try await harness.written(from: "192.168.50.10", harness.ingestHead(late, length: 2) + "ok")
        #expect(try await harness.nextOutput().peerMatchesLock)
        await harness.server.stop()
    }
}
