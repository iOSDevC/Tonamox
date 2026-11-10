#if os(macOS)
import Foundation
import Testing
@testable import TerminalBridgeHelper
import TerminalBridgeKit

/// The helper loop against a real PhoneBridgeSession on 127.0.0.1 (ephemeral port), with the
/// screen side faked at the process level.
@Suite(.serialized) struct HelperSessionTests {
    private static let phoneSecret = Data((0..<20).map { UInt8($0) })
    private static let otherSecret = Data((100..<120).map { UInt8($0) })
    private static let fastBackoff = BackoffPolicy(steps: [.milliseconds(10)], cap: .milliseconds(20))

    private func makeEngine(
        secret: Data,
        runner: FakeProcessRunner,
        scratch: TemporaryDirectory,
        recorder: (any WriteRecorder)? = nil
    ) throws -> HelperBridgeSession {
        HelperBridgeSession(
            secret: secret,
            helperID: UUID(),
            helperName: "tonamox-bridge 1 · test",
            injector: try makeInjector(runner, scratch: scratch),
            recentWrites: RecentWriteIDs(),
            recorder: recorder
        )
    }

    private func isConnected(_ phone: PhoneBridgeSession) async -> Bool {
        if case .connected = await phone.state { return true }
        return false
    }

    @Test func rejectedProofIsRetriedAndNeverEndsTheLoop() async throws {
        let scratch = TemporaryDirectory()
        defer { scratch.remove() }
        let phone = PhoneBridgeSession(secret: Self.phoneSecret, phoneID: UUID(), port: 0)
        let port = try await phone.start()
        let runner = FakeProcessRunner()
        let sink = LineSink()
        let session = HelperSession(
            engine: try makeEngine(secret: Self.otherSecret, runner: runner, scratch: scratch),
            dialer: SimulatorDialer(port: port),
            console: HelperConsole(sink: sink.append),
            backoff: Self.fastBackoff
        )
        let loop = Task { await session.run() }

        #expect(await eventually { await session.phoneRejections >= 3 })
        #expect(await phone.rejectedAttempts >= 3)
        #expect(await session.lastEnd == .rejectedByPhone(.authFailed))
        await session.stop()
        loop.cancel()
        await loop.value
        await phone.stop()
        #expect(runner.stuffInvocations.isEmpty)
        #expect(sink.joined.contains("Sigo reintentando"))
    }

    @Test func servesAWriteAndJournalsOnlyItsHMAC() async throws {
        let scratch = TemporaryDirectory()
        defer { scratch.remove() }
        let phone = PhoneBridgeSession(secret: Self.phoneSecret, phoneID: UUID(), port: 0)
        let port = try await phone.start()
        let runner = FakeProcessRunner()
        let sink = LineSink()
        let console = HelperConsole(sink: sink.append)
        let journalURL = scratch.file("Logs/writes.log")
        let key = HelperConfig().journalSymmetricKey
        let journal = try WriteJournal(fileURL: journalURL, key: key, session: "tnx-h1", window: "0", device: "simulator")
        let recorder = ReportingRecorder(journal: journal, console: console, targetLabel: "tnx-h1:0")
        let session = HelperSession(
            engine: try makeEngine(secret: Self.phoneSecret, runner: runner, scratch: scratch, recorder: recorder),
            dialer: SimulatorDialer(port: port),
            console: console,
            journal: journal,
            backoff: Self.fastBackoff
        )
        let loop = Task { await session.run() }
        #expect(await eventually { await isConnected(phone) })
        #expect(await eventually { await phone.latestStatus?.target.state == .ready })

        let id = UUID()
        let ack = try await phone.write(text: "printf hello", id: id)
        #expect(ack.result == .typed)
        #expect(ack.verified)
        #expect(runner.stuffInvocations == [["-S", "53730.tnx-h1", "-p", "0", "-X", "stuff", "printf hello"]])

        await session.stop()
        loop.cancel()
        await loop.value
        await phone.stop()
        journal.close()
        let log = try String(contentsOf: journalURL, encoding: .utf8)
        #expect(log.contains(BridgeDigest.hmacSHA256Hex("printf hello", key: key)))
        #expect(!log.contains("printf hello"))
        #expect(!sink.joined.contains("printf hello"))
        #expect(sink.joined.contains("escrito 12 B"))
        #expect(try WriteJournal.typedWriteIDs(at: journalURL) == [id])
    }

    @Test func waitsQuietlyWhileTheAppIsNotListening() async throws {
        let scratch = TemporaryDirectory()
        defer { scratch.remove() }
        let probe = PhoneBridgeSession(secret: Self.phoneSecret, phoneID: UUID(), port: 0)
        let closedPort = try await probe.start()
        await probe.stop()
        let sink = LineSink()
        let session = HelperSession(
            engine: try makeEngine(secret: Self.phoneSecret, runner: FakeProcessRunner(), scratch: scratch),
            dialer: SimulatorDialer(port: closedPort),
            console: HelperConsole(sink: sink.append),
            backoff: Self.fastBackoff
        )
        let loop = Task { await session.run() }
        #expect(await eventually { await session.dialAttempts >= 4 })
        await session.stop()
        loop.cancel()
        await loop.value
        #expect(sink.lines.filter { $0.contains("Esperando la app en 127.0.0.1:\(closedPort)") }.count == 1)
    }

