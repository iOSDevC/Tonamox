import Foundation
import Testing
@testable import TonamoxCore

// MARK: - Template switch

@Suite("Reasoning control: chat template")
struct ReasoningTemplateTests {
    /// The generation prompt of LFM3's template, which reads `enable_thinking` with a `true` default.
    static let switchable = """
    {%- set enable_thinking = enable_thinking | default(true) -%}
    {%- for message in messages -%}{{- '<|im_start|>' + message.role + '\\n' + message.content + '<|im_end|>\\n' -}}\
    {%- endfor -%}
    {%- if add_generation_prompt -%}{{- '<|im_start|>assistant\\n' -}}\
    {%- if enable_thinking -%}{{- '<think>' -}}{%- else -%}{{- '<think></think>' -}}{%- endif -%}{%- endif -%}
    """
    static let chatML = """
    {% for message in messages %}{{ '<|im_start|>' + message['role'] + '\\n' + message['content'] + '<|im_end|>' + '\\n' }}\
    {% endfor %}{% if add_generation_prompt %}{{ '<|im_start|>assistant\\n' }}{% endif %}
    """

    @Test func templateThatReadsEnableThinkingCanDisableIt() {
        #expect(LlamaPromptRenderer(template: Self.switchable).canDisableThinking)
        #expect(!LlamaPromptRenderer(template: Self.chatML).canDisableThinking)
        #expect(!LlamaPromptRenderer(template: nil).canDisableThinking)
    }

    @Test func templateThatOnlyNamesEnableThinkingCannotDisableIt() {
        let comment = "{# enable_thinking is not supported #}" + Self.chatML
        let alreadyOff = Self.switchable.replacingOccurrences(of: "default(true)", with: "default(false)")
        #expect(!LlamaPromptRenderer(template: comment).canDisableThinking)
        #expect(!LlamaPromptRenderer(template: alreadyOff).canDisableThinking)
        #expect(LlamaPromptRenderer(template: comment).thinking(disabled: true).rendersWithoutThinking == false)
    }

    @Test func switchSurvivesDerivedRenderers() {
        let renderer = LlamaPromptRenderer(template: Self.switchable)
        #expect(renderer.withoutTools.canDisableThinking)
        #expect(renderer.thinking(disabled: true).canDisableThinking)
        #expect(renderer.thinking(disabled: true).rendersWithoutThinking)
    }

    @Test func disabledThinkingRendersEnableThinkingFalse() throws {
        let renderer = LlamaPromptRenderer(template: Self.switchable)
        let on = try renderer.render([.user("Hi")])
        let off = try renderer.thinking(disabled: true).render([.user("Hi")])

        #expect(on.hasSuffix("<|im_start|>assistant\n<think>"))
        #expect(off.hasSuffix("<|im_start|>assistant\n<think></think>"))
        #expect(off.contains("Hi"))
        #expect(try renderer.thinking(disabled: true).thinking(disabled: false).render([.user("Hi")]) == on)
    }

    @Test func templateWithoutTheSwitchIsLeftAsItIs() throws {
        let renderer = LlamaPromptRenderer(template: Self.chatML)
        let disabled = renderer.thinking(disabled: true)

        #expect(!disabled.rendersWithoutThinking)
        #expect(try disabled.render([.user("Hi")]) == renderer.render([.user("Hi")]))
    }

