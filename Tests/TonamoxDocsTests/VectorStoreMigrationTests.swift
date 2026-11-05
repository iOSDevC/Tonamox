import Foundation
import os
import SQLite3
import XCTest
@testable import TonamoxCore
@testable import TonamoxDocs

/// The app's private `vectors.sqlite` files are handed to the shared index once, only when their vectors fit it,
/// and are never changed themselves.
final class VectorStoreMigrationTests: XCTestCase {

    private let stubA = EmbeddingIndexIdentity(identifier: "stub/a", dimensions: 4)
    private let stubB = EmbeddingIndexIdentity(identifier: "stub/b", dimensions: 8)

    // MARK: Merge rules

    func testMatchingIdentitiesMergeAndFullTextSearchFindsTheMergedChunks() async throws {
        let roots = try makeRoots()
        let sharedDocument = try await index(["alpha shared text"], identity: stubA, in: roots.shared)
        let legacyDocument = try await indexLeavingWAL(["bravo legacy text"], identity: stubA, in: roots.legacy)

        let store = sharedStore(roots, legacy: [roots.legacy])
        let ids = Set(try await store.allDocuments().map(\.id))
        let hits = try await store.search(query: "bravo", queryEmbedding: vector(4))

        XCTAssertEqual(ids, [sharedDocument, legacyDocument])
        XCTAssertEqual(hits.map(\.chunk.documentID), [legacyDocument])
        XCTAssertTrue(exists(marker(roots.legacy)))
        XCTAssertEqual(try count("documents", in: roots.legacy), 1)
    }

    func testAnEmptySharedIndexMergesAndTakesOverTheLegacyIdentity() async throws {
        let roots = try makeRoots()
        let empty = VectorStore(directory: roots.shared)
        try await empty.setEmbeddingIdentity(stubB)
        await empty.close()
        let legacyDocument = try await indexLeavingWAL(["charlie legacy"], identity: stubA, in: roots.legacy)

        let store = sharedStore(roots, legacy: [roots.legacy])
        let ids = try await store.allDocuments().map(\.id)
        let identity = try await store.embeddingIdentity()

        XCTAssertEqual(ids, [legacyDocument])
        XCTAssertEqual(identity, stubA)
    }

    func testAnotherIdentityKeepsTheLegacyIndexOutAndUnmarked() async throws {
        let roots = try makeRoots()
        let sharedDocument = try await index(["delta shared"], identity: stubB, in: roots.shared)
        _ = try await indexLeavingWAL(["echo legacy"], identity: stubA, in: roots.legacy)

        let store = sharedStore(roots, legacy: [roots.legacy])
        let ids = try await store.allDocuments().map(\.id)
        let identity = try await store.embeddingIdentity()

        XCTAssertEqual(ids, [sharedDocument])
        XCTAssertEqual(identity, stubB)
        XCTAssertFalse(exists(marker(roots.legacy)))
        XCTAssertEqual(try count("chunks", in: roots.legacy), 1)
    }

    func testTheOrphanedAuraLocalDocsIndexIsMergedAfterTheCurrentOne() async throws {
        let roots = try makeRoots()
        let legacyFolders = DocumentLibrary.legacyDocumentDirectories(in: roots.privateSupport)
        let current = try await indexLeavingWAL(["foxtrot current"], identity: stubA, in: legacyFolders[0])
        let orphaned = try await indexLeavingWAL(["golf orphaned"], identity: stubA, in: legacyFolders[1])

        let store = sharedStore(roots, legacy: legacyFolders)
        let ids = Set(try await store.allDocuments().map(\.id))
        let hits = try await store.search(query: "orphaned", queryEmbedding: vector(4))

        XCTAssertEqual(legacyFolders.map(\.lastPathComponent), ["docs", "docs"])
        XCTAssertEqual(legacyFolders[1].deletingLastPathComponent().lastPathComponent, "AuraLocal")
        XCTAssertEqual(ids, [current, orphaned])
        XCTAssertEqual(hits.map(\.chunk.documentID), [orphaned])
        XCTAssertTrue(legacyFolders.allSatisfy { exists(marker($0)) })
    }

