import Darwin
import Foundation
import Network
import Testing
@testable import TerminalBridgeKit

/// A non-loopback IPv4 address of this Mac, or nil when it has none (offline).
func lanAddress() -> IPv4Address? {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return nil }
    defer { freeifaddrs(head) }
    for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
        if let address = ipv4Address(of: entry.pointee), address.rawValue.first != 127 { return address }
    }
    return nil
}

/// A BSD socket bound to `source` and connected to 127.0.0.1:`port`. NWConnection cannot do this:
/// it replaces a non-loopback local endpoint with 127.0.0.1 for a loopback destination (measured).
func connectBSD(from source: IPv4Address, toLoopbackPort port: UInt16) -> Int32? {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return nil }
    var local = socketAddress(source.rawValue.withUnsafeBytes { $0.load(as: in_addr_t.self) }, port: 0)
    var remote = socketAddress(inet_addr("127.0.0.1"), port: port)
    let size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafePointer(to: &local) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, size) }
    }
    let connected = withUnsafePointer(to: &remote) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, size) }
    }
    guard bound == 0, connected == 0 else {
        close(descriptor)
        return nil
    }
    return descriptor
}

private func socketAddress(_ address: in_addr_t, port: UInt16) -> sockaddr_in {
    var value = sockaddr_in()
    value.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    value.sin_family = sa_family_t(AF_INET)
    value.sin_port = port.bigEndian
    value.sin_addr.s_addr = address
    return value
}

private func ipv4Address(of entry: ifaddrs) -> IPv4Address? {
    guard let socketAddress = entry.ifa_addr, socketAddress.pointee.sa_family == UInt8(AF_INET) else { return nil }
    let raw = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
    return withUnsafeBytes(of: raw) { IPv4Address(Data($0)) }
}

@Suite(.serialized) struct LoopbackListenerTests {
    private func connectClient(port: UInt16) async throws -> BridgeChannel {
        let client = BridgeChannel.loopbackClient(port: port)
        try await client.start()
        return client
    }

    @Test func capsUnauthenticatedConnections() async throws {
        let listener = LoopbackListener(port: 0, maxUnauthenticated: 2)
        let port = try await listener.start()
        defer { listener.stop() }
        var accepted = listener.connections.makeAsyncIterator()

        let first = try await connectClient(port: port)
        let second = try await connectClient(port: port)
        let firstServer = try #require(await accepted.next())
        _ = try #require(await accepted.next())
        #expect(listener.unauthenticatedCount == 2)

        let third = try await connectClient(port: port)
        #expect(await eventually { listener.refusedCount == 1 })
        await #expect(throws: (any Error).self) { try await third.receiveFrame() }

        firstServer.close()
        #expect(listener.unauthenticatedCount == 1)
        let fourth = try await connectClient(port: port)
        _ = try #require(await accepted.next())
        #expect(listener.unauthenticatedCount == 2)
        for client in [first, second, third, fourth] {
            client.close()
        }
    }

    @Test func authenticationFreesTheSlot() async throws {
        let listener = LoopbackListener(port: 0, maxUnauthenticated: 1)
        let port = try await listener.start()
        defer { listener.stop() }
        var accepted = listener.connections.makeAsyncIterator()
        let client = try await connectClient(port: port)
        defer { client.close() }
        let server = try #require(await accepted.next())
        defer { server.close() }
        #expect(listener.unauthenticatedCount == 1)
        let keys = FrameAuthenticator(sendKey: .init(size: .bits256), receiveKey: .init(size: .bits256))
        try await server.enableAuthentication(keys)
        #expect(listener.unauthenticatedCount == 0)
    }

    @Test func secondListenerOnTheSamePortFails() async throws {
        let listener = LoopbackListener(port: 0)
        let port = try await listener.start()
        defer { listener.stop() }
        let competitor = LoopbackListener(port: port)
        await #expect(throws: LoopbackListenerError.portInUse(port)) { try await competitor.start() }
    }