    @Test func profileReadsTheOpenedTagBothWays() {
        let profile = GGUFReasoningProfile(renderer: LlamaPromptRenderer(template: Self.switchable))

        #expect(profile == GGUFReasoningProfile(canDisableThinking: true, openedTag: "<think>",
                                                openedTagWithoutThinking: nil))
        #expect(profile.plan(for: .disabled)
                == ReasoningPlan(rendersWithoutThinking: true, budget: 0, openedTag: nil))
        #expect(profile.plan(for: ReasoningOptions(thinking: .disabled, budget: 64))
                == ReasoningPlan(rendersWithoutThinking: true, budget: 64, openedTag: nil))
        #expect(profile.plan(for: .budgeted(512))
                == ReasoningPlan(rendersWithoutThinking: false, budget: 512, openedTag: "<think>"))
        #expect(profile.openedTag(for: .automatic) == "<think>")
    }

    @Test func disabledThinkingWithoutTheSwitchClosesAnyBlockAtOnce() {
        let opening = Self.chatML.replacingOccurrences(of: "'<|im_start|>assistant\\n'",
                                                       with: "'<|im_start|>assistant\\n<think>\\n'")
        let profile = GGUFReasoningProfile(renderer: LlamaPromptRenderer(template: opening))

        #expect(!profile.canDisableThinking)
        #expect(profile.plan(for: .disabled)
                == ReasoningPlan(rendersWithoutThinking: false, budget: 0, openedTag: "<think>"))
    }

    @Test func optionsClampANegativeBudget() {
        #expect(ReasoningOptions(budget: -5).budget == 0)
        #expect(ReasoningOptions.automatic == ReasoningOptions(thinking: .automatic, budget: nil))
    }

    @Test func pieceLimitAddsTheBudgetAndItsCloseWithoutOverflowing() {
        #expect(GGUFTurnEngines.pieceLimit(maxTokens: 400, reasoning: .automatic) == 400)
        let budgeted = ReasoningPlan(rendersWithoutThinking: false, budget: 512, openedTag: nil)
        #expect(GGUFTurnEngines.pieceLimit(maxTokens: 400, reasoning: budgeted) == 913)
        #expect(GGUFTurnEngines.pieceLimit(maxTokens: .max, reasoning: budgeted) == .max)
        #expect(ReasoningPlan.pieceLimit(maxTokens: 400, budget: .max) == .max)
        #expect(ReasoningPlan.pieceLimit(maxTokens: 400, budget: nil) == 400)
    }

    @Test func replyReserveCountsTheBudgetOnlyWhenThePromptOpensABlock() {
        let opened = ReasoningPlan(rendersWithoutThinking: false, budget: 512, openedTag: "<think>")
        let notOpened = ReasoningPlan(rendersWithoutThinking: false, budget: 512, openedTag: nil)
        #expect(GGUFTurnEngines.replyReserve(answer: 400, total: 913, reasoning: opened) == 913)
        #expect(GGUFTurnEngines.replyReserve(answer: 400, total: 913, reasoning: notOpened) == 400)
        #expect(GGUFTurnEngines.replyReserve(answer: 400, total: 400, reasoning: .automatic) == 400)
    }

    @Test func cappingTheBudgetKeepsTheRestOfThePlan() {
        let plan = ReasoningPlan(rendersWithoutThinking: true, budget: 1024, openedTag: "<think>")
        #expect(plan.cappingBudget(at: 64)
                == ReasoningPlan(rendersWithoutThinking: true, budget: 64, openedTag: "<think>"))
        #expect(plan.cappingBudget(at: 2048) == plan)
        #expect(ReasoningPlan.automatic.cappingBudget(at: 64) == .automatic)
    }
}

// MARK: - Budget

/// Reasons with `thought` pieces until something is forced into it, then answers.
private struct ScriptedReasoner: PieceSource {
    var reasoningPiece = " hmm"
    var answer = ["7", "5", "4"]
    /// Pieces it reasons before closing the block itself; `nil` never does.
    var closesAfter: Int?
    var acceptsForce = true
    /// After each forced close, opens a new block instead of answering.
    var reopens = false
    private(set) var forced: [(text: String, flushing: Bool)] = []
    private var reopening = false
    private var sent = 0
    private var answering = false

    init(closesAfter: Int? = nil, acceptsForce: Bool = true, answer: [String] = ["7", "5", "4"]) {
        self.closesAfter = closesAfter
        self.acceptsForce = acceptsForce
        self.answer = answer
    }

