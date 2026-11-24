import Foundation

public enum ServerState: Sendable, Equatable {
    case stopped
    case starting
    case listening(ServerEndpoint)
    case suspended(SuspendReason)
    case failed(ServerFailure)
}

public enum SuspendReason: Sendable, Equatable {
    /// The app left the foreground: the listener and every connection were closed (a suspended app's socket
    /// accepts but never answers).
    case appBackgrounded
    /// The bound interface (named) lost or changed its address; the server never rebinds to a new one by itself.
    case interfaceLost(String)
    /// Interface exposure with no answered request for ``ServerConfiguration/idleShutdown``.
    case idle
}

public enum ServerFailure: Error, Sendable, Equatable {
    case portInUse(UInt16)
    case alreadyRunning
    case listener(String)
    /// The chosen interface (named) is gone or no longer has the chosen address.
    case interfaceUnavailable(String)
}

public struct ServerEndpoint: Sendable, Equatable {
    public let host: String
    public let port: UInt16
    public let exposure: ServerExposure

    public var baseURL: URL {
        URL(string: "http://\(host):\(port)") ?? URL(fileURLWithPath: "/")
    }

    /// `true` for interface exposure: prompts, answers, credentials and ingested output are readable by anyone on
    /// that network (no TLS). `false` on loopback.
    public var isObservableByNetwork: Bool {
        if case .interface = exposure { return true }
        return false
    }
}

public enum ServerEvent: Sendable, Equatable {
    case stateChanged(ServerState)
    /// More than the global budget of wrong credentials in a minute: unknown credentials get 429 for a while.
    case authFlood
    case keyIssued(UUID)
    case keyRevoked(UUID)
    /// A browser asked to pair; ``TonamoxServer/pendingPairing`` holds it.
    case pairingRequested(UUID)
    /// The pending pairing ended without a session: denied, expired, wrong code three times, or closed.
    case pairingEnded(UUID)
    case browserPaired(UUID)
    case browserSessionEnded(UUID)
    /// Interface exposure: this address is now one of the computers allowed to connect.
    case peerLocked(String)
}

/// One answered request, without content.
public struct ServerActivity: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let answeredAt: Date
    public let route: String
    public let status: Int
    public let clientLabel: String?
    public let modelID: String?
}

/// An API key as the host app shows it. Never carries the secret.
public struct ClientInfo: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let label: String
    public let scopes: ClientScopes
    public let createdAt: Date
    public let expiresAt: Date?
    public let lastUsed: Date?
    public let lastPeer: String?
}

/// Who sent a served request: shown to the app, logged without content.
public struct ClientIdentity: Sendable, Equatable {
    public let clientID: UUID?
    public let label: String
    public let peer: String

    public init(clientID: UUID?, label: String, peer: String) {
        self.clientID = clientID
        self.label = label
        self.peer = peer
    }
}
