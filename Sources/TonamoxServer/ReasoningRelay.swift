import Foundation
import TonamoxCore

/// Turns raw model text into served events: a leading `<think>`/`<thought>` block becomes ``ServedChatEvent/reasoning(_:)``
/// and the rest ``ServedChatEvent/text(_:)``, with the rules of ``ReasoningSplitter``.
///
/// Output without a leading block keeps its bytes: whitespace before the answer is relayed too. A lone closing tag (a
/// block the chat template opened in the prompt) cannot be retracted from a stream: once answer text went out, the
/// relay passes the rest of the raw output through as text, closing tag included, so a client can still split it.
/// When nothing was relayed yet, the text before the tag is relayed as reasoning.
package struct ReasoningRelay: Sendable {
    private var splitter = ReasoningSplitter()
    private var relayedAnswerBytes = 0
    /// Raw output, kept only while no leading block was seen: the only time a retraction can come.
    private var raw: [UInt8] = []
    private var isPassingThrough = false

    package init() {}

    package mutating func consume(_ chunk: String) -> [ServedChatEvent] {
        guard !isPassingThrough else { return chunk.isEmpty ? [] : [.text(chunk)] }
        if !splitter.hasReasoning { raw.append(contentsOf: chunk.utf8) }
        return relay(splitter.consume(chunk))
    }

    package mutating func finish() -> [ServedChatEvent] {
        guard !isPassingThrough else { return [] }
        var events = relay(splitter.finish())
        // Whitespace-only output: the splitter dropped it all, the client still gets it.
        if !splitter.hasReasoning, relayedAnswerBytes == 0, !raw.isEmpty {
            events.append(.text(String(decoding: raw, as: UTF8.self)))
        }
        return events
    }

    private mutating func relay(_ pieces: [ReasoningSplitter.Piece]) -> [ServedChatEvent] {
        var events: [ServedChatEvent] = []
        for piece in pieces {
            switch piece {
            case .answer(var text):
                if relayedAnswerBytes == 0, !splitter.hasReasoning { text = leadingWhitespace() + text }
                relayedAnswerBytes += text.utf8.count
                events.append(.text(text))
            case .answerRetracted where relayedAnswerBytes > 0:
                isPassingThrough = true
                let unsent = raw.dropFirst(relayedAnswerBytes)
                raw = []
                if !unsent.isEmpty { events.append(.text(Self.text(of: unsent))) }
                return events
            case .answerRetracted:
                break
            case .reasoning(let text):
                events.append(.reasoning(text))
            }
            if splitter.hasReasoning { raw = [] }
        }
        return events
    }

    private func leadingWhitespace() -> String {
        Self.text(of: raw.prefix(ReasoningSplitter.leadingWhitespaceLength(raw)))
    }

    private static func text(of bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes, as: UTF8.self)
    }
}
