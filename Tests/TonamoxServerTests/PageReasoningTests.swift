import Foundation
import Testing

@Suite("Browser page reasoning")
struct PageReasoningTests {
    private static func lines(containing needle: String, in text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.contains(needle) }
    }

    @Test func transcriptSentBackHoldsTheAnswerOnly() {
        let script = PageSource.script
        #expect(Set(Self.lines(containing: "state.history.push(", in: script)) == [
            "state.history.push({ role: 'user', content: text });",
            "state.history.push({ role: 'assistant', content: reply.answer });",
        ])
        #expect(Self.lines(containing: "reply.answer +=", in: script) == ["reply.answer += delta.content;"])
        #expect(Self.lines(containing: "messages: state.history", in: script) == ["messages: state.history,"])
        #expect(Self.lines(containing: "reasoning_effort: ", in: script).filter { !$0.hasPrefix("invalid_") }
            == ["reasoning_effort: state.reason,"])
        #expect(!script.contains("content: target.textContent"))
    }

    @Test func reasoningIsACollapsedNativeDisclosureFilledAsText() {
        let script = PageSource.script
        #expect(script.contains("details: element('details', 'reasoning'),"))
        #expect(script.contains("const summary = element('summary');"))
        #expect(script.contains("shown.textContent += shown.textContent ? delta.reasoning_content : delta.reasoning_content.trimStart();"))
        #expect(!script.contains(".open ="))
        #expect(!script.contains("'open'"))
        #expect(Self.lines(containing: "reasoningBlock(target)", in: script).count == 2)
    }

    @Test func stopOrFailureMidReasoningShowsItInterrupted() {
        let script = PageSource.script
        #expect(script.contains("if (reply.reasoning && reply.reasoning.ended === null) reply.reasoning.interrupted = true;"))
        #expect(script.contains("text = t('chat.reasoning.interrupted');"))
    }

    @Test func durationIsMeasuredInThePageAndRedrawnOnALanguageSwitch() {
        let script = PageSource.script
        #expect(Self.lines(containing: "performance.now()", in: script).count == 2)
        #expect(script.contains("if (reply.reasoning) endReasoning(reply.reasoning);"))
        #expect(script.contains("plural('chat.reasoning.done', seconds, { seconds: number(seconds) })"))
        #expect(script.contains("state.reasoningBlocks.forEach(drawReasoning);"))
        #expect(Self.lines(containing: "state.reasoningBlocks = [];", in: script).count == 2)
    }

    @Test func expandedReasoningIsDimmerWithARuleOnTheLeft() throws {
        let css = try PageSource.text("app.css")
        #expect(css.contains(".message-item .reasoning { margin-bottom: 0.4rem; font-size: 0.85rem; color: var(--muted); }"))
        #expect(css.contains("border-left: 2px solid var(--muted)"))
        #expect(css.contains(".message-item .reasoning summary:focus-visible"))
    }
}
