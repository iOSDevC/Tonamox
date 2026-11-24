import Foundation
import Network
import Testing
@testable import TonamoxHTTP

/// A private (RFC 1918) or link-local address of this machine, for the one test that needs a real interface bind.
let exposableAddress = InterfaceCatalog.current().first { address in
    !address.ipv4.isLoopback && (address.ipv4.isPrivate || address.ipv4.isLinkLocal)
        && !["utun", "ipsec", "ppp", "awdl", "llw", "pdp_ip"].contains(where: address.name.hasPrefix)
}

@Suite("Interface transport", .serialized)
struct InterfaceTransportTests {
    static let subnet = IPv4Subnet(network: IPv4Literal(octets: [192, 168, 50, 0]), prefixLength: 24)

    static func onLink(maxPerPeer: Int? = 4) -> AdmissionPolicy {
        AdmissionPolicy(maxConnections: 16, maxPerPeer: maxPerPeer, maxReadingHead: 8, peers: .onLink(subnet))
    }

    @Test func onLinkFilterRefusesOffSubnetPeer() async throws {
        let (transport, port) = try await startedTransport(Self.onLink())
        transport.accept(NWConnection(host: "192.168.51.3", port: 9, using: .tcp))
        transport.accept(NWConnection(host: "192.0.2.10", port: 9, using: .tcp))
        #expect(transport.refusedCount == 2)
        #expect(transport.admits(PeerAddress(host: "192.168.50.77")))
        #expect(!transport.admits(PeerAddress(host: "fe80::1")))
        let local = try await RawHTTPClient.connected(port: port)
        #expect(await eventually { transport.openCount == 1 })
        local.close()
        await transport.stop()
    }

    @Test func peerLockRefusesOtherIP() async throws {
        let (transport, port) = try await startedTransport(Self.onLink())
        let paired = IPv4Literal(octets: [192, 168, 50, 10])
        transport.restrictPeers(to: [paired])
        #expect(transport.admits(PeerAddress(host: "192.168.50.10")))
        #expect(!transport.admits(PeerAddress(host: "192.168.50.11")))
        transport.accept(NWConnection(host: "192.168.50.11", port: 9, using: .tcp))
        #expect(transport.refusedCount == 1)
        // This device's own clients are not another computer.
        let local = try await RawHTTPClient.connected(port: port)
        #expect(await eventually { transport.openCount == 1 })
        local.close()
        transport.restrictPeers(to: nil)
        #expect(transport.admits(PeerAddress(host: "192.168.50.11")))
        await transport.stop()
    }

    @Test(.enabled(if: exposableAddress != nil, "skipped: this machine has no private or link-local IPv4 address"))
    func bindsInterfaceAddressOnly() async throws {
        let address = try #require(exposableAddress)
        let transport = try Self.interfaceTransport(address)
        let port = try await transport.start()
        await #expect(throws: RawHTTPClient.Refused.self) {
            _ = try await RawHTTPClient.connected(port: port)
        }
        let client = try await RawHTTPClient.connected(host: address.ipv4.description, port: port)
        client.close()
        await transport.stop()
    }

    /// Opt-in: on macOS 27 an unsigned test process completed the TCP handshake on the LAN address but Network
    /// framework never delivered the connection (BSD `accept` did), likely Local Network privacy.
    @Test(.enabled(if: exposableAddress != nil && ProcessInfo.processInfo.environment["TONAMOX_LAN_ACCEPT"] == "1",
                   "skipped: set TONAMOX_LAN_ACCEPT=1 on a machine whose test runner has Local Network access"))
    func interfaceBindDeliversLANConnection() async throws {
        let address = try #require(exposableAddress)
        let transport = try Self.interfaceTransport(address)
        let port = try await transport.start()
        let client = try await RawHTTPClient.connected(host: address.ipv4.description, port: port)
        let connection = try await nextConnection(transport)
        #expect(connection.peer.ipv4 == address.ipv4)
        client.close()
        connection.close()
        await transport.stop()
    }

    static func interfaceTransport(_ address: NetworkInterfaceAddress) throws -> NWHTTPTransport {
        let subnet = IPv4Subnet(network: address.ipv4, prefixLength: address.prefixLength)
        return NWHTTPTransport(binding: .interface(name: address.name, ipv4: address.ipv4, subnet: subnet),
                               port: 0, admission: AdmissionPolicy(peers: .onLink(subnet)))
    }

    @Test func addressClassesMatchTheExposureRule() {
        #expect(IPv4Literal("10.1.2.3")?.isPrivate == true)
        #expect(IPv4Literal("172.16.0.1")?.isPrivate == true)
        #expect(IPv4Literal("172.31.255.1")?.isPrivate == true)
        #expect(IPv4Literal("172.32.0.1")?.isPrivate == false)
        #expect(IPv4Literal("192.168.0.1")?.isPrivate == true)
        #expect(IPv4Literal("100.64.0.1")?.isPrivate == false)
        #expect(IPv4Literal("169.254.1.1")?.isLinkLocal == true)
        #expect(IPv4Literal("8.8.8.8")?.isPrivate == false)
    }
}
