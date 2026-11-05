import Foundation
#if os(macOS)
import Security
#endif

// MARK: - StoragePlatform

/// What decides whether an App Group can hold Tonamox's data in this process.
package enum StoragePlatform: Sendable, Equatable {
    /// iOS, iPadOS and visionOS: always sandboxed; the group container exists only when the app is entitled.
    case iOSFamily
    /// A sandboxed Mac app. `containerURL(forSecurityApplicationGroupIdentifier:)` answers even without the
    /// entitlement, so the entitlement is read from the code signature instead.
    case sandboxedMac(hasGroupEntitlement: Bool)
    /// A Mac process without App Sandbox: the CLI, `swift test`, the example Mac builds.
    case unsandboxedMac

    /// This process, for `appGroup`.
    static func current(appGroup: String) -> StoragePlatform {
        #if os(macOS)
        guard ModelStorage.isSandboxed else { return .unsandboxedMac }
        return .sandboxedMac(hasGroupEntitlement: entitledAppGroups().contains(appGroup))
        #else
        return .iOSFamily
        #endif
    }

    #if os(macOS)
    private static func entitledAppGroups() -> [String] {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString,
                                                         nil) else { return [] }
        return value as? [String] ?? []
    }
    #endif
}

// MARK: - StorageConsumer

/// The part of Tonamox that read the storage configuration first; named in the log when a late
/// ``TonamoxSharedStorage/configure(appGroup:)`` is ignored.
package enum StorageConsumer: String, Sendable {
    case models, records, imageRecords, keychain, conversations, documents, embeddings
    case scope = "TonamoxSharedStorage.scope"
}

// MARK: - SharedStorageResolution

/// Where each kind of Tonamox data lives in this process, fixed once per process.
package struct SharedStorageResolution: Sendable, Equatable {
    package let scope: SharedStorageScope
    /// The base under which `AuraLocal/Models`, `AuraLocal/conversations.sqlite`, `AuraLocal/embeddings` and
    /// `Tonamox/docs` live: the group's `Library/Application Support` for ``SharedStorageScope/appGroup(identifier:container:)``,
    /// otherwise the process's own Application Support.
    package let applicationSupport: URL
    /// The app's own Application Support when ``applicationSupport`` is the group's: the migration source and a
    /// read fallback. `nil` otherwise.
    package let privateApplicationSupport: URL?
    /// The keychain access group items are written to; `nil` keeps the default group.
    package let keychainAccessGroup: String?
    /// The prefix of the Darwin notification names; `nil` posts changes in this process only.
    package let signalPrefix: String?

    package init(scope: SharedStorageScope, applicationSupport: URL, privateApplicationSupport: URL?,
                 keychainAccessGroup: String?, signalPrefix: String?) {
        self.scope = scope
        self.applicationSupport = applicationSupport
        self.privateApplicationSupport = privateApplicationSupport
        self.keychainAccessGroup = keychainAccessGroup
        self.signalPrefix = signalPrefix
    }

    /// Today's behaviour: the process's own Application Support, no group anywhere.
    package static func standard(applicationSupport: URL) -> SharedStorageResolution {
        SharedStorageResolution(scope: .standard, applicationSupport: applicationSupport,
                                privateApplicationSupport: nil, keychainAccessGroup: nil, signalPrefix: nil)
    }

    /// The resolution table. Pure, so every row is unit-tested; `containerURL` is the answer of
    /// `containerURL(forSecurityApplicationGroupIdentifier:)` and is ignored on a non-sandboxed Mac.
    package static func resolve(appGroup: String?, platform: StoragePlatform, containerURL: URL?,
                                applicationSupport: URL) -> SharedStorageResolution {
        guard let appGroup else { return standard(applicationSupport: applicationSupport) }
        switch platform {
        case .unsandboxedMac:
            // Files already sit in the user-wide Application Support every process of the user shares.
            return SharedStorageResolution(scope: .userWide(identifier: appGroup),
                                           applicationSupport: applicationSupport, privateApplicationSupport: nil,
                                           keychainAccessGroup: nil, signalPrefix: appGroup)
        case .sandboxedMac(let hasGroupEntitlement):
            guard hasGroupEntitlement, let containerURL else { return standard(applicationSupport: applicationSupport) }
            // The file-based Mac keychain ignores access groups, so keychain items stay where they are.
            return group(appGroup, container: containerURL, applicationSupport: applicationSupport,
                         keychainAccessGroup: nil)
        case .iOSFamily:
            guard let containerURL else { return standard(applicationSupport: applicationSupport) }
            return group(appGroup, container: containerURL, applicationSupport: applicationSupport,
                         keychainAccessGroup: appGroup)
        }
    }

    private static func group(_ identifier: String, container: URL, applicationSupport: URL,
                              keychainAccessGroup: String?) -> SharedStorageResolution {
        SharedStorageResolution(
            scope: .appGroup(identifier: identifier, container: container),
            applicationSupport: container.appending(path: "Library/Application Support", directoryHint: .isDirectory),
            privateApplicationSupport: applicationSupport,
            keychainAccessGroup: keychainAccessGroup,
            signalPrefix: identifier)
    }

    // MARK: Derived locations

    /// Whether records live in a file every process of the group reads, instead of `UserDefaults.standard`.
    package var usesSharedRecords: Bool { scope != .standard }

    /// `<base>/AuraLocal`, the folder of the model root, the conversation store and the records files.
    package var auraLocalDirectory: URL {
        applicationSupport.appending(path: "AuraLocal", directoryHint: .isDirectory)
    }

    /// The app's own `AuraLocal` folder when data moved into the group.
    package var privateAuraLocalDirectory: URL? {
        privateApplicationSupport?.appending(path: "AuraLocal", directoryHint: .isDirectory)
    }

    /// The download records file in a shared scope; `nil` keeps `UserDefaults.standard`.
    package var downloadRecordsFile: URL? {
        usesSharedRecords ? auraLocalDirectory.appending(path: "download-records.json") : nil
    }

    /// The image model records file in a shared scope; `nil` keeps `UserDefaults.standard`.
    package var imageRecordsFile: URL? {
        usesSharedRecords ? auraLocalDirectory.appending(path: "image-model-records.json") : nil
    }

    /// The `flock` every read-modify-write of a records file holds, across processes.
    package var recordsLockFile: URL? {
        usesSharedRecords ? auraLocalDirectory.appending(path: "records.lock") : nil
    }
}
