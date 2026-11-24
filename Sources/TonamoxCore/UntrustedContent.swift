import Foundation

/// Text from an untrusted source (terminal output, a tool result) prepared for a model prompt: escapes, control
/// characters and invisible Unicode removed (and counted), CRLF normalized, text over `maxCharacters` Unicode scalars
/// cut in the middle, and the result wrapped between two lines holding a random boundary that does not occur in the
/// content, after `preamble`. Defence in depth only: a model can still be misled by what the block says.
package struct UntrustedBlock: Sendable, Equatable {
    package let boundary: String
    package let rendered: String
    package let removedInvisible: Int
    package let removedControls: Int
    /// UTF-8 bytes cut from the middle; 0 when nothing was cut.
    package let omittedBytes: Int

    package init(
        _ text: String,
        preamble: String,
        maxCharacters: Int,
        boundaries: () -> String = UntrustedFraming.randomBoundary
    ) {
        let cleaned = TerminalSanitizer.clean(text)
        let cut = UntrustedFraming.truncateMiddle(cleaned.text, maxCharacters: max(maxCharacters, 2))
        boundary = UntrustedFraming.boundary(absentFrom: cut.text, boundaries: boundaries)
        removedInvisible = cleaned.invisible
        removedControls = cleaned.controls
        omittedBytes = cut.omitted
        rendered = preamble + "\n" + UntrustedFraming.framed(cut.text, boundary: boundary)
    }
}

package enum UntrustedFraming {
    /// `TONAMOX-UNTRUSTED-` and 32 hex digits (128 random bits from the system CSPRNG).
    package static func randomBoundary() -> String {
        "TONAMOX-UNTRUSTED-" + hex(UInt64.random(in: .min ... .max)) + hex(UInt64.random(in: .min ... .max))
    }

    /// The first candidate from `boundaries` that does not occur in `text`.
    package static func boundary(absentFrom text: String, boundaries: () -> String) -> String {
        var candidate = boundaries()
        while text.contains(candidate) {
            candidate = boundaries()
        }
        return candidate
    }

    /// `text` between two `boundary` lines, each line ending in `\n`.
    package static func framed(_ text: String, boundary: String) -> String {
        let body = text.hasSuffix("\n") || text.isEmpty ? text : text + "\n"
        return boundary + "\n" + body + boundary + "\n"
    }

    /// Keeps the first and last halves of `maxCharacters` and marks the cut. Counts Unicode scalars, not
    /// characters: one character can carry thousands of combining marks. Cuts fall on character boundaries.
    package static func truncateMiddle(_ text: String, maxCharacters: Int) -> (text: String, omitted: Int) {
        guard text.unicodeScalars.count > maxCharacters else { return (text, 0) }
        let headCount = maxCharacters / 2
        let head = text[..<endOfPrefix(text, maxScalars: headCount)]
        let tail = text[startOfSuffix(text, maxScalars: maxCharacters - headCount)...]
        let omitted = text.utf8.count - head.utf8.count - tail.utf8.count
        return (head + "\n[… \(omitted) bytes omitted …]\n" + tail, omitted)
    }

    /// The longest run of whole leading characters holding at most `maxScalars` Unicode scalars, with `…` in place of
    /// the rest when something was cut (the `…` counts toward the limit).
    package static func prefix(_ text: String, maxScalars: Int) -> String {
        guard text.unicodeScalars.count > maxScalars else { return text }
        guard maxScalars > 0 else { return "" }
        return text[..<endOfPrefix(text, maxScalars: maxScalars - 1)] + "…"
    }

    private static func endOfPrefix(_ text: String, maxScalars: Int) -> String.Index {
        var used = 0
        var end = text.startIndex
        while end < text.endIndex {
            let next = text.index(after: end)
            used += text.unicodeScalars[end..<next].count
            guard used <= maxScalars else { break }
            end = next
        }
        return end
    }

    private static func startOfSuffix(_ text: String, maxScalars: Int) -> String.Index {
        var used = 0
        var start = text.endIndex
        while start > text.startIndex {
            let previous = text.index(before: start)
            used += text.unicodeScalars[previous..<start].count
            guard used <= maxScalars else { break }
            start = previous
        }
        return start
    }

    private static func hex(_ value: UInt64) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }
}

