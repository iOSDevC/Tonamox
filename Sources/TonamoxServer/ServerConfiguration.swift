import Foundation

/// How a ``TonamoxServer`` listens and what it allows.
public struct ServerConfiguration: Sendable, Equatable {
    /// Choose ``ServerExposure/interface(_:)`` explicitly for each start; never persist it as a default.
    public var exposure: ServerExposure = .loopback
    /// The port is kept for the server's lifetime: a resume rebinds the same one or fails.
    public var port: PortChoice = .fixed(47830)
    public var limits = ServerLimits()
    public var features: ServerFeatures = [.openAIAPI]
    /// Extra `Host` values accepted, each an exact `host:port` (for a USB forwarder on another local port).
    public var extraHostNames: [String] = []
    /// Interface exposure only: which computers may connect after the first one pairs or uses a key.
    public var peerLockPolicy: PeerLock = .firstPairedPeer
    /// Interface exposure only: with no answered request for this long the server suspends with
    /// ``SuspendReason/idle``. `nil` keeps it listening.
    public var idleShutdown: Duration? = .seconds(900)
    /// Who runs the server; the page's guide uses it to say where keys come from and when the server stops.
    public var hostedBy: ServerHost = .app
    public var serverName: String

    public init(serverName: String) {
        self.serverName = serverName
    }
}

/// Where the server listens.
public enum ServerExposure: Sendable, Equatable {
    /// 127.0.0.1: same-device clients, and a USB forwarder that binds 127.0.0.1 on the computer.
    case loopback
    /// That interface's IPv4 address only (Wi-Fi, Personal Hotspot, USB or Ethernet), never 0.0.0.0. Without TLS
    /// everything sent on it, credentials included, is readable by anyone on that network.
    case interface(ServerInterface)
}

public enum ServerHost: Sendable, Equatable {
    /// An app on the device: it shows each API key once and serves only in the foreground.
    case app
    /// `tonamox serve`: the key goes to a 0600 header file and is valid until the command ends.
    case commandLine
}

public enum PeerLock: Sendable, Equatable {
    /// Any on-link computer may connect; each still needs a credential.
    case none
    /// After the first successful pairing or API-key use, only that computer may connect;
    /// ``TonamoxServer/allowAnotherComputer()`` admits one more.
    case firstPairedPeer
}

public enum PortChoice: Sendable, Hashable {
    /// This port or fail with ``ServerFailure/portInUse(_:)``.
    case fixed(UInt16)
    /// This port on the first start, else an ephemeral one; a resume keeps whichever was bound.
    case preferred(UInt16)
    case ephemeral
}

public struct ServerFeatures: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// `GET /v1/models`, `GET /v1/models/{id}`, `POST /v1/chat/completions`.
    public static let openAIAPI = ServerFeatures(rawValue: 1 << 0)
    /// `GET /` (chat page and guide), `POST /pair`, `POST /pair/{id}`, `GET /api/session`,
    /// `POST /api/session/logout`. Pairing also needs a ``PairingPresenter`` and an armed window. Opt-in.
    public static let browserPage = ServerFeatures(rawValue: 1 << 1)
    /// `POST /i/{ticket}`: command output posted with a one-time ticket from ``TonamoxServer/ingest``. Opt-in.
    public static let ingest = ServerFeatures(rawValue: 1 << 2)
    /// `GET /s/{name}`: the fixed ``HelperScript``s, unauthenticated. Opt-in.
    public static let scripts = ServerFeatures(rawValue: 1 << 3)
}

/// Every limit the server enforces. The defaults are the documented ones.
public struct ServerLimits: Sendable, Equatable {
    public var maxConnections = 16
    public var maxConnectionsReadingHead = 8
    /// Interface exposure only; on loopback every client is 127.0.0.1.
    public var maxConnectionsPerPeer = 4
    public var headTimeout: Duration = .seconds(5)
    public var bodyTimeoutBase: Duration = .seconds(10)
    public var bodyTimeoutPer64KiB: Duration = .seconds(1)
    public var bodyTimeoutMax: Duration = .seconds(60)
    /// Request bodies being read at once, across all connections.
    public var inflightBodyBytes: Int = Self.defaultInflightBodyBytes
    public var writeStall: Duration = .seconds(30)
    public var chatBodyBytes = 1 << 20
    public var maxMessages = 256
    public var maxCharactersPerMessage = 200_000
    public var maxJSONDepth = 16
    public var defaultMaxTokens = 1024
    /// Raising it also raises the text a slow reader can make the server buffer.
    public var maxTokensCap = 4096
    /// Reasoning tokens a request without `reasoning_effort` may spend before its block is closed, on top of the
    /// answer's `max_tokens`.
    public var defaultReasoningBudget = 1024
    /// Ceiling for every reasoning budget, the default and `reasoning_effort: "high"` included.
    public var maxReasoningBudget = 4096
    public var queueWait: Duration = .seconds(30)
    public var chatRequestsPerMinute = 30
    public var keepAliveInterval: Duration = .seconds(15)
    public var globalAuthFailuresPerMinute = 30
    public var authFloodPause: Duration = .seconds(60)
    /// Per-IP budget; applies only to interface exposure, where peers have distinct addresses.
    public var authFailuresPerMinutePerIP = 5
    public var authFailureBlock: Duration = .seconds(300)
    public var ingestDefaultBytes = 1 << 20
    public var ingestMaxBytes = 16 << 20
    public var maxLiveTickets = 32
    /// Ingest posts per minute per peer address; on loopback every local client shares one budget.
    public var ingestPostsPerMinute = 30
    /// Shorter than the chat body deadline: a racer that stalls holds the ticket's reservation until it expires.
    public var ingestBodyTimeoutBase: Duration = .seconds(5)
    public var ingestBodyTimeoutPer256KiB: Duration = .seconds(1)
    public var ingestBodyTimeoutMax: Duration = .seconds(20)
    /// Script fetches per minute per peer address.
    public var scriptFetchesPerMinute = 10
    /// How long ``TonamoxServer/openPairingWindow()`` keeps `POST /pair` open; one pairing per window.
    public var pairingWindow: Duration = .seconds(120)
    public var pairingRequestTTL: Duration = .seconds(120)
    public var pairingCodeAttempts = 3
    public var pairingRequestsPerMinutePerIP = 3
    public var pairingRequestsPerMinute = 20
    public var pairingBodyBytes = 1024
    public var browserSessionIdle: Duration = .seconds(30 * 60)
    public var browserSessionLifetime: Duration = .seconds(8 * 3600)

    public init() {}

    #if os(macOS)
    public static let defaultInflightBodyBytes = 32 << 20
    #else
    public static let defaultInflightBodyBytes = 8 << 20
    #endif

    func bodyTimeout(for length: Int) -> Duration {
        let extra = bodyTimeoutPer64KiB * (length / (64 * 1024))
        return min(bodyTimeoutBase + extra, bodyTimeoutMax)
    }

    func ingestBodyTimeout(for length: Int) -> Duration {
        let extra = ingestBodyTimeoutPer256KiB * (length / (256 * 1024))
        return min(ingestBodyTimeoutBase + extra, ingestBodyTimeoutMax)
    }
}

public struct ClientScopes: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let chat = ClientScopes(rawValue: 1 << 0)
    public static let models = ClientScopes(rawValue: 1 << 1)
    /// `GET /api/session` and `POST /api/session/logout`; browser tokens carry it.
    public static let session = ClientScopes(rawValue: 1 << 2)
}
