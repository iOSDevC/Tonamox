#if os(macOS)
import CryptoKit
import Foundation
import Testing
@testable import TerminalBridgeHelper
@testable import TerminalBridgeKit

@Suite struct WriteJournalTests {
    private let key = SymmetricKey(data: Data(repeating: 7, count: 32))

    private func makeJournal(_ url: URL) throws -> WriteJournal {
        try WriteJournal(fileURL: url, key: key, session: "tonamox", window: "0", device: "simulator")
    }

    private func lines(_ url: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: url)
        return try data.split(separator: UInt8(ascii: "\n")).map { line in
            try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        }
    }

    @Test func storesAKeyedHashNeverTheTextOrItsSHA256() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file("Logs/Tonamox Bridge/writes.log")
        let journal = try makeJournal(url)
        let id = UUID()
        await journal.record(WriteRecord(id: id, text: "ls -la", bytes: 6, outcome: .typed, warnings: [], verified: true))
        journal.close()

        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(!raw.contains("ls -la"))
        #expect(!raw.contains(BridgeDigest.sha256Hex("ls -la")))
        let entry = try #require(try lines(url).first)
        #expect(entry["hmac"] as? String == BridgeDigest.hmacSHA256Hex("ls -la", key: key))
        #expect(entry["id"] as? String == id.uuidString)
        #expect(entry["bytes"] as? Int == 6)
        #expect(entry["result"] as? String == "typed")
        #expect(entry["event"] as? String == "write")
        #expect(entry["verified"] as? Bool == true)
        #expect(entry["device"] as? String == "simulator")
        #expect(entry["ts"] as? String != nil)
        #expect(entry["seq"] == nil)
    }

    @Test func fileAndNewDirectoriesArePrivateOnAPathWithASpace() throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file("Library/Logs/Tonamox Bridge/writes.log")
        let journal = try makeJournal(url)
        journal.note(.started)
        journal.close()
        #expect(url.path(percentEncoded: false).contains(" "))
        #expect(fileMode(url) == 0o600)
        #expect(fileMode(url.deletingLastPathComponent()) == 0o700)
    }

    @Test func refusesAJournalOthersCanRead() throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file("writes.log")
        FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: Data(), attributes: [.posixPermissions: 0o644])
        #expect(throws: PrivateFileError.insecurePermissions(path: url.path(percentEncoded: false), mode: 0o644)) {
            try makeJournal(url)
        }
    }

    @Test func recordsRefusalsWithTheirCode() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file("writes.log")
        let journal = try makeJournal(url)
        await journal.record(WriteRecord(
            id: UUID(), text: "sudo ls", bytes: 7, outcome: .refused(.promptNotIdle), warnings: ["sudo"], verified: false
        ))
        journal.note(.rejected, detail: "rejectedByPhone:authFailed")
        journal.close()
        let entries = try lines(url)
        #expect(entries[0]["result"] as? String == "refused")
        #expect(entries[0]["code"] as? String == "promptNotIdle")
        #expect(entries[0]["warnings"] as? [String] == ["sudo"])
        #expect(entries[1]["event"] as? String == "rejected")
    }

    @Test func seedsTheReplayCacheWithTypedIDsOnly() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file("writes.log")
        let journal = try makeJournal(url)
        let typedFirst = UUID()
        let refused = UUID()
        let typedSecond = UUID()
        await journal.record(WriteRecord(id: typedFirst, text: "true", bytes: 4, outcome: .typed, warnings: [], verified: true))
        await journal.record(WriteRecord(id: refused, text: "true", bytes: 4, outcome: .refused(.policy), warnings: [], verified: false))
        journal.note(.connected, detail: "Tonamox Terminal")
        await journal.record(WriteRecord(id: typedSecond, text: "true", bytes: 4, outcome: .typed, warnings: [], verified: false))
        journal.close()
        FileHandle(forWritingAtPath: url.path(percentEncoded: false)).map { handle in
            handle.seekToEndOfFile()
            handle.write(Data("{truncated line\n".utf8))
            handle.closeFile()
        }

        #expect(try WriteJournal.typedWriteIDs(at: url) == [typedFirst, typedSecond])
        #expect(try WriteJournal.typedWriteIDs(at: url, limit: 1) == [typedSecond])
        #expect(try WriteJournal.typedWriteIDs(at: directory.file("missing.log")).isEmpty)
        #expect(try WriteJournal.summary(at: url) == WriteJournal.Summary(counts: ["typed": 2, "refused": 1], isPartial: false))
    }

    @Test func readsOnlyTheTailAndDropsItsPartialFirstLine() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file("Logs dir/writes.log")
        let journal = try makeJournal(url)
        let old = UUID()
        let recent = UUID()
        await journal.record(WriteRecord(id: old, text: "true", bytes: 4, outcome: .typed, warnings: [], verified: true))
        let filler = String(repeating: "x", count: 150)
        for _ in 0..<40 {
            journal.note(.rejected, detail: filler)
        }
        await journal.record(WriteRecord(id: recent, text: "true", bytes: 4, outcome: .typed, warnings: [], verified: true))
        journal.close()
        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? Int)

        #expect(try WriteJournal.typedWriteIDs(at: url, scanLimit: 2_000) == [recent])
        #expect(try WriteJournal.typedWriteIDs(at: url, scanLimit: size) == [old, recent])
        let tail = try WriteJournal.summary(at: url, scanLimit: 2_000)
        #expect(tail == WriteJournal.Summary(counts: ["typed": 1], isPartial: true))
        let partial = try #require(try PrivateFiles.readTail(url, maxBytes: 1_000))
        #expect(partial.isPartial)
        #expect(partial.data.first == UInt8(ascii: "{"))
    }

    @Test func notesCarryACountAndABoundedDetail() throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file("writes.log")
        let journal = try makeJournal(url)
        journal.note(.rejected, detail: "rejectedByPhone:authFailed", count: 7)
        journal.note(.rejected, detail: String(repeating: "y", count: 16_000))
        journal.close()
        let entries = try lines(url)
        #expect(entries[0]["count"] as? Int == 7)
        #expect((entries[1]["detail"] as? String)?.count == WriteJournal.maxDetailCharacters)
        #expect(entries[1]["count"] == nil)
    }

    @Test func seededIDIsAlreadyTypedAfterARestart() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file("writes.log")
        let id = UUID()
        let first = try makeJournal(url)
        await first.record(WriteRecord(id: id, text: "printf once", bytes: 11, outcome: .typed, warnings: [], verified: true))
        first.close()

        let runner = FakeProcessRunner()
        let engine = HelperBridgeSession(
            secret: Data(repeating: 1, count: 20),
            helperID: UUID(),
            helperName: "test",
            injector: try makeInjector(runner, scratch: directory),
            recentWrites: RecentWriteIDs(seed: try WriteJournal.typedWriteIDs(at: url))
        )
        let reply = await engine.process(WriteRequest(id: id, text: "printf once"))
        guard case .ack(let ack) = reply else {
            Issue.record("expected an ack, got \(reply)")
            return
        }
        #expect(ack.result == .alreadyTyped)
        #expect(runner.invocations.isEmpty)
    }
}

