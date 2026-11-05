import Foundation
import os
import Security

/// Stores remote-provider API keys in the Keychain — never in source,
/// UserDefaults, or logs. Generic password, service `dev.auralocal.remote`,
/// account = provider id, accessible only when the device is unlocked and never
/// synced to iCloud (correct for local-first BYOK).
///
/// On iOS, once ``TonamoxSharedStorage/configure(appGroup:)`` applied a group, items are written to the group's
/// keychain access group so every app of the group reads them. Existing items are copied into the group once and
/// the private copy is kept for older builds; until that copy finished, reads fall back to any group the app has,
/// afterwards they read the group only, so a key another app deleted stays deleted. ``delete(for:)`` removes every
/// copy this app can reach. On macOS nothing changes (the login keychain has no access groups).
public enum KeychainStore {
    static let defaultService = "dev.auralocal.remote"

    public enum KeychainError: Error, LocalizedError {
        case status(OSStatus)
        public var errorDescription: String? {
            switch self {
            case .status(let s): "Keychain error (\(s))."
            }
        }
    }

    /// Store (or replace) the API key for `account`.
    public static func save(_ key: String, for account: String) throws {
        let location = currentLocation
        let data = Data(key.utf8)
        let status = backend.update(data, service: location.service, account: account,
                                    accessGroup: location.accessGroup)
        if status == errSecItemNotFound {
            let addStatus = backend.add(data, service: location.service, account: account,
                                        accessGroup: location.accessGroup)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.status(status)
        }
    }

    /// Read the API key for `account`, or `nil` if not configured.
    public static func read(for account: String) -> String? {
        let location = currentLocation
        var data: Data?
        if let group = location.accessGroup {
            data = backend.read(service: location.service, account: account, accessGroup: group).data
            if data == nil, currentMergeFlag.isSet {
                return nil
            }
        }
        if data == nil {
            data = backend.read(service: location.service, account: account, accessGroup: nil).data
        }
        return data.flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Remove the API key for `account`, every copy in every access group (no-op if absent).
    public static func delete(for account: String) {
        backend.delete(service: currentLocation.service, account: account, accessGroup: nil)
    }

    /// Whether a key is configured for `account`. Reads attributes only, so the macOS keychain does not ask
    /// another app for permission to reveal the secret.
    public static func hasKey(for account: String) -> Bool {
        let location = currentLocation
        let group = currentMergeFlag.isSet ? location.accessGroup : nil
        return backend.exists(service: location.service, account: account, accessGroup: group)
    }

    // MARK: Location

    /// Where items live: the service and, in an App Group scope on iOS, the access group.
    package struct Location: Sendable, Equatable {
        package let service: String
        package let accessGroup: String?

        package init(service: String, accessGroup: String?) {
            self.service = service
            self.accessGroup = accessGroup
        }
    }

    /// Replaces the service and access group for the current task (tests use their own service).
    @TaskLocal package static var locationOverride: Location?
    /// Replaces the Security framework for the current task (tests use an in-memory keychain).
    @TaskLocal package static var backendOverride: (any KeychainBackend)?

    private static let resolvedLocation = Location(
        service: defaultService,
        accessGroup: TonamoxSharedStorage.resolution(for: .keychain).keychainAccessGroup)

    static var currentLocation: Location { locationOverride ?? resolvedLocation }
    static var backend: any KeychainBackend { backendOverride ?? SecItemKeychainBackend() }

    /// Set in `UserDefaults.standard` once this app's items were copied into the group.
    static let mergedFlagKey = "dev.auralocal.keychain.mergedIntoShared"

    /// Whether this app finished copying its items into the group, kept in a `UserDefaults` key.
    // The reason for @unchecked: UserDefaults is thread-safe per call but not marked Sendable in this SDK.
    package struct MergeFlag: @unchecked Sendable {
        private let defaults: UserDefaults
        private let key: String

        package init(defaults: UserDefaults, key: String = KeychainStore.mergedFlagKey) {
            self.defaults = defaults
            self.key = key
        }

        package var isSet: Bool { defaults.bool(forKey: key) }
        package func set() { defaults.set(true, forKey: key) }
    }

    /// Replaces the merge flag for the current task (tests use their own `UserDefaults` suite).
    @TaskLocal package static var mergeFlagOverride: MergeFlag?
    static var currentMergeFlag: MergeFlag { mergeFlagOverride ?? MergeFlag(defaults: .standard) }

    // MARK: Migration

    /// What one migration pass did.
    package struct MigrationReport: Sendable, Equatable {
        package var copied: [String] = []
        package var alreadyShared: [String] = []
        /// Locked device or another transient refusal: retry later.
        package var isPending = false
        package var failures: [String] = []
    }

    static let log = Logger(subsystem: "dev.auralocal", category: "Keychain")

    /// Copies this app's items into the App Group access group once, ever: a later pass would copy back a key
    /// another app deleted from the group. Runs again (at launch and on foreground) only while a locked device
    /// kept it from finishing. A no-op without an access group.
    @discardableResult
    package static func migrateToAccessGroupIfNeeded() -> MigrationReport? {
        let location = currentLocation
        let flag = currentMergeFlag
        guard let group = location.accessGroup, !flag.isSet else { return nil }
        let report = migrateToAccessGroup(group, service: location.service, backend: backend)
        if !report.isPending {
            flag.set()
        }
        if !report.copied.isEmpty || report.isPending || !report.failures.isEmpty {
            log.notice("""
                keychain items copied into the App Group: \(report.copied.count); pending: \(report.isPending); \
                failed: \(report.failures.count)
                """)
        }
        return report
    }

    /// Adds a copy in `group` of every item of `service` that has none there; the original stays.
    package static func migrateToAccessGroup(_ group: String, service: String,
                                             backend: any KeychainBackend) -> MigrationReport {
        var report = MigrationReport()
        let listing = backend.list(service: service)
        if listing.status == errSecInteractionNotAllowed {
            report.isPending = true
            return report
        }
        let shared = Set(listing.items.filter { $0.accessGroup == group }.map(\.account))
        let accounts = Set(listing.items.map(\.account)).subtracting(shared).sorted()
        report.alreadyShared = shared.sorted()
        for account in accounts {
            copy(account, service: service, into: group, backend: backend, report: &report)
        }
        return report
    }

    private static func copy(_ account: String, service: String, into group: String, backend: any KeychainBackend,
                             report: inout MigrationReport) {
        let original = backend.read(service: service, account: account, accessGroup: nil)
        guard original.status != errSecInteractionNotAllowed else {
            report.isPending = true
            return
        }
        guard let data = original.data else {
            report.failures.append(account)
            return
        }
        switch backend.add(data, service: service, account: account, accessGroup: group) {
        case errSecSuccess: report.copied.append(account)
        case errSecDuplicateItem: report.alreadyShared.append(account)
        case errSecInteractionNotAllowed: report.isPending = true
        default: report.failures.append(account)
        }
    }
}

// MARK: - KeychainBackend

/// One generic-password item, without its secret.
package struct KeychainItem: Sendable, Equatable {
    package let account: String
    package let accessGroup: String?

    package init(account: String, accessGroup: String?) {
        self.account = account
        self.accessGroup = accessGroup
    }
}

/// The keychain operations ``KeychainStore`` needs. A `nil` access group means any group on reads and deletes,
/// and the default group on writes.
package protocol KeychainBackend: Sendable {
    func list(service: String) -> (status: OSStatus, items: [KeychainItem])
    func read(service: String, account: String, accessGroup: String?) -> (status: OSStatus, data: Data?)
    func exists(service: String, account: String, accessGroup: String?) -> Bool
    func add(_ data: Data, service: String, account: String, accessGroup: String?) -> OSStatus
    func update(_ data: Data, service: String, account: String, accessGroup: String?) -> OSStatus
    @discardableResult
    func delete(service: String, account: String, accessGroup: String?) -> OSStatus
}

/// The Security framework.
struct SecItemKeychainBackend: KeychainBackend {

