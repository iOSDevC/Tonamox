import Foundation
import SQLite3
import XCTest
@testable import TonamoxCore

/// The app's private `conversations.sqlite` is handed to the shared store once, and is never changed itself.
final class ConversationStoreMigrationTests: XCTestCase {

    // MARK: Copy

    func testALegacyDatabaseWithWALContentIsCopiedWhenTheSharedOneIsMissing() async throws {
        let (legacy, shared) = try makeRoots()
        let seeded = try await seedLegacyWithUncheckpointedWAL(in: legacy, words: ["kiwi orchard"])
        let walBefore = try fileSize(legacy.appending(path: "conversations.sqlite-wal"))
        XCTAssertGreaterThan(walBefore, 0)

        let store = ConversationStore(directory: shared, legacyDirectory: legacy, suspension: SharedStorageSuspension())
        let conversations = try await store.allConversations()
        let hits = try await store.search("orchard")

        XCTAssertEqual(conversations.map(\.id), [seeded.conversation])
        XCTAssertEqual(hits.map(\.id), seeded.turns)
        XCTAssertTrue(exists(SQLiteHandoff.markerURL(for: legacy.appending(path: "conversations.sqlite"))))
        XCTAssertEqual(try fileSize(legacy.appending(path: "conversations.sqlite-wal")), walBefore)
        XCTAssertEqual(try rowCount("turns", in: legacy), seeded.turns.count)
        XCTAssertFalse(try leftovers(in: shared).contains { $0.contains("handoff") })
    }

    // MARK: Merge

    func testLegacyRowsAreMergedIntoAnExistingSharedDatabaseAndFoundBySearch() async throws {
        let (legacy, shared) = try makeRoots()
        let sharedOnly = try await seed(shared, title: "shared", words: ["mango shared"])
        let seeded = try await seedLegacyWithUncheckpointedWAL(in: legacy, words: ["papaya legacy", "guava legacy"])

        let store = ConversationStore(directory: shared, legacyDirectory: legacy, suspension: SharedStorageSuspension())
        let ids = Set(try await store.allConversations().map(\.id))
        let legacyHits = try await store.search("legacy")
        let sharedHits = try await store.search("mango")
        let merged = try await store.conversation(id: seeded.conversation)

        XCTAssertEqual(ids, [sharedOnly, seeded.conversation])
        XCTAssertEqual(Set(legacyHits.map(\.id)), Set(seeded.turns))
        XCTAssertEqual(sharedHits.count, 1)
        XCTAssertEqual(merged?.turnCount, 2)
        XCTAssertTrue(exists(SQLiteHandoff.markerURL(for: legacy.appending(path: "conversations.sqlite"))))
        XCTAssertEqual(try rowCount("turns", in: legacy), 2)
    }

    func testTheMarkerKeepsADeletedConversationFromComingBack() async throws {
        let (legacy, shared) = try makeRoots()
        _ = try await seed(shared, title: "shared", words: ["shared"])
        let seeded = try await seedLegacyWithUncheckpointedWAL(in: legacy, words: ["merged once"])
        let first = ConversationStore(directory: shared, legacyDirectory: legacy, suspension: SharedStorageSuspension())
        try await first.deleteConversation(id: seeded.conversation)
        await first.close()

        let relaunched = ConversationStore(directory: shared, legacyDirectory: legacy,
                                           suspension: SharedStorageSuspension())
        let ids = try await relaunched.allConversations().map(\.id)
        let hits = try await relaunched.search("merged")

        XCTAssertFalse(ids.contains(seeded.conversation))
        XCTAssertEqual(hits, [])
        XCTAssertEqual(try rowCount("conversations", in: legacy), 1)
    }

    func testOnlyTheColumnsBothSidesHaveAreMergedAndTheRestTakeTheirDefaults() async throws {
        let (legacy, shared) = try makeRoots()
        _ = try await seed(shared, title: "shared", words: ["shared"])
        let conversation = UUID()
        try sql("""
            CREATE TABLE conversations (id TEXT PRIMARY KEY, title TEXT NOT NULL, model TEXT NOT NULL,
                                        created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
            CREATE TABLE turns (id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, role TEXT NOT NULL,
                                content TEXT NOT NULL, created_at TEXT NOT NULL);
            INSERT INTO conversations VALUES ('\(conversation.uuidString)', 'old', 'm',
                                              '2025-01-01T00:00:00.000Z', '2025-01-01T00:00:00.000Z');
            INSERT INTO turns VALUES ('\(UUID().uuidString)', '\(conversation.uuidString)', 'user', 'quince era',
                                      '2025-01-01T00:00:00.000Z');
            """, in: legacy)

        let store = ConversationStore(directory: shared, legacyDirectory: legacy, suspension: SharedStorageSuspension())
        let merged = try await store.conversation(id: conversation)
        let turns = try await store.turns(for: conversation)
        let hits = try await store.search("quince")

        XCTAssertEqual(merged?.title, "old")
        XCTAssertEqual(merged?.turnCount, 0)
        XCTAssertEqual(turns.map(\.tokenEstimate), [0])
        XCTAssertEqual(hits.count, 1)
    }

