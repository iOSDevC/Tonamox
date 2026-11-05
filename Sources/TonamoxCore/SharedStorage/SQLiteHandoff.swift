import Darwin
import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - SQLiteHandoff

/// Brings a database the app kept privately into the shared copy once, without changing the private file.
///
/// The legacy file is only ever opened read-only and snapshotted with `VACUUM INTO`, which includes what its `-wal`
/// holds and leaves its journal mode alone. Without a shared copy the snapshot is renamed into place; otherwise the
/// shared copy gets the legacy rows with `INSERT OR IGNORE` over the columns both sides have, so the shared triggers
/// fill its full-text index. A `<name>.merged-into-group` marker next to the legacy file then stops every later
/// merge, so rows deleted from the shared copy never come back. Older builds keep reading the legacy file.
package enum SQLiteHandoff {

    /// How long a connection to a shared database waits for another process's lock before `SQLITE_BUSY`.
    package static let busyTimeoutMilliseconds: Int32 = 3000

    package static let markerSuffix = ".merged-into-group"

    /// A table to merge, in order. `filter` is a `WHERE` clause over the legacy rows (unqualified columns are the
    /// legacy table's; the shared schema is `main`).
    package struct Table: Sendable {
        package let name: String
        package let filter: String?

        package init(_ name: String, filter: String? = nil) {
            self.name = name
            self.filter = filter
        }
    }

    /// Whether the legacy rows belong in the shared copy. `merge` may finish the job inside the merge transaction.
    package enum Decision {
        case merge(then: ((_ legacy: Database, _ shared: Database) throws -> Void)?)
        case keep(reason: String)
    }

    package enum Outcome: Equatable, Sendable {
        /// No legacy file.
        case noLegacy
        /// The marker says it was merged before.
        case alreadyMerged
        /// There was no shared copy; the legacy snapshot became it.
        case copied
        /// The legacy rows were added to the shared copy; `rows` were new.
        case merged(rows: Int)
        /// The decision kept the legacy rows out; no marker, so a later launch decides again.
        case kept(String)
        /// Nothing changed; no marker, so a later launch retries.
        case failed(String)
    }

    /// One schema of an open connection, for a ``Decision``.
    package struct Database {
        fileprivate let handle: OpaquePointer
        /// `main`, or `legacy` for the snapshot attached to the shared connection.
        package let schema: String

        package func tableExists(_ name: String) throws -> Bool {
            try integer("SELECT count(*) FROM \(schema).sqlite_master WHERE type = 'table' AND name = ?;",
                        bindings: [name]) > 0
        }

        package func integer(_ sql: String, bindings: [String] = []) throws -> Int {
            try SQLiteHandoff.firstColumn(sql, bindings: bindings, in: handle) { Int(sqlite3_column_int64($0, 0)) } ?? 0
        }

        package func text(_ sql: String, bindings: [String] = []) throws -> String? {
            try SQLiteHandoff.firstColumn(sql, bindings: bindings, in: handle) { statement in
                sqlite3_column_text(statement, 0).map { String(cString: $0) }
            } ?? nil
        }

        package func execute(_ sql: String, bindings: [String] = []) throws {
            try SQLiteHandoff.run(sql, bindings: bindings, in: handle)
        }
    }

    /// The marker that records `legacy` as merged.
    package static func markerURL(for legacy: URL) -> URL {
        legacy.deletingLastPathComponent().appending(path: legacy.lastPathComponent + markerSuffix)
    }

    /// Hands `legacy` over to `shared` once. Never deletes, renames or writes `legacy`. `decide` runs only when a
    /// shared copy exists: once on the legacy file to skip the snapshot early, then inside the merge transaction.
    @discardableResult
    package static func handOff(
        legacy: URL,
        into shared: URL,
        tables: [Table],
        decide: (_ legacy: Database, _ shared: Database) throws -> Decision = { _, _ in .merge(then: nil) },
        fileManager: FileManager = .default
    ) -> Outcome {
        guard fileManager.fileExists(atPath: legacy.path(percentEncoded: false)) else { return .noLegacy }
        let marker = markerURL(for: legacy)
        guard !fileManager.fileExists(atPath: marker.path(percentEncoded: false)) else { return .alreadyMerged }
        let snapshot = shared.deletingLastPathComponent()
            .appending(path: ".\(shared.lastPathComponent).handoff-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: snapshot) }
        let result: Outcome
        do {
            result = try transfer(legacy: legacy, into: shared, snapshot: snapshot, tables: tables, decide: decide,
                                  fileManager: fileManager)
        } catch {
            result = .failed(String(describing: error))
        }
        switch result {
        case .copied, .merged:
            writeMarker(marker, shared: shared)
        default:
            break
        }
        report(result, legacy: legacy, shared: shared)
        return result
    }

    // MARK: Steps

    private static func transfer(
        legacy: URL, into shared: URL, snapshot: URL, tables: [Table],
        decide: (Database, Database) throws -> Decision, fileManager: FileManager
    ) throws -> Outcome {
        let source = try Connection(legacy, readOnly: true)
        if !fileManager.fileExists(atPath: shared.path(percentEncoded: false)) {
            try source.snapshot(to: snapshot)
            source.close()
            switch ModelStorage.moveExclusively(snapshot, to: shared, fileManager: fileManager) {
            case .moved:
                return .copied
            case .conflict:
                break // Another process created the shared copy meanwhile: merge into it instead.
            case .vanished:
                throw HandoffError("the snapshot vanished")
            case .failed(let code):
                throw HandoffError("rename failed: \(String(cString: strerror(code)))")
            }
        }
        let target = try Connection(shared, readOnly: false)
        if source.isOpen {
            if case .keep(let reason) = try decide(source.schema("main"), target.schema("main")) {
                return .kept(reason)
            }
            try source.snapshot(to: snapshot)
            source.close()
        }
        return try merge(snapshot: snapshot, into: target, tables: tables, decide: decide)
    }

    private static func merge(snapshot: URL, into target: Connection, tables: [Table],
                              decide: (Database, Database) throws -> Decision) throws -> Outcome {
        let address = URL(filePath: snapshot.path(percentEncoded: false)).absoluteString + "?mode=ro"
        try target.execute("ATTACH DATABASE ? AS legacy;", bindings: [address])
        defer { try? target.execute("DETACH DATABASE legacy;") }
        let legacyView = target.schema("legacy")
        let sharedView = target.schema("main")
        try target.execute("BEGIN IMMEDIATE;")
        do {
            switch try decide(legacyView, sharedView) {
            case .keep(let reason):
                try target.execute("ROLLBACK;")
                return .kept(reason)
            case .merge(let finish):
                var added = 0
                for entry in tables {
                    added += try insertMissingRows(of: entry, in: target)
                }
                try finish?(legacyView, sharedView)
                try target.execute("COMMIT;")
                return .merged(rows: added)
            }
        } catch {
            try? target.execute("ROLLBACK;")
            throw error
        }
    }

    /// Rows already in the shared table by key stay as they are.
    private static func insertMissingRows(of entry: Table, in target: Connection) throws -> Int {
        let sharedColumns = try target.columns(of: entry.name, schema: "main")
        guard !sharedColumns.isEmpty else { throw HandoffError("the shared database has no table \(entry.name)") }
        let legacyColumns = Set(try target.columns(of: entry.name, schema: "legacy"))
        let common = sharedColumns.filter(legacyColumns.contains).map(quoted).joined(separator: ", ")
        guard !common.isEmpty else { return 0 }
        let filter = entry.filter.map { " WHERE \($0)" } ?? ""
        try target.execute("""
            INSERT OR IGNORE INTO main.\(quoted(entry.name)) (\(common))
            SELECT \(common) FROM legacy.\(quoted(entry.name))\(filter);
            """)
        return target.changes
    }

    private static func writeMarker(_ marker: URL, shared: URL) {
        do {
            try Data(shared.path(percentEncoded: false).utf8).write(to: marker, options: .atomic)
        } catch {
            TonamoxSharedStorage.log.error("""
                could not write \(marker.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public); \
                the merge repeats next launch
                """)
        }
    }

    private static func report(_ result: Outcome, legacy: URL, shared: URL) {
        let name = legacy.lastPathComponent
        let log = TonamoxSharedStorage.log
        switch result {
        case .noLegacy, .alreadyMerged:
            break
        case .copied:
            log.notice("\(name, privacy: .public): private copy copied into the group; the private file is kept")
        case .merged(let rows):
            log.notice("\(name, privacy: .public): \(rows) private rows merged into the group; the private file is kept")
        case .kept(let reason):
            log.notice("\(name, privacy: .public): private rows not merged (\(reason, privacy: .public))")
        case .failed(let reason):
            log.error("\(name, privacy: .public): hand-off failed, retried next launch: \(reason, privacy: .public)")
        }
    }

    // MARK: SQL helpers

    private static func quoted(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    fileprivate static func run(_ sql: String, bindings: [String], in handle: OpaquePointer) throws {
        _ = try firstColumn(sql, bindings: bindings, in: handle) { _ in () }
    }

    /// Runs `sql`, returning `read` of its first row, or `nil` when it yields none.
    fileprivate static func firstColumn<Value>(_ sql: String, bindings: [String], in handle: OpaquePointer,
                                               read: (OpaquePointer) -> Value) throws -> Value? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw HandoffError(message(of: handle))
        }
        var position: Int32 = 1
        for value in bindings {
            sqlite3_bind_text(statement, position, value, -1, SQLITE_TRANSIENT)
            position += 1
        }
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return read(statement)
        case SQLITE_DONE: return nil
        default: throw HandoffError(message(of: handle))
        }
    }

    fileprivate static func message(of handle: OpaquePointer?) -> String {
        handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown SQLite error"
    }

    fileprivate static func columnName(_ statement: OpaquePointer?) -> String {
        sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
    }
}

