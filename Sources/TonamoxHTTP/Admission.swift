import Darwin
import Foundation

/// A dotted-quad IPv4 address.
package struct IPv4Literal: Sendable, Hashable, CustomStringConvertible {
    package let octets: [UInt8]

    package init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let values = parts.compactMap { UInt8($0) }
        guard parts.count == 4, values.count == 4 else { return nil }
        octets = values
    }

    package init(octets: [UInt8]) {
        precondition(octets.count == 4)
        self.octets = octets
    }

    package var value: UInt32 { octets.reduce(0) { ($0 << 8) | UInt32($1) } }
    package var isLoopback: Bool { octets[0] == 127 }
    /// 10/8, 172.16/12, 192.168/16 (RFC 1918).
    package var isPrivate: Bool {
        octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) || (octets[0] == 192 && octets[1] == 168)
    }
    /// 169.254/16.
    package var isLinkLocal: Bool { octets[0] == 169 && octets[1] == 254 }
    package var description: String { octets.map(String.init).joined(separator: ".") }

    package static let loopback = IPv4Literal(octets: [127, 0, 0, 1])
}

package struct IPv4Subnet: Sendable, Hashable {
    package let network: IPv4Literal
    package let prefixLength: Int

    package init(network: IPv4Literal, prefixLength: Int) {
        self.network = network
        self.prefixLength = max(0, min(32, prefixLength))
    }

    package func contains(_ address: IPv4Literal) -> Bool {
        guard prefixLength > 0 else { return true }
        let mask = UInt32.max << UInt32(32 - prefixLength)
        return address.value & mask == network.value & mask
    }
}

/// Where a connection came from. IPv6 and unknown endpoints keep their text form and never pass an IPv4 filter.
package struct PeerAddress: Sendable, Hashable, CustomStringConvertible {
    package let host: String
    package let ipv4: IPv4Literal?

    package init(host: String) {
        self.host = host
        self.ipv4 = IPv4Literal(host)
    }

    package var description: String { host }
    package var isLoopback: Bool { ipv4?.isLoopback ?? (host == "::1") }
}

package enum PeerFilter: Sendable, Equatable {
    case loopbackOnly
    case onLink(IPv4Subnet)
    case only(Set<IPv4Literal>)

    package func admits(_ peer: PeerAddress) -> Bool {
        switch self {
        case .loopbackOnly:
            return peer.isLoopback
        case .onLink(let subnet):
            guard let address = peer.ipv4 else { return false }
            return address.isLoopback || subnet.contains(address)
        case .only(let allowed):
            guard let address = peer.ipv4 else { return false }
            return allowed.contains(address)
        }
    }
}

package enum ListenerBinding: Sendable, Equatable {
    case loopbackIPv4
    case interface(name: String, ipv4: IPv4Literal, subnet: IPv4Subnet)

    package var host: String {
        switch self {
        case .loopbackIPv4: "127.0.0.1"
        case .interface(_, let ipv4, _): ipv4.description
        }
    }
}

package struct AdmissionPolicy: Sendable, Equatable {
    package var maxConnections: Int
    /// `nil` on loopback, where every client shares 127.0.0.1 and a per-peer cap would only lock out the CLI.
    package var maxPerPeer: Int?
    package var maxReadingHead: Int
    package var peers: PeerFilter

    package init(maxConnections: Int = 16, maxPerPeer: Int? = nil, maxReadingHead: Int = 8,
                 peers: PeerFilter = .loopbackOnly) {
        self.maxConnections = maxConnections
        self.maxPerPeer = maxPerPeer
        self.maxReadingHead = maxReadingHead
        self.peers = peers
    }
}

/// One IPv4 address on a local interface.
package struct NetworkInterfaceAddress: Sendable, Hashable {
    package let name: String
    package let ipv4: IPv4Literal
    package let prefixLength: Int

    package init(name: String, ipv4: IPv4Literal, prefixLength: Int) {
        self.name = name
        self.ipv4 = ipv4
        self.prefixLength = prefixLength
    }
}

package enum InterfaceCatalog {
    /// IPv4 addresses of interfaces that are up, from `getifaddrs`.
    package static func current() -> [NetworkInterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        return sequence(first: first, next: { $0.pointee.ifa_next }).compactMap(address(of:))
    }

    private static func address(of entry: UnsafeMutablePointer<ifaddrs>) -> NetworkInterfaceAddress? {
        let flags = Int32(entry.pointee.ifa_flags)
        guard flags & IFF_UP != 0, let socket = entry.pointee.ifa_addr,
              socket.pointee.sa_family == UInt8(AF_INET), let netmask = entry.pointee.ifa_netmask else { return nil }
        let host = socket.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
        let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
        let octets = withUnsafeBytes(of: host) { Array($0) }
        return NetworkInterfaceAddress(name: String(cString: entry.pointee.ifa_name),
                                       ipv4: IPv4Literal(octets: octets),
                                       prefixLength: UInt32(bigEndian: mask).nonzeroBitCount)
    }
}
