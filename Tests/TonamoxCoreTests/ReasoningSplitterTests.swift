import Testing
import TonamoxCore

/// `ReasoningSplitter` on its own: real outputs, every chunk boundary, and the edge cases of the leading-block rule.
struct ReasoningSplitterTests {
    private struct Outcome: Equatable {
        let reasoning: String
        let answer: String
        let blocks: Int
        let unterminated: Bool

        init(_ splitter: ReasoningSplitter) {
            reasoning = splitter.reasoning
            answer = splitter.answer
            blocks = splitter.blockCount
            unterminated = splitter.isReasoningUnterminated
        }
    }

    /// What a consumer that only sees the pieces ends up with.
    private struct Replay {
        var reasoning = ""
        var answer = ""

        mutating func apply(_ pieces: [ReasoningSplitter.Piece]) {
            for piece in pieces {
                switch piece {
                case .reasoning(let text): reasoning += text
                case .answer(let text): answer += text
                case .answerRetracted: answer = ""
                }
            }
        }
    }

    static let listo = "<think>\nThe user asks: \"Responde solo con la palabra: listto\". They want a response that is "
        + "only the word \"listo\". So we respond with \"listo\". No extra text. According to instructions, we "
        + "should not add any extra commentary. So final answer: listo.\n</think>\nlisto"
    static let ordering = "<think>\nOkay, let's see. The user wants me to order the numbers 42, 7, 19, and 3 from "
        + "smallest to largest.\n\nWait, let me double-check. 3 is less than 7. Just list them in order.\n</think>\n"
        + "3, 7, 19, 42"
    static let octal = "<thought>\nThe user asks for the octal number corresponding to the permissions rwxr-xr--. "
        + "The correct answer is 29.\n</thought>\nThe user wants the number only. So, the response is \"29\"."

    static let samples = [
        listo, ordering, octal,
        "Reasoning first\n</think>\n\nHello",
        "<think>\nstill going",
        "  <THINK>a</Think>\n<thought>b</thought>\n  c <think>d</think>",
        "Plain answer with <think>tag</think> later",
        "```html\n<thought>\n```\n",
        "<thinking>x</thinking>y",
        "a <",
        "<th",
        "<think>héllo 🧠 wörld</think>ünïcode ✅",
        "<think>a<think>b</think>c</think>ans",
        "\u{FEFF}\u{00A0}<think>r</think>\u{3000}a",
        "The user asks about the <think> tag.\n```sh\nrm x\n```</think>\nAnswer",
    ]

    private static func streamed(_ chunks: [String]) -> (ReasoningSplitter, Replay) {
        var splitter = ReasoningSplitter()
        var replay = Replay()
        for chunk in chunks { replay.apply(splitter.consume(chunk)) }
        replay.apply(splitter.finish())
        return (splitter, replay)
    }

    // MARK: Real outputs

    @Test func realThinkOutputsSplitIntoReasoningAndAnswer() {
        let listo = ReasoningSplitter.split(Self.listo)
        #expect(listo.answer == "listo")
        #expect(listo.reasoning.hasPrefix("\nThe user asks:"))
        #expect(listo.reasoning.hasSuffix("So final answer: listo.\n"))
        let ordering = ReasoningSplitter.split(Self.ordering)
        #expect(ordering.answer == "3, 7, 19, 42")
        #expect(ordering.reasoning.contains("double-check"))
        #expect(ordering.blockCount == 1)
        #expect(!ordering.isReasoningUnterminated)
    }

    @Test func realThoughtOutputSplitsToo() {
        let octal = ReasoningSplitter.split(Self.octal)
        #expect(octal.answer == "The user wants the number only. So, the response is \"29\".")
        #expect(octal.reasoning.contains("rwxr-xr--"))
        #expect(!octal.answer.contains("thought"))
    }

    // MARK: Chunk boundaries

    @Test(arguments: samples)
    func everyTwoChunkSplitMatchesOneShot(_ text: String) {
        let expected = Outcome(ReasoningSplitter.split(text))
        for cut in 0...text.count {
            let index = text.index(text.startIndex, offsetBy: cut)
            let (splitter, replay) = Self.streamed([String(text[..<index]), String(text[index...])])
            #expect(Outcome(splitter) == expected, "cut at \(cut)")
            #expect(replay.reasoning == expected.reasoning && replay.answer == expected.answer, "cut at \(cut)")
        }
    }