    func testTheMarkerKeepsARemovedDocumentFromComingBack() async throws {
        let roots = try makeRoots()
        _ = try await index(["hotel shared"], identity: stubA, in: roots.shared)
        let legacyDocument = try await indexLeavingWAL(["india legacy"], identity: stubA, in: roots.legacy)
        let first = sharedStore(roots, legacy: [roots.legacy])
        try await first.deleteDocument(id: legacyDocument)
        await first.close()

        let relaunched = sharedStore(roots, legacy: [roots.legacy])
        let ids = try await relaunched.allDocuments().map(\.id)

        XCTAssertFalse(ids.contains(legacyDocument))
        XCTAssertEqual(try count("documents", in: roots.legacy), 1)
    }

    func testAFileIndexedOnBothSidesKeepsOneCopyOfItsChunks() async throws {
        let roots = try makeRoots()
        let document = UUID()
        _ = try await index(["juliet one", "juliet two"], identity: stubA, in: roots.shared, document: document)
        _ = try await indexLeavingWAL(["juliet one", "juliet two"], identity: stubA, in: roots.legacy,
                                      document: document)

        let store = sharedStore(roots, legacy: [roots.legacy])
        let chunks = try await store.chunksForDocument(id: document)

        XCTAssertEqual(chunks.count, 2)
        XCTAssertTrue(exists(marker(roots.legacy)))
    }

    // MARK: Connection and suspension

    func testTheConnectionWaitsForAnotherProcessesLock() async throws {
        let roots = try makeRoots()
        let timeout = try await VectorStore(directory: roots.shared).busyTimeout()
        XCTAssertEqual(timeout, Int(SQLiteHandoff.busyTimeoutMilliseconds))
    }

    func testWhileSuspendedEachCallRunsInABackgroundTaskAndClosesTheIndex() async throws {
        let roots = try makeRoots()
        let suspension = SharedStorageSuspension()
        let tasks = CountingBackgroundTasks()
        suspension.backgroundTasks = tasks
        let store = VectorStore(directory: roots.shared, suspension: suspension)
        try await store.open()

        suspension.setSuspended(true)
        try await store.setEmbeddingIdentity(stubA)
        let openWhileSuspended = await store.isOpen
        await suspension.runHandlers()
        suspension.setSuspended(false)
        let identity = try await store.embeddingIdentity()
        let openAfterResume = await store.isOpen

        XCTAssertFalse(openWhileSuspended)
        XCTAssertEqual(tasks.counts, [1, 1])
        XCTAssertEqual(identity, stubA)
        XCTAssertTrue(openAfterResume)
    }

    func testAfterTheSuspensionHandlerTheLibraryReadsTheIdentityAgain() async throws {
        let roots = try makeRoots()
        let suspension = SharedStorageSuspension()
        let library = DocumentLibrary(directory: roots.shared, legacyDirectories: [], suspension: suspension,
                                      chunkTargetTokens: 24)
        await library.configure(embeddingProvider: StubEmbedder("stub/a", dimensions: 4), llm: await Self.llm())
        try await library.add(url: try writeDocument("first.txt", in: roots.base))
        let matchedBefore = await library.matchedIdentity

        // Another app of the group re-embeds the shared index while this one is in the background.
        let other = DocumentLibrary(directory: roots.shared, chunkTargetTokens: 24)
        await other.configure(embeddingProvider: StubEmbedder("stub/b", dimensions: 8), llm: await Self.llm())
        try await other.add(url: try writeDocument("second.txt", in: roots.base))
        await suspension.runHandlers()
        let matchedAfterSuspension = await library.matchedIdentity

        try await library.add(url: try writeDocument("third.txt", in: roots.base))
        let check = VectorStore(directory: roots.shared)
        let identity = try await check.embeddingIdentity()
        let lengths = try await check.storedVectorLengths()

        XCTAssertEqual(matchedBefore, stubA)
        XCTAssertNil(matchedAfterSuspension)
        XCTAssertEqual(identity, stubA)
        XCTAssertEqual(lengths, [4])
    }

    // MARK: Helpers

    private struct Roots {
        let base: URL
        let privateSupport: URL
        let legacy: URL
        let shared: URL
    }

    /// Every path contains a space, as the real Application Support and group container do.
    private func makeRoots() throws -> Roots {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "Docs Handoff \(UUID().uuidString)", directoryHint: .isDirectory)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let privateSupport = base.appending(path: "Private Support", directoryHint: .isDirectory)
        let shared = base.appending(path: "Group Containers/group x/Library/Application Support/Tonamox/docs",
                                    directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        return Roots(base: base, privateSupport: privateSupport,
                     legacy: DocumentLibrary.documentDirectory(in: privateSupport), shared: shared)
    }

