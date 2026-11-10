import Foundation

/// One line of a shell block that can get its own "Escribir" button.
public struct CommandCandidate: Identifiable, Hashable, Sendable {
    public static let multilineNote = "Forma parte de un comando de varias líneas: no se puede escribir línea a "
        + "línea. Pide una versión en una sola línea."

    public let id: UUID
    /// Exactly what would be typed: indentation, one "$ " or "% " prompt and trailing blanks removed.
    public let text: String
    public let sourceLine: String
    /// Index of `sourceLine` inside the block body.
    public let lineIndex: Int
    public let violations: [CommandTextViolation]
    public let warnings: [RiskyRule]
    public let isPartOfMultilineCommand: Bool

    /// Lines of a multi-line command are not typeable: after the first Enter the shell shows its
    /// continuation prompt, which the helper's idle check refuses.
    public var isTypeable: Bool { violations.isEmpty && !isPartOfMultilineCommand }

    public init(
        id: UUID = UUID(),
        text: String,
        sourceLine: String,
        lineIndex: Int,
        isPartOfMultilineCommand: Bool
    ) {
        self.id = id
        self.text = text
        self.sourceLine = sourceLine
        self.lineIndex = lineIndex
        self.violations = CommandTextPolicy.validate(text)
        self.warnings = RiskyCommandRules.evaluate(text)
        self.isPartOfMultilineCommand = isPartOfMultilineCommand
    }
}

/// A fenced block. Only shell languages produce candidates.
public struct CodeBlock: Hashable, Sendable {
    public let language: String
    public let lines: [String]
    public let isShell: Bool
    public let candidates: [CommandCandidate]
    /// False when the reply ended before the closing fence.
    public let isClosed: Bool
}

public enum ReplySegment: Hashable, Sendable {
    /// Plain text; the UI must not render it as Markdown (no tappable links).
    case prose(String)
    case code(CodeBlock)
}

/// Splits a finished model reply into prose and fenced blocks (``` or ~~~).
public enum CodeBlockParser {
    public static let shellLanguages: Set<String> = [
        "bash", "sh", "zsh", "shell", "console", "",
        "shell-session", "sh-session", "bash-session", "zsh-session", "terminal",
    ]

    private struct OpenFence {
        let marker: Character
        let length: Int
        let language: String
        var body: [String] = []
    }

    public static func parse(_ markdown: String) -> [ReplySegment] {
        var segments: [ReplySegment] = []
        var prose: [String] = []
        var fence: OpenFence?
        for line in splitLines(markdown) {
            if var open = fence {
                if isClosingFence(line, of: open) {
                    segments.append(makeCodeSegment(open, isClosed: true))
                    fence = nil
                } else {
                    open.body.append(line)
                    fence = open
                }
            } else if let opened = openingFence(line) {
                appendProse(&prose, to: &segments)
                fence = opened
            } else {
                prose.append(line)
            }
        }
        if let open = fence {
            segments.append(makeCodeSegment(open, isClosed: false))
        }
        appendProse(&prose, to: &segments)
        return segments
    }

    /// Candidates for the body lines of a shell block.
    public static func candidates(fromShellLines lines: [String]) -> [CommandCandidate] {
        let commands = lines.map(normalizedCommand)
        let blockIsMultiline = commands.contains { command in
            guard let command else { return false }
            return opensCompoundOrHeredoc(command)
        }
        var candidates: [CommandCandidate] = []
        var continuesPrevious = false
        for (index, command) in commands.enumerated() {
            guard let command else { continue }
            let continuesNext = endsWithContinuation(command)
            let isMultiline = blockIsMultiline || continuesPrevious || continuesNext
            candidates.append(makeCandidate(command, source: lines[index], index: index, isMultiline: isMultiline))
            continuesPrevious = continuesNext
        }
        return candidates
    }

    // MARK: Fences

    // "\r\n" is a single Character in Swift, so splitting on "\n" alone would miss it.
    private static func splitLines(_ text: String) -> [String] {
        text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }
            .map(String.init)
    }

    private static func openingFence(_ line: String) -> OpenFence? {
        let trimmed = line.drop { $0 == " " }
        guard line.count - trimmed.count <= 3, let marker = trimmed.first, marker == "`" || marker == "~" else {
            return nil
        }
        let run = trimmed.prefix { $0 == marker }
        guard run.count >= 3 else { return nil }
        let info = trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
        if marker == "`" && info.contains("`") { return nil }
        return OpenFence(marker: marker, length: run.count, language: normalizedLanguage(info))
    }

    /// The fence tag as small models write it ("bash:", "{bash}", "{.sh}", "Zsh;"), lowercased. The
    /// result must still match `shellLanguages` exactly.
    static func normalizedLanguage(_ info: String) -> String {
        let word = info.split(whereSeparator: \.isWhitespace).first?.lowercased() ?? ""
        var tag = word.drop { $0 == "{" || $0 == "." }
        while let last = tag.last, "}:;,.".contains(last) {
            tag = tag.dropLast()
        }
        return String(tag)
    }

    private static func isClosingFence(_ line: String, of fence: OpenFence) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= fence.length && trimmed.allSatisfy { $0 == fence.marker }
    }

    private static func makeCodeSegment(_ fence: OpenFence, isClosed: Bool) -> ReplySegment {
        let isShell = shellLanguages.contains(fence.language)
        let block = CodeBlock(
            language: fence.language,
            lines: fence.body,
            isShell: isShell,
            candidates: isShell ? candidates(fromShellLines: fence.body) : [],
            isClosed: isClosed
        )
        return .code(block)
    }

    private static func appendProse(_ lines: inout [String], to segments: inout [ReplySegment]) {
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        lines.removeAll()
        if !text.isEmpty { segments.append(.prose(text)) }
    }

    // MARK: Lines

    /// The command a line would type, or nil for blank and comment lines.
    static func normalizedCommand(_ line: String) -> String? {
        var text = Substring(line).drop { $0 == " " || $0 == "\t" }
        if text.hasPrefix("$ ") || text.hasPrefix("% ") {
            text = text.dropFirst(2)
        }
        while let last = text.last, last == " " || last == "\t" || last == "\r" {
            text = text.dropLast()
        }
        guard !text.isEmpty, !text.hasPrefix("#") else { return nil }
        return String(text)
    }

    private static let compoundClosers: [String: String] = [
        "for": "done", "while": "done", "until": "done", "select": "done", "if": "fi", "case": "esac"
    ]
    private static let compoundContinuations: Set<String> = [
        "do", "done", "then", "fi", "else", "elif", "esac", "}"
    ]

    private static func opensCompoundOrHeredoc(_ command: String) -> Bool {
        if command.contains("<<") && !command.contains("<<<") { return true }
        if command.hasSuffix("{") { return true }
        let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first else { return false }
        if compoundContinuations.contains(first) { return true }
        if let closer = compoundClosers[first] { return !command.contains(closer) }
        return false
    }

    private static func endsWithContinuation(_ command: String) -> Bool {
        command.hasSuffix("\\") || command.hasSuffix("|") || command.hasSuffix("&&") || command.hasSuffix("||")
    }

    private static func makeCandidate(
        _ text: String,
        source: String,
        index: Int,
        isMultiline: Bool
    ) -> CommandCandidate {
        CommandCandidate(text: text, sourceLine: source, lineIndex: index, isPartOfMultilineCommand: isMultiline)
    }
}