    @Test func rebindsTheSamePortAfterClosingAnAcceptedConnection() async throws {
        let listener = LoopbackListener(port: 0)
        let port = try await listener.start()
        var accepted = listener.connections.makeAsyncIterator()
        let client = try await connectClient(port: port)
        let server = try #require(await accepted.next())
        try await server.start()
        try await client.sendFrame(Data("x".utf8))
        #expect(try await server.receiveFrame() == Data("x".utf8))
        // The phone closes first, as it does when the app goes to the background.
        server.close()
        listener.stop()
        client.close()
        try await Task.sleep(for: .milliseconds(200))

        let again = LoopbackListener(port: port)
        defer { again.stop() }
        #expect(try await again.start() == port)
    }

    @Test func refusesNonLoopbackEndpoints() {
        #expect(LoopbackListener.isLoopback(.hostPort(host: .ipv4(.loopback), port: 1)))
        #expect(!LoopbackListener.isLoopback(.hostPort(host: .ipv4(IPv4Address("192.168.1.20")!), port: 1)))
        #expect(LoopbackListener.isLoopback(.hostPort(host: .ipv6(.loopback), port: 1)))
        #expect(!LoopbackListener.isLoopback(.hostPort(host: "localhost", port: 1)))
        #expect(!LoopbackListener.isLoopback(.hostPort(host: .ipv4(IPv4Address("10.0.0.1")!), port: 1)))
        #expect(!LoopbackListener.isLoopback(.hostPort(host: .ipv4(IPv4Address("169.254.3.4")!), port: 1)))
        #expect(!LoopbackListener.isLoopback(.hostPort(host: .ipv6(IPv6Address("fe80::1")!), port: 1)))
        #expect(!LoopbackListener.isLoopback(.hostPort(host: .ipv6(IPv6Address("::ffff:192.168.1.20")!), port: 1)))
        #expect(!LoopbackListener.isLoopback(.service(name: "x", type: "_x._tcp", domain: "local", interface: nil)))
    }

    @Test func acceptCancelsConnectionsFromNonLoopbackPeers() {
        let listener = LoopbackListener(port: 0)
        let remote = NWEndpoint.hostPort(host: .ipv4(IPv4Address("192.168.1.20")!), port: 50000)
        let connection = NWConnection(to: remote, using: .tcp)
        listener.accept(connection)
        #expect(listener.refusedCount == 1)
        #expect(listener.unauthenticatedCount == 0)
        listener.stop()
    }

    @Test func parametersBindLoopbackWithoutPortReuse() {
        let parameters = LoopbackListener.makeParameters(port: 47821)
        #expect(parameters.allowLocalEndpointReuse == false)
        #expect(parameters.includePeerToPeer == false)
        #expect(parameters.requiredLocalEndpoint == .hostPort(host: .ipv4(.loopback), port: 47821))
        // Off because the simulator drops the Mac's loopback connection with it on; see makeParameters.
        #expect(parameters.acceptLocalOnly == false)
    }

    @Test func aConnectionFromTheLANAddressToLoopbackIsRefused() async throws {
        guard let lan = lanAddress() else { return }
        let listener = LoopbackListener(port: 0)
        let port = try await listener.start()
        defer { listener.stop() }
        let descriptor = try #require(connectBSD(from: lan, toLoopbackPort: port))
        defer { close(descriptor) }
        #expect(await eventually { listener.refusedCount == 1 })
        #expect(listener.unauthenticatedCount == 0)
    }

    @Test func theListenerIsNotReachableOnTheLANAddress() async throws {
        guard let lan = lanAddress() else { return }
        let listener = LoopbackListener(port: 0)
        let port = try await listener.start()
        defer { listener.stop() }
        let connection = NWConnection(
            host: .ipv4(lan),
            port: try #require(NWEndpoint.Port(rawValue: port)),
            using: .tcp
        )
        let client = BridgeChannel(connection: connection)
        defer { client.close() }
        await #expect(throws: (any Error).self) { try await client.start() }
        #expect(listener.refusedCount == 0)
        #expect(listener.unauthenticatedCount == 0)
    }

    @Test func clientToAClosedPortFailsInsteadOfWaiting() async throws {
        let listener = LoopbackListener(port: 0)
        let port = try await listener.start()
        listener.stop()
        try await Task.sleep(for: .milliseconds(100))
        let client = BridgeChannel.loopbackClient(port: port)
        await #expect(throws: (any Error).self) { try await client.start() }
        #expect(client.isClosed)
    }
}
