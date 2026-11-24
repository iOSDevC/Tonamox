import Foundation

/// Separates the reasoning a model writes before its answer from the answer itself, chunk by chunk or in one shot.
///
/// Rules:
/// - A reasoning block is `<think>…</think>` or `<thought>…</thought>`. Tag names are ASCII case-insensitive and a
///   block ends only at the closing tag of its own name; `<thinking>` or `<thoughtful>` are not tags.
/// - Only leading blocks count: optional whitespace, then one or more consecutive blocks with optional whitespace
///   between them. Their texts join with a blank line. The first other character starts the answer, and from there
///   no tag is special, so a tag later in the answer or inside a code fence stays answer text.
/// - Inside a block, an opening tag of the same name nests: the block ends at the closing tag that balances it.
/// - In output that does not start with a block, the first closing tag (either name) ends a block the chat template
///   opened in the prompt, even after an opening tag: everything before it becomes reasoning. While streaming that
///   text was already yielded as answer, so the splitter yields ``Piece/answerRetracted`` and then the same text as
///   ``Piece/reasoning(_:)``. Such a tag is taken as the end of reasoning wherever it appears, fenced or not, so an
///   answer that only mentions a closing tag loses the text before it to the reasoning.
/// - A block that never closes makes everything after its opening tag reasoning: ``finish()`` sets
///   ``isReasoningUnterminated`` and the answer stays empty.
/// - Whitespace before and between blocks and before the answer is dropped: ASCII whitespace, U+00A0, U+200B,
///   U+3000 and a byte order mark. Block text and the answer's end are kept as written.
///
/// When the prompt itself ends with the opening tag, feed that tag first (``Tonamox/promptOpenedReasoningTag``), so
/// the output starts inside the block.
///
/// Streaming holds back at most the bytes that could still begin a tag (nine), so a tag split across chunks never
/// shows up as answer or reasoning text; ``finish()`` releases them.
public struct ReasoningSplitter: Sendable {
    /// What one ``consume(_:)`` or ``finish()`` call adds.
    public enum Piece: Sendable, Equatable {
        /// More reasoning text.
        case reasoning(String)
        /// More answer text.
        case answer(String)
        /// Everything yielded as answer so far was reasoning (a lone closing tag arrived). Drop it; it follows as
        /// ``reasoning(_:)``.
        case answerRetracted
    }

    private enum Phase: Sendable {
        /// Before the first block, between blocks, or before the answer: whitespace is skipped.
        case leading
        /// `depth` counts nested opening tags of the block's own name.
        case reasoning(open: [UInt8], close: [UInt8], depth: Int)
        /// An answer that did not start with a block: a lone closing tag may still turn it into reasoning.
        case openAnswer
        /// Plain text to the end.
        case answer
    }

    /// Reasoning so far: block texts joined by a blank line.
    public private(set) var reasoning = ""
    /// Answer so far.
    public private(set) var answer = ""
    /// Leading blocks seen, a template-opened one included. An empty block counts.
    public private(set) var blockCount = 0
    /// The stream ended inside a block.
    public private(set) var isReasoningUnterminated = false
    /// ``finish()`` ran; later chunks are ignored.
    public private(set) var isFinished = false

    private var state = Phase.leading
    private var held: [UInt8] = []

    public init() {}

    /// At least one leading block was seen.
    public var hasReasoning: Bool { blockCount > 0 }

    /// The text being received is reasoning: a block is open and not yet closed.
    public var isInsideReasoning: Bool {
        if case .reasoning = state { return true }
        return false
    }

    /// The closing tags that would end the open block, one per nesting level; `nil` outside a block.
    package var closingTagsOfOpenBlock: String? {
        guard case .reasoning(_, let close, let depth) = state else { return nil }
        return String(repeating: String(decoding: close, as: UTF8.self), count: depth + 1)
    }

    /// The end of the last chunk may be the start of a tag, kept until the next chunk says.
    package var isHoldingPartialTag: Bool { !held.isEmpty }

    /// Length of the whitespace the splitter drops at the start of `bytes`.
    package static func leadingWhitespaceLength(_ bytes: [UInt8]) -> Int {
        ReasoningTag.skippableLength(bytes, from: 0)
    }

