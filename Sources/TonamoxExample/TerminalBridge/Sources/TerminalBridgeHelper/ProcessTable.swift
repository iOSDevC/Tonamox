#if os(macOS)
import Foundation

/// One row of `ps -A -o pid=,ppid=,pgid=,tpgid=,uid=,ruid=,stat=,tty=,comm=`.
public struct ProcessEntry: Equatable, Sendable {
    public let pid: Int32
    public let ppid: Int32
    public let pgid: Int32
    /// Foreground process group of the controlling terminal.
    public let tpgid: Int32
    public let uid: UInt32
    public let ruid: UInt32
    public let stat: String
    /// "ttys003", or "??" without a controlling terminal.
    public let tty: String
    /// Full executable path or login-shell name ("-zsh"); may contain spaces.
    public let command: String

    public init(
        pid: Int32,
        ppid: Int32,
        pgid: Int32,
        tpgid: Int32,
        uid: UInt32,
        ruid: UInt32,
        stat: String,
        tty: String,
        command: String
    ) {
        self.pid = pid
        self.ppid = ppid
        self.pgid = pgid
        self.tpgid = tpgid
        self.uid = uid
        self.ruid = ruid
        self.stat = stat
        self.tty = tty
        self.command = command
    }

    /// "zsh" for "/bin/zsh" or "-zsh".
    public var name: String {
        let base = command.split(separator: "/").last.map(String.init) ?? command
        return base.hasPrefix("-") ? String(base.dropFirst()) : base
    }

    public var hasTerminal: Bool {
        !tty.isEmpty && tty != "??"
    }
}

public struct ProcessTable: Sendable {
    public static let psPath = "/bin/ps"
    public static let psArguments = ["-A", "-o", "pid=,ppid=,pgid=,tpgid=,uid=,ruid=,stat=,tty=,comm="]

    public let entries: [ProcessEntry]

    public init(entries: [ProcessEntry]) {
        self.entries = entries
    }

    public init(parsing output: String) {
        entries = output.split(whereSeparator: \.isNewline).compactMap(Self.entry(from:))
    }

    public func process(_ pid: Int32) -> ProcessEntry? {
        entries.first { $0.pid == pid }
    }

    public func children(of pid: Int32) -> [ProcessEntry] {
        entries.filter { $0.ppid == pid }
    }

    static func entry(from line: Substring) -> ProcessEntry? {
        guard let split = fields(line, count: 8) else { return nil }
        let values = split.fields
        guard
            let pid = Int32(values[0]),
            let ppid = Int32(values[1]),
            let pgid = Int32(values[2]),
            let tpgid = Int32(values[3]),
            let uid = UInt32(values[4]),
            let ruid = UInt32(values[5])
        else { return nil }
        return ProcessEntry(
            pid: pid,
            ppid: ppid,
            pgid: pgid,
            tpgid: tpgid,
            uid: uid,
            ruid: ruid,
            stat: String(values[6]),
            tty: String(values[7]),
            command: String(split.rest)
        )
    }

    /// The first `count` blank-separated fields plus the untouched remainder (comm may hold spaces).
    static func fields(_ line: Substring, count: Int) -> (fields: [Substring], rest: Substring)? {
        var found: [Substring] = []
        var cursor = line.startIndex
        while found.count < count {
            cursor = line[cursor...].firstIndex { $0 != " " && $0 != "\t" } ?? line.endIndex
            guard cursor < line.endIndex else { return nil }
            let end = line[cursor...].firstIndex { $0 == " " || $0 == "\t" } ?? line.endIndex
            found.append(line[cursor..<end])
            cursor = end
        }
        let rest = line[cursor...].drop { $0 == " " || $0 == "\t" }
        guard !rest.isEmpty else { return nil }
        return (found, rest)
    }
}

/// What runs in a screen session's window, from the process tree: SCREEN → login → shell.
/// There is no window→tty mapping in screen 4.00.03, so only single-window sessions are accepted.
public struct WindowProcessReport: Equatable, Sendable {
    public enum Finding: Equatable, Sendable {
        case shellInForeground
        case noWindow
        case multipleWindows(Int)
        case notShell(String)
    }

    public static let allowedShells: Set<String> = ["zsh", "bash", "sh", "dash", "fish"]

    public let verdict: Finding
    public let windowCount: Int
    /// Name of the tty's foreground process group leader, when known.
    public let foreground: String?
    public let shell: ProcessEntry?

    public init(verdict: Finding, windowCount: Int, foreground: String?, shell: ProcessEntry?) {
        self.verdict = verdict
        self.windowCount = windowCount
        self.foreground = foreground
        self.shell = shell
    }

    /// Requires exactly one window whose login has a single shell child owned by `userID`
    /// (uid and ruid) that leads the tty's foreground process group.
    public static func analyze(_ table: ProcessTable, screenPID: Int32, userID: UInt32) -> WindowProcessReport {
        let windows = table.children(of: screenPID).filter(\.hasTerminal)
        guard windows.count == 1, let window = windows.first else {
            let verdict: Finding = windows.isEmpty ? .noWindow : .multipleWindows(windows.count)
            return WindowProcessReport(verdict: verdict, windowCount: windows.count, foreground: nil, shell: nil)
        }
        guard window.name == "login" else {
            return refusal(window.name, windowCount: 1, shell: nil)
        }
        let shells = table.children(of: window.pid).filter { $0.tty == window.tty }
        guard shells.count == 1, let shell = shells.first else {
            return refusal(shells.first?.name ?? window.name, windowCount: 1, shell: nil)
        }
        guard allowedShells.contains(shell.name) else {
            return refusal(shell.name, windowCount: 1, shell: shell)
        }
        guard shell.uid == userID, shell.ruid == userID else {
            return refusal("\(shell.name) (uid \(shell.uid))", windowCount: 1, shell: shell)
        }
        guard shell.tpgid == shell.pid else {
            let leader = table.process(shell.tpgid)
                ?? table.entries.first { $0.pgid == shell.tpgid && $0.tty == shell.tty }
            return refusal(leader?.name ?? "pgid \(shell.tpgid)", windowCount: 1, shell: shell)
        }
        return WindowProcessReport(verdict: .shellInForeground, windowCount: 1, foreground: shell.name, shell: shell)
    }

    private static func refusal(_ name: String, windowCount: Int, shell: ProcessEntry?) -> WindowProcessReport {
        WindowProcessReport(verdict: .notShell(name), windowCount: windowCount, foreground: name, shell: shell)
    }
}
#endif
