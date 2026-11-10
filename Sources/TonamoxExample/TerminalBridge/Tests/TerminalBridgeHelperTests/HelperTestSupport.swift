#if os(macOS)
import Darwin
import Foundation
import Synchronization
@testable import TerminalBridgeHelper
import TerminalBridgeKit

/// Real `/usr/bin/screen` 4.00.03 and `ps` outputs captured on this Mac (2026-11-05) in a
/// private SCREENDIR; only the SCREENDIR path is shortened.
enum ScreenFixtures {
    static let socketDir = "/private/tmp/tnx-fixture/screendir"

    static let version = "Screen version 4.00.03 (FAU) 23-Oct-06\n"

    static let oneDetached = "There is a screen on:\r\n\t53730.tnx-h1\t(Detached)\n1 Socket in \(socketDir).\n\n"

    static let prefixPair = """
    There are screens on:\r
    \t54553.tnx-h1x\t(Detached)
    \t54557.tnx-dead\t(Detached)
    \t53730.tnx-h1\t(Detached)
    3 Sockets in \(socketDir).

    """

    static let withDead = """
    There are screens on:\r
    \t54553.tnx-h1x\t(Detached)
    \t54557.tnx-dead\t(Dead ???)
    \t53730.tnx-h1\t(Detached)
    Remove dead screens with 'screen -wipe'.
    3 Sockets in \(socketDir).

    """

    static let wiped = """
    There are screens on:\r
    \t54553.tnx-h1x\t(Detached)
    \t54557.tnx-dead\t(Removed)
    \t53730.tnx-h1\t(Detached)
    1 socket wiped out.
    2 Sockets in \(socketDir).

    """

    static let attached = """
    There are screens on:\r
    \t54553.tnx-h1x\t(Attached)
    \t53730.tnx-h1\t(Detached)
    2 Sockets in \(socketDir).

    """

    static let none = "No Sockets found in \(socketDir).\n"

    /// Two live sessions with the exact same name (screen allows it).
    static let duplicates = """
    There are screens on:\r
    \t48105.tnx-dup\t(Detached)
    \t48102.tnx-dup\t(Detached)
    2 Sockets in \(socketDir).

    """

    /// SCREEN → login (uid 0, ruid 501) → zsh leading the foreground group.
    static let idleShellTable = """
    53730     1 53730     0   501   501 Ss   ??       /usr/bin/SCREEN
    53732 53730 53732 53733     0   501 Ss   ttys000  login
    53733 53732 53733 53733   501   501 S+   ttys000  zsh
      412     1   412     0   501   501 S    ??       /Applications/Some App.app/Contents/MacOS/Some App
    """

    static let catInForegroundTable = """
    53730     1 53730     0   501   501 Ss   ??       /usr/bin/SCREEN
    53732 53730 53732 54382     0   501 Ss   ttys000  login
    53733 53732 53733 54382   501   501 S    ttys000  zsh
    54382 53733 54382 54382   501   501 S+   ttys000  cat
    """

    static let twoWindowsTable = """
    53730     1 53730     0   501   501 Ss   ??       /usr/bin/SCREEN
    53732 53730 53732 53733     0   501 Ss   ttys000  login
    53733 53732 53733 53733   501   501 S+   ttys000  zsh
    54482 53730 54482 54483     0   501 Ss   ttys008  login
    54483 54482 54483 54483   501   501 S+   ttys008  zsh
    """

    /// `su` inside the window: root's zsh leads the foreground group.
    static let rootShellTable = """
    53730     1 53730     0   501   501 Ss   ??       /usr/bin/SCREEN
    53732 53730 53732 60002     0   501 Ss   ttys000  login
    53733 53732 53733 60002   501   501 S    ttys000  zsh
    60001 53733 60001 60002     0   501 S    ttys000  su
    60002 60001 60002 60002     0     0 S+   ttys000  -zsh
    """

    static let idleScreen = "% printf one\none\n%\n\n\n\n"
    static let yesNoScreen = "% printf 'Proceed [yn]? '; read -k1 x\nProceed [yn]?\n\n\n"
    static let halfTypedScreen = "% printf one\none\n% echo half\n\n"
}

/// A scripted stand-in for /usr/bin/screen and /bin/ps. Hardcopy requests write the scripted
/// screen into the requested file; with `echoesStuff`, stuffed text then shows at the prompt.
final class FakeProcessRunner: ProcessRunner {
    struct Script: Sendable {
        var listing = ScreenFixtures.oneDetached
        var processTable = ScreenFixtures.idleShellTable
        var screen: String? = ScreenFixtures.idleScreen
        /// Window numbers whose hardcopy gets `screen`; any other `-p` hardcopies 0 bytes, as screen does.
        var windows: Set<String> = ["0"]
        var stuffStatus: Int32 = 0
        var stuffError = ""
        var echoesStuff = true
        var psStatus: Int32 = 0
    }

    struct Invocation: Equatable, Sendable {
        let executable: String
        let arguments: [String]
    }

