import Foundation
import Network
import TonamoxHTTP

/// What an interface probably is, guessed from its BSD name. Not verified on every device (hotspot naming is open).
public enum InterfaceKind: Sendable, Hashable {
    case wifi
    case personalHotspot
    case wired
    case other
}

/// A local IPv4 address the server may listen on instead of 127.0.0.1. Only ``available()`` creates one, so an
/// app can never offer a cellular, VPN, peer-to-peer, CGNAT or public address.
public struct ServerInterface: Sendable, Hashable, Identifiable {
    public let name: String
    public let ipv4: String
    public let prefixLength: Int
    public let kind: InterfaceKind

    public var id: String { name + "/" + ipv4 }

    package init(name: String, ipv4: String, prefixLength: Int, kind: InterfaceKind) {
        self.name = name
        self.ipv4 = ipv4
        self.prefixLength = prefixLength
        self.kind = kind
    }

    /// Interfaces that are up with an RFC 1918 or 169.254/16 IPv4 address, excluding cellular (`pdp_ip*`),
    /// VPN and tunnels (`utun*`, `ipsec*`, `ppp*`, `gif*`, `stf*`, `tun*`, `tap*`), peer-to-peer (`awdl*`, `llw*`)
    /// and loopback. Read again before every choice: addresses change when the network does.
    public static func available() -> [ServerInterface] {
        available(from: InterfaceCatalog.current())
    }

    package static func available(from addresses: [NetworkInterfaceAddress]) -> [ServerInterface] {
        addresses.filter(isExposable).map(make)
    }

    static let excludedPrefixes = ["lo", "pdp_ip", "utun", "ipsec", "ppp", "gif", "stf", "tun", "tap", "awdl", "llw"]

    static func isExposable(_ address: NetworkInterfaceAddress) -> Bool {
        guard !excludedPrefixes.contains(where: address.name.hasPrefix) else { return false }
        guard (1...32).contains(address.prefixLength) else { return false }
        // CGNAT 100.64/10 (Tailscale-style VPNs) and public addresses fall outside both ranges.
        return address.ipv4.isPrivate || address.ipv4.isLinkLocal
    }

    private static func make(_ address: NetworkInterfaceAddress) -> ServerInterface {
        ServerInterface(name: address.name, ipv4: address.ipv4.description, prefixLength: address.prefixLength,
                        kind: guessKind(address.name))
    }

    /// `en0` is Wi-Fi on iPhone and most Macs; the hotspot's bridge is `bridge*`; other `en*` are USB or Ethernet.
    static func guessKind(_ name: String) -> InterfaceKind {
        if name == "en0" { return .wifi }
        if name.hasPrefix("bridge") { return .personalHotspot }
        if name.hasPrefix("en") { return .wired }
        return .other
    }

    var wireName: String {
        switch kind {
        case .wifi: "wifi"
        case .personalHotspot: "personal_hotspot"
        case .wired: "wired"
        case .other: "other"
        }
    }
}

/// The network facts the server reads, injectable for tests.
package struct ServerNetwork: Sendable {
    package var interfaces: @Sendable () -> [NetworkInterfaceAddress]
    /// Tests only: listen on 127.0.0.1 while applying the interface policy, since a test cannot connect from a
    /// second address.
    package var listensOnLoopback: Bool
    /// Starts watching path changes; live it is `NWPathMonitor`, tests fire the callback themselves.
    package var watchPaths: @Sendable (_ onChange: @escaping @MainActor @Sendable () -> Void) -> PathWatch

    package init(interfaces: @escaping @Sendable () -> [NetworkInterfaceAddress], listensOnLoopback: Bool,
                 watchPaths: @escaping @Sendable (_ onChange: @escaping @MainActor @Sendable () -> Void) -> PathWatch) {
        self.interfaces = interfaces
        self.listensOnLoopback = listensOnLoopback
        self.watchPaths = watchPaths
    }

    package static let live = ServerNetwork(interfaces: { InterfaceCatalog.current() }, listensOnLoopback: false,
                                            watchPaths: PathWatch.monitoring)
}

/// A running path watch; ``cancel()`` stops its callbacks.
package final class PathWatch: Sendable {
    private let stop: @Sendable () -> Void

    package init(cancel: @escaping @Sendable () -> Void) {
        stop = cancel
    }

    /// Calls back on the main actor whenever the system's network path changes.
    @Sendable package static func monitoring(_ onChange: @escaping @MainActor @Sendable () -> Void) -> PathWatch {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { _ in
            Task { @MainActor in onChange() }
        }
        monitor.start(queue: DispatchQueue(label: "TonamoxServer.PathWatch"))
        return PathWatch { monitor.cancel() }
    }

    func cancel() {
        stop()
    }
}
