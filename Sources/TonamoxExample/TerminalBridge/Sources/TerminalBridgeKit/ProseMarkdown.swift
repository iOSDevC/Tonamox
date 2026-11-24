import Foundation

/// A reply's prose segments as the chat shows them: inline Markdown (bold, italics, inline code) with whitespace and
/// line breaks kept, and nothing that can be tapped. Code blocks never come here: `CodeBlockParser` splits them out
/// of the raw reply first, and commands are read from those blocks only.
public enum ProseMarkdown {
    private static let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace,
        failurePolicy: .returnPartiallyParsedIfPossible
    )

    /// Links come out as their label followed by the address in parentheses, as plain text.
    public static func attributed(_ prose: String) -> AttributedString {
        guard var text = try? AttributedString(markdown: prose, options: options) else {
            return AttributedString(prose)
        }
        let links = text.runs[\.link].compactMap { url, range in url.map { (url: $0, range: range) } }
        for link in links.reversed() {
            text.replaceSubrange(link.range, with: unlinked(text[link.range], url: link.url))
        }
        return text
    }

    private static func unlinked(_ run: AttributedSubstring, url: URL) -> AttributedString {
        let label = String(run.characters)
        let address = url.absoluteString
        var plain = AttributedString(label == address || address.isEmpty ? label : label + " (" + address + ")")
        plain.inlinePresentationIntent = run.inlinePresentationIntent
        return plain
    }
}