@Suite struct HelperConfigStoreTests {
    @Test func savesA0600FileInA0700DirectoryWithASpace() throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file("Library/Application Support/TonamoxBridge/config.json")
        let store = HelperConfigStore(fileURL: url)
        var config = HelperConfig()
        config.pair(with: try PairingCode(secret: Data((0..<20).map { UInt8($0) })))
        try store.save(config)

        #expect(store.path.contains("Application Support"))
        #expect(fileMode(url) == 0o600)
        #expect(fileMode(url.deletingLastPathComponent()) == 0o700)
        let loaded = try store.loadPaired()
        #expect(loaded == config)
        #expect(loaded.fingerprint == "SJMQ-HVBB")
        #expect(loaded.journalKey.count == 32)
        #expect(directory.contents().count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path(percentEncoded: false))
            == ["config.json"])
    }

    @Test func refusesAWorldReadableConfigWithTheChmodToRun() throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file("config.json")
        let store = HelperConfigStore(fileURL: url)
        try store.save(HelperConfig())
        chmod(url.path(percentEncoded: false), 0o644)
        do {
            _ = try store.load()
            Issue.record("expected a permissions error")
        } catch {
            #expect(error == .file(.insecurePermissions(path: store.path, mode: 0o644)))
            #expect(error.message.contains("chmod 600 '\(store.path)'"))
        }
    }

    @Test func refusesASymbolicLink() throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let real = directory.file("real.json")
        let link = directory.file("link.json")
        try HelperConfigStore(fileURL: real).save(HelperConfig())
        try FileManager.default.createSymbolicLink(atPath: link.path(percentEncoded: false), withDestinationPath: real.path(percentEncoded: false))
        #expect(throws: HelperConfigError.file(.symbolicLink(link.path(percentEncoded: false)))) {
            try HelperConfigStore(fileURL: link).load()
        }
    }

    @Test func unpairKeepsTheIdentityAndJournalKey() throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let store = HelperConfigStore(fileURL: directory.file("config.json"))
        var config = HelperConfig(promptRegex: "❯ ?$")
        config.pair(with: PairingCode.generate())
        try store.save(config)
        config.unpair()
        try store.save(config)

        let loaded = try #require(try store.loadIfPresent())
        #expect(!loaded.isPaired)
        #expect(loaded.secret == nil)
        #expect(loaded.helperID == config.helperID)
        #expect(loaded.journalKey == config.journalKey)
        #expect(loaded.promptRegex == "❯ ?$")
        #expect(throws: HelperConfigError.notPaired(path: store.path)) { try store.loadPaired() }
    }

    @Test func missingConfigIsNotAnError() throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let store = HelperConfigStore(fileURL: directory.file("nothing/config.json"))
        #expect(try store.loadIfPresent() == nil)
        #expect(throws: HelperConfigError.notPaired(path: store.path)) { try store.loadPaired() }
    }

    @Test func defaultLocationsAreTheDocumentedOnes() {
        #expect(HelperConfigStore.defaultURL.path(percentEncoded: false).hasSuffix("/Library/Application Support/TonamoxBridge/config.json"))
        #expect(WriteJournal.defaultURL.path(percentEncoded: false).hasSuffix("/Library/Logs/TonamoxBridge/writes.log"))
    }
}
#endif