    private struct Log {
        var plan: Script
        var invocations: [Invocation] = []
        var hardcopyModes: [UInt16] = []
        var hardcopyPaths: [String] = []
    }

    private let ledger: Mutex<Log>

    init(_ script: Script = Script()) {
        ledger = Mutex(Log(plan: script))
    }

    var invocations: [Invocation] {
        ledger.withLock { $0.invocations }
    }

    var stuffInvocations: [[String]] {
        invocations.filter { $0.arguments.contains("stuff") }.map(\.arguments)
    }

    var hardcopyModes: [UInt16] {
        ledger.withLock { $0.hardcopyModes }
    }

    var hardcopyPaths: [String] {
        ledger.withLock { $0.hardcopyPaths }
    }

    func update(_ change: (inout Script) -> Void) {
        ledger.withLock { change(&$0.plan) }
    }

    func run(_ executable: String, _ arguments: [String]) async -> ProcessResult {
        ledger.withLock { state in
            state.invocations.append(Invocation(executable: executable, arguments: arguments))
            return respond(executable, arguments, &state)
        }
    }

    private func respond(_ executable: String, _ arguments: [String], _ state: inout Log) -> ProcessResult {
        if executable == ProcessTable.psPath {
            return ProcessResult(status: state.plan.psStatus, stdout: Data(state.plan.processTable.utf8))
        }
        guard executable == ScreenVersionCheck.defaultScreenPath else {
            return ProcessResult(status: -1, launchError: "unexpected \(executable)")
        }
        switch arguments.dropFirst(4).first == "-X" ? arguments[5] : arguments.first {
        case "-ls":
            return ProcessResult(status: 1, stdout: Data(state.plan.listing.utf8))
        case "-v":
            return ProcessResult(status: 1, stdout: Data(ScreenFixtures.version.utf8))
        case "hardcopy":
            writeHardcopy(to: arguments[6], window: arguments[3], &state)
            return ProcessResult(status: 0)
        case "stuff":
            if state.plan.stuffStatus == 0, state.plan.echoesStuff, let screen = state.plan.screen {
                state.plan.screen = Self.appendingToLastLine(screen, " " + arguments[6])
            }
            return ProcessResult(status: state.plan.stuffStatus, stderr: Data(state.plan.stuffError.utf8))
        default:
            return ProcessResult(status: 1, stderr: Data("unexpected \(arguments)".utf8))
        }
    }

    private func writeHardcopy(to path: String, window: String, _ state: inout Log) {
        var info = stat()
        if stat(path, &info) == 0 { state.hardcopyModes.append(UInt16(info.st_mode & 0o777)) }
        state.hardcopyPaths.append(path)
        guard state.plan.windows.contains(window), let screen = state.plan.screen else { return }
        FileManager.default.createFile(atPath: path, contents: Data(screen.utf8))
    }

    static func appendingToLastLine(_ screen: String, _ suffix: String) -> String {
        var lines = screen.components(separatedBy: "\n")
        guard let index = lines.lastIndex(where: { !$0.isEmpty }) else { return suffix }
        lines[index] += suffix
        return lines.joined(separator: "\n")
    }
}

/// A unique directory whose path contains a space, removed by `remove()`.
struct TemporaryDirectory {
    let location: URL

    init(_ label: String = "tonamox bridge tests") {
        location = FileManager.default.temporaryDirectory
            .appending(path: "\(label) \(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(
            atPath: location.path(percentEncoded: false),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    var path: String {
        let raw = location.path(percentEncoded: false)
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    func file(_ relative: String) -> URL {
        location.appending(path: relative, directoryHint: .notDirectory)
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }

    func contents() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }
}

func fileMode(_ url: URL) -> UInt16? {
    var info = stat()
    guard lstat(url.path(percentEncoded: false), &info) == 0 else { return nil }
    return UInt16(info.st_mode & 0o777)
}

func makeInjector(
    _ runner: FakeProcessRunner,
    scratch: TemporaryDirectory,
    session: String = "tnx-h1",
    window: String = "0",
    userID: UInt32 = 501,
    prompt: String = IdlePromptPattern.defaultPattern
) throws -> ScreenInjector {
    let settings = ScreenInjectorSettings(
        session: session,
        window: window,
        idlePrompt: try IdlePromptPattern(prompt),
        scratchDirectory: scratch.location,
        userID: userID,
        verificationAttempts: 3,
        verificationInterval: .milliseconds(1),
        emptyHardcopyRereads: 1,
        emptyHardcopyRereadInterval: .milliseconds(1)
    )
    return ScreenInjector(settings: settings, runner: runner)
}

/// Polls `condition` in real time until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// Collects console lines in memory.
final class LineSink: Sendable {
    private let storage = Mutex<[String]>([])

    var lines: [String] {
        storage.withLock { $0 }
    }

    var joined: String {
        lines.joined(separator: "\n")
    }

    func append(_ line: String) {
        storage.withLock { $0.append(line) }
    }
}
#endif
