import Darwin
import Foundation
import os

// MARK: - DownloadGate

/// One writer per destination: a snapshot download holds `snapshots/main`, a file download its file; overlapping paths
/// wait in this process, identical ones across processes (``DownloadFileLock``). Not reentrant for overlapping paths.
actor DownloadGate {
    static let shared = DownloadGate()

    private struct Turn {
        let id: UInt64
        let path: [String]
        let request: String?
        var isHolding = false
        /// An earlier turn for the same path and request ended successfully while this one waited.
        var peerFinished = false
        var continuation: CheckedContinuation<Bool, any Error>?
    }

    /// Arrival order. A turn may hold once no earlier turn overlaps it, holding or still waiting.
    private var turns: [Turn] = []
    private var nextID: UInt64 = 0
    /// How often a caller retries a lock file another process holds.
    let lockRetryInterval: Duration

    init(lockRetryInterval: Duration = .milliseconds(250)) {
        self.lockRetryInterval = lockRetryInterval
    }

    /// Runs `body` once every earlier caller for an overlapping path is done. `body` learns whether one with the same
    /// `request` (a string naming what is fetched) succeeded while this one waited.
    func exclusive<T>(
        _ destination: URL,
        request: String? = nil,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (_ peerFinished: Bool) async throws -> T
    ) async throws -> T {
        let turn = try await enter(Self.components(of: destination), request: request)
        let lock: DownloadFileLock
        do {
            lock = try await DownloadFileLock.acquire(for: destination, retryInterval: lockRetryInterval)
        } catch {
            await leave(turn.id, succeeded: false)
            throw error
        }
        do {
            let value = try await body(turn.peerFinished)
            lock.release()
            await leave(turn.id, succeeded: true)
            return value
        } catch {
            lock.release()
            await leave(turn.id, succeeded: false)
            throw error
        }
    }

    /// Callers queued behind another for exactly `destination`.
    func waitingCount(at destination: URL) -> Int {
        let path = Self.components(of: destination)
        return turns.filter { !$0.isHolding && $0.path == path }.count
    }

    static func components(of destination: URL) -> [String] {
        destination.standardizedFileURL.pathComponents
    }

    // MARK: Queue

    private func enter(_ path: [String], request: String?) async throws -> (id: UInt64, peerFinished: Bool) {
        let id = nextID
        nextID += 1
        turns.append(Turn(id: id, path: path, request: request))
        if isClear(turns.count - 1) {
            turns[turns.count - 1].isHolding = true
            return (id, false)
        }
        let peerFinished = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
                guard let index = index(of: id) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if turns[index].isHolding {
                    continuation.resume(returning: turns[index].peerFinished)
                } else if Task.isCancelled {
                    turns.remove(at: index)
                    continuation.resume(throwing: CancellationError())
                    admitWaiting()
                } else {
                    turns[index].continuation = continuation
                }
            }
        } onCancel: {
            Task { await self.abandon(id) }
        }
        return (id, peerFinished)
    }

    /// A cancelled caller still queued leaves at once; one already holding ends through `leave`.
    private func abandon(_ id: UInt64) {
        guard let index = index(of: id), !turns[index].isHolding else { return }
        let continuation = turns.remove(at: index).continuation
        continuation?.resume(throwing: CancellationError())
        admitWaiting()
    }

    private func leave(_ id: UInt64, succeeded: Bool) {
        guard let index = index(of: id) else { return }
        let ended = turns.remove(at: index)
        if succeeded, let request = ended.request {
            for waiting in turns.indices where turns[waiting].path == ended.path && turns[waiting].request == request {
                turns[waiting].peerFinished = true
            }
        }
        admitWaiting()
    }

    private func admitWaiting() {
        for index in turns.indices where !turns[index].isHolding && isClear(index) {
            turns[index].isHolding = true
            let continuation = turns[index].continuation
            turns[index].continuation = nil
            continuation?.resume(returning: turns[index].peerFinished)
        }
    }

    private func isClear(_ index: Int) -> Bool {
        let path = turns[index].path
        return !turns[..<index].contains { Self.overlaps($0.path, path) }
    }

    private func index(of id: UInt64) -> Int? {
        turns.firstIndex { $0.id == id }
    }

    /// Equal paths, or one inside the other.
    static func overlaps(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.count <= rhs.count ? rhs.starts(with: lhs) : lhs.starts(with: rhs)
    }
}

// MARK: - DownloadFileLock

/// An advisory `flock(2)` on `<destination>.lock` for processes sharing the storage root. The kernel drops it with
/// the holder, so a crash leaves nothing stale; waiting polls a non-blocking `flock` so no thread blocks.
struct DownloadFileLock: Sendable {
    let lockFile: URL
    private let descriptor: Int32
    private let id: UInt64
    private let registry: DownloadLockRegistry
    /// Folders created to hold the lock file; removed on release if still empty.
    private let createdFolders: [URL]

    static let log = Logger(subsystem: "dev.auralocal", category: "DownloadGate")

    private init(lockFile: URL, descriptor: Int32, registry: DownloadLockRegistry, createdFolders: [URL]) {
        self.lockFile = lockFile
        self.descriptor = descriptor
        self.registry = registry
        self.id = registry.register(descriptor)
        self.createdFolders = createdFolders
    }

    static func lockFile(for destination: URL) -> URL {
        let target = destination.standardizedFileURL
        return target.deletingLastPathComponent()
            .appendingPathComponent(target.lastPathComponent + ".lock", isDirectory: false)
    }

    /// Whether this process holds any download lock; a backgrounded app keeps running while it does.
    static var hasHeldLocks: Bool { DownloadLockRegistry.shared.hasHeldLocks }