    mutating func next() async throws -> String? {
        if reopening {
            reopening = false
            return "<think>"
        }
        if answering {
            return answer.isEmpty ? nil : answer.removeFirst()
        }
        sent += 1
        if let closesAfter, sent > closesAfter {
            answering = true
            return "</think>"
        }
        return reasoningPiece
    }

    mutating func force(_ text: String, flushing: Bool) -> Bool {
        forced.append((text, flushing))
        guard acceptsForce else { return false }
        if reopens {
            reopening = true
        } else {
            answering = true
        }
        return true
    }
}

/// Reasoning pieces in order, then "7" once something is forced or the list runs out.
private struct ListedSource: PieceSource {
    var reasoning: [String]
    private(set) var forcedAfter: Int?
    private var sent = 0
    private var answered = false

    init(reasoning: [String]) {
        self.reasoning = reasoning
    }

    mutating func next() async throws -> String? {
        if forcedAfter != nil {
            defer { answered = true }
            return answered ? nil : "7"
        }
        guard !reasoning.isEmpty else { return nil }
        sent += 1
        return reasoning.removeFirst()
    }

    mutating func force(_ text: String, flushing: Bool) -> Bool {
        forcedAfter = sent
        return true
    }
}

@Suite("Reasoning control: budget")
struct ReasoningBudgetTests {
    private static func plan(budget: Int?, opened: String? = "<think>") -> ReasoningPlan {
        ReasoningPlan(rendersWithoutThinking: false, budget: budget, openedTag: opened)
    }