/// Removes what a terminal would interpret instead of print, and characters that hide text from a reader.
package enum TerminalSanitizer {
    package static func clean(_ text: String) -> (text: String, invisible: Int, controls: Int) {
        let scalars = Array(text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars)
        var kept = String.UnicodeScalarView()
        var invisible = 0
        var controls = 0
        var index = 0
        while index < scalars.count {
            let value = scalars[index].value
            if let end = sequenceEnd(scalars, start: index) {
                controls += 1
                index = end
            } else if isInvisible(value) || (isVariationSelector(value) && !isEmojiPresentation(value, after: kept.last)) {
                invisible += 1
                index += 1
            } else if isControl(value) {
                controls += 1
                index += 1
            } else {
                kept.append(scalars[index])
                index += 1
            }
        }
        return (String(kept), invisible, controls)
    }

    /// Index after the escape sequence starting at `start`, or `nil` when none starts there.
    package static func sequenceEnd(_ scalars: [Unicode.Scalar], start: Int) -> Int? {
        let value = scalars[start].value
        switch value {
        case 0x9B: return controlSequenceEnd(scalars, from: start + 1)
        case 0x9D, 0x90, 0x98, 0x9E, 0x9F: return stringEnd(scalars, from: start + 1)
        case 0x1B: break
        default: return nil
        }
        let next = start + 1
        guard next < scalars.count else { return next }
        switch scalars[next].value {
        case 0x5B: return controlSequenceEnd(scalars, from: next + 1)
        case 0x5D, 0x50, 0x58, 0x5E, 0x5F: return stringEnd(scalars, from: next + 1)
        case 0x20...0x2F:
            var index = next
            while index < scalars.count, (0x20...0x2F).contains(scalars[index].value) { index += 1 }
            return min(index + 1, scalars.count)
        case 0x30...0x7E: return next + 1
        default: return next
        }
    }

    /// CSI: parameter bytes 0x30-0x3F, intermediate bytes 0x20-0x2F, one final byte 0x40-0x7E.
    private static func controlSequenceEnd(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var index = start
        while index < scalars.count, (0x20...0x3F).contains(scalars[index].value) { index += 1 }
        guard index < scalars.count, (0x40...0x7E).contains(scalars[index].value) else { return index }
        return index + 1
    }

    /// OSC, DCS, SOS, PM, APC: up to BEL, ST (ESC \) or C1 ST, or the end of the text.
    private static func stringEnd(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var index = start
        while index < scalars.count {
            switch scalars[index].value {
            case 0x07, 0x9C: return index + 1
            case 0x1B where index + 1 < scalars.count && scalars[index + 1] == "\\": return index + 2
            default: index += 1
            }
        }
        return index
    }

    package static func isControl(_ value: UInt32) -> Bool {
        if value == 0x0A || value == 0x09 { return false }
        return value < 0x20 || (0x7F...0x9F).contains(value)
    }

    /// Characters used to hide instructions from a human reader. Variation selectors are handled in `clean`.
    package static func isInvisible(_ value: UInt32) -> Bool {
        (0xE0000...0xE007F).contains(value) || (0x202A...0x202E).contains(value) || (0x2066...0x2069).contains(value)
            || (0x200B...0x200F).contains(value) || (0x2060...0x2064).contains(value) || value == 0xFEFF
            || value == 0x00AD || value == 0x034F || value == 0x061C || value == 0x180E
    }

    package static func isVariationSelector(_ value: UInt32) -> Bool {
        (0xFE00...0xFE0F).contains(value) || (0xE0100...0xE01EF).contains(value)
    }

    /// One text or emoji presentation selector right after an emoji keeps it as written. Any other variation
    /// selector can carry hidden data ("emoji smuggling"), and a second one in a row is never presentation.
    private static func isEmojiPresentation(_ value: UInt32, after previous: Unicode.Scalar?) -> Bool {
        guard value == 0xFE0E || value == 0xFE0F, let previous else { return false }
        return previous.properties.isEmoji
    }
}