    @Test(arguments: samples)
    func singleCharacterChunksMatchOneShot(_ text: String) {
        let expected = Outcome(ReasoningSplitter.split(text))
        let (splitter, replay) = Self.streamed(text.map { String($0) })
        #expect(Outcome(splitter) == expected)
        #expect(replay.reasoning == expected.reasoning && replay.answer == expected.answer)
    }

    /// Never a partial tag or reasoning text in the answer: without a lone closing tag, every intermediate answer is a
    /// prefix of the final one.
    @Test(arguments: [listo, ordering, octal, "  <THINK>a</Think>\n<thought>b</thought>\n  c"])
    func answerOnlyGrowsWhileStreaming(_ text: String) {
        let final = ReasoningSplitter.split(text)
        var splitter = ReasoningSplitter()
        for character in text {
            let pieces = splitter.consume(String(character))
            #expect(!pieces.contains(.answerRetracted))
            #expect(final.answer.hasPrefix(splitter.answer))
            #expect(final.reasoning.hasPrefix(splitter.reasoning))
        }
    }

    @Test func splitTagIsHeldBackUntilItCompletes() {
        var splitter = ReasoningSplitter()
        #expect(splitter.consume("<th").isEmpty)
        #expect(!splitter.isInsideReasoning)
        #expect(splitter.consume("ink>abc</thi") == [.reasoning("abc")])
        #expect(splitter.isInsideReasoning)
        #expect(splitter.consume("nk>\nok") == [.answer("ok")])
        #expect(!splitter.isInsideReasoning)
        #expect(splitter.finish().isEmpty)
    }

    // MARK: Rules

    @Test func loneClosingTagTurnsThePrefixIntoReasoning() {
        let split = ReasoningSplitter.split("Reasoning first\n</think>\n\nHello")
        #expect(split.reasoning == "Reasoning first\n")
        #expect(split.answer == "Hello")
        #expect(split.blockCount == 1)
        var splitter = ReasoningSplitter()
        #expect(splitter.consume("Reasoning first\n") == [.answer("Reasoning first\n")])
        #expect(splitter.consume("</THOUGHT>Hi") == [.answerRetracted, .reasoning("Reasoning first\n"), .answer("Hi")])
    }

    /// Fail-safe trade: an answer that only mentions the tags loses its start to the reasoning.
    @Test func openingTagInAnUnopenedAnswerDoesNotDisableTheLoneClosingTag() {
        let split = ReasoningSplitter.split("Use <think> to open and </think> to close.")
        #expect(split.reasoning == "Use <think> to open and ")
        #expect(split.answer == "to close.")
    }

    @Test func templateOpenedReasoningThatMentionsTheOpeningTagKeepsItsFenceOutOfTheAnswer() {
        let text = "The user asks about the <think> tag.\n```sh\nrm x\n```</think>\nAnswer"
        let split = ReasoningSplitter.split(text)
        #expect(split.answer == "Answer")
        #expect(split.reasoning.contains("rm x"))
    }

    @Test func promptOpenedTagFedFirstKeepsATruncatedReasoningOutOfTheAnswer() {
        var splitter = ReasoningSplitter()
        #expect(splitter.consume("<think>").isEmpty)
        #expect(splitter.isInsideReasoning)
        _ = splitter.consume("Let me check.\n```bash\ngit reset --hard\n```\nThen")
        _ = splitter.finish()
        #expect(splitter.answer.isEmpty)
        #expect(splitter.isReasoningUnterminated)
        #expect(splitter.reasoning.contains("git reset --hard"))
    }

    @Test func nestedBlockOfTheSameNameEndsAtTheBalancingTag() {
        let split = ReasoningSplitter.split("<think>a<think>b</think>c</think>ans")
        #expect(split.reasoning == "a<think>b</think>c")
        #expect(split.answer == "ans")
    }

    /// Fail-safe trade of nesting: a lone opening tag mentioned in the reasoning swallows the answer.
    @Test func openingTagMentionedInsideABlockLeavesItUnterminated() {
        let split = ReasoningSplitter.split("<think>about the <think> tag</think>ans")
        #expect(split.answer.isEmpty)
        #expect(split.isReasoningUnterminated)
    }

