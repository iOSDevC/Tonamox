#if os(macOS)
import Testing
@testable import TerminalBridgeHelper

@Suite struct ScreenListParserTests {
    @Test func parsesASingleDetachedSessionWithCRLFHeader() {
        let entries = ScreenListParser.parse(ScreenFixtures.oneDetached)
        #expect(entries == [ScreenSessionEntry(pid: 53730, name: "tnx-h1", status: "Detached")])
        #expect(entries.first?.socketName == "53730.tnx-h1")
    }

    @Test func noSocketsFoundIsEmpty() {
        #expect(ScreenListParser.parse(ScreenFixtures.none).isEmpty)
        #expect(ScreenListParser.match("tonamox", in: []) == .missing)
    }

    @Test func exactNameWinsOverAPrefixSibling() {
        let entries = ScreenListParser.parse(ScreenFixtures.prefixPair)
        #expect(entries.map(\.socketName) == ["54553.tnx-h1x", "54557.tnx-dead", "53730.tnx-h1"])
        #expect(ScreenListParser.match("tnx-h1", in: entries) == .found(entries[2]))
        #expect(ScreenListParser.match("tnx-h1x", in: entries) == .found(entries[0]))
        #expect(ScreenListParser.match("tnx-h", in: entries) == .missing)
    }

    @Test func deadAndRemovedSessionsNeverMatch() {
        let dead = ScreenListParser.parse(ScreenFixtures.withDead)
        #expect(dead[1].status == "Dead ???")
        #expect(dead[1].isDead)
        #expect(ScreenListParser.match("tnx-dead", in: dead) == .missing)
        let wiped = ScreenListParser.parse(ScreenFixtures.wiped)
        #expect(wiped[1].status == "Removed")
        #expect(ScreenListParser.match("tnx-dead", in: wiped) == .missing)
    }

    @Test func attachedSessionsAreUsable() {
        let entries = ScreenListParser.parse(ScreenFixtures.attached)
        #expect(entries[0].status == "Attached")
        #expect(ScreenListParser.match("tnx-h1x", in: entries) == .found(entries[0]))
        let multi = ScreenListParser.parse("There is a screen on:\r\n\t901.tonamox\t(Multi, attached)\n")
        #expect(multi == [ScreenSessionEntry(pid: 901, name: "tonamox", status: "Multi, attached")])
    }

    @Test func twoSessionsWithTheSameNameAreAmbiguous() {
        let entries = ScreenListParser.parse(ScreenFixtures.duplicates)
        #expect(ScreenListParser.match("tnx-dup", in: entries) == .ambiguous(entries))
    }

    @Test func ignoresMalformedLines() {
        let output = "\tnotapid.name\t(Detached)\n\t12.\t(Detached)\n\t13.ok\tDetached\nrandom\n\t14.ok\t(Detached)\n"
        #expect(ScreenListParser.parse(output).map(\.socketName) == ["14.ok"])
    }

    @Test func readsTheScreenVersion() {
        #expect(ScreenVersionCheck.version(in: ScreenFixtures.version) == "4.00.03")
        #expect(ScreenVersionCheck.version(in: "Screen version 4.09.01 (GNU) 20-Aug-23\n") == "4.09.01")
        #expect(ScreenVersionCheck.version(in: "tmux 3.4") == nil)
    }

    @Test func versionCheckRefusesAnythingButTheBundledScreen() async {
        let supported = await ScreenVersionCheck.check(runner: FakeProcessRunner())
        #expect(supported == .supported("4.00.03"))
        let missing = await ScreenVersionCheck.check(runner: FakeProcessRunner(), screenPath: "/nonexistent/screen")
        guard case .unavailable = missing else {
            Issue.record("expected unavailable, got \(missing)")
            return
        }
    }
}

