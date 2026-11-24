import Foundation

/// Unwraps LaTeX `\boxed{…}` answers, which math-tuned models write even in plain chat, for display.
///
/// Rules (the browser page's `AnswerFormat` in `app.js` follows the same ones, checked on shared fixtures):
/// - Fenced code blocks (``` or ~~~ lines) and inline code spans are never touched.
/// - Braces nest; `\{` and `\}` are literal. A `\boxed{` without its closing brace stays as written.
/// - Inside a box, `\text{…}`, `\textbf{…}` and `\mathrm{…}` keep only their content; so does a nested box.
/// - A math wrapper that holds nothing but one box (`$…$`, `$$…$$`, `\(…\)`, `\[…\]`, spaces, tabs and line
///   breaks allowed) goes too.
/// - A backtick fence line has no backtick after its marks; such a line is prose (CommonMark).
/// - ``display(_:)`` marks each box's content bold (`**…**`), unless the box already sits between emphasis marks
///   (`**\boxed{1}**`), and escapes `*`, `_` and backticks in it; ``plain(_:)`` keeps the content alone. The content
///   is trimmed of the whitespace JavaScript's `\s` matches. An empty box disappears.
public enum BoxedAnswer {
    public static func display(_ text: String) -> String {
        rewrite(text, bold: true)
    }

    public static func plain(_ text: String) -> String {
        rewrite(text, bold: false)
    }

    /// The text has at least one box outside code.
    public static func containsBox(_ text: String) -> Bool {
        plain(text) != text
    }

    // MARK: Regions

    private static func rewrite(_ text: String, bold: Bool) -> String {
        guard text.contains("\\boxed{") else { return text }
        var output = ""
        for region in regions(of: Array(text.unicodeScalars)) {
            switch region {
            case .code(let scalars): output.unicodeScalars.append(contentsOf: scalars)
            case .prose(let scalars): output += rewriteProse(scalars, bold: bold)
            }
        }
        return output
    }

    private enum Region {
        case prose([Unicode.Scalar])
        case code([Unicode.Scalar])
    }

    /// Splits into code (fenced blocks by line, then inline spans) and the prose between.
    private static func regions(of scalars: [Unicode.Scalar]) -> [Region] {
        var result: [Region] = []
        var prose: [Unicode.Scalar] = []
        var fence: (mark: Unicode.Scalar, count: Int)?
        var code: [Unicode.Scalar] = []
        for line in lines(of: scalars) {
            if let open = fence {
                code += line
                if let mark = fenceMark(of: line), mark.mark == open.mark, mark.count >= open.count,
                   isBareFence(line) {
                    result.append(.code(code))
                    code = []
                    fence = nil
                }
            } else if let mark = fenceMark(of: line) {
                result += inlineRegions(of: prose)
                prose = []
                fence = mark
                code = line
            } else {
                prose += line
            }
        }
        result += inlineRegions(of: prose)
        if !code.isEmpty { result.append(.code(code)) }
        return result
    }