// MARK: - Connection

/// A connection closed exactly once, by ``close()`` or on deinit.
private final class Connection {
    private let handle: OpaquePointer
    private(set) var isOpen = true

    init(_ file: URL, readOnly: Bool) throws {
        var opened: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_URI
        let status = sqlite3_open_v2(file.path(percentEncoded: false), &opened, flags, nil)
        guard status == SQLITE_OK, let opened else {
            let reason = SQLiteHandoff.message(of: opened)
            sqlite3_close(opened)
            throw HandoffError("cannot open \(file.lastPathComponent): \(reason)")
        }
        handle = opened
        sqlite3_busy_timeout(handle, SQLiteHandoff.busyTimeoutMilliseconds)
    }

    deinit { close() }

    var changes: Int { Int(sqlite3_changes(handle)) }

    func close() {
        guard isOpen else { return }
        isOpen = false
        sqlite3_close(handle)
    }

    func schema(_ name: String) -> SQLiteHandoff.Database {
        SQLiteHandoff.Database(handle: handle, schema: name)
    }

    func execute(_ sql: String, bindings: [String] = []) throws {
        guard isOpen else { throw HandoffError("connection closed") }
        try SQLiteHandoff.run(sql, bindings: bindings, in: handle)
    }

    /// A single-file copy that includes the `-wal` frames; the source stays as it is.
    func snapshot(to destination: URL) throws {
        try execute("VACUUM INTO ?;", bindings: [destination.path(percentEncoded: false)])
        // VACUUM INTO does not sync its output, and the copy may be renamed into place right after.
        let descriptor = open(destination.path(percentEncoded: false), O_RDONLY)
        guard descriptor >= 0 else { throw HandoffError("cannot sync the snapshot") }
        defer { Darwin.close(descriptor) }
        if fcntl(descriptor, F_FULLFSYNC) != 0 { fsync(descriptor) }
    }

    func columns(of table: String, schema: String) throws -> [String] {
        guard isOpen else { throw HandoffError("connection closed") }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, "SELECT name FROM pragma_table_info(?1, ?2);", -1, &statement, nil) == SQLITE_OK
        else { throw HandoffError(SQLiteHandoff.message(of: handle)) }
        sqlite3_bind_text(statement, 1, table, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, schema, -1, SQLITE_TRANSIENT)
        var names: [String] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            names.append(SQLiteHandoff.columnName(statement))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw HandoffError(SQLiteHandoff.message(of: handle)) }
        return names
    }
}

// MARK: - HandoffError

private struct HandoffError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
