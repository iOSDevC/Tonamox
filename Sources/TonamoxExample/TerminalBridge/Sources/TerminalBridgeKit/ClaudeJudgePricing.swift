import Foundation

/// US dollars per million tokens.
public struct ClaudeTokenPrice: Hashable, Sendable {
    public let inputUSDPerMillion: Decimal
    public let outputUSDPerMillion: Decimal

    public init(inputUSDPerMillion: Decimal, outputUSDPerMillion: Decimal) {
        self.inputUSDPerMillion = inputUSDPerMillion
        self.outputUSDPerMillion = outputUSDPerMillion
    }

    public func cost(inputTokens: Int, outputTokens: Int) -> Decimal {
        (Decimal(inputTokens) * inputUSDPerMillion + Decimal(outputTokens) * outputUSDPerMillion) / 1_000_000
    }
}

/// List prices of the judge models and of the models a `fallbacks: "default"` reply can come from. Dated: the
/// app passes them to `CostLedger.setPrice` explicitly instead of trusting its defaults.
public enum ClaudeJudgePrices {
    public static let checkedOn = "2026-11-03"

    /// Haiku's price holds for prompts up to 100K tokens; a judge prompt is a few thousand at most.
    static let table: [String: ClaudeTokenPrice] = [
        ClaudeJudgeModel.opus.rawValue: price(input: 400, output: 2000),
        ClaudeJudgeModel.sonnet.rawValue: price(input: 200, output: 1000),
        ClaudeJudgeModel.haiku.rawValue: price(input: 10, output: 50),
        "claude-opus-5": price(input: 500, output: 2500),
        "claude-opus-4-8": price(input: 500, output: 2500),
    ]

    /// The dearest entry: what an attempt on a model missing from the table is charged.
    public static let ceiling: ClaudeTokenPrice = price(input: 500, output: 2500)

    public static func knownPrice(for modelID: String) -> ClaudeTokenPrice? {
        table[modelID]
    }

    public static func price(for modelID: String) -> ClaudeTokenPrice {
        knownPrice(for: modelID) ?? ceiling
    }

    public static func price(for model: ClaudeJudgeModel) -> ClaudeTokenPrice {
        price(for: model.rawValue)
    }

    public static func cost(of attempts: [ClaudeJudgeAttempt]) -> Decimal {
        attempts.map { price(for: $0.modelID).cost(inputTokens: $0.inputTokens, outputTokens: $0.outputTokens) }
            .reduce(0, +)
    }

    private static func price(input inputCents: Int, output outputCents: Int) -> ClaudeTokenPrice {
        ClaudeTokenPrice(inputUSDPerMillion: Decimal(inputCents) / 100,
                         outputUSDPerMillion: Decimal(outputCents) / 100)
    }
}

/// The cost range of a batch, shown before it is sent and checked against the session cap.
public struct ClaudeJudgeEstimate: Hashable, Sendable {
    /// A three-field JSON and a short low-effort think; the low end of a reply.
    public static let typicalOutputTokens = 100
    /// What a refused attempt is charged at in the high end: a refusal stops early instead of filling `max_tokens`.
    public static let refusedOutputTokens = 256

    public let requestCount: Int
    /// Every prompt at its smallest token count, every reply at ``typicalOutputTokens``.
    public let lowUSD: Decimal
    /// Every prompt at its largest count. Per request, the dearer of two paths: the requested model answers with
    /// `max_tokens`, or, for Opus and Sonnet, it refuses after ``refusedOutputTokens`` and a fallback at
    /// ``ClaudeJudgePrices/ceiling`` answers with `max_tokens`.
    public let highUSD: Decimal

    public init(requests: [ClaudeJudgeRequest]) {
        requestCount = requests.count
        lowUSD = requests.map { request in
            ClaudeJudgePrices.price(for: request.model).cost(
                inputTokens: request.estimatedInputTokens.lowerBound, outputTokens: Self.typicalOutputTokens)
        }.reduce(0, +)
        highUSD = requests.map(Self.highCost).reduce(0, +)
    }

    /// The high end of one request.
    public static func highCost(_ request: ClaudeJudgeRequest) -> Decimal {
        let input = request.estimatedInputTokens.upperBound
        let output = ClaudeJudgeRequest.maxTokens
        let price = ClaudeJudgePrices.price(for: request.model)
        let answered = price.cost(inputTokens: input, outputTokens: output)
        guard request.model.supportsServerFallback else { return answered }
        let refused = price.cost(inputTokens: input, outputTokens: refusedOutputTokens)
        return max(answered, refused + ClaudeJudgePrices.ceiling.cost(inputTokens: input, outputTokens: output))
    }

    /// True when the high end would take the session past its cap.
    public func exceedsCap(_ capUSD: Decimal, spentUSD: Decimal) -> Bool {
        spentUSD + highUSD > capUSD
    }

    /// How many of `requests`, from the first, fit at their high end in what is left of the cap; 0 when not even
    /// one does.
    public static func affordableCount(of requests: [ClaudeJudgeRequest], capUSD: Decimal, spentUSD: Decimal)
        -> Int {
        var total = spentUSD
        var count = 0
        for request in requests {
            total += highCost(request)
            guard total <= capUSD else { break }
            count += 1
        }
        return count
    }
}