    /// Splits a complete output: the same result as one ``consume(_:)`` of `text` and ``finish()``.
    public static func split(_ text: String) -> ReasoningSplitter {
        var splitter = ReasoningSplitter()
        _ = splitter.consume(text)
        _ = splitter.finish()
        return splitter
    }

    /// Adds one chunk and returns what it made definite, in order.
    public mutating func consume(_ chunk: String) -> [Piece] {
        guard !isFinished, !chunk.isEmpty else { return [] }
        var bytes = held
        bytes.append(contentsOf: chunk.utf8)
        held = []
        var pieces: [Piece] = []
        var cursor: Int? = 0
        while let start = cursor, start < bytes.count {
            cursor = step(bytes, from: start, into: &pieces)
        }
        return pieces
    }

    /// Ends the stream: releases held bytes (a lone `<` included) and records an unterminated block.
    public mutating func finish() -> [Piece] {
        guard !isFinished else { return [] }
        isFinished = true
        var pieces: [Piece] = []
        let rest = held[...]
        held = []
        if case .reasoning = state {
            isReasoningUnterminated = true
            appendReasoning(rest, into: &pieces)
        } else {
            appendAnswer(rest, into: &pieces)
        }
        state = .answer
        return pieces
    }

    // MARK: Steps

    /// Handles bytes from `start`; returns where to continue, or nil when the rest was yielded or held.
    private mutating func step(_ bytes: [UInt8], from start: Int, into pieces: inout [Piece]) -> Int? {
        switch state {
        case .leading:
            return stepLeading(bytes, from: start, into: &pieces)
        case .reasoning(let open, let close, let depth):
            return stepReasoning(bytes, from: start, tag: ReasoningTag.Pair(open: open, close: close), depth: depth,
                                 into: &pieces)
        case .openAnswer:
            return stepOpenAnswer(bytes, from: start, into: &pieces)
        case .answer:
            appendAnswer(bytes[start...], into: &pieces)
            return nil
        }
    }

    private mutating func stepLeading(_ bytes: [UInt8], from start: Int, into pieces: inout [Piece]) -> Int? {
        let index = start + ReasoningTag.skippableLength(bytes, from: start)
        guard index < bytes.count else { return nil }
        if let tag = ReasoningTag.openings.first(where: { ReasoningTag.matches($0.open, in: bytes, at: index) }) {
            if !reasoning.isEmpty { appendReasoning("\n\n", into: &pieces) }
            blockCount += 1
            state = .reasoning(open: tag.open, close: tag.close, depth: 0)
            return index + tag.open.count
        }
        if ReasoningTag.openings.contains(where: { ReasoningTag.isProperPrefix(bytes[index...], of: $0.open) }) {
            held = Array(bytes[index...])
            return nil
        }
        state = hasReasoning ? .answer : .openAnswer
        return index
    }

    private mutating func stepReasoning(_ bytes: [UInt8], from start: Int, tag: ReasoningTag.Pair, depth: Int,
                                        into pieces: inout [Piece]) -> Int? {
        let tokens = [tag.open, tag.close]
        if let found = ReasoningTag.firstMatch(of: tokens, in: bytes, from: start) {
            let end = found.position + found.token.count
            if found.token == tag.open {
                appendReasoning(bytes[start..<end], into: &pieces)
                state = .reasoning(open: tag.open, close: tag.close, depth: depth + 1)
            } else if depth > 0 {
                appendReasoning(bytes[start..<end], into: &pieces)
                state = .reasoning(open: tag.open, close: tag.close, depth: depth - 1)
            } else {
                appendReasoning(bytes[start..<found.position], into: &pieces)
                state = .leading
            }
            return end
        }
        let keep = ReasoningTag.heldSuffixLength(bytes, from: start, tokens: tokens)
        appendReasoning(bytes[start..<(bytes.count - keep)], into: &pieces)
        held = Array(bytes[(bytes.count - keep)...])
        return nil
    }

