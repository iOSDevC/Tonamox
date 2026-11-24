import Foundation

// MARK: - ReasoningOptions

/// How a turn may reason before it answers. Applies to GGUF models (llama.cpp and layer streaming); MLX, Apple
/// Intelligence and remote models ignore it.
public struct ReasoningOptions: Sendable, Hashable, Codable {
    public enum ThinkingMode: String, Sendable, Hashable, Codable {
        /// The chat template's own default.
        case automatic
        /// Renders the template with `enable_thinking = false` when that changes the prompt
        /// (``ReasoningCapabilities/canDisableThinking``). Either way, without a budget of its own any block the
        /// model still opens is closed at once, as with a budget of 0.
        case disabled
    }

    public var thinking: ThinkingMode
    /// Reasoning tokens allowed before the block is closed for the model, on top of the answer's `maxTokens`; `nil`
    /// gives reasoning no budget of its own, so it counts against `maxTokens` as any other text. Negative counts as 0.
    public var budget: Int?

    public init(thinking: ThinkingMode = .automatic, budget: Int? = nil) {
        self.thinking = thinking
        self.budget = budget.map { max(0, $0) }
    }

    /// The template's default and no reasoning budget: the behaviour before reasoning control existed.
    public static let automatic = ReasoningOptions()
    public static let disabled = ReasoningOptions(thinking: .disabled)

    /// Thinking as the template sets it, closed after `tokens` reasoning tokens.
    public static func budgeted(_ tokens: Int) -> ReasoningOptions {
        ReasoningOptions(thinking: .automatic, budget: tokens)
    }
}

// MARK: - ReasoningCapabilities

/// What the loaded model's backend can do with ``ReasoningOptions``.
public struct ReasoningCapabilities: Sendable, Hashable {
    /// Rendering the chat template with `enable_thinking = false` changes the prompt, so
    /// ``ReasoningOptions/ThinkingMode/disabled`` switches thinking off in the template itself.
    public let canDisableThinking: Bool
    /// The backend closes a reasoning block at its budget. `false` for MLX, Apple Intelligence, remote models and a
    /// GGUF loaded with tools whose calls are not `<tool_call>` JSON.
    public let enforcesBudget: Bool

    public init(canDisableThinking: Bool, enforcesBudget: Bool) {
        self.canDisableThinking = canDisableThinking
        self.enforcesBudget = enforcesBudget
    }

    public static let unsupported = ReasoningCapabilities(canDisableThinking: false, enforcesBudget: false)
}

// MARK: - ReasoningTurn

/// What reasoning control did in the last generation of a GGUF instance.
public struct ReasoningTurn: Sendable, Hashable {
    /// The template was rendered with `enable_thinking = false`.
    public let renderedWithoutThinking: Bool
    /// The budget the turn ran with; 0 when thinking was disabled and no budget was given.
    public let budget: Int?
    /// Pieces inside the leading reasoning block; a forced close is not counted.
    public let reasoningTokens: Int
    /// Pieces after it.
    public let answerTokens: Int
    /// The budget ran out inside the block and its closing tag was decoded for the model. `false` for a budget of
    /// 0: a block closed at once is reasoning that was not asked for, not a cut.
    public let wasCut: Bool

    public init(renderedWithoutThinking: Bool, budget: Int?, reasoningTokens: Int, answerTokens: Int, wasCut: Bool) {
        self.renderedWithoutThinking = renderedWithoutThinking
        self.budget = budget
        self.reasoningTokens = reasoningTokens
        self.answerTokens = answerTokens
        self.wasCut = wasCut
    }

    /// Rounds of one turn (tool loops) added up.
    func adding(_ other: ReasoningTurn) -> ReasoningTurn {
        ReasoningTurn(renderedWithoutThinking: renderedWithoutThinking, budget: budget,
                      reasoningTokens: reasoningTokens + other.reasoningTokens,
                      answerTokens: answerTokens + other.answerTokens, wasCut: wasCut || other.wasCut)
    }
}

// MARK: - ReasoningBudgetMeter

/// Counts one reply's pieces as reasoning or answer with the rules of ``ReasoningSplitter`` and says when the budget
/// ran out inside the block. The caller decodes the returned closing text and hands it back through ``forced(_:)``.
struct ReasoningBudgetMeter: Sendable {
    /// What to decode for the model and what to show for it.
    struct Closing: Sendable, Equatable {
        let decoded: String
        let visible: String
    }

    /// `nil` only counts.
    let budget: Int?
    /// Reasoning pieces earlier replies of the same turn (tool rounds) already used.
    let spent: Int
    private var splitter = ReasoningSplitter()
    private(set) var reasoningTokens = 0
    private(set) var answerTokens = 0
    private(set) var wasCut = false
    private(set) var forcedCloses = 0

    /// A model that reopens a block after this many forced closes ends the reply: closing it again would only feed
    /// it more forced text.
    static let maxForcedCloses = 2

    /// `openedTag` is the tag the prompt ended with (``LlamaPromptRenderer/reasoningTagOpenedByPrompt``).
    init(openedTag: String?, budget: Int?, spent: Int = 0) {
        self.budget = budget
        self.spent = max(0, spent)
        if let openedTag { _ = splitter.consume(openedTag) }
    }