    // MARK: Connection

    func testTheConnectionWaitsForAnotherProcessesLock() async throws {
        let (_, shared) = try makeRoots()
        let store = ConversationStore(directory: shared)
        let timeout = try await store.busyTimeout()
        XCTAssertEqual(timeout, Int(SQLiteHandoff.busyTimeoutMilliseconds))
    }

    func testWhileSuspendedEachCallRunsInABackgroundTaskAndClosesTheDatabase() async throws {
        let (legacy, shared) = try makeRoots()
        let suspension = SharedStorageSuspension()
        let tasks = FakeBackgroundTasks()
        suspension.backgroundTasks = tasks
        let store = ConversationStore(directory: shared, legacyDirectory: legacy, suspension: suspension)
        let conversation = try await store.createConversation(model: .qwen3_1_7b)
        let openWhileActive = await store.isOpen

        suspension.setSuspended(true)
        try await store.appendTurn(Turn(conversationID: conversation.id, role: .assistant, content: "partial reply"))
        let openWhileSuspended = await store.isOpen
        let turnsWhileSuspended = try await store.turns(for: conversation.id)

        suspension.setSuspended(false)
        _ = try await store.allConversations()
        let openAfterResume = await store.isOpen

        XCTAssertTrue(openWhileActive)
        XCTAssertFalse(openWhileSuspended)
        XCTAssertEqual(turnsWhileSuspended.map(\.content), ["partial reply"])
        XCTAssertEqual(tasks.begunCount, 2)
        XCTAssertEqual(tasks.endedCount, 2)
        XCTAssertTrue(openAfterResume)
    }

    func testTheSuspensionHandlerClosesAnIdleConnection() async throws {
        let (legacy, shared) = try makeRoots()
        let suspension = SharedStorageSuspension()
        let store = ConversationStore(directory: shared, legacyDirectory: legacy, suspension: suspension)
        try await store.open()
        let openBefore = await store.isOpen

        await suspension.runHandlers()
        let openAfter = await store.isOpen
        let conversations = try await store.allConversations()

        XCTAssertTrue(openBefore)
        XCTAssertFalse(openAfter)
        XCTAssertEqual(conversations, [])
    }

    // MARK: Helpers

    /// Both roots sit under a folder whose name has a space, as the real Application Support does.
    private func makeRoots() throws -> (legacy: URL, shared: URL) {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "Conversation Handoff \(UUID().uuidString)", directoryHint: .isDirectory)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let legacy = base.appending(path: "Private Support/AuraLocal", directoryHint: .isDirectory)
        let shared = base.appending(path: "Group Containers/group x/AuraLocal", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        return (legacy, shared)
    }

    private func seed(_ directory: URL, title: String, words: [String]) async throws -> UUID {
        let store = ConversationStore(directory: directory)
        let conversation = try await store.createConversation(model: .qwen3_1_7b, title: title)
        for text in words {
            try await store.appendTurn(userTurn(text, in: conversation.id))
        }
        await store.close()
        return conversation.id
    }

    /// The state an app killed mid-session leaves: rows that live only in `-wal`. The writer stays open in a
    /// scratch folder while its files are copied, so closing it cannot checkpoint the copy.
    private func seedLegacyWithUncheckpointedWAL(in legacy: URL, words: [String]) async throws
        -> (conversation: UUID, turns: [UUID]) {
        let scratch = legacy.deletingLastPathComponent().appending(path: "writer", directoryHint: .isDirectory)
        let writer = ConversationStore(directory: scratch)
        let conversation = try await writer.createConversation(model: .qwen3_1_7b, title: "legacy")
        var turns: [UUID] = []
        for text in words {
            turns.append(try await writer.appendTurn(userTurn(text, in: conversation.id)).id)
        }
        for suffix in ["", "-wal"] {
            try FileManager.default.copyItem(at: scratch.appending(path: "conversations.sqlite" + suffix),
                                             to: legacy.appending(path: "conversations.sqlite" + suffix))
        }
        await writer.close()
        return (conversation.id, turns)
    }

    private func userTurn(_ text: String, in conversation: UUID) -> Turn {
        Turn(conversationID: conversation, role: .user, content: text)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    private func fileSize(_ url: URL) throws -> Int {
        try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? Int ?? 0
    }

    private func leftovers(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
    }

    /// Read-only, so counting never checkpoints or otherwise changes the legacy file.
    private func rowCount(_ table: String, in directory: URL) throws -> Int {
        var db: OpaquePointer?
        let path = directory.appending(path: "conversations.sqlite").path(percentEncoded: false)
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw HandoffTestFailure(message: "open")
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM \(table);", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            throw HandoffTestFailure(message: String(cString: sqlite3_errmsg(db)))
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func sql(_ script: String, in directory: URL) throws {
        var db: OpaquePointer?
        let path = directory.appending(path: "conversations.sqlite").path(percentEncoded: false)
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            throw HandoffTestFailure(message: "open")
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, script, nil, nil, nil) == SQLITE_OK else {
            throw HandoffTestFailure(message: String(cString: sqlite3_errmsg(db)))
        }
    }
}

private struct HandoffTestFailure: Error {
    let message: String
}
