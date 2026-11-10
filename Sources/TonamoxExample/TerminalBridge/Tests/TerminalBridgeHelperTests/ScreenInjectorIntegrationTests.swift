#if os(macOS)
import Darwin
import Foundation
import Synchronization
import Testing
@testable import TerminalBridgeHelper
import TerminalBridgeKit

/// Sessions live in a private 0700 SCREENDIR with an empty .screenrc and ZDOTDIR, so nothing of the
/// user's is touched. Only the harness itself ever sends CR or other control bytes.
final class ScreenHarness: Sendable {
    let root: URL
    let screenDirectory: URL
    let workDirectory: URL
    let scratchDirectory: URL
    private let zdotDirectory: URL
    private let screenrc: URL
    private let created = Mutex<[String]>([])

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["TONAMOX_SCREEN_IT"] == "1"
    }

    init() throws {
        let base = ProcessInfo.processInfo.environment["TONAMOX_SCREEN_IT_DIR"].map { URL(filePath: $0) }
            ?? FileManager.default.temporaryDirectory
        try PrivateFiles.ensureDirectory(base)
        root = try PrivateFiles.makeTemporaryDirectory(in: base, prefix: "it")
        screenDirectory = try PrivateFiles.makeTemporaryDirectory(in: root, prefix: "sd")
        workDirectory = try PrivateFiles.makeTemporaryDirectory(in: root, prefix: "work")
        scratchDirectory = try PrivateFiles.makeTemporaryDirectory(in: root, prefix: "hc")
        zdotDirectory = try PrivateFiles.makeTemporaryDirectory(in: root, prefix: "zdot")
        screenrc = root.appending(path: "empty.screenrc", directoryHint: .notDirectory)
        try PrivateFiles.createEmpty(screenrc)
    }

    var screenEnvironment: [String: String] {
        ["SCREENDIR": PrivateFiles.path(screenDirectory)]
    }

    private func sessionEnvironment(screenrc custom: URL? = nil) -> [String: String] {
        screenEnvironment.merging([
            "ZDOTDIR": PrivateFiles.path(zdotDirectory),
            "PROMPT": "%% ",
            "SCREENRC": PrivateFiles.path(custom ?? screenrc),
        ]) { _, new in new }
    }

    /// A private screenrc with `contents`, for sessions that need a non-default setting.
    func screenrc(_ label: String, contents: String) throws -> URL {
        let file = root.appending(path: "\(label).screenrc", directoryHint: .notDirectory)
        try PrivateFiles.atomicWrite(Data(contents.utf8), to: file)
        return file
    }

    static func uniqueName(_ label: String) -> String {
        "tnx-it-\(label)-\(UUID().uuidString.prefix(6).lowercased())"
    }

    @discardableResult
    func run(_ arguments: [String], environment: [String: String]? = nil) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/screen")
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment ?? screenEnvironment) { _, new in new }
        process.currentDirectoryURL = workDirectory
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        guard (try? process.run()) != nil else { return (-1, "") }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func sessions() -> [ScreenSessionEntry] {
        ScreenListParser.parse(run(["-ls"]).output)
    }

    /// Starts a detached session and returns its `pid.name` once the command is running.
    func start(_ name: String, command: [String] = ["/bin/zsh", "-f"], screenrc custom: URL? = nil) async throws -> String {
        let before = Set(sessions().map(\.socketName))
        run(["-dmS", name] + command, environment: sessionEnvironment(screenrc: custom))
        let socket = try #require(await waitFor { self.sessions().first { $0.name == name && !before.contains($0.socketName) } })
        created.withLock { $0.append(socket.socketName) }
        note("created \(socket.socketName)")
        return socket.socketName
    }

    func startShell(_ name: String) async throws -> String {
        let socket = try await start(name)
        #expect(await waitFor { self.lastLine(socket) == "%" ? true : nil } == true)
        return socket
    }

    /// The harness's own keystrokes (may include CR or ^U); the bridge never sends these.
    func harnessKeys(_ socket: String, _ keys: String) {
        run(["-S", socket, "-p", "0", "-X", "stuff", keys])
    }

    func hardcopy(_ socket: String, window: String = "0") -> String {
        let file = scratchDirectory.appending(path: "harness-\(UUID().uuidString).txt", directoryHint: .notDirectory)
        try? PrivateFiles.createEmpty(file)
        defer { unlink(PrivateFiles.path(file)) }
        run(["-S", socket, "-p", window, "-X", "hardcopy", PrivateFiles.path(file)])
        return (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }

    func lastLine(_ socket: String) -> String? {
        IdlePromptPattern.lastNonEmptyLine(of: hardcopy(socket))
    }

    func joinedScreen(_ socket: String) -> String {
        hardcopy(socket).split(whereSeparator: \.isNewline).joined()
    }

    func quit(_ socket: String) {
        let status = run(["-S", socket, "-X", "quit"]).status
        created.withLock { $0.removeAll { $0 == socket } }
        note("quit \(socket) rc=\(status)")
    }

    /// Appends to <root>/sessions.log so every session created and quit can be audited.
    private func note(_ line: String) {
        let log = root.appending(path: "sessions.log", directoryHint: .notDirectory)
        guard let descriptor = try? PrivateFiles.openForAppending(log) else { return }
        _ = PrivateFiles.writeAll(Data((line + "\n").utf8), to: descriptor)
        close(descriptor)
    }

    /// Quits every session this harness created and returns their names.
    @discardableResult
    func quitAll() -> [String] {
        let sockets = created.withLock { $0 }
        sockets.forEach(quit)
        return sockets
    }

    func injector(session: String, window: String = "0") throws -> ScreenInjector {
        ScreenInjector(
            settings: ScreenInjectorSettings(
                session: session,
                window: window,
                idlePrompt: try IdlePromptPattern(),
                scratchDirectory: scratchDirectory
            ),
            runner: SystemProcessRunner(extraEnvironment: screenEnvironment)
        )
    }

    func canary(_ label: String) -> URL {
        workDirectory.appending(path: "CANARY_\(label)", directoryHint: .notDirectory)
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: PrivateFiles.path(url))
    }

    func waitFor<Value>(timeout: Duration = .seconds(5), _ probe: @Sendable () async -> Value?) async -> Value? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let value = await probe() { return value }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await probe()
    }

    /// Screen text with wrapped lines joined and blanks dropped (hardcopy trims a blank at a wrap).
    func screenEnds(_ socket: String, with text: String) -> Bool {
        ScreenInjector.screen(hardcopy(socket), endsWith: ScreenInjector.compacted(text))
    }
}