    private func sharedStore(_ roots: Roots, legacy: [URL]) -> VectorStore {
        VectorStore(directory: roots.shared, legacyDirectories: legacy, suspension: SharedStorageSuspension())
    }

    @discardableResult
    private func index(_ texts: [String], identity: EmbeddingIndexIdentity, in directory: URL,
                       document: UUID = UUID()) async throws -> UUID {
        let store = VectorStore(directory: directory)
        try await fill(store, texts: texts, identity: identity, document: document)
        await store.close()
        return document
    }

    /// The state an app killed mid-session leaves: rows that live only in `-wal`. The writer stays open in a
    /// scratch folder while its files are copied, so closing it cannot checkpoint the copy.
    private func indexLeavingWAL(_ texts: [String], identity: EmbeddingIndexIdentity, in directory: URL,
                                 document: UUID = UUID()) async throws -> UUID {
        let scratch = directory.deletingLastPathComponent()
            .appending(path: "writer \(UUID().uuidString)", directoryHint: .isDirectory)
        let writer = VectorStore(directory: scratch)
        try await fill(writer, texts: texts, identity: identity, document: document)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for suffix in ["", "-wal"] {
            try FileManager.default.copyItem(at: scratch.appending(path: "vectors.sqlite" + suffix),
                                             to: directory.appending(path: "vectors.sqlite" + suffix))
        }
        await writer.close()
        return document
    }

    private func fill(_ store: VectorStore, texts: [String], identity: EmbeddingIndexIdentity,
                      document: UUID) async throws {
        let chunks = texts.map { chunk($0, document: document, dimensions: identity.dimensions) }
        try await store.insertDocument(id: document, title: "doc", url: "file:///doc/\(document)", chunks: chunks)
        try await store.setEmbeddingIdentity(identity)
    }

    private func chunk(_ text: String, document: UUID, dimensions: Int) -> DocumentChunk {
        var made = DocumentChunk(documentID: document, documentTitle: "doc", pageNumber: 1, text: text)
        made.embedding = vector(dimensions)
        return made
    }

    private func vector(_ dimensions: Int) -> [Float] {
        [Float](repeating: 0.5, count: dimensions)
    }

    private func marker(_ legacyFolder: URL) -> URL {
        SQLiteHandoff.markerURL(for: legacyFolder.appending(path: "vectors.sqlite"))
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    private func writeDocument(_ name: String, in folder: URL) throws -> URL {
        let text = (0..<8)
            .map { "Sentence \($0) says the invoices of \(name) are paid within thirty days." }
            .joined(separator: " ")
        let url = folder.appending(path: name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Never loaded: indexing needs an LLM only to satisfy `configure`.
    @MainActor
    private static func llm() -> Tonamox {
        Tonamox(model: .qwen3_1_7b)
    }

    /// Read-only, so counting never checkpoints or otherwise changes the legacy file.
    private func count(_ table: String, in folder: URL) throws -> Int {
        var db: OpaquePointer?
        let path = folder.appending(path: "vectors.sqlite").path(percentEncoded: false)
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw MigrationTestFailure(message: "open")
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM \(table);", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            throw MigrationTestFailure(message: String(cString: sqlite3_errmsg(db)))
        }
        return Int(sqlite3_column_int64(statement, 0))
    }
}

// MARK: - Stubs

private struct MigrationTestFailure: Error {
    let message: String
}

/// `[begun, ended]`.
private final class CountingBackgroundTasks: BackgroundTaskAsserting, Sendable {
    private let tally = OSAllocatedUnfairLock(initialState: [0, 0])

    var counts: [Int] { tally.withLock { $0 } }

    func begin(name: String, onExpiration: @escaping @Sendable () -> Void) -> Int? {
        tally.withLock { $0[0] += 1; return $0[0] }
    }

    func end(_ identifier: Int) {
        tally.withLock { $0[1] += 1 }
    }
}

/// Deterministic vectors derived from the text length.
private struct StubEmbedder: EmbeddingProvider {
    let identifier: String
    let dimensions: Int

    init(_ identifier: String, dimensions: Int) {
        self.identifier = identifier
        self.dimensions = dimensions
    }

    func embed(_ text: String) async throws -> [Float] {
        (0..<dimensions).map { Float(text.utf8.count % 97 + $0 + 1) }
    }
}