@Suite struct ProcessTableTests {
    @Test func parsesPsRowsIncludingCommandsWithSpaces() {
        let table = ProcessTable(parsing: ScreenFixtures.idleShellTable)
        #expect(table.entries.count == 4)
        let login = table.process(53732)
        #expect(login?.uid == 0)
        #expect(login?.ruid == 501)
        #expect(login?.tty == "ttys000")
        #expect(login?.name == "login")
        #expect(table.process(412)?.command == "/Applications/Some App.app/Contents/MacOS/Some App")
        #expect(table.process(53730)?.hasTerminal == false)
        #expect(table.children(of: 53730).map(\.pid) == [53732])
    }

    @Test func namesDropPathsAndTheLoginDash() {
        let entry = ProcessEntry(pid: 1, ppid: 0, pgid: 1, tpgid: 1, uid: 0, ruid: 0, stat: "S", tty: "??", command: "-zsh")
        #expect(entry.name == "zsh")
        #expect(ProcessTable(parsing: "  7  1  7  7  501  501 S+ ttys001 /bin/bash").process(7)?.name == "bash")
    }

    @Test func skipsTruncatedRows() {
        #expect(ProcessTable(parsing: "1 0 1 1 0 0 Ss\n2 1 2\n").entries.isEmpty)
    }

    @Test func idleShellPasses() {
        let report = WindowProcessReport.analyze(ProcessTable(parsing: ScreenFixtures.idleShellTable), screenPID: 53730, userID: 501)
        #expect(report.verdict == .shellInForeground)
        #expect(report.foreground == "zsh")
        #expect(report.shell?.pid == 53733)
    }

    @Test func catInTheForegroundIsRefusedByName() {
        let report = WindowProcessReport.analyze(
            ProcessTable(parsing: ScreenFixtures.catInForegroundTable), screenPID: 53730, userID: 501
        )
        #expect(report.verdict == .notShell("cat"))
        #expect(report.foreground == "cat")
    }

    @Test func twoWindowsAreRefused() {
        let report = WindowProcessReport.analyze(ProcessTable(parsing: ScreenFixtures.twoWindowsTable), screenPID: 53730, userID: 501)
        #expect(report.verdict == .multipleWindows(2))
        #expect(report.windowCount == 2)
    }

    @Test func rootShellUnderSuIsRefused() {
        let report = WindowProcessReport.analyze(ProcessTable(parsing: ScreenFixtures.rootShellTable), screenPID: 53730, userID: 501)
        #expect(report.verdict == .notShell("zsh"))
    }

    @Test func shellOfAnotherUserIsRefused() {
        let report = WindowProcessReport.analyze(ProcessTable(parsing: ScreenFixtures.idleShellTable), screenPID: 53730, userID: 502)
        #expect(report.verdict == .notShell("zsh (uid 501)"))
    }

    @Test func nestedShellIsRefused() {
        let nested = ScreenFixtures.idleShellTable
            .replacingOccurrences(of: "53733 53732 53733 53733   501   501 S+", with: "53733 53732 53733 53800   501   501 S ")
            + "\n53800 53733 53800 53800   501   501 S+   ttys000  zsh"
        let report = WindowProcessReport.analyze(ProcessTable(parsing: nested), screenPID: 53730, userID: 501)
        #expect(report.verdict == .notShell("zsh"))
    }

    @Test func windowWithoutAShellIsRefused() {
        let table = """
        53730     1 53730     0   501   501 Ss   ??       /usr/bin/SCREEN
        53732 53730 53732 53733     0   501 Ss   ttys000  login
        53733 53732 53733 53733   501   501 S+   ttys000  /usr/bin/python3
        """
        let report = WindowProcessReport.analyze(ProcessTable(parsing: table), screenPID: 53730, userID: 501)
        #expect(report.verdict == .notShell("python3"))
        let bare = WindowProcessReport.analyze(
            ProcessTable(parsing: "53730 1 53730 0 501 501 Ss ?? /usr/bin/SCREEN"), screenPID: 53730, userID: 501
        )
        #expect(bare.verdict == .noWindow)
    }
}
#endif