    private var isSpent: Bool {
        guard let budget else { return false }
        return spent + reasoningTokens >= budget
    }

    /// The text to decode before the first piece: a spent budget on a block the prompt opened.
    func closingBeforeFirstPiece() -> Closing? {
        isSpent ? closingIfInside() : nil
    }

    /// Counts `piece`; returns the closing text to decode when the budget is used up inside the block. Never right
    /// after an empty piece (the sampler holds part of a UTF-8 character) or while a tag is half written.
    mutating func record(_ piece: String) -> Closing? {
        let wasInside = splitter.isInsideReasoning
        _ = splitter.consume(piece)
        if wasInside || splitter.isInsideReasoning {
            reasoningTokens += 1
        } else {
            answerTokens += 1
        }
        guard isSpent, !piece.isEmpty, !splitter.isHoldingPartialTag else { return nil }
        return closingIfInside()
    }

    /// The model reasons again after every close it may get.
    var reopenedAfterLastClose: Bool {
        isSpent && forcedCloses >= Self.maxForcedCloses && splitter.isInsideReasoning
    }

    /// The forced text was decoded, so the splitter sees the block closed. A budget of 0 is no reasoning asked
    /// for, not a cut.
    mutating func forced(_ closing: Closing) {
        _ = splitter.consume(closing.decoded)
        forcedCloses += 1
        if budget != 0 { wasCut = true }
    }

    private func closingIfInside() -> Closing? {
        guard forcedCloses < Self.maxForcedCloses, let tags = splitter.closingTagsOfOpenBlock else { return nil }
        return Self.closing(tags, budget: budget, first: forcedCloses == 0)
    }

    /// A bare closing tag is not enough: small models then keep reasoning in the answer. The sentence before it is
    /// the one Qwen's thinking-budget guide uses; the tag then sits on its own line before a blank line, as templates
    /// render a closed block.
    static let budgetMessage = "\n\nConsidering the limited time by the user, I have to give the solution based on the "
        + "thinking directly now."

    /// Only the first close carries the sentence, which the model reads but the reader is not shown. A budget of 0
    /// stands for "no reasoning": the tag follows the opening at once, as a template renders thinking off.
    static func closing(_ tags: String, budget: Int?, first: Bool = true) -> Closing {
        let ending = tags + "\n\n"
        guard budget != 0 else { return Closing(decoded: ending, visible: ending) }
        return Closing(decoded: (first ? budgetMessage : "") + "\n" + ending, visible: "\n" + ending)
    }

    func turn(renderedWithoutThinking: Bool) -> ReasoningTurn {
        ReasoningTurn(renderedWithoutThinking: renderedWithoutThinking, budget: budget,
                      reasoningTokens: reasoningTokens, answerTokens: answerTokens, wasCut: wasCut)
    }
}

// MARK: - BudgetedDecode

/// Where ``BudgetedDecode`` takes pieces from: a model's sampler, or a script in tests.
package protocol PieceSource {
    /// The next piece; `nil` at the end of generation.
    mutating func next() async throws -> String?
    /// Feeds `text` to the model as if it had written it, so the next piece follows it. `flushing` is `true` after a
    /// piece (whose sampled token may still be queued) and `false` before the first. `false` when it did not fit.
    mutating func force(_ text: String, flushing: Bool) -> Bool
}

/// One reply under a ``ReasoningPlan``: pieces stream to `emit`; a block still open when the reasoning reaches its
/// budget gets its closing tag forced and emitted as one more piece, then the answer decodes. Stops at the end of
/// generation, after `maxTokens` pieces (forced ones included), after `answerTokens` answer pieces, when the model
/// reopens a block after its last allowed close, or when the task is cancelled.
package enum BudgetedDecode {
    package struct Outcome: Sendable {
        package let turn: ReasoningTurn
        /// The source ran out by itself rather than being cut.
        package let endedByItself: Bool
    }

    /// A piece as shown, and as the model's context holds it; they differ only for a forced close.
    package struct Piece: Sendable, Equatable {
        package let visible: String
        package let decoded: String
    }

    /// `spent` is the reasoning earlier replies of the turn used, counted against the same budget.
    package static func runDecoded<Source: PieceSource>(
        _ source: inout Source,
        plan: ReasoningPlan,
        maxTokens: Int,
        answerTokens: Int?,
        spent: Int = 0,
        emit: (Piece) -> Void
    ) async throws -> Outcome {
        var meter = ReasoningBudgetMeter(openedTag: plan.openedTag, budget: plan.budget, spent: spent)
        let summary = { (ended: Bool) in
            Outcome(turn: meter.turn(renderedWithoutThinking: plan.rendersWithoutThinking), endedByItself: ended)
        }
        var produced = 0
        if let closing = meter.closingBeforeFirstPiece() {
            guard source.force(closing.decoded, flushing: false) else { return summary(false) }
            meter.forced(closing)
            emit(Piece(visible: closing.visible, decoded: closing.decoded))
            produced += 1
        }
        while let piece = try await source.next() {
            emit(Piece(visible: piece, decoded: piece))
            produced += 1
            let closing = meter.record(piece)
            if produced >= maxTokens || Task.isCancelled || answerTokens.map({ meter.answerTokens >= $0 }) == true
                || meter.reopenedAfterLastClose {
                return summary(false)
            }
            guard let closing else { continue }
            guard source.force(closing.decoded, flushing: true) else { return summary(false) }
            meter.forced(closing)
            emit(Piece(visible: closing.visible, decoded: closing.decoded))
            produced += 1
        }
        return summary(true)
    }

    /// As ``runDecoded(_:plan:maxTokens:answerTokens:spent:emit:)``, emitting the visible text only.
    package static func run<Source: PieceSource>(
        _ source: inout Source,
        plan: ReasoningPlan,
        maxTokens: Int,
        answerTokens: Int?,
        spent: Int = 0,
        emit: (String) -> Void
    ) async throws -> Outcome {
        try await runDecoded(&source, plan: plan, maxTokens: maxTokens, answerTokens: answerTokens, spent: spent) {
            emit($0.visible)
        }
    }
}