    @Test(arguments: ["\u{FEFF}", "\u{00A0}", "\u{3000}", "\u{200B}", " \u{FEFF}\n"])
    func wideSpacesBeforeATagAreSkipped(_ prefix: String) {
        let split = ReasoningSplitter.split(prefix + "<think>r ```sh\nx\n```</think>a")
        #expect(split.answer == "a")
        #expect(split.reasoning.contains("```sh"))
    }

    @Test func unterminatedBlockIsAllReasoning() {
        let split = ReasoningSplitter.split("<think>\nstill going</thi")
        #expect(split.reasoning == "\nstill going</thi")
        #expect(split.answer.isEmpty)
        #expect(split.isReasoningUnterminated)
        #expect(!split.isInsideReasoning)
    }

    @Test func tagNamesIgnoreCase() {
        let split = ReasoningSplitter.split("<THINK>a</Think>b")
        #expect(split.reasoning == "a")
        #expect(split.answer == "b")
    }

    @Test func tagLaterInTheAnswerIsAnswerText() {
        let afterBlock = ReasoningSplitter.split("<think>r</think>b <think>c</think> </think>")
        #expect(afterBlock.reasoning == "r")
        #expect(afterBlock.answer == "b <think>c</think> </think>")
    }

    @Test func tagInsideACodeFenceInTheAnswerIsAnswerText() {
        let fenced = "```html\n<thought>\n```\n"
        #expect(ReasoningSplitter.split(fenced).answer == fenced)
        let afterBlock = ReasoningSplitter.split("<think>r</think>\n```\n<think>x</think>\n```\n")
        #expect(afterBlock.answer == "```\n<think>x</think>\n```\n")
    }

    @Test func emptyBlockCountsButAddsNoText() {
        let split = ReasoningSplitter.split("<think>\n\n</think>\n\nHello")
        #expect(split.hasReasoning)
        #expect(split.reasoning == "\n\n")
        #expect(split.answer == "Hello")
        #expect(ReasoningSplitter.split("<think></think>Hi").reasoning.isEmpty)
    }

    @Test func consecutiveLeadingBlocksJoinWithABlankLine() {
        let split = ReasoningSplitter.split("  <think>a</think>\n<thought>b</thought>\n  c <think>d</think>")
        #expect(split.reasoning == "a\n\nb")
        #expect(split.blockCount == 2)
        #expect(split.answer == "c <think>d</think>")
    }

    @Test func blockEndsOnlyAtItsOwnClosingTag() {
        let split = ReasoningSplitter.split("<think>a</thought>b</think>c")
        #expect(split.reasoning == "a</thought>b")
        #expect(split.answer == "c")
    }

    @Test(arguments: ["<thinking>x</thinking>y", "<thoughtful>x</thoughtful>y", "<think x>y"])
    func lookalikesAreNotTags(_ text: String) {
        let split = ReasoningSplitter.split(text)
        #expect(!split.hasReasoning)
        #expect(split.answer == text)
    }

    @Test func trailingAngleBracketIsFlushed() {
        var splitter = ReasoningSplitter()
        #expect(splitter.consume("a ") == [.answer("a ")])
        #expect(splitter.consume("<").isEmpty)
        #expect(splitter.finish() == [.answer("<")])
        #expect(splitter.answer == "a <")
        #expect(ReasoningSplitter.split("<").answer == "<")
        #expect(ReasoningSplitter.split("<th").answer == "<th")
    }

    @Test func chunksAfterFinishAreIgnored() {
        var splitter = ReasoningSplitter()
        _ = splitter.consume("Hi")
        _ = splitter.finish()
        #expect(splitter.consume(" more").isEmpty)
        #expect(splitter.answer == "Hi")
    }

    /// The chat parses commands from the answer only, so a fence in the reasoning must never reach it.
    @Test func codeFenceInReasoningNeverReachesTheAnswer() {
        let text = "<think>\nMaybe:\n```bash\nrm -rf ~\n```\nNo, safer.\n</think>\n```bash\nls -la\n```\n"
        let split = ReasoningSplitter.split(text)
        #expect(split.answer == "```bash\nls -la\n```\n")
        #expect(!split.answer.contains("rm -rf"))
        #expect(split.reasoning.contains("rm -rf"))
    }
}
