import Testing
import TerminalBridgeKit

@Suite struct ReasoningTextTests {
    @Test func underOneSecondHasNoNumber() {
        #expect(ReasoningText.header(thoughtFor: .zero) == "Pensó un momento")
        #expect(ReasoningText.header(thoughtFor: .milliseconds(999)) == "Pensó un momento")
    }

    @Test func oneSecondIsSingular() {
        #expect(ReasoningText.header(thoughtFor: .seconds(1)) == "Pensó durante 1 segundo")
        #expect(ReasoningText.header(thoughtFor: .milliseconds(1_499)) == "Pensó durante 1 segundo")
    }

    @Test func moreThanOneSecondIsPluralAndRounded() {
        #expect(ReasoningText.header(thoughtFor: .milliseconds(1_500)) == "Pensó durante 2 segundos")
        #expect(ReasoningText.header(thoughtFor: .seconds(42)) == "Pensó durante 42 segundos")
        #expect(ReasoningText.header(thoughtFor: .seconds(125)) == "Pensó durante 125 segundos")
    }

    @Test func liveHeaderAndNoteAreSpanish() {
        #expect(ReasoningText.live == "Pensando…")
        #expect(ReasoningText.unfinishedNote.contains("límite de tokens"))
        #expect(ReasoningText.expandHint != ReasoningText.collapseHint)
        #expect(ReasoningText.interrupted == "Razonamiento interrumpido")
    }

    @Test func shownTextDropsSurroundingBlankLines() {
        #expect(ReasoningText.shown("\n\nThe user asks.\n") == "The user asks.")
        #expect(ReasoningText.shown("\n\n").isEmpty)
    }
}