@Suite(.serialized, .enabled(if: ScreenHarness.isEnabled, "set TONAMOX_SCREEN_IT=1 to drive real screen sessions"))
struct ScreenInjectorIntegrationTests {
    @Test func stuffedBytesArriveIdenticalWithNoTrailingNewline() async throws {
        let harness = try ScreenHarness()
        defer { harness.quitAll() }
        let sink = harness.workDirectory.appending(path: "sink.bin", directoryHint: .notDirectory)
        let name = ScreenHarness.uniqueName("sink")
        let socket = try await harness.start(name, command: ["/bin/sh", "-c", "stty raw -echo; exec cat > '\(PrivateFiles.path(sink))'"])
        #expect(await harness.waitFor { harness.exists(sink) ? true : nil } == true)
        try await Task.sleep(for: .milliseconds(300))
        let injector = try harness.injector(session: name)

        guard case .refused(.foregroundNotShell, let detail) = await injector.type("printf guarded") else {
            Issue.record("a cat sink must not count as a shell")
            return
        }
        #expect(detail.contains("'cat'"))

        let text = #"a^Mb\033c$HOME `id` 'q' "d" ;#{}~|&<>*?[]!"#
        #expect(await injector.deliver(text, to: socket) == .typed(verified: false))
        let delivered = await harness.waitFor { () -> Data? in
            let data = FileManager.default.contents(atPath: PrivateFiles.path(sink)) ?? Data()
            return data.count >= text.utf8.count ? data : nil
        }
        try await Task.sleep(for: .milliseconds(300))
        let bytes = FileManager.default.contents(atPath: PrivateFiles.path(sink)) ?? Data()
        #expect(delivered != nil)
        #expect(bytes == Data(text.utf8))
        #expect(bytes.last != 0x0A)
        #expect(bytes.last != 0x0D)
    }

