import Foundation
import TonamoxHTTP

extension TonamoxServer {

    // MARK: - Binding

    /// The listener binding for the configured exposure, re-read from the current interface list so a stale
    /// choice never binds an address the device no longer has.
    func resolvedBinding() throws -> ListenerBinding {
        guard case .interface(let chosen) = configuration.exposure else { return .loopbackIPv4 }
        guard let current = currentAddress(of: chosen), let ipv4 = IPv4Literal(current.ipv4) else {
            log.record("interface \(chosen.name) has no longer the chosen address")
            throw ServerFailure.interfaceUnavailable(chosen.name)
        }
        return .interface(name: current.name, ipv4: ipv4,
                          subnet: IPv4Subnet(network: ipv4, prefixLength: current.prefixLength))
    }

    private func currentAddress(of chosen: ServerInterface) -> ServerInterface? {
        ServerInterface.available(from: network.interfaces()).first {
            $0.name == chosen.name && $0.ipv4 == chosen.ipv4
        }
    }

    var isInterfaceExposure: Bool { configuration.exposure != .loopback }

    // MARK: - Peer admission

    var isPeerLocking: Bool { isInterfaceExposure && configuration.peerLockPolicy == .firstPairedPeer }

    /// While nobody is locked, or another computer is allowed, the transport admits every on-link peer.
    var transportPeerRestriction: Set<IPv4Literal>? {
        guard isPeerLocking, !isLockOpen else { return nil }
        return Set(lockedPeers.compactMap(IPv4Literal.init))
    }

    private var isLockOpen: Bool {
        lockedPeers.isEmpty || (anotherComputerUntil.map { clock.monotonic() < $0 } ?? false)
    }

    /// The per-connection recheck on interface exposure: on-link subnet, then the peer lock. Loopback peers are
    /// this device. On loopback exposure the transport admits 127.0.0.1 only.
    func admitsConnection(from peer: PeerAddress) -> Bool {
        guard isInterfaceExposure, !peer.isLoopback else { return true }
        guard let subnet = boundSubnet, PeerFilter.onLink(subnet).admits(peer) else { return false }
        guard isPeerLocking else { return true }
        return lockedPeers.contains(peer.host) || isLockOpen
    }

    /// Called after a successful pairing or API-key use: locks the first computer (or the one more allowed by
    /// ``allowAnotherComputer()``). `false` when another computer won the lock first.
    func admitAuthenticated(_ peer: PeerAddress) -> Bool {
        guard isPeerLocking, !peer.isLoopback, !lockedPeers.contains(peer.host) else { return true }
        guard isLockOpen else {
            log.record("credential used from an address outside the peer lock", peer: peer)
            return false
        }
        lockedPeers.append(peer.host)
        anotherComputerUntil = nil
        transport?.restrictPeers(to: transportPeerRestriction)
        emit(.peerLocked(peer.host))
        log.record("peer locked", peer: peer)
        return true
    }

    /// `true` when no peer lock applies or the peer is one of the locked computers.
    func peerMatchesLock(_ peer: PeerAddress) -> Bool {
        guard isPeerLocking, !peer.isLoopback else { return true }
        return lockedPeers.contains(peer.host)
    }

    /// Interface exposure with ``PeerLock/firstPairedPeer``: lets one more computer pair or use a key during the
    /// next ``ServerLimits/pairingWindow``. Does nothing on loopback or without a lock.
    public func allowAnotherComputer() {
        guard isPeerLocking, !lockedPeers.isEmpty else { return }
        anotherComputerUntil = clock.monotonic() + configuration.limits.pairingWindow
        transport?.restrictPeers(to: nil)
        log.record("peer lock reopened for one computer")
    }

    func resetPeerLock() {
        lockedPeers = []
        anotherComputerUntil = nil
    }

    // MARK: - Interface loss

    func watchInterface() {
        lastActivity = clock.monotonic()
        guard isInterfaceExposure else { return }
        pathWatch = network.watchPaths { [weak self] in
            guard let self else { return }
            Task { await self.checkBoundInterface() }
        }
        watchIdle()
    }

    func stopWatchingInterface() {
        pathWatch?.cancel()
        pathWatch = nil
        idleWatch?.cancel()
        idleWatch = nil
    }

    /// Suspends with ``SuspendReason/interfaceLost(_:)`` when the bound interface lost or changed its address.
    /// The path watch (`NWPathMonitor` when live) calls it on every path change.
    package func checkBoundInterface() async {
        guard case .interface(let chosen) = configuration.exposure, case .listening = state else { return }
        guard currentAddress(of: chosen) == nil else { return }
        log.record("interface \(chosen.name) lost its address")
        await suspend(.interfaceLost(chosen.name))
    }

    // MARK: - Idle shutdown

    /// Only authenticated work counts: unauthenticated page or script fetches must not keep an exposed server up.
    func noteActivity() {
        lastActivity = clock.monotonic()
    }

    private func watchIdle() {
        idleWatch?.cancel()
        guard let idle = configuration.idleShutdown else { return }
        let tick = min(idle / 4, .seconds(5))
        idleWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tick)
                guard let self, await self.suspendIfIdle(idle) == false else { return }
            }
        }
    }

    /// `true` once the server is no longer listening (suspended now or earlier).
    private func suspendIfIdle(_ idle: Duration) async -> Bool {
        guard case .listening = state else { return true }
        guard generations.isEmpty, inflightBody == 0, clock.monotonic() - lastActivity >= idle else { return false }
        idleWatch = nil
        log.record("idle: suspended")
        await suspend(.idle)
        return true
    }
}
