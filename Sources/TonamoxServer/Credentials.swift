import Foundation
import Security
import Synchronization

/// What a credential store keeps about an API key: its SHA-256 digest and metadata, never the key.
public struct StoredAPIKey: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let label: String
    public let scopes: ClientScopes
    /// SHA-256 of the key text.
    public let keyHash: Data
    public let createdAt: Date
    public let expiresAt: Date?
    public var lastUsed: Date?
    public var lastPeer: String?

    public init(id: UUID, label: String, scopes: ClientScopes, keyHash: Data, createdAt: Date, expiresAt: Date?,
                lastUsed: Date? = nil, lastPeer: String? = nil) {
        self.id = id
        self.label = label
        self.scopes = scopes
        self.keyHash = keyHash
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.lastUsed = lastUsed
        self.lastPeer = lastPeer
    }

    /// What a host shows for this key; the digest is not part of it.
    public var info: ClientInfo {
        ClientInfo(id: id, label: label, scopes: scopes, createdAt: createdAt, expiresAt: expiresAt,
                   lastUsed: lastUsed, lastPeer: lastPeer)
    }
}

/// A newly issued key. ``secret`` exists only here: show it once, then drop this value.
public struct IssuedAPIKey: Sendable, CustomStringConvertible {
    public let client: ClientInfo
    /// `tnx_` followed by 43 base64url characters.
    public let secret: String
    /// The curl header line for a 0600 file used with `curl -H @file`.
    public var headerLine: String { "Authorization: Bearer \(secret)" }
    public var description: String { "IssuedAPIKey(\(client.label), secret redacted)" }
}

public protocol ServerCredentialStore: Sendable {
    func loadKeys() throws -> [StoredAPIKey]
    func save(_ keys: [StoredAPIKey]) throws
}

/// Keys for this process only (the default).
public struct InMemoryServerCredentials: ServerCredentialStore {
    private let storage = KeyStorage()

    public init() {}

    public func loadKeys() throws -> [StoredAPIKey] { storage.keys.withLock { $0 } }
    public func save(_ keys: [StoredAPIKey]) throws { storage.keys.withLock { $0 = keys } }

    private final class KeyStorage: Sendable {
        let keys = Mutex<[StoredAPIKey]>([])
    }
}

public enum ServerCredentialError: Error, Sendable, Equatable {
    case keychain(OSStatus)
}

/// Digests and metadata in the keychain, readable only on this device while it is unlocked and never synced.
public struct KeychainServerCredentials: ServerCredentialStore {
    public static let service = "dev.tonamox.server"
    public let account: String
    /// The keychain access group every query names; nil leaves it to the system (the app's default group for a
    /// write, every group the app can read for a match).
    public let accessGroup: String?

    /// Pass the app's own `accessGroup` when it shares an App Group or keychain group with other apps: without it a
    /// match also finds an item a sibling app wrote under the same service and account. With a group, macOS uses
    /// the data-protection keychain, which needs a signed app with that group in its entitlements.
    public init(account: String = "server.apikeys", accessGroup: String? = nil) {
        self.account = account
        self.accessGroup = accessGroup
    }

    public func loadKeys() throws -> [StoredAPIKey] {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(loadQuery as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else { throw ServerCredentialError.keychain(status) }
        return try Self.decode(data)
    }

    public func save(_ keys: [StoredAPIKey]) throws {
        let data = try Self.encode(keys)
        var status = SecItemUpdate(baseQuery as CFDictionary, updateAttributes(data) as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(addQuery(data) as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ServerCredentialError.keychain(status) }
    }

    /// Matches only this store's item: service, account, the access group when set, and never a synced item.
    package var baseQuery: [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: Self.service,
                                    kSecAttrAccount as String: account,
                                    kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
            // macOS ignores access groups and accessibility in the file-based keychain; iOS always uses this one.
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    package var loadQuery: [String: Any] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    /// Also resets the accessibility class, so an item written another way ends up device-only after one save.
    package func updateAttributes(_ data: Data) -> [String: Any] {
        [kSecValueData as String: data,
         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
    }

    package func addQuery(_ data: Data) -> [String: Any] {
        baseQuery.merging(updateAttributes(data)) { _, new in new }
    }

    /// The exact bytes stored in the keychain item.
    package static func encode(_ keys: [StoredAPIKey]) throws -> Data {
        try JSONEncoder().encode(keys)
    }

    package static func decode(_ data: Data) throws -> [StoredAPIKey] {
        try JSONDecoder().decode([StoredAPIKey].self, from: data)
    }
}