    /// Opening tags do not end this phase: template-opened reasoning that mentions `<think>` still closes at its tag.
    private mutating func stepOpenAnswer(_ bytes: [UInt8], from start: Int, into pieces: inout [Piece]) -> Int? {
        guard let found = ReasoningTag.firstMatch(of: ReasoningTag.closings, in: bytes, from: start) else {
            let keep = ReasoningTag.heldSuffixLength(bytes, from: start, tokens: ReasoningTag.closings)
            appendAnswer(bytes[start..<(bytes.count - keep)], into: &pieces)
            held = Array(bytes[(bytes.count - keep)...])
            return nil
        }
        let retracted = answer + String(decoding: bytes[start..<found.position], as: UTF8.self)
        answer = ""
        pieces.append(.answerRetracted)
        appendReasoning(retracted, into: &pieces)
        blockCount = 1
        state = .leading
        return found.position + found.token.count
    }

    // MARK: Output

    private mutating func appendReasoning(_ bytes: ArraySlice<UInt8>, into pieces: inout [Piece]) {
        appendReasoning(String(decoding: bytes, as: UTF8.self), into: &pieces)
    }

    private mutating func appendReasoning(_ text: String, into pieces: inout [Piece]) {
        guard !text.isEmpty else { return }
        reasoning += text
        pieces.append(.reasoning(text))
    }

    private mutating func appendAnswer(_ bytes: ArraySlice<UInt8>, into pieces: inout [Piece]) {
        guard !bytes.isEmpty else { return }
        let text = String(decoding: bytes, as: UTF8.self)
        answer += text
        pieces.append(.answer(text))
    }
}

/// Byte-level matching is safe: every tag byte is ASCII and UTF-8 continuation bytes never are, so each cut falls
/// on a character boundary.
private enum ReasoningTag {
    struct Pair {
        let open: [UInt8]
        let close: [UInt8]
    }

    struct Match {
        let position: Int
        let token: [UInt8]
    }

    static let openings: [Pair] = ["think", "thought"].map { name in
        Pair(open: Array("<\(name)>".utf8), close: Array("</\(name)>".utf8))
    }
    static let closings: [[UInt8]] = openings.map(\.close)
    static let openAngle = UInt8(ascii: "<")
    /// U+00A0, U+200B, U+3000 and U+FEFF: tokenizers emit them before a tag.
    static let wideSpaces: [[UInt8]] = [[0xC2, 0xA0], [0xE2, 0x80, 0x8B], [0xE3, 0x80, 0x80], [0xEF, 0xBB, 0xBF]]

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    /// Length of the whitespace from `start`. Chunks are whole strings, so a multi-byte space never arrives split.
    static func skippableLength(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start
        while index < bytes.count {
            if isWhitespace(bytes[index]) {
                index += 1
            } else if let space = wideSpaces.first(where: { matches($0, in: bytes, at: index) }) {
                index += space.count
            } else {
                break
            }
        }
        return index - start
    }

    private static func lowered(_ byte: UInt8) -> UInt8 {
        (0x41...0x5A).contains(byte) ? byte | 0x20 : byte
    }

    /// `token` (lowercase) starts at `index`, ignoring ASCII case.
    static func matches(_ token: [UInt8], in bytes: [UInt8], at index: Int) -> Bool {
        guard bytes.count - index >= token.count else { return false }
        return token.indices.allSatisfy { lowered(bytes[index + $0]) == token[$0] }
    }

    /// `bytes` is shorter than `token` and could still grow into it.
    static func isProperPrefix(_ bytes: ArraySlice<UInt8>, of token: [UInt8]) -> Bool {
        guard bytes.count < token.count else { return false }
        return zip(bytes, token).allSatisfy { lowered($0) == $1 }
    }

    static func firstMatch(of tokens: [[UInt8]], in bytes: [UInt8], from start: Int) -> Match? {
        var index = start
        var token: [UInt8]?
        while index < bytes.count, token == nil {
            if bytes[index] == openAngle { token = tokens.first { matches($0, in: bytes, at: index) } }
            if token == nil { index += 1 }
        }
        return token.map { Match(position: index, token: $0) }
    }

    /// Length of the longest tail of `bytes[start...]` that could still become one of `tokens`.
    static func heldSuffixLength(_ bytes: [UInt8], from start: Int, tokens: [[UInt8]]) -> Int {
        let longest = min(bytes.count - start, (tokens.map(\.count).max() ?? 1) - 1)
        guard longest > 0 else { return 0 }
        return (1...longest).reversed().first { length in
            tokens.contains { isProperPrefix(bytes[(bytes.count - length)...], of: $0) }
        } ?? 0
    }
}
