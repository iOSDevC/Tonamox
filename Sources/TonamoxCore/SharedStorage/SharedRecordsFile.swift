import Darwin
import Foundation
import os

// MARK: - SharedRecordsFile

/// A `[key: encoded record]` dictionary in a JSON file that every process of a group reads and writes.
///
/// `UserDefaults` suites are not used for this: each process caches them, so a read under a lock can be stale and a
/// write can drop another app's record. Every read-modify-write here holds an exclusive `flock` on a lock file,
/// reads the file fresh and replaces it atomically; plain reads need no lock.
package struct SharedRecordsFile: Sendable {
    package let file: URL
    package let lockFile: URL

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private static let decoder = JSONDecoder()
    static let log = Logger(subsystem: "dev.auralocal", category: "SharedRecords")

    package init(file: URL, lockFile: URL) {
        self.file = file
        self.lockFile = lockFile
    }

    /// The stored records; empty when the file is missing or unreadable.
    package func read() -> [String: Data] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        do {
            return try Self.decoder.decode([String: Data].self, from: data)
        } catch {
            Self.log.error("unreadable \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    /// Applies `body` to the current records while holding the lock, and writes them when `body` returns `true`.
    /// Returns whether anything was written.
    @discardableResult
    package func update(_ body: (inout [String: Data]) -> Bool) throws -> Bool {
        try withLock {
            var records = try readForUpdate()
            guard body(&records) else { return false }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Self.encoder.encode(records).write(to: file, options: .atomic)
            return true
        }
    }

    /// The stored records, for a write that replaces the file. A file that cannot be read throws (a locked device
    /// may refuse it); one that does not decode is moved aside, so the write does not drop every app's records
    /// for good.
    private func readForUpdate() throws -> [String: Data] {
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return [:] }
        let data = try Data(contentsOf: file)
        do {
            return try Self.decoder.decode([String: Data].self, from: data)
        } catch {
            let aside = file.deletingLastPathComponent()
                .appendingPathComponent("\(file.lastPathComponent).corrupt-\(Int(Date().timeIntervalSince1970))")
            try FileManager.default.moveItem(at: file, to: aside)
            Self.log.error("""
                moved undecodable \(file.lastPathComponent, privacy: .public) aside to \
                \(aside.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)
                """)
            return [:]
        }
    }

    /// Copies the records stored in `defaults` under `keys` (a later key wins) into the file once, keeping entries
    /// the file already has, then sets `flagKey` in `defaults`. The keys stay, for builds that still read them.
    /// Returns how many records were added.
    @discardableResult
    package func mergeOnce(from defaults: UserDefaults, keys: [String], flagKey: String) -> Int {
        guard !defaults.bool(forKey: flagKey) else { return 0 }
        var legacy: [String: Data] = [:]
        for key in keys {
            legacy.merge(defaults.dictionary(forKey: key) as? [String: Data] ?? [:]) { _, later in later }
        }
        var added = 0
        do {
            try update { records in
                let missing = legacy.filter { records[$0.key] == nil }
                records.merge(missing) { current, _ in current }
                added = missing.count
                return !missing.isEmpty
            }
        } catch {
            Self.log.error("could not merge records into \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return 0
        }
        defaults.set(true, forKey: flagKey)
        if added > 0 {
            Self.log.notice("merged \(added) records into \(file.lastPathComponent, privacy: .public)")
        }
        return added
    }

    /// Holds an exclusive `flock` on ``lockFile`` around `body`. The lock is per open file, so it also orders
    /// threads of this process; held only for a synchronous read-modify-write.
    package func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: lockFile.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let path = lockFile.path(percentEncoded: false)
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw Self.posixError(errno) }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw Self.posixError(errno) }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