    /// Unlocks and closes every lock this process holds, for an app about to be suspended (iOS kills a suspended
    /// app holding a lock in a shared container). The interrupted transfers lose their cross-process guard.
    static func relinquishAll() {
        let count = DownloadLockRegistry.shared.relinquishAll()
        if count > 0 { log.notice("relinquished \(count) download locks before suspension") }
    }

    /// Waits until no other open file holds the lock on `destination`'s lock file, then holds it.
    static func acquire(for destination: URL, retryInterval: Duration,
                        registry: DownloadLockRegistry = .shared) async throws -> DownloadFileLock {
        let lockFile = lockFile(for: destination)
        var created: [URL] = []
        var reportedWait = false
        do {
            while true {
                try Task.checkCancellation()
                created += try createMissingFolders(above: lockFile)
                if let descriptor = try lockIfFree(lockFile) {
                    return held(lockFile, descriptor: descriptor, registry: registry, createdFolders: created)
                }
                if !reportedWait {
                    reportedWait = true
                    log.notice("waiting for another process writing \(destination.lastPathComponent, privacy: .public)")
                }
                try await Task.sleep(for: retryInterval)
            }
        } catch {
            removeEmpty(created)
            throw error
        }
    }

    enum Attempt {
        /// The lock file's folder does not exist, so nothing is being written there.
        case absent
        /// Another open file holds the lock.
        case busy
        case held(DownloadFileLock)
    }

    /// Takes the lock without waiting and without creating folders.
    static func attempt(for destination: URL, registry: DownloadLockRegistry = .shared) throws -> Attempt {
        let lockFile = lockFile(for: destination)
        guard FileManager.default.fileExists(atPath: lockFile.deletingLastPathComponent().path(percentEncoded: false))
        else { return .absent }
        guard let descriptor = try lockIfFree(lockFile) else { return .busy }
        return .held(held(lockFile, descriptor: descriptor, registry: registry, createdFolders: []))
    }

    /// Unlinks the lock file while still holding it, so a process that opened it starts over. A file recreated after a
    /// delete removed this one belongs to another holder and stays. A relinquished lock was already closed.
    func release() {
        defer { Self.removeEmpty(createdFolders) }
        guard registry.unregister(id) else { return }
        let path = lockFile.path(percentEncoded: false)
        if Self.isLinked(descriptor, at: path) {
            unlink(path)
        }
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    private static func held(_ lockFile: URL, descriptor: Int32, registry: DownloadLockRegistry,
                             createdFolders: [URL]) -> DownloadFileLock {
        DownloadFileLock(lockFile: lockFile, descriptor: descriptor, registry: registry, createdFolders: createdFolders)
    }

    /// The locked descriptor, or `nil` to retry: another open file holds the lock, or the file or its folder vanished.
    private static func lockIfFree(_ lockFile: URL) throws -> Int32? {
        let path = lockFile.path(percentEncoded: false)
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            let failure = errno
            // A releasing holder removed the folder it had created; it is created again on the next try.
            if failure == ENOENT { return nil }
            throw posixError(failure)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            close(descriptor)
            if failure == EWOULDBLOCK { return nil }
            throw posixError(failure)
        }
        // A holder unlinks the file before unlocking it; a lock on that old file guards nothing.
        guard isLinked(descriptor, at: path) else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    private static func isLinked(_ descriptor: Int32, at path: String) -> Bool {
        var opened = stat()
        var named = stat()
        guard fstat(descriptor, &opened) == 0, stat(path, &named) == 0 else { return false }
        return opened.st_dev == named.st_dev && opened.st_ino == named.st_ino
    }

    /// Creates the missing folders above `lockFile` and returns them, deepest first.
    private static func createMissingFolders(above lockFile: URL) throws -> [URL] {
        var missing: [URL] = []
        var folder = lockFile.deletingLastPathComponent()
        while folder.pathComponents.count > 1,
              !FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) {
            missing.append(folder)
            folder.deleteLastPathComponent()
        }
        if let deepest = missing.first {
            try FileManager.default.createDirectory(at: deepest, withIntermediateDirectories: true)
        }
        return missing
    }

    /// Deepest first; `rmdir` only removes an empty folder, so one another download writes into stays.
    private static func removeEmpty(_ folders: [URL]) {
        let deepestFirst = Set(folders).sorted { $0.pathComponents.count > $1.pathComponents.count }
        for folder in deepestFirst {
            rmdir(folder.path(percentEncoded: false))
        }
    }

    private static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}

// MARK: - DownloadLockRegistry

/// The descriptors of the download locks this process holds. Instances keep tests apart from the process-wide one.
final class DownloadLockRegistry: Sendable {
    static let shared = DownloadLockRegistry()

    private struct State: Sendable {
        var nextID: UInt64 = 0
        var held: [UInt64: Int32] = [:]
    }

    private let locked = OSAllocatedUnfairLock(initialState: State())

    func register(_ descriptor: Int32) -> UInt64 {
        locked.withLock { current in
            let id = current.nextID
            current.nextID += 1
            current.held[id] = descriptor
            return id
        }
    }

    /// `true` when the caller still owns the descriptor, `false` after ``relinquishAll()`` closed it.
    func unregister(_ id: UInt64) -> Bool {
        locked.withLock { $0.held.removeValue(forKey: id) != nil }
    }

    var hasHeldLocks: Bool { locked.withLock { !$0.held.isEmpty } }

    /// Returns how many locks were released.
    @discardableResult
    func relinquishAll() -> Int {
        let descriptors = locked.withLock { current -> [Int32] in
            defer { current.held.removeAll() }
            return Array(current.held.values)
        }
        for descriptor in descriptors {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        return descriptors.count
    }
}
