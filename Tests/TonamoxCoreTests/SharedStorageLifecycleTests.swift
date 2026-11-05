import Darwin
import Foundation
import os
import XCTest
@testable import TonamoxCore

/// Background tasks without UIKit: records what was begun and ended, and expires on demand.
final class FakeBackgroundTasks: BackgroundTaskAsserting, @unchecked Sendable {
    private let lock = NSLock()
    private var nextID = 1
    private var expirations: [Int: @Sendable () -> Void] = [:]
    private(set) var begun: [String] = []
    private(set) var ended: [Int] = []
    private let grantsOnlyAfterPrepare: Bool
    private var isPrepared = false

    /// `grantsOnlyAfterPrepare`: like UIKit before the app exists, nothing is granted until `prepare()` ran.
    init(grantsOnlyAfterPrepare: Bool = false) {
        self.grantsOnlyAfterPrepare = grantsOnlyAfterPrepare
    }

    @MainActor func prepare() {
        lock.withLock { isPrepared = true }
    }

    func begin(name: String, onExpiration: @escaping @Sendable () -> Void) -> Int? {
        lock.withLock {
            begun.append(name)
            guard isPrepared || !grantsOnlyAfterPrepare else { return nil }
            let id = nextID
            nextID += 1
            expirations[id] = onExpiration
            return id
        }
    }

    func end(_ identifier: Int) {
        lock.withLock {
            ended.append(identifier)
            expirations[identifier] = nil
        }
    }

    /// Calls every pending expiration handler, as UIKit does when background time runs out.
    func expire() {
        let handlers = lock.withLock { Array(expirations.values) }
        handlers.forEach { $0() }
    }

    var endedCount: Int { lock.withLock { ended.count } }
    var begunCount: Int { lock.withLock { begun.count } }
}

/// Backgrounding is simulated with a private `NotificationCenter`, so it runs on macOS where UIKit never posts.
@MainActor
final class SharedStorageLifecycleTests: XCTestCase {
    private let background = Notification.Name("test.shared.didEnterBackground")
    private let foreground = Notification.Name("test.shared.willEnterForeground")
    private let notifications = NotificationCenter()

    private func makeLifecycle(suspension: SharedStorageSuspension, tasks: FakeBackgroundTasks,
                               registry: DownloadLockRegistry = DownloadLockRegistry()) -> SharedStorageLifecycle {
        let lifecycle = SharedStorageLifecycle(
            notificationCenter: notifications, didEnterBackground: background, willEnterForeground: foreground,
            suspension: suspension, backgroundTasks: tasks,
            relinquishLocks: { registry.relinquishAll() }, hasHeldLocks: { registry.hasHeldLocks },
            lockPollInterval: .milliseconds(10))
        lifecycle.startObserving()
        return lifecycle
    }

    func testEnteringTheBackgroundPreparesTheTaskSourceBeforeBeginning() async {
        let suspension = SharedStorageSuspension()
        let tasks = FakeBackgroundTasks(grantsOnlyAfterPrepare: true)
        let lifecycle = makeLifecycle(suspension: suspension, tasks: tasks)

        notifications.post(name: background, object: nil)
        await lifecycle.waitUntilSettled()
        let perCall = suspension.performInBackgroundTask(named: "store call") { tasks.begunCount }

        XCTAssertEqual(perCall, 2)
        XCTAssertEqual(tasks.endedCount, 2)
    }

    func testBackgroundClosesStoresInsideABackgroundTaskAndForegroundResumes() async throws {
        let suspension = SharedStorageSuspension()
        let tasks = FakeBackgroundTasks()
        let closed = OSAllocatedUnfairLock(initialState: 0)
        suspension.addHandler { closed.withLock { $0 += 1 } }
        let lifecycle = makeLifecycle(suspension: suspension, tasks: tasks)
        var foregrounded = false
        lifecycle.onForeground = { foregrounded = true }

        notifications.post(name: background, object: nil)
        XCTAssertTrue(suspension.isSuspended)
        await lifecycle.waitUntilSettled()

        XCTAssertEqual(closed.withLock { $0 }, 1)
        XCTAssertEqual(tasks.begunCount, 1)
        XCTAssertEqual(tasks.endedCount, 1)

        notifications.post(name: foreground, object: nil)
        XCTAssertFalse(suspension.isSuspended)
        XCTAssertTrue(foregrounded)
        XCTAssertFalse(lifecycle.isInBackground)
    }

    func testExpirationRelinquishesHeldDownloadLocks() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "SharedStorageLifecycleTests-\(UUID().uuidString)/Application Support",
                       directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let registry = DownloadLockRegistry()
        let destination = folder.appending(path: "model.gguf")
        let lock = try await DownloadFileLock.acquire(for: destination, retryInterval: .milliseconds(10),
                                                      registry: registry)
        let suspension = SharedStorageSuspension()
        let tasks = FakeBackgroundTasks()
        let lifecycle = makeLifecycle(suspension: suspension, tasks: tasks, registry: registry)

        notifications.post(name: background, object: nil)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(tasks.endedCount, 0, "the task stays while a download lock is held")
        XCTAssertFalse(lockIsFree(lock.lockFile))

        tasks.expire()
        await lifecycle.waitUntilSettled()

        XCTAssertFalse(registry.hasHeldLocks)
        XCTAssertTrue(lockIsFree(lock.lockFile))
        XCTAssertEqual(tasks.endedCount, 1)
        lock.release()
    }

    func testPerCallBackgroundTasksOnlyWhileSuspended() {
        let suspension = SharedStorageSuspension()
        let tasks = FakeBackgroundTasks()
        suspension.backgroundTasks = tasks

        XCTAssertEqual(suspension.performInBackgroundTask(named: "store") { 1 }, 1)
        XCTAssertEqual(tasks.begunCount, 0)

        suspension.setSuspended(true)
        XCTAssertEqual(suspension.performInBackgroundTask(named: "store") { 2 }, 2)
        XCTAssertEqual(tasks.begun, ["store"])
        XCTAssertEqual(tasks.endedCount, 1)
    }

    func testRemovedHandlersDoNotRun() async {
        let suspension = SharedStorageSuspension()
        let ran = OSAllocatedUnfairLock(initialState: false)
        let id = suspension.addHandler { ran.withLock { $0 = true } }
        suspension.removeHandler(id)

        await suspension.runHandlers()

        XCTAssertFalse(ran.withLock { $0 })
    }

    /// Whether another open file can take the lock now, as another process would.
    private func lockIsFree(_ lockFile: URL) -> Bool {
        let descriptor = open(lockFile.path(percentEncoded: false), O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
        flock(descriptor, LOCK_UN)
        return true
    }
}
