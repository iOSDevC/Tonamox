import Foundation
import os
#if os(iOS) || os(tvOS)
import UIKit
#endif

// MARK: - BackgroundTaskAsserting

/// Keeps the process running for a short task after it leaves the foreground (`UIApplication` background tasks).
package protocol BackgroundTaskAsserting: Sendable {
    /// `nil` when no time was granted. `onExpiration` must end the task.
    func begin(name: String, onExpiration: @escaping @Sendable () -> Void) -> Int?
    func end(_ identifier: Int)
    /// Called on the main actor each time the app enters the background, before any `begin`.
    @MainActor func prepare()
}

extension BackgroundTaskAsserting {
    @MainActor package func prepare() {}
}

// MARK: - SharedStorageSuspension

/// Whether the app is backgrounded with shared stores open, and what closes them. Lock-protected, so actors and
/// the main actor read it synchronously.
package final class SharedStorageSuspension: Sendable {
    package static let live = SharedStorageSuspension()

    private struct State: Sendable {
        var isSuspended = false
        var handlers: [UUID: @Sendable () async -> Void] = [:]
        var backgroundTasks: (any BackgroundTaskAsserting)?
    }

    private let locked = OSAllocatedUnfairLock(initialState: State())

    package init() {}

    package var isSuspended: Bool { locked.withLock { $0.isSuspended } }

    package func setSuspended(_ suspended: Bool) {
        locked.withLock { $0.isSuspended = suspended }
    }

    @discardableResult
    package func addHandler(_ handler: @escaping @Sendable () async -> Void) -> UUID {
        let id = UUID()
        locked.withLock { $0.handlers[id] = handler }
        return id
    }

    package func removeHandler(_ id: UUID) {
        locked.withLock { $0.handlers[id] = nil }
    }

    /// Runs every handler concurrently and returns when all are done.
    package func runHandlers() async {
        let handlers = locked.withLock { Array($0.handlers.values) }
        await withTaskGroup(of: Void.self) { group in
            for handler in handlers {
                group.addTask { await handler() }
            }
        }
    }

    package var backgroundTasks: (any BackgroundTaskAsserting)? {
        get { locked.withLock { $0.backgroundTasks } }
        set { locked.withLock { $0.backgroundTasks = newValue } }
    }

    /// Runs `body` inside its own background task while suspended, so a file or SQLite lock it takes is released
    /// before the app can be suspended; directly otherwise.
    package func performInBackgroundTask<T>(named name: String, _ body: () throws -> T) rethrows -> T {
        guard isSuspended, let tasks = backgroundTasks else { return try body() }
        let task = BackgroundTaskHandle(tasks: tasks)
        task.begin(name: name)
        defer { task.end() }
        return try body()
    }
}

// MARK: - BackgroundTaskHandle

/// One background task that ends exactly once, from its expiration handler or from its owner.
package final class BackgroundTaskHandle: Sendable {
    private let tasks: any BackgroundTaskAsserting
    private let identifier = OSAllocatedUnfairLock<Int?>(initialState: nil)

    package init(tasks: any BackgroundTaskAsserting) {
        self.tasks = tasks
    }

    package func begin(name: String, onExpiration: @escaping @Sendable () -> Void = {}) {
        let granted = tasks.begin(name: name) { [self] in
            onExpiration()
            end()
        }
        identifier.withLock { $0 = granted }
    }

    package func end() {
        guard let granted = identifier.withLock({ current -> Int? in
            defer { current = nil }
            return current
        }) else { return }
        tasks.end(granted)
    }

    package var isActive: Bool { identifier.withLock { $0 != nil } }
}

// MARK: - SharedStorageLifecycle

