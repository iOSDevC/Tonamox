import Foundation

/// Tokens of one model attempt inside a reply: a refused attempt and the fallback that answered are billed apart,
/// each at its own model's prices.
public struct ClaudeJudgeAttempt: Hashable, Sendable {
    public let modelID: String
    /// Cache writes and reads included, at the full input price: an overestimate, never an underestimate.
    public let inputTokens: Int
    /// Thinking included.
    public let outputTokens: Int

    public init(modelID: String, inputTokens: Int, outputTokens: Int) {
        self.modelID = modelID
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// How one judge request ended.
public enum ClaudeJudgeOutcome: Hashable, Sendable {
    case judged(ClaudeJudgment)
    /// HTTP 200 with `stop_reason: "refusal"`; both fields can be missing.
    case refused(category: String?, explanation: String?)
    /// `stop_reason: "max_tokens"`: the JSON may be cut, so nothing is read.
    case cutOff
    /// The Spanish line the row shows.
    case failed(String)
}

/// A Messages API reply read for the judge. `stop_reason` is checked before any content, and only the `text`
/// blocks after the last `fallback` block are read: `thinking`, `fallback` and any other block are skipped.
public struct ClaudeJudgeResponse: Hashable, Sendable {
    public let outcome: ClaudeJudgeOutcome
    /// The top-level `model`: the one that produced the message, a fallback included.
    public let servedBy: String?
    /// A server-side fallback ran (a `fallback_message` attempt or a `fallback` block).
    public let fellBack: Bool
    /// What to record in the cost ledger; empty when the reply had no usage.
    public let attempts: [ClaudeJudgeAttempt]

    public var judgment: ClaudeJudgment? {
        if case .judged(let judgment) = outcome { judgment } else { nil }
    }

    public var costUSD: Decimal { ClaudeJudgePrices.cost(of: attempts) }

    public static func parse(
        _ data: Data,
        status: Int,
        requested: ClaudeJudgeModel,
        date: Date
    ) -> ClaudeJudgeResponse {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else {
            let failure = (200..<300).contains(status) ? ClaudeJudgeText.unreadable : ClaudeJudgeText.httpError(status)
            return ClaudeJudgeResponse(outcome: .failed(failure), servedBy: nil, fellBack: false, attempts: [])
        }
        let attempts = wire.usage.map { attempts(of: $0, servedBy: wire.model, requested: requested) } ?? []
        let blocks = wire.content ?? []
        let fellBack = blocks.contains { $0.type == "fallback" }
            || (wire.usage?.iterations ?? []).contains { $0.type == "fallback_message" }
        let outcome = (200..<300).contains(status)
            ? outcome(of: wire, blocks: blocks, judgeModel: wire.model ?? requested.rawValue, date: date)
            : .failed(ClaudeJudgeText.httpError(status, type: wire.error?.type))
        return ClaudeJudgeResponse(outcome: outcome, servedBy: wire.model, fellBack: fellBack, attempts: attempts)
    }

    private static func outcome(
        of wire: Wire,
        blocks: [Wire.Block],
        judgeModel: String,
        date: Date
    ) -> ClaudeJudgeOutcome {
        switch wire.stopReason {
        case "refusal":
            return .refused(category: wire.stopDetails?.category, explanation: wire.stopDetails?.explanation)
        case "max_tokens":
            return .cutOff
        case "end_turn":
            break
        default:
            return .failed(ClaudeJudgeText.unexpectedStop(wire.stopReason))
        }
        let afterFallback = blocks.lastIndex { $0.type == "fallback" }.map { blocks.index(after: $0) } ?? 0
        let text = blocks[afterFallback...].filter { $0.type == "text" }.compactMap(\.text).joined()
        guard let judgment = judgment(from: text, judgeModel: judgeModel, date: date) else {
            return .failed(ClaudeJudgeText.invalidJudgment)
        }
        return .judged(judgment)
    }

    /// The schema's three keys and nothing else, with the declared types; nil otherwise.
    static func judgment(from text: String, judgeModel: String, date: Date) -> ClaudeJudgment? {
        guard let fields = try? JSONDecoder().decode([String: RawJSON].self, from: Data(text.utf8)),
              Set(fields.keys) == ["verdict", "formatting_only", "reason"],
              case .string(let word)? = fields["verdict"], let verdict = ClaudeVerdict(rawValue: word),
              case .bool(let formattingOnly)? = fields["formatting_only"],
              case .string(let reason)? = fields["reason"],
              !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return ClaudeJudgment(verdict: verdict, formattingOnly: formattingOnly, reason: reason,
                              judgeModel: judgeModel, date: date)
    }

    /// Per attempt from `usage.iterations` when present, else the top-level usage as one attempt.
    private static func attempts(
        of usage: Wire.TokenCounts,
        servedBy: String?,
        requested: ClaudeJudgeModel
    ) -> [ClaudeJudgeAttempt] {
        let iterations = (usage.iterations ?? []).filter { $0.inputTokens != nil || $0.outputTokens != nil }
        guard !iterations.isEmpty else {
            return [usage.attempt(modelID: servedBy ?? requested.rawValue)]
        }
        return iterations.map { iteration in
            let fallbackModel = iteration.type == "fallback_message" ? servedBy : nil
            return iteration.attempt(modelID: iteration.model ?? fallbackModel ?? requested.rawValue)
        }
    }

    private struct Wire: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }

        struct StopInfo: Decodable {
            let category: String?
            let explanation: String?
        }

        struct TokenCounts: Decodable {
            let type: String?
            let model: String?
            let inputTokens: Int?
            let outputTokens: Int?
            let cacheCreationInputTokens: Int?
            let cacheReadInputTokens: Int?
            let iterations: [TokenCounts]?

            func attempt(modelID: String) -> ClaudeJudgeAttempt {
                let input = (inputTokens ?? 0) + (cacheCreationInputTokens ?? 0) + (cacheReadInputTokens ?? 0)
                return ClaudeJudgeAttempt(modelID: modelID, inputTokens: input, outputTokens: outputTokens ?? 0)
            }

            enum CodingKeys: String, CodingKey {
                case type, model, iterations
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
            }
        }

        struct APIError: Decodable {
            let type: String?
        }

        let model: String?
        let stopReason: String?
        let stopDetails: StopInfo?
        let content: [Block]?
        let usage: TokenCounts?
        let error: APIError?

        enum CodingKeys: String, CodingKey {
            case model, content, usage, error
            case stopReason = "stop_reason"
            case stopDetails = "stop_details"
        }
    }
}
