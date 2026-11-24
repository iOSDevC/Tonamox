import Foundation

/// Shows a browser pairing request on the device that runs the server: the code, the requester's address and its
/// untrusted name, with a way to deny it (``TonamoxServer/denyPairing(_:)``). The code is never sent to the browser;
/// the person types it there.
@MainActor
public protocol PairingPresenter: AnyObject {
    func present(_ request: PairingRequest) async
    func dismiss(_ id: PairingRequest.ID)
}

public struct PairingRequest: Sendable, Identifiable, Equatable {
    public let id: UUID
    /// The requester's address.
    public let peer: String
    /// The name the page sent, filtered to printable text; never used for a decision.
    public let untrustedLabel: String
    /// 8 Crockford base32 characters shown as `XXXX-XXXX`.
    public let code: String
    public let expiresAt: Date

    /// `XXXX-XXXX`.
    public var displayCode: String {
        String(code.prefix(4)) + "-" + String(code.dropFirst(4))
    }
}

/// A paired browser as the host app shows it. Never carries the token.
public struct BrowserSessionInfo: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let label: String
    public let peer: String
    public let pairedAt: Date
    /// The absolute expiry; idle expiry comes earlier when the page is not used.
    public let expiresAt: Date
}

/// One browser token: digest only, bound to the peer that paired, memory only.
struct BrowserToken {
    let id: UUID
    let label: String
    let tokenHash: [UInt8]
    let peer: String
    let scopes: ClientScopes
    let createdAt: ContinuousClock.Instant
    var lastUsed: ContinuousClock.Instant
    let pairedAt: Date
    let expiresAt: Date

    var info: BrowserSessionInfo {
        BrowserSessionInfo(id: id, label: label, peer: peer, pairedAt: pairedAt, expiresAt: expiresAt)
    }
}

/// The single pending pairing: id and code kept as digests, so they are compared in constant time.
struct PairingSlot {
    let request: PairingRequest
    let idHash: [UInt8]
    let codeHash: [UInt8]
    let peer: String
    let expiresAt: ContinuousClock.Instant
    var attemptsLeft: Int
}

/// Who passed authentication: an API key or a browser token.
struct AuthenticatedClient {
    let id: UUID
    let label: String
    let scopes: ClientScopes
    let isBrowser: Bool
}