    @Test func typedLineWaitsAtThePromptAndRunsNothing() async throws {
        let harness = try ScreenHarness()
        defer { harness.quitAll() }
        let name = ScreenHarness.uniqueName("type")
        let socket = try await harness.startShell(name)
        let injector = try harness.injector(session: name)
        let canary = harness.canary("TYPED")
        let command = "touch \(PrivateFiles.path(canary))"

        let ready = await injector.inspect()
        #expect(ready.state == .ready)
        #expect(ready.socketName == socket)
        #expect(ready.windowCount == 1)
        #expect(ready.foreground == "zsh")

        #expect(await injector.type(command) == .typed(verified: true))
        try await Task.sleep(for: .milliseconds(500))
        #expect(harness.screenEnds(socket, with: "% " + command))
        #expect(!harness.exists(canary))

        guard case .refused(.promptNotIdle, _) = await injector.type("printf twice") else {
            Issue.record("a line with typed text is not an idle prompt")
            return
        }
        #expect(!harness.joinedScreen(socket).contains("printf twice"))
        harness.harnessKeys(socket, "\u{15}")
        #expect(await harness.waitFor { harness.lastLine(socket) == "%" ? true : nil } == true)
        #expect(!harness.exists(canary))
    }

    @Test func singleKeyQuestionIsNeverAnswered() async throws {
        let harness = try ScreenHarness()
        defer { harness.quitAll() }
        let name = ScreenHarness.uniqueName("yn")
        let socket = try await harness.startShell(name)
        // Positive marker: only the harness's own "n" below may create it.
        let marker = harness.workDirectory.appending(path: "MARKER_answered_by_harness", directoryHint: .notDirectory)
        harness.harnessKeys(socket, "printf 'Proceed [yn]? '; read -k1 x; touch \(PrivateFiles.path(marker))\r")
        #expect(await harness.waitFor { harness.lastLine(socket) == "Proceed [yn]?" ? true : nil } == true)
        let injector = try harness.injector(session: name)

        let inspection = await injector.inspect()
        #expect(inspection.state == .promptNotIdle)
        #expect(inspection.foreground == "zsh")
        guard case .refused(.promptNotIdle, _) = await injector.type("yarn build") else {
            Issue.record("a [yn] question must be refused")
            return
        }
        try await Task.sleep(for: .milliseconds(400))
        #expect(harness.lastLine(socket) == "Proceed [yn]?")
        #expect(!harness.exists(marker))

        harness.harnessKeys(socket, "n")
        #expect(await harness.waitFor { harness.exists(marker) ? true : nil } == true)
    }

