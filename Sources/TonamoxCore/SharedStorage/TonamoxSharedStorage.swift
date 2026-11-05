import Foundation
import os

// MARK: - Public types

/// Where Tonamox keeps models, records, conversations, documents and keychain items in this process.
public enum SharedStorageScope: Sendable, Equatable {
    /// Not configured, or the group did not resolve: the process's own Application Support, as before.
    case standard
    /// Files, records, keychain items (iOS) and change signals go through the App Group container.
    case appGroup(identifier: String, container: URL)
    /// A Mac process without App Sandbox: files stay in `~/Library/Application Support`, which every process of the
    /// user already shares; records move to a file there and changes are signalled across processes.
    case userWide(identifier: String)
}

/// What ``TonamoxSharedStorage/configure(appGroup:)`` did.
public enum SharedStorageConfiguration: Sendable, Equatable {
    /// The scope this process now uses.
    case applied(SharedStorageScope)
    /// The group did not resolve (missing entitlement, no container); the scope stays ``SharedStorageScope/standard``.
    case unavailable(appGroup: String)
    /// Nothing changed: storage was used before (`firstUse` names what used it), or another group was configured.
    case ignored(current: SharedStorageScope, firstUse: String)
}

/// The kind of shared data that changed; the payload of ``TonamoxSharedStorage/didChangeNotification``.
public enum SharedStorageChange: String, Sendable, CaseIterable {
    case models, conversations, documents
}

// MARK: - TonamoxSharedStorage

/// Opt-in sharing of Tonamox's data between the apps of one App Group.
///
/// Call ``configure(appGroup:)`` first in `App.init`, before any other Tonamox call. Without it, or when the group
/// does not resolve, every path stays exactly where it was. On iOS and in a sandboxed Mac app with the group
/// entitlement, data lives in the group container and existing private data is merged in once, without deleting
/// it (model files are renamed, never copied). A Mac app without App Sandbox keeps its files user-wide and only
/// moves its records to a shared file.
public enum TonamoxSharedStorage {

    /// Opts this process into the App Group. The first storage access fixes the configuration: a call after it,
    /// or with another identifier, changes nothing and returns ``SharedStorageConfiguration/ignored(current:firstUse:)``.
    /// The same identifier again returns the first answer.
    @MainActor @discardableResult
    public static func configure(appGroup identifier: String) -> SharedStorageConfiguration {
        let outcome = configurator.configure(appGroup: identifier)
        if outcome.sealedNow, outcome.resolution.scope != .standard {
            activate(outcome.resolution)
        }
        return outcome.configuration
    }

    /// Where Tonamox keeps data in this process. Reading it fixes the configuration, like any storage access.
    public static var scope: SharedStorageScope { resolution(for: .scope).scope }

    /// Posted on the main queue after shared data changed, in this process or in another one of the group.
    public static let didChangeNotification = Notification.Name("dev.auralocal.sharedStorage.didChange")

    /// The change a ``didChangeNotification`` carries.
    public static func change(of notification: Notification) -> SharedStorageChange? {
        (notification.userInfo?[changeKey] as? String).flatMap(SharedStorageChange.init(rawValue:))
    }

    /// Signals `change` to every process of the group, this one included, when a group is configured; otherwise
    /// posts ``didChangeNotification`` in this process only. Either way observers hear it on the main queue.
    public static func postChange(_ change: SharedStorageChange) {
        if let prefix = configurator.sealedResolution?.signalPrefix {
            SharedStorageSignal.post(change, prefix: prefix)
        } else {
            SharedStorageSignal.postLocally(change, center: .default)
        }
    }

    // MARK: Package

    /// The resolution every storage user reads. The first read before ``configure(appGroup:)`` fixes
    /// ``SharedStorageScope/standard``.
    package static func resolution(for consumer: StorageConsumer) -> SharedStorageResolution {
        configurator.resolution(for: consumer)
    }

    static let changeKey = "change"
    static let log = Logger(subsystem: "dev.auralocal", category: "SharedStorage")
    static let configurator = SharedStorageConfigurator.live()

    /// Runs after the lock is released: these read the resolution themselves.
    @MainActor
    private static func activate(_ resolution: SharedStorageResolution) {
        ModelStorage.prepareSharedRoot()
        if resolution.keychainAccessGroup != nil {
            KeychainStore.migrateToAccessGroupIfNeeded()
        }
        if let prefix = resolution.signalPrefix {
            configurator.storeSignalTokens(SharedStorageSignal.observe(prefix: prefix, center: .default))
        }
        if case .appGroup = resolution.scope {
            SharedStorageLifecycle.installShared()
        }
    }
}