    private func rejectedLines(_ url: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: url)
        return try data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            let entry = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
            return entry["event"] as? String == "rejected" ? entry : nil
        }
    }

    private func runRejectedLoop(summaryInterval: Duration, until rejections: Int) async throws -> (
        lines: [[String: Any]], console: LineSink, rejections: Int
    ) {
        let scratch = TemporaryDirectory()
        defer { scratch.remove() }
        let phone = PhoneBridgeSession(secret: Self.phoneSecret, phoneID: UUID(), port: 0)
        let port = try await phone.start()
        let journalURL = scratch.file("Logs/writes.log")
        let journal = try WriteJournal(
            fileURL: journalURL, key: HelperConfig().journalSymmetricKey, session: "tnx-h1", window: "0", device: "simulator"
        )
        let sink = LineSink()
        let session = HelperSession(
            engine: try makeEngine(secret: Self.otherSecret, runner: FakeProcessRunner(), scratch: scratch),
            dialer: SimulatorDialer(port: port),
            console: HelperConsole(sink: sink.append),
            journal: journal,
            backoff: Self.fastBackoff,
            rejectionSummaryInterval: summaryInterval
        )
        let loop = Task { await session.run() }
        #expect(await eventually(timeout: .seconds(10)) { await session.phoneRejections >= rejections })
        await session.stop()
        loop.cancel()
        await loop.value
        await phone.stop()
        journal.close()
        return (try rejectedLines(journalURL), sink, await session.phoneRejections)
    }

    @Test func repeatedRejectionsAreCoalescedIntoCounts() async throws {
        let result = try await runRejectedLoop(summaryInterval: .seconds(60), until: 6)
        #expect(result.lines.count == 2)
        #expect(result.lines.first?["count"] as? Int == 1)
        #expect(result.lines.map { $0["count"] as? Int ?? 0 }.reduce(0, +) == result.rejections)
        #expect(result.console.lines.filter { $0.contains("rechazó la prueba") }.count == 1)
        #expect(result.console.joined.contains("Siguen los rechazos"))
    }

    @Test func aLongStreakLogsOneSummaryPerInterval() async throws {
        let result = try await runRejectedLoop(summaryInterval: .milliseconds(40), until: 12)
        #expect(result.lines.count >= 3)
        #expect(result.lines.count < result.rejections)
        #expect(result.lines.map { $0["count"] as? Int ?? 0 }.reduce(0, +) == result.rejections)
    }

    @Test func aForgedErrorCodeNeverReachesTheConsoleRaw() async throws {
        let scratch = TemporaryDirectory()
        defer { scratch.remove() }
        let forged = "\u{1B}[31mFORGED escrito 9 B verificado\u{1B}[0m\u{1B}]0;TITLE\u{07}\nfake line"
        let payload = try BridgeMessageCoder.encode(.error(ErrorReport(code: .unrecognized(forged))))
        let fakePhone = LoopbackListener(port: 0)
        let port = try await fakePhone.start()
        let server = Task {
            for await channel in fakePhone.connections {
                try? await channel.start()
                _ = try? await channel.receiveFrame()
                try? await channel.sendFrame(payload)
                channel.close()
            }
        }
        let journalURL = scratch.file("writes.log")
        let journal = try WriteJournal(
            fileURL: journalURL, key: HelperConfig().journalSymmetricKey, session: "tnx-h1", window: "0", device: "simulator"
        )
        let sink = LineSink()
        let session = HelperSession(
            engine: try makeEngine(secret: Self.phoneSecret, runner: FakeProcessRunner(), scratch: scratch),
            dialer: SimulatorDialer(port: port),
            console: HelperConsole(sink: sink.append),
            journal: journal,
            backoff: Self.fastBackoff
        )
        let loop = Task { await session.run() }
        #expect(await eventually { await session.phoneRejections >= 2 })
        await session.stop()
        loop.cancel()
        await loop.value
        fakePhone.stop()
        server.cancel()
        journal.close()

        #expect(await session.lastEnd == .rejectedByPhone(.unrecognized(forged)))
        #expect(!sink.joined.unicodeScalars.contains { $0.value < 0x20 && $0 != "\n" })
        #expect(!sink.joined.contains("FORGED"))
        #expect(sink.joined.contains("código desconocido, \(forged.utf8.count) B"))
        let log = try String(contentsOf: journalURL, encoding: .utf8)
        #expect(!log.contains("FORGED"))
        #expect(log.contains("rejectedByPhone:unrecognized(\(forged.utf8.count)B)"))
    }

    @Test func consoleNeutralisesControlAndBidiCharacters() {
        let sink = LineSink()
        HelperConsole(sink: sink.append).info("a\u{1B}[31mb\u{07}\nc\u{9B}d\u{202E}e\u{7F}ñ")
        let line = try? #require(sink.lines.first)
        #expect(line?.hasSuffix(" a?[31mb??c?d?e?ñ") == true)
    }

    @Test func backoffSteps() {
        let policy = BackoffPolicy()
        #expect((0..<6).map(policy.delay(afterFailures:)) == [
            .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(5), .seconds(5),
        ])
    }

    @Test func consoleLinesNeverCarryTheCommand() {
        let record = WriteRecord(id: UUID(), text: "sudo rm -rf /", bytes: 13, outcome: .typed, warnings: ["sudo"], verified: false)
        let line = ReportingRecorder.describe(record, target: "tonamox:0")
        #expect(!line.contains("sudo"))
        #expect(line.contains("NO verificado"))
    }
}
#endif