    func list(service: String) -> (status: OSStatus, items: [KeychainItem]) {
        var query = match(service: service, account: nil, accessGroup: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let attributes = result as? [[String: Any]] ?? []
        return (status, attributes.compactMap(item(from:)))
    }

    func read(service: String, account: String, accessGroup: String?) -> (status: OSStatus, data: Data?) {
        var query = match(service: service, account: account, accessGroup: accessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, status == errSecSuccess ? result as? Data : nil)
    }

    func exists(service: String, account: String, accessGroup: String?) -> Bool {
        var query = match(service: service, account: account, accessGroup: accessGroup)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func add(_ data: Data, service: String, account: String, accessGroup: String?) -> OSStatus {
        var attributes = match(service: service, account: account, accessGroup: accessGroup)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    func update(_ data: Data, service: String, account: String, accessGroup: String?) -> OSStatus {
        let changes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        return SecItemUpdate(match(service: service, account: account, accessGroup: accessGroup) as CFDictionary,
                             changes as CFDictionary)
    }

    @discardableResult
    func delete(service: String, account: String, accessGroup: String?) -> OSStatus {
        SecItemDelete(match(service: service, account: account, accessGroup: accessGroup) as CFDictionary)
    }

    private func match(service: String, account: String?, accessGroup: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    private func item(from attributes: [String: Any]) -> KeychainItem? {
        guard let account = attributes[kSecAttrAccount as String] as? String else { return nil }
        return KeychainItem(account: account, accessGroup: attributes[kSecAttrAccessGroup as String] as? String)
    }
}