// MARK: - SharedStorageConfigurator

/// The sealed-once storage configuration. Instances keep tests from sharing state with the process-wide one.
package final class SharedStorageConfigurator: Sendable {

    package struct Environment: Sendable {
        package var platform: @Sendable (String) -> StoragePlatform
        package var containerURL: @Sendable (String) -> URL?
        package var applicationSupport: @Sendable () -> URL

        package init(platform: @escaping @Sendable (String) -> StoragePlatform,
                     containerURL: @escaping @Sendable (String) -> URL?,
                     applicationSupport: @escaping @Sendable () -> URL) {
            self.platform = platform
            self.containerURL = containerURL
            self.applicationSupport = applicationSupport
        }
    }

    package struct Outcome: Sendable {
        package let configuration: SharedStorageConfiguration
        package let resolution: SharedStorageResolution
        /// This call fixed the resolution, so the caller runs the one-time work (merges, observers).
        package let sealedNow: Bool
    }

    private struct State: Sendable {
        var resolution: SharedStorageResolution?
        var firstUse: String?
        var configuredGroup: String?
        var firstConfiguration: SharedStorageConfiguration?
        var signalTokens: [Int32] = []
    }

    private let system: Environment
    private let locked = OSAllocatedUnfairLock(initialState: State())

    package init(environment: Environment) {
        self.system = environment
    }

    static func live() -> SharedStorageConfigurator {
        SharedStorageConfigurator(environment: Environment(
            platform: { StoragePlatform.current(appGroup: $0) },
            containerURL: { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) },
            applicationSupport: { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }))
    }

    package func configure(appGroup identifier: String) -> Outcome {
        let candidate = proposedResolution(for: identifier)
        let outcome = locked.withLock { current -> Outcome in
            if let sealed = current.resolution {
                if current.configuredGroup == identifier, let first = current.firstConfiguration {
                    return Outcome(configuration: first, resolution: sealed, sealedNow: false)
                }
                let firstUse = current.configuredGroup.map { "configure(appGroup: \($0))" } ?? current.firstUse ?? "storage"
                return Outcome(configuration: .ignored(current: sealed.scope, firstUse: firstUse), resolution: sealed,
                               sealedNow: false)
            }
            let configuration: SharedStorageConfiguration = candidate.scope == .standard
                ? .unavailable(appGroup: identifier) : .applied(candidate.scope)
            current.resolution = candidate
            current.configuredGroup = identifier
            current.firstConfiguration = configuration
            return Outcome(configuration: configuration, resolution: candidate, sealedNow: true)
        }
        Self.report(outcome, identifier: identifier)
        return outcome
    }

    package func resolution(for consumer: StorageConsumer) -> SharedStorageResolution {
        if let sealed = sealedResolution { return sealed }
        let standard = SharedStorageResolution.standard(applicationSupport: system.applicationSupport())
        return locked.withLock { current in
            if let sealed = current.resolution { return sealed }
            current.resolution = standard
            current.firstUse = consumer.rawValue
            return standard
        }
    }

    /// The resolution if something fixed it already; never fixes it.
    package var sealedResolution: SharedStorageResolution? {
        locked.withLock { $0.resolution }
    }

    func storeSignalTokens(_ tokens: [Int32]) {
        locked.withLock { $0.signalTokens += tokens }
    }

    /// Computed outside the lock: it asks FileManager and the code signature.
    private func proposedResolution(for identifier: String) -> SharedStorageResolution {
        let platform = system.platform(identifier)
        let container: URL? = platform == .unsandboxedMac ? nil : system.containerURL(identifier)
        return SharedStorageResolution.resolve(appGroup: identifier, platform: platform, containerURL: container,
                                               applicationSupport: system.applicationSupport())
    }

    private static func report(_ outcome: Outcome, identifier: String) {
        let log = TonamoxSharedStorage.log
        switch outcome.configuration {
        case .applied(let scope) where outcome.sealedNow:
            log.notice("configure(appGroup: \(identifier, privacy: .public)) applied: \(String(describing: scope), privacy: .public)")
        case .unavailable where outcome.sealedNow:
            log.error("""
                configure(appGroup: \(identifier, privacy: .public)): the group did not resolve (entitlement or \
                container missing); storage stays private
                """)
        case .ignored(_, let firstUse):
            log.fault("configure(appGroup: \(identifier, privacy: .public)) after \(firstUse, privacy: .public) used storage; ignored")
        default:
            break
        }
    }
}