    @Test func reasoningThatNeverClosesIsClosedAtTheBudgetAndTheAnswerDecodes() async throws {
        var source = ScriptedReasoner()
        var emitted: [String] = []
        let outcome = try await BudgetedDecode.run(&source, plan: Self.plan(budget: 5), maxTokens: 100,
                                                   answerTokens: 50) { emitted.append($0) }

        #expect(Array(emitted.prefix(5)) == Array(repeating: " hmm", count: 5))
        let closing = ReasoningBudgetMeter.closing("</think>", budget: 5)
        #expect(emitted[5] == "\n</think>\n\n")
        #expect(closing.visible == "\n</think>\n\n")
        #expect(closing.decoded == ReasoningBudgetMeter.budgetMessage + "\n</think>\n\n")
        #expect(Array(emitted.dropFirst(6)) == ["7", "5", "4"])
        #expect(source.forced.count == 1 && source.forced[0].flushing)
        #expect(source.forced[0].text == closing.decoded)
        #expect(outcome.endedByItself)
        #expect(outcome.turn == ReasoningTurn(renderedWithoutThinking: false, budget: 5, reasoningTokens: 5,
                                              answerTokens: 3, wasCut: true))

        var splitter = ReasoningSplitter()
        _ = splitter.consume("<think>" + emitted.joined())
        _ = splitter.finish()
        #expect(splitter.answer == "754")
        #expect(!splitter.isReasoningUnterminated)
    }

    @Test func reasoningThatClosesInTimeIsNotCut() async throws {
        var source = ScriptedReasoner(closesAfter: 3)
        var emitted: [String] = []
        let outcome = try await BudgetedDecode.run(&source, plan: Self.plan(budget: 5), maxTokens: 100,
                                                   answerTokens: 50) { emitted.append($0) }

        #expect(source.forced.isEmpty)
        #expect(!outcome.turn.wasCut)
        #expect(outcome.turn.reasoningTokens == 4)
        #expect(outcome.turn.answerTokens == 3)
        #expect(emitted.joined() == " hmm hmm hmm</think>754")
    }

    @Test func budgetZeroOnAPromptOpenedBlockClosesBeforeTheFirstPiece() async throws {
        var source = ScriptedReasoner()
        var emitted: [String] = []
        let outcome = try await BudgetedDecode.run(&source, plan: Self.plan(budget: 0), maxTokens: 100,
                                                   answerTokens: 50) { emitted.append($0) }

        #expect(emitted == ["</think>\n\n", "7", "5", "4"])
        #expect(source.forced.count == 1 && !source.forced[0].flushing)
        #expect(outcome.turn.reasoningTokens == 0 && !outcome.turn.wasCut)
        var relay = ReasoningSplitter()
        #expect(relay.consume("<think>" + emitted.joined()).allSatisfy {
            if case .reasoning = $0 { return false }
            return true
        })
    }

    @Test func blockTheModelOpensItselfIsCutToo() async throws {
        var source = ScriptedReasoner()
        source.reasoningPiece = "<think>"
        var emitted: [String] = []
        let outcome = try await BudgetedDecode.run(&source, plan: Self.plan(budget: 0, opened: nil), maxTokens: 100,
                                                   answerTokens: 50) { emitted.append($0) }

        #expect(emitted == ["<think>", "</think>\n\n", "7", "5", "4"])
        #expect(!outcome.turn.wasCut)
    }

    @Test func withoutABudgetNothingIsForcedAndMaxTokensCuts() async throws {
        var source = ScriptedReasoner()
        var count = 0
        let outcome = try await BudgetedDecode.run(&source, plan: Self.plan(budget: nil), maxTokens: 10,
                                                   answerTokens: nil) { _ in count += 1 }

        #expect(count == 10)
        #expect(source.forced.isEmpty)
        #expect(!outcome.endedByItself)
        #expect(outcome.turn == ReasoningTurn(renderedWithoutThinking: false, budget: nil, reasoningTokens: 10,
                                              answerTokens: 0, wasCut: false))
    }

    @Test func answerLimitCutsTheAnswerOnly() async throws {
        var source = ScriptedReasoner(answer: ["a", "b", "c", "d"])
        var emitted: [String] = []
        let outcome = try await BudgetedDecode.run(&source, plan: Self.plan(budget: 2), maxTokens: 100,
                                                   answerTokens: 2) { emitted.append($0) }

        #expect(Array(emitted.suffix(2)) == ["a", "b"])
        #expect(!outcome.endedByItself)
        #expect(outcome.turn.answerTokens == 2)
    }

    @Test func aCloseThatDoesNotFitEndsTheReplyCut() async throws {
        var source = ScriptedReasoner(acceptsForce: false)
        var emitted: [String] = []
        let outcome = try await BudgetedDecode.run(&source, plan: Self.plan(budget: 3), maxTokens: 100,
                                                   answerTokens: 50) { emitted.append($0) }

        #expect(emitted.count == 3)
        #expect(!outcome.endedByItself)
        #expect(!outcome.turn.wasCut)
    }

    @Test func aCutWaitsForAPieceThatCompletesItsCharacter() async throws {
        var source = ListedSource(reasoning: [" a", " b", "", "é", " c"])
        var emitted: [String] = []
        let outcome = try await BudgetedDecode.run(&source, plan: Self.plan(budget: 3), maxTokens: 100,
                                                   answerTokens: 50) { emitted.append($0) }

        #expect(Array(emitted.prefix(4)) == [" a", " b", "", "é"])
        #expect(emitted[4] == "\n</think>\n\n")
        #expect(source.forcedAfter == 4)
        #expect(outcome.turn.wasCut)
    }

    @Test func aCutWaitsWhileATagIsHalfWritten() async throws {
        var source = ListedSource(reasoning: [" a", " </thi", "nk>", "7"])
        var emitted: [String] = []
        let outcome = try await BudgetedDecode.run(&source, plan: Self.plan(budget: 2), maxTokens: 100,
                                                   answerTokens: 50) { emitted.append($0) }

        #expect(source.forcedAfter == nil)
        #expect(emitted == [" a", " </thi", "nk>", "7"])
        #expect(!outcome.turn.wasCut && outcome.endedByItself)
    }

    @Test func aBlockReopenedAfterTheCutIsClosedOnceMoreThenTheReplyEnds() async throws {
        var source = ScriptedReasoner()
        source.reopens = true
        var emitted: [String] = []
        let outcome = try await BudgetedDecode.run(&source, plan: Self.plan(budget: 2), maxTokens: 100,
                                                   answerTokens: 50) { emitted.append($0) }

        #expect(source.forced.map(\.text) == [ReasoningBudgetMeter.budgetMessage + "\n</think>\n\n", "\n</think>\n\n"])
        #expect(emitted == [" hmm", " hmm", "\n</think>\n\n", "<think>", "\n</think>\n\n", "<think>"])
        #expect(!outcome.endedByItself)
        #expect(outcome.turn.wasCut)
    }

    @Test func reasoningAnEarlierRoundSpentCountsAgainstTheBudget() async throws {
        var source = ScriptedReasoner()
        var emitted: [String] = []
        let outcome = try await BudgetedDecode.run(&source, plan: Self.plan(budget: 5), maxTokens: 100,
                                                   answerTokens: 50, spent: 4) { emitted.append($0) }

        #expect(emitted == [" hmm", "\n</think>\n\n", "7", "5", "4"])
        #expect(outcome.turn.reasoningTokens == 1 && outcome.turn.wasCut)

        var spentSource = ScriptedReasoner()
        var first: [String] = []
        _ = try await BudgetedDecode.run(&spentSource, plan: Self.plan(budget: 5), maxTokens: 100,
                                         answerTokens: 50, spent: 5) { first.append($0) }
        #expect(first.first == "\n</think>\n\n")
        #expect(spentSource.forced.first?.flushing == false)
    }

    @Test func meterCountsWithoutABudgetAndNeverCuts() {
        var meter = ReasoningBudgetMeter(openedTag: "<think>", budget: nil)
        for piece in ["a", "b", "</think>", "x", "y"] {
            #expect(meter.record(piece) == nil)
        }
        #expect(meter.reasoningTokens == 3 && meter.answerTokens == 2 && !meter.wasCut)
    }

    @Test func nestedOpenBlockGetsOneClosingTagPerLevel() {
        var meter = ReasoningBudgetMeter(openedTag: nil, budget: 2)
        #expect(meter.record("<think>") == nil)
        let closing = meter.record("<think>")
        #expect(closing == ReasoningBudgetMeter.closing("</think></think>", budget: 2))
    }

    @Test func turnsOfSeveralRoundsAddUp() {
        let first = ReasoningTurn(renderedWithoutThinking: true, budget: 8, reasoningTokens: 8, answerTokens: 2,
                                  wasCut: true)
        let second = ReasoningTurn(renderedWithoutThinking: true, budget: 8, reasoningTokens: 3, answerTokens: 4,
                                   wasCut: false)
        #expect(first.adding(second) == ReasoningTurn(renderedWithoutThinking: true, budget: 8, reasoningTokens: 11,
                                                      answerTokens: 6, wasCut: true))
    }
}

// MARK: - Boxed answers

struct BoxedFixture: Decodable, Sendable, CustomTestStringConvertible {
    let name: String
    let input: String
    let display: String
    let plain: String

    var testDescription: String { name }

    /// Shared with the browser page's tests (`Tests/SharedFixtures`).
    static let all: [BoxedFixture] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SharedFixtures/boxed-answers.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([BoxedFixture].self, from: data)) ?? []
    }()
}

@Suite("Boxed answers")
struct BoxedAnswerTests {
    @Test func fixturesLoad() {
        #expect(BoxedFixture.all.count >= 20)
    }

    @Test(arguments: BoxedFixture.all)
    func displayAndPlainMatchTheFixture(_ fixture: BoxedFixture) {
        #expect(BoxedAnswer.display(fixture.input) == fixture.display)
        #expect(BoxedAnswer.plain(fixture.input) == fixture.plain)
    }

    @Test func containsBoxIgnoresCode() {
        #expect(BoxedAnswer.containsBox("$\\boxed{1}$"))
        #expect(!BoxedAnswer.containsBox("`\\boxed{1}`"))
        #expect(!BoxedAnswer.containsBox("plain"))
    }
}