/// Releases the locks a shared container must not hold while the app is suspended (iOS kills it with 0xdead10cc).
///
/// On entering the background it marks storage suspended, runs the registered handlers (the SQLite stores close
/// their idle connections) inside a background task, and keeps that task while a download lock is held; when the
/// time runs out it relinquishes the download locks. Entering the foreground clears the flag. Installed by
/// ``TonamoxSharedStorage/configure(appGroup:)`` for an App Group scope; it observes UIKit on iOS and tvOS only,
/// the same set as ``BackgroundLifecycle``, so on macOS and visionOS nothing is ever suspended.
@MainActor
package final class SharedStorageLifecycle {

    package static let shared = SharedStorageLifecycle()

    /// `true` while an App Group app is in the background. Stores then open, run and close per call.
    nonisolated package static var isSuspended: Bool { SharedStorageSuspension.live.isSuspended }

    /// `handler` runs when the app enters the background; it should close what holds a lock in the container.
    @discardableResult
    nonisolated package static func addSuspensionHandler(_ handler: @escaping @Sendable () async -> Void) -> UUID {
        SharedStorageSuspension.live.addHandler(handler)
    }

    nonisolated package static func removeSuspensionHandler(_ id: UUID) {
        SharedStorageSuspension.live.removeHandler(id)
    }

    /// Runs `body` inside its own background task while suspended (iOS), directly otherwise.
    nonisolated package static func performInBackgroundTask<T>(named name: String,
                                                              _ body: () throws -> T) rethrows -> T {
        try SharedStorageSuspension.live.performInBackgroundTask(named: name, body)
    }

    static func installShared() {
        shared.startObserving()
    }

    /// Called after entering the foreground; retries what a locked device deferred.
    package var onForeground: (@MainActor () -> Void)?
    package private(set) var isInBackground = false

    private let notifications: NotificationCenter
    private let didEnterBackground: Notification.Name?
    private let willEnterForeground: Notification.Name?
    private let suspension: SharedStorageSuspension
    private let backgroundTasks: (any BackgroundTaskAsserting)?
    private let relinquishLocks: @Sendable () -> Void
    private let hasHeldLocks: @Sendable () -> Bool
    private let lockPollInterval: Duration
    private var isObserving = false
    private var closingTask: BackgroundTaskHandle?
    private var closing: Task<Void, Never>?

    private convenience init() {
        #if os(iOS) || os(tvOS)
        self.init(notificationCenter: .default,
                  didEnterBackground: UIApplication.didEnterBackgroundNotification,
                  willEnterForeground: UIApplication.willEnterForegroundNotification,
                  suspension: .live, backgroundTasks: UIKitBackgroundTasks())
        #else
        self.init(notificationCenter: .default, didEnterBackground: nil, willEnterForeground: nil,
                  suspension: .live, backgroundTasks: nil)
        #endif
        onForeground = { KeychainStore.migrateToAccessGroupIfNeeded() }
    }

    /// A lifecycle driven by arbitrary notifications and a fake task source, so tests run on any platform.
    package init(notificationCenter: NotificationCenter, didEnterBackground: Notification.Name?,
                 willEnterForeground: Notification.Name?, suspension: SharedStorageSuspension,
                 backgroundTasks: (any BackgroundTaskAsserting)?,
                 relinquishLocks: @escaping @Sendable () -> Void = { DownloadFileLock.relinquishAll() },
                 hasHeldLocks: @escaping @Sendable () -> Bool = { DownloadFileLock.hasHeldLocks },
                 lockPollInterval: Duration = .milliseconds(500)) {
        self.notifications = notificationCenter
        self.didEnterBackground = didEnterBackground
        self.willEnterForeground = willEnterForeground
        self.suspension = suspension
        self.backgroundTasks = backgroundTasks
        self.relinquishLocks = relinquishLocks
        self.hasHeldLocks = hasHeldLocks
        self.lockPollInterval = lockPollInterval
    }

    package func startObserving() {
        guard !isObserving, didEnterBackground != nil || willEnterForeground != nil else { return }
        isObserving = true
        suspension.backgroundTasks = backgroundTasks
        if let didEnterBackground {
            notifications.addObserver(forName: didEnterBackground, object: nil, queue: nil) { [weak self] _ in
                let lifecycle = self
                Self.onMainActor { lifecycle?.enterBackground() }
            }
        }
        if let willEnterForeground {
            notifications.addObserver(forName: willEnterForeground, object: nil, queue: nil) { [weak self] _ in
                let lifecycle = self
                Self.onMainActor { lifecycle?.enterForeground() }
            }
        }
    }

    /// Finishes when the handlers ran and the background task ended (tests).
    package func waitUntilSettled() async {
        await closing?.value
    }

    private func enterBackground() {
        isInBackground = true
        backgroundTasks?.prepare()
        suspension.setSuspended(true)
        let task = backgroundTasks.map(BackgroundTaskHandle.init(tasks:))
        let relinquish = relinquishLocks
        task?.begin(name: "Tonamox shared storage") {
            // UIKit calls this on the main thread, with the process about to be suspended.
            relinquish()
        }
        closingTask = task
        let suspension = suspension
        let hasHeldLocks = hasHeldLocks
        let interval = lockPollInterval
        closing = Task { @MainActor [weak self] in
            await suspension.runHandlers()
            while hasHeldLocks(), task?.isActive == true, self?.isInBackground == true {
                try? await Task.sleep(for: interval)
            }
            task?.end()
        }
    }

    private func enterForeground() {
        isInBackground = false
        suspension.setSuspended(false)
        closingTask?.end()
        closingTask = nil
        onForeground?()
    }

    /// UIKit posts these on the main thread; run synchronously there, because the app may be suspended soon after.
    nonisolated private static func onMainActor(_ work: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(work)
        } else {
            Task { @MainActor in work() }
        }
    }
}

// MARK: - UIKitBackgroundTasks

#if os(iOS) || os(tvOS)
/// `UIApplication` background tasks. UIKit declares begin and end nonisolated (safe from any thread), so the stores
/// call them from their own actors; only `UIApplication.shared` needs the main actor.
struct UIKitBackgroundTasks: BackgroundTaskAsserting {
    // Read in prepare(), not in init: configure runs in App.init, before UIApplication.shared exists, and a
    // message to that nil application returned an invalid task without asking UIKit.
    private let application = OSAllocatedUnfairLock<UIApplication?>(initialState: nil)

    @MainActor func prepare() {
        let shared = UIApplication.shared
        application.withLock { $0 = shared }
    }

    func begin(name: String, onExpiration: @escaping @Sendable () -> Void) -> Int? {
        guard let application = application.withLock({ $0 }) else { return nil }
        let identifier = application.beginBackgroundTask(withName: name, expirationHandler: onExpiration)
        return identifier == .invalid ? nil : identifier.rawValue
    }

    func end(_ identifier: Int) {
        guard let application = application.withLock({ $0 }) else { return }
        application.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: identifier))
    }
}
#endif