    @Test func catInTheForegroundIsRefused() async throws {
        let harness = try ScreenHarness()
        defer { harness.quitAll() }
        let name = ScreenHarness.uniqueName("cat")
        let socket = try await harness.startShell(name)
        harness.harnessKeys(socket, "cat\r")
        let injector = try harness.injector(session: name)
        let refused = try #require(await harness.waitFor { () -> ScreenInspection? in
            let inspection = await injector.inspect()
            return inspection.state == .foregroundNotShell ? inspection : nil
        })
        #expect(refused.foreground == "cat")
        let canary = harness.canary("CAT")
        guard case .refused(.foregroundNotShell, _) = await injector.type("touch \(PrivateFiles.path(canary))") else {
            Issue.record("cat in the foreground must be refused")
            return
        }
        harness.harnessKeys(socket, "\u{04}")
        #expect(await harness.waitFor { harness.lastLine(socket) == "%" ? true : nil } == true)
        #expect(await injector.inspect().state == .ready)
        #expect(!harness.exists(canary))
    }

    @Test func missingWindowAndSecondWindowAreRefused() async throws {
        let harness = try ScreenHarness()
        defer { harness.quitAll() }
        let name = ScreenHarness.uniqueName("win")
        let socket = try await harness.startShell(name)

        let seventh = try harness.injector(session: name, window: "7")
        #expect(await seventh.currentTarget().state == .windowMissing)
        // Before a write window 0 also counts as another window, so either refusal is correct here.
        guard case .refused(let code, _) = await seventh.type("printf seven"),
              code == .windowMissing || code == .multipleWindows
        else {
            Issue.record("-p 7 must be refused")
            return
        }
        #expect(!harness.joinedScreen(socket).contains("printf seven"))

        harness.run(["-S", socket, "-X", "screen", "/bin/zsh", "-f"])
        let injector = try harness.injector(session: name)
        let inspection = try #require(await harness.waitFor { () -> ScreenInspection? in
            let inspection = await injector.inspect(.status)
            return inspection.state == .multipleWindows ? inspection : nil
        })
        #expect(inspection.windowCount == 2)
        #expect(await injector.inspect(.beforeWrite).state == .multipleWindows)
        guard case .refused(.multipleWindows, _) = await injector.type("printf two") else {
            Issue.record("a second window must be refused")
            return
        }
    }

    @Test func aZombieWindowZeroIsAnotherWindowEvenWithOneShell() async throws {
        let harness = try ScreenHarness()
        defer { harness.quitAll() }
        let name = ScreenHarness.uniqueName("zomb")
        let screenrc = try harness.screenrc("zombie", contents: "zombie kr\n")
        let socket = try await harness.start(name, command: ["/usr/bin/true"], screenrc: screenrc)
        #expect(await harness.waitFor { harness.hardcopy(socket).contains("terminated") ? true : nil } == true)
        harness.run(["-S", socket, "-X", "screen", "/bin/zsh", "-f"])
        #expect(await harness.waitFor { harness.hardcopy(socket, window: "1").contains("%") ? true : nil } == true)
        let injector = try harness.injector(session: name)

        let inspection = await injector.inspect(.beforeWrite)
        #expect(inspection.state == .multipleWindows)
        #expect(inspection.detail.contains("ventana 1"))
        let before = harness.hardcopy(socket, window: "1")
        guard case .refused(.multipleWindows, _) = await injector.type("printf zombie") else {
            Issue.record("a zombie window 0 next to a shell window must be refused")
            return
        }
        #expect(harness.hardcopy(socket, window: "1") == before)
        #expect(!harness.hardcopy(socket).contains("printf zombie"))
    }

    @Test func exactNameIsResolvedByPidAndDuplicatesAreRefused() async throws {
        let harness = try ScreenHarness()
        defer { harness.quitAll() }
        let name = ScreenHarness.uniqueName("pre")
        let exact = try await harness.startShell(name)
        let longer = try await harness.startShell(name + "x")

        let injector = try harness.injector(session: name)
        #expect(await injector.type("printf exact-only") == .typed(verified: true))
        #expect(harness.screenEnds(exact, with: "% printf exact-only"))
        #expect(!harness.joinedScreen(longer).contains("exact-only"))
        harness.harnessKeys(exact, "\u{15}")

        let twin = try await harness.startShell(name)
        let inspection = await injector.inspect()
        #expect(inspection.state == .ambiguousSession)
        #expect(Set(inspection.candidates.map(\.socketName)) == [exact, twin])
        #expect(!harness.joinedScreen(twin).contains("printf"))
    }

    @Test func phoneWriteReachesTheRealPromptThroughTheHelperLoop() async throws {
        let harness = try ScreenHarness()
        defer { harness.quitAll() }
        let name = ScreenHarness.uniqueName("e2e")
        let socket = try await harness.startShell(name)
        let secret = Data((0..<20).map { UInt8($0) })
        let phone = PhoneBridgeSession(secret: secret, phoneID: UUID(), port: 0)
        let port = try await phone.start()
        let journalURL = harness.root.appending(path: "Logs dir/writes.log", directoryHint: .notDirectory)
        let key = HelperConfig().journalSymmetricKey
        let journal = try WriteJournal(fileURL: journalURL, key: key, session: name, window: "0", device: "simulator")
        let console = HelperConsole(sink: { _ in })
        let engine = HelperBridgeSession(
            secret: secret,
            helperID: UUID(),
            helperName: "tonamox-bridge 1 · it",
            injector: try harness.injector(session: name),
            recentWrites: RecentWriteIDs(),
            recorder: ReportingRecorder(journal: journal, console: console, targetLabel: "\(name):0")
        )
        let session = HelperSession(engine: engine, dialer: SimulatorDialer(port: port), console: console, journal: journal)
        let loop = Task { await session.run() }
        defer { loop.cancel() }
        #expect(await eventually { await phone.latestStatus?.target.state == .ready })

        let canary = harness.canary("E2E")
        let command = "touch \(PrivateFiles.path(canary))"
        let id = UUID()
        let ack = try await phone.write(text: command, id: id)
        #expect(ack.result == .typed)
        #expect(ack.verified)
        #expect(ack.bytes == command.utf8.count)
        #expect(ack.textSHA256 == BridgeDigest.sha256Hex(command))
        try await Task.sleep(for: .milliseconds(400))
        let retry = try await phone.write(text: command, id: id)
        #expect(retry.result == .alreadyTyped)
        #expect(harness.screenEnds(socket, with: "% " + command))
        #expect(!harness.screenEnds(socket, with: command + command))
        #expect(!harness.exists(canary))

        await session.stop()
        await loop.value
        await phone.stop()
        journal.close()
        let log = try String(contentsOf: journalURL, encoding: .utf8)
        #expect(!log.contains(command))
        #expect(log.contains(BridgeDigest.hmacSHA256Hex(command, key: key)))
        #expect(try WriteJournal.typedWriteIDs(at: journalURL) == [id])
        #expect(fileMode(journalURL) == 0o600)
    }
}
#endif
