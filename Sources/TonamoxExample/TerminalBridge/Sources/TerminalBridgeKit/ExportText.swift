import Foundation

/// Escaping, file names and dates shared by the Markdown, JSON, CSV and PDF exports.
public enum ExportText {
    private static let fileTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter
    }()

    // Never mutated after this closure, so sharing it across threads is safe.
    nonisolated(unsafe) private static let isoTimestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// "20261120-0930", in UTC: the date part of an export file name.
    public static func timestamp(_ date: Date) -> String {
        fileTimestamp.string(from: date)
    }

    /// "2026-11-20T09:30:00Z".
    public static func isoDate(_ date: Date) -> String {
        isoTimestamp.string(from: date)
    }

    /// `modelTitle` folded to `[a-z0-9-]`, at most 40 characters; "modelo" when nothing is left.
    public static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                                   locale: Locale(identifier: "en_US_POSIX")).lowercased()
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        let mapped = String(folded.map { allowed.contains($0) ? $0 : "-" })
        let words = mapped.split(separator: "-", omittingEmptySubsequences: true)
        let joined = String(words.joined(separator: "-").prefix(40))
        let trimmed = joined.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "modelo" : trimmed
    }

    // MARK: Markdown

    /// A table cell: `\`, `|`, `<`, `>` and `&` escaped, line breaks as spaces. Grader reasons quote model text,
    /// so a cell must never become HTML or an entity.
    public static func markdownCell(_ text: String) -> String {
        revealingInvisibles(text)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "&", with: "\\&")
            .replacingOccurrences(of: "<", with: "\\<")
            .replacingOccurrences(of: ">", with: "\\>")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static let inlineSpecials = Set("\\`*_[]<>!#|&")

    /// Text outside a table that must not turn into emphasis, links, images, headings or HTML.
    public static func markdownInline(_ text: String) -> String {
        var escaped = ""
        for character in revealingInvisibles(text) {
            if inlineSpecials.contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        // A lone CR is a CommonMark line end too: it could start a heading, a list or a rule.
        return escaped.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// A fenced block whose fence is one backtick longer than the longest run inside, at least three.
    public static func fenced(_ text: String, info: String = "") -> String {
        var longest = 0
        var run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        let body = text.hasSuffix("\n") ? String(text.dropLast()) : text
        return fence + info + "\n" + body + "\n" + fence
    }

    /// Bidirectional overrides and zero-width characters shown as `<U+202E>`, so a reply cannot reorder or hide
    /// what the reader sees.
    public static func revealingInvisibles(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isInvisibleControl) else { return text }
        var shown = ""
        for scalar in text.unicodeScalars {
            if isInvisibleControl(scalar) {
                shown += codeLabel(scalar)
            } else {
                shown.unicodeScalars.append(scalar)
            }
        }
        return shown
    }

    private static func codeLabel(_ scalar: Unicode.Scalar) -> String {
        "<U+" + String(scalar.value, radix: 16, uppercase: true) + ">"
    }

    private static func isInvisibleControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x202A...0x202E, 0x2066...0x2069, 0x200B...0x200D, 0xFEFF: true
        default: false
        }
    }

    // MARK: CSV

    private static let formulaStarts: Set<Unicode.Scalar> = ["=", "+", "-", "@", "\t", "\r"]

    /// A text cell (RFC 4180). One that a spreadsheet would read as a formula gets a leading `'`.
    public static func csvField(_ text: String) -> String {
        var cell = text
        // By scalar: "=" with a combining mark, or CR LF, is a different Character but still starts a formula.
        if let first = cell.unicodeScalars.first, formulaStarts.contains(first) {
            cell = "'" + cell
        }
        let needsQuotes = cell.contains { $0 == "," || $0 == "\"" || $0.isNewline }
            || cell.first?.isWhitespace == true || cell.last?.isWhitespace == true
        guard needsQuotes else { return cell }
        return "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// A number cell: never prefixed, empty for nil, "." as decimal point.
    public static func csvNumber(_ value: Int?) -> String {
        value.map(String.init) ?? ""
    }

    public static func csvNumber(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    // MARK: PDF

    /// Pieces of at most `maxLines` lines and `maxCharacters` characters, cut at line ends when possible, so a long
    /// reply never makes one block taller than a page.
    public static func chunks(_ text: String, maxLines: Int = 28, maxCharacters: Int = 1800) -> [String] {
        let lines = text.components(separatedBy: "\n").flatMap { hardWrapped($0, width: maxCharacters) }
        var pieces: [[String]] = []
        var current: [String] = []
        var characters = 0
        for line in lines {
            if !current.isEmpty, current.count >= maxLines || characters + line.count > maxCharacters {
                pieces.append(current)
                current.removeAll()
                characters = 0
            }
            current.append(line)
            characters += line.count + 1
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces.map { $0.joined(separator: "\n") }
    }

    /// Cuts after the last space in each window when there is one past its middle, else at the window's end.
    private static func hardWrapped(_ line: String, width: Int) -> [String] {
        guard line.count > width, width > 0 else { return [line] }
        var pieces: [Substring] = []
        var rest = line[...]
        while rest.count > width {
            let window = rest.prefix(width)
            let middle = window.index(window.startIndex, offsetBy: width / 2)
            let cut = window[middle...].lastIndex(of: " ").map { window.index(after: $0) } ?? window.endIndex
            pieces.append(rest[..<cut])
            rest = rest[cut...]
        }
        pieces.append(rest)
        return pieces.map(String.init)
    }
}
