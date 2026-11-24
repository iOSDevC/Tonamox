import Foundation
import Security
import Synchronization
import TerminalBridgeKit
import TonamoxServer

/// The SDK's keychain store pinned to this app's own access group, or memory when that group is unknown (an unpinned
/// query could read a list a sibling app planted); hides keys whose revocation did not reach the keychain.
nonisolated final class ServerKeyStore: ServerCredentialStore {
    let storage: APIKeyStorage
    private let inner: any ServerCredentialStore
    private let ledger = Mutex(State())

    private nonisolated struct State {
        var known: Set<UUID> = []
        var pending = PendingRevocations()
        var lastFailure: WriteFailure?
    }

    nonisolated struct WriteFailure: Sendable, Equatable {
        /// The keychain's OSStatus; nil for an encoding failure.
        let status: Int32?
    }

    init(accessGroup: String?) {
        if let accessGroup {
            inner = KeychainServerCredentials(account: "terminal.apikeys", accessGroup: accessGroup)
            storage = .keychain
        } else {
            inner = InMemoryServerCredentials()
            storage = .memoryOnly
        }
    }

    func loadKeys() throws -> [StoredAPIKey] {
        let keys = try inner.loadKeys()
        return ledger.withLock { current in
            current.known = Set(keys.map(\.id))
            let shown = current.pending.filter(keys.map(\.id))
            return keys.filter { shown.contains($0.id) }
        }
    }

    func save(_ keys: [StoredAPIKey]) throws {
        let pendingIDs = ledger.withLock { $0.pending.ids }
        let written = keys.filter { !pendingIDs.contains($0.id) }
        do {
            try inner.save(written)
            ledger.withLock { current in
                current.known = Set(written.map(\.id))
                current.pending.confirmSaved()
                current.lastFailure = nil
            }
        } catch {
            ledger.withLock { current in
                current.pending.recordFailedSave(known: current.known, attempted: Set(written.map(\.id)))
                current.lastFailure = WriteFailure(status: Self.status(of: error))
            }
            throw error
        }
    }

    /// The last write's error, cleared by reading it; nil when the last write succeeded.
    func takeLastFailure() -> WriteFailure? {
        ledger.withLock { current in
            defer { current.lastFailure = nil }
            return current.lastFailure
        }
    }

    static func status(of error: any Error) -> Int32? {
        if case ServerCredentialError.keychain(let status)? = error as? ServerCredentialError { return status }
        return nil
    }
}