// MARK: - ReasoningPlan

/// One GGUF turn's reasoning settings, resolved against the template.
package struct ReasoningPlan: Sendable, Equatable {
    /// Render with `enable_thinking = false`.
    package let rendersWithoutThinking: Bool
    /// Budget the meter enforces; `nil` only counts.
    package let budget: Int?
    /// The tag the prompt ends with when rendered this way.
    package let openedTag: String?

    package static let automatic = ReasoningPlan(rendersWithoutThinking: false, budget: nil, openedTag: nil)

    package init(rendersWithoutThinking: Bool, budget: Int?, openedTag: String?) {
        self.rendersWithoutThinking = rendersWithoutThinking
        self.budget = budget
        self.openedTag = openedTag
    }

    /// The total pieces a reply may produce: the answer's `maxTokens`, plus the budget and its forced close.
    package static func pieceLimit(maxTokens: Int, budget: Int?) -> Int {
        guard let budget else { return maxTokens }
        let (extra, overflowed) = max(0, budget).addingReportingOverflow(1)
        let (sum, overflow) = maxTokens.addingReportingOverflow(extra)
        return overflowed || overflow ? Int.max : sum
    }

    /// The same plan with its budget at most `cap`.
    func cappingBudget(at cap: Int) -> ReasoningPlan {
        guard let budget, budget > cap else { return self }
        return ReasoningPlan(rendersWithoutThinking: rendersWithoutThinking, budget: max(0, cap), openedTag: openedTag)
    }
}

/// What a GGUF chat template allows, read once per load.
struct GGUFReasoningProfile: Sendable, Equatable {
    let canDisableThinking: Bool
    let openedTag: String?
    let openedTagWithoutThinking: String?

    static let none = GGUFReasoningProfile(canDisableThinking: false, openedTag: nil, openedTagWithoutThinking: nil)

    init(canDisableThinking: Bool, openedTag: String?, openedTagWithoutThinking: String?) {
        self.canDisableThinking = canDisableThinking
        self.openedTag = openedTag
        self.openedTagWithoutThinking = openedTagWithoutThinking
    }

    init(renderer: LlamaPromptRenderer) {
        let canDisable = renderer.canDisableThinking
        let opened = renderer.thinking(disabled: false).reasoningTagOpenedByPrompt
        self.init(canDisableThinking: canDisable, openedTag: opened,
                  openedTagWithoutThinking: canDisable ? renderer.thinking(disabled: true).reasoningTagOpenedByPrompt
                      : opened)
    }

    /// Disabled thinking closes any block at once: on a template without the switch, and on one whose model reasons
    /// anyway.
    func plan(for options: ReasoningOptions) -> ReasoningPlan {
        switch options.thinking {
        case .automatic:
            ReasoningPlan(rendersWithoutThinking: false, budget: options.budget, openedTag: openedTag)
        case .disabled where canDisableThinking:
            ReasoningPlan(rendersWithoutThinking: true, budget: options.budget ?? 0, openedTag: openedTagWithoutThinking)
        case .disabled:
            ReasoningPlan(rendersWithoutThinking: false, budget: 0, openedTag: openedTag)
        }
    }

    func openedTag(for options: ReasoningOptions) -> String? {
        plan(for: options).openedTag
    }
}

// MARK: - ReasoningControlHost

/// A backend that applies ``ReasoningOptions``.
@MainActor
protocol ReasoningControlHost: AnyObject {
    var reasoningSupport: ReasoningCapabilities { get }
    var lastReasoningTurn: ReasoningTurn? { get }
    func promptOpenedReasoningTag(for options: ReasoningOptions) -> String?

    func generate(prompt: String, systemPrompt: String?, maxTokens: Int, reasoning: ReasoningOptions,
                  onToken: @escaping @MainActor (String) -> Void) async throws -> String

    func generate(messages: [[String: String]], maxTokens: Int, reasoning: ReasoningOptions,
                  onToken: @escaping @MainActor (String) -> Void) async throws -> String
}