    /// Lines with their terminators.
    private static func lines(of scalars: [Unicode.Scalar]) -> [[Unicode.Scalar]] {
        var result: [[Unicode.Scalar]] = []
        var current: [Unicode.Scalar] = []
        for scalar in scalars {
            current.append(scalar)
            if scalar == "\n" {
                result.append(current)
                current = []
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Up to three spaces, then three or more backticks or tildes.
    private static func fenceMark(of line: [Unicode.Scalar]) -> (mark: Unicode.Scalar, count: Int)? {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3, indent < line.count else { return nil }
        let mark = line[indent]
        guard mark == "`" || mark == "~" else { return nil }
        let count = line[indent...].prefix { $0 == mark }.count
        guard count >= 3 else { return nil }
        if mark == "`" && line[(indent + count)...].contains("`") { return nil }
        return (mark, count)
    }

    /// A closing fence carries nothing after its marks.
    private static func isBareFence(_ line: [Unicode.Scalar]) -> Bool {
        let rest = line.drop { $0 == " " }.drop { $0 == "`" || $0 == "~" }
        return rest.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
    }

    /// Inline code: a run of backticks up to the next run of the same length; an unmatched run is prose.
    private static func inlineRegions(of scalars: [Unicode.Scalar]) -> [Region] {
        guard !scalars.isEmpty else { return [] }
        var result: [Region] = []
        var prose: [Unicode.Scalar] = []
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "`" else {
                prose.append(scalars[index])
                index += 1
                continue
            }
            let run = scalars[index...].prefix { $0 == "`" }.count
            if let close = closingRun(of: run, in: scalars, from: index + run) {
                if !prose.isEmpty { result.append(.prose(prose)) }
                prose = []
                result.append(.code(slice(scalars, index, close + run)))
                index = close + run
            } else {
                prose += scalars[index..<(index + run)]
                index += run
            }
        }
        if !prose.isEmpty { result.append(.prose(prose)) }
        return result
    }

    private static func closingRun(of length: Int, in scalars: [Unicode.Scalar], from start: Int) -> Int? {
        var index = start
        while index < scalars.count {
            guard scalars[index] == "`" else {
                index += 1
                continue
            }
            let run = scalars[index...].prefix { $0 == "`" }.count
            if run == length { return index }
            index += run
        }
        return nil
    }

    // MARK: Boxes

    private static let boxOpen = Array("\\boxed{".unicodeScalars)
    /// Commands reduced to their content inside a box.
    private static let unwrappedCommands = ["\\boxed{", "\\text{", "\\textbf{", "\\mathrm{"]
        .map { Array($0.unicodeScalars) }
    /// Opening and closing math wrappers, longest first.
    private static let wrappers: [(open: [Unicode.Scalar], close: [Unicode.Scalar])] = [
        ("$$", "$$"), ("\\(", "\\)"), ("\\[", "\\]"), ("$", "$"),
    ].map { (Array($0.0.unicodeScalars), Array($0.1.unicodeScalars)) }

    private struct Box {
        let start: Int
        /// Past the closing brace.
        let end: Int
        let content: [Unicode.Scalar]
    }

    private static func rewriteProse(_ scalars: [Unicode.Scalar], bold: Bool) -> String {
        var output = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            if let wrapped = wrappedBox(in: scalars, at: index) {
                let framed = isFramed(scalars, from: index, to: wrapped.end)
                output.append(contentsOf: rendered(wrapped.box, bold: bold, framed: framed).unicodeScalars)
                index = wrapped.end
            } else if let box = box(in: scalars, at: index) {
                let framed = isFramed(scalars, from: index, to: box.end)
                output.append(contentsOf: rendered(box, bold: bold, framed: framed).unicodeScalars)
                index = box.end
            } else {
                output.append(scalars[index])
                index += 1
            }
        }
        return String(output)
    }

    /// `display` output goes through Markdown, so the content's own emphasis marks are escaped; between marks the
    /// model already wrote, a bold of its own would leave stray asterisks.
    private static func rendered(_ box: Box, bold: Bool, framed: Bool) -> String {
        let inner = trimmed(cleaned(box.content))
        guard !inner.isEmpty else { return "" }
        guard bold else { return String(String.UnicodeScalarView(inner)) }
        let shown = String(String.UnicodeScalarView(escaped(inner)))
        return framed ? shown : "**" + shown + "**"
    }

    /// The span from `start` to `end` has the same `*` or `_` right before and right after it.
    private static func isFramed(_ scalars: [Unicode.Scalar], from start: Int, to end: Int) -> Bool {
        guard start > 0, end < scalars.count else { return false }
        let before = scalars[start - 1]
        return (before == "*" || before == "_") && scalars[end] == before
    }

    private static let emphasisMarks: Set<Unicode.Scalar> = ["*", "_", "`"]

    /// Marks not already escaped get a backslash.
    private static func escaped(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var output: [Unicode.Scalar] = []
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\\", index + 1 < scalars.count {
                output.append(scalar)
                output.append(scalars[index + 1])
                index += 2
                continue
            }
            if emphasisMarks.contains(scalar) { output.append("\\") }
            output.append(scalar)
            index += 1
        }
        return output
    }

    /// The characters of JavaScript's `\s`, so the page trims alike.
    private static let trimmable = Set<UInt32>([
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF,
    ]).union(0x2000...0x200A)

    private static func trimmed(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        guard let first = scalars.firstIndex(where: { !trimmable.contains($0.value) }),
              let last = scalars.lastIndex(where: { !trimmable.contains($0.value) }) else { return [] }
        return Array(scalars[first...last])
    }

    /// A wrapper opening at `index` whose only content is one box.
    private static func wrappedBox(in scalars: [Unicode.Scalar], at index: Int) -> (box: Box, end: Int)? {
        for wrapper in wrappers where matches(wrapper.open, in: scalars, at: index) {
            let start = skippingSpaces(in: scalars, from: index + wrapper.open.count)
            guard let box = box(in: scalars, at: start) else { continue }
            let close = skippingSpaces(in: scalars, from: box.end)
            guard matches(wrapper.close, in: scalars, at: close) else { continue }
            return (box, close + wrapper.close.count)
        }
        return nil
    }

    private static func box(in scalars: [Unicode.Scalar], at index: Int) -> Box? {
        guard matches(boxOpen, in: scalars, at: index),
              let close = closingBrace(in: scalars, from: index + boxOpen.count) else { return nil }
        return Box(start: index, end: close + 1, content: slice(scalars, index + boxOpen.count, close))
    }

    /// Index of the brace that closes one opened just before `start`.
    private static func closingBrace(in scalars: [Unicode.Scalar], from start: Int) -> Int? {
        var depth = 0
        var index = start
        while index < scalars.count {
            switch scalars[index] {
            case "\\":
                index += 2
                continue
            case "{":
                depth += 1
            case "}":
                if depth == 0 { return index }
                depth -= 1
            default:
                break
            }
            index += 1
        }
        return nil
    }

    /// Box content with nested boxes and text commands reduced to their content.
    private static func cleaned(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var output: [Unicode.Scalar] = []
        var index = 0
        while index < scalars.count {
            let command = unwrappedCommands.first { matches($0, in: scalars, at: index) }
            if let command, let close = closingBrace(in: scalars, from: index + command.count) {
                output += cleaned(slice(scalars, index + command.count, close))
                index = close + 1
            } else {
                output.append(scalars[index])
                index += 1
            }
        }
        return output
    }

    private static func slice(_ scalars: [Unicode.Scalar], _ start: Int, _ end: Int) -> [Unicode.Scalar] {
        Array(scalars[start..<end])
    }

    private static let gapSpaces: Set<Unicode.Scalar> = [" ", "\t", "\n", "\r"]

    private static func skippingSpaces(in scalars: [Unicode.Scalar], from start: Int) -> Int {
        var index = start
        while index < scalars.count, gapSpaces.contains(scalars[index]) { index += 1 }
        return index
    }

    private static func matches(_ token: [Unicode.Scalar], in scalars: [Unicode.Scalar], at index: Int) -> Bool {
        guard index >= 0, scalars.count - index >= token.count else { return false }
        return token.indices.allSatisfy { scalars[index + $0] == token[$0] }
    }
}
