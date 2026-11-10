#if os(macOS)
import Foundation

/// One line of `screen -ls`, e.g. "\t53730.tonamox\t(Detached)".
public struct ScreenSessionEntry: Equatable, Sendable {
    public let pid: Int32
    public let name: String
    /// Text inside the last parentheses: "Detached", "Attached", "Multi, attached", "Dead ???".
    public let status: String

    public init(pid: Int32, name: String, status: String) {
        self.pid = pid
        self.name = name
        self.status = status
    }

    /// `pid.name`: the only form `-S` matches exactly (a bare name matches by prefix).
    public var socketName: String {
        "\(pid).\(name)"
    }

    public var isDead: Bool {
        status.hasPrefix("Dead") || status == "Removed"
    }
}

public enum ScreenSessionMatch: Equatable, Sendable {
    case missing
    case found(ScreenSessionEntry)
    case ambiguous([ScreenSessionEntry])
}

/// Parses `screen -ls` from screen 4.00.03. Its exit code is 1 with or without sessions,
/// so callers ignore it and rely on this parser.
public enum ScreenListParser {
    public static func parse(_ output: String) -> [ScreenSessionEntry] {
        output.split(whereSeparator: \.isNewline).compactMap(entry(from:))
    }

    /// Exact name match among live sessions; zero or several matches are refusals.
    public static func match(_ name: String, in entries: [ScreenSessionEntry]) -> ScreenSessionMatch {
        let matches = entries.filter { $0.name == name && !$0.isDead }
        switch matches.count {
        case 0: return .missing
        case 1: return .found(matches[0])
        default: return .ambiguous(matches)
        }
    }

    static func entry(from line: Substring) -> ScreenSessionEntry? {
        guard line.first == "\t" else { return nil }
        let fields = line.dropFirst().split(separator: "\t", omittingEmptySubsequences: true)
        guard fields.count >= 2, let socket = fields.first, let statusField = fields.last else { return nil }
        guard statusField.hasPrefix("("), statusField.hasSuffix(")") else { return nil }
        guard let dot = socket.firstIndex(of: ".") else { return nil }
        guard let pid = Int32(socket[..<dot]), pid > 0 else { return nil }
        let name = socket[socket.index(after: dot)...]
        guard !name.isEmpty else { return nil }
        return ScreenSessionEntry(
            pid: pid,
            name: String(name),
            status: String(statusField.dropFirst().dropLast())
        )
    }
}

/// `screen -v` must report exactly 4.00.03: its `-X stuff` is literal, newer builds may not be.
public enum ScreenVersionCheck {
    public static let requiredVersion = "4.00.03"
    public static let defaultScreenPath = "/usr/bin/screen"

    public enum Outcome: Equatable, Sendable {
        case supported(String)
        case unsupported(String)
        case unavailable(String)
    }

    /// "Screen version 4.00.03 (FAU) 23-Oct-06" gives "4.00.03".
    public static func version(in output: String) -> String? {
        let marker = "Screen version "
        guard let range = output.range(of: marker) else { return nil }
        let version = output[range.upperBound...].prefix { !$0.isWhitespace }
        return version.isEmpty ? nil : String(version)
    }

    public static func check(runner: any ProcessRunner, screenPath: String = defaultScreenPath) async -> Outcome {
        let result = await runner.run(screenPath, ["-v"])
        guard result.didLaunch else {
            return .unavailable("No se pudo ejecutar \(screenPath): \(result.launchError ?? "")")
        }
        let output = result.stdoutText + result.stderrText
        guard let found = version(in: output) else {
            return .unsupported(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return found == requiredVersion ? .supported(found) : .unsupported(found)
    }
}
#endif
