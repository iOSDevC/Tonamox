import Foundation

/// The Terminal chat's answer limit ("Longitud de respuesta" in the model sheet), kept in UserDefaults. Applies to
/// every engine; for a remote one it is also the output the consent sheet and the cost cap count.
public enum ReplyLength: String, CaseIterable, Sendable {
    case short
    case medium
    case long

    public static let defaultsKey = "terminal.replyLength"
    public static let sectionTitle = "Longitud de respuesta"
    public static let footer = "Límite de la respuesta en todos los motores, también los remotos. Si el mensaje no deja "
        + "sitio en el contexto del modelo, la respuesta se acorta y se indica debajo."

    /// The stored value; ``short`` when nothing valid is stored.
    public static func stored(_ raw: String?) -> ReplyLength {
        raw.flatMap(ReplyLength.init(rawValue:)) ?? .short
    }

    public var tokens: Int {
        switch self {
        case .short: 400
        case .medium: 800
        case .long: 1600
        }
    }

    public var title: String {
        switch self {
        case .short: "Corta (400 tokens)"
        case .medium: "Media (800 tokens)"
        case .long: "Larga (1600 tokens)"
        }
    }

    /// Builds before the setting answered with this many tokens at most, on every engine.
    public static let legacyTokens = 400

    /// The line the results page shows for a report's ``CapabilityReport/answerLength``.
    public static func reportText(_ tokens: Int?) -> String {
        guard let tokens else {
            return "Longitud de respuesta: hasta \(legacyTokens) tokens (fija en informes anteriores)."
        }
        return "Longitud de respuesta: hasta \(tokens) tokens."
    }

    /// Seconds a capability probe may stream after its first delta. Scales with the tokens a reply may take, at the
    /// slowest decode the battery expects, so a long setting is not graded as a timeout; never under the old 120 s.
    public static func probeTimeLimit(answerTokens: Int, reasoningTokens: Int?) -> Int {
        let tokens = max(0, answerTokens) + max(0, reasoningTokens ?? 0)
        return max(minimumProbeSeconds, (tokens + slowestDecodeRate - 1) / slowestDecodeRate)
    }

    static let minimumProbeSeconds = 120
    /// Tokens per second; an 8B GGUF on an older iPhone.
    static let slowestDecodeRate = 8

    /// The reason a timed-out probe records, so the report says which limit cut it.
    public static func timeoutReason(seconds: Int, tokens: Int) -> String {
        "Sin terminar en \(seconds) s, el límite para \(tokens) tokens."
    }
}

// MARK: - ReplyBudget

/// One turn's answer and reasoning tokens, bounded so the prompt, the reasoning and the answer fit the model's
/// context window. The answer keeps its length before the reasoning does: reasoning without an answer is useless.
public struct ReplyBudget: Equatable, Sendable {
    public enum Clamp: Equatable, Sendable {
        /// The answer was cut to this many tokens; `withoutReasoning` when the reasoning budget went to 0 too.
        case answer(Int, withoutReasoning: Bool)
        /// Only the reasoning was cut, to this many tokens.
        case reasoning(Int)
        /// Not even ``ReplyBudget/minimumAnswer`` tokens fit the window.
        case noRoom(window: Int)
    }

    public let answerTokens: Int
    /// `nil` when the reasoning has no budget of its own (disabled, or a backend that does not enforce one).
    public let reasoningTokens: Int?
    /// `nil` when the request fit as asked.
    public let limit: Clamp?

    public init(answerTokens: Int, reasoningTokens: Int?, limit: Clamp? = nil) {
        self.answerTokens = answerTokens
        self.reasoningTokens = reasoningTokens
        self.limit = limit
    }

    /// Chat-template tokens around the system and user turns.
    public static let templateAllowance = 128
    /// A forced reasoning close is one piece of the budget but decodes the budget sentence and the tag (about 30
    /// tokens), and a model that reopens its block gets one more tag.
    public static let closeAllowance = 48
    /// Below this an answer cannot hold a command and a sentence, so the turn is refused instead.
    public static let minimumAnswer = 32

    /// No tokenizer is exposed for GGUF, so the prompt is estimated at one token per two UTF-8 bytes plus
    /// ``templateAllowance``. LFM3 measured ~3.9 bytes per token on Spanish prose and ~2.3 on `ls`/`ps` output; three
    /// bytes, the server's ratio, undercounts a full paste of the latter. Tokenizers that split digits one by one
    /// (Qwen, Gemma) can go under two on numeric output; `mayHaveFilledWindow` flags the replies that may have cut.
    public static func estimatedPromptTokens(systemPrompt: String, prompt: String) -> Int {
        let bytes = systemPrompt.utf8.count + prompt.utf8.count
        return (bytes + 1) / 2 + templateAllowance
    }

    /// The prompt's tokens at most: a tokenizer never makes more than one token per UTF-8 byte.
    public static func maximumPromptTokens(systemPrompt: String, prompt: String) -> Int {
        systemPrompt.utf8.count + prompt.utf8.count + templateAllowance
    }

    /// llama.cpp ends a reply at a full window as if the model had stopped. A reply whose answer stopped short of
    /// `answerLimit` may have ended that way only when the prompt at its largest plus the `decoded` pieces reaches
    /// `window`; `false` proves it did not. `nil` window: no fixed window to fill.
    public static func mayHaveFilledWindow(window: Int?, maximumPromptTokens: Int, decoded: Int, answered: Int,
                                           answerLimit: Int) -> Bool {
        guard let window, window > 0, answered < answerLimit else { return false }
        return maximumPromptTokens + decoded + closeAllowance >= window
    }

    /// The line under a reply `mayHaveFilledWindow` flags.
    public static func windowFilledNote(window: Int) -> String {
        "Puede que la respuesta esté incompleta: el mensaje y la respuesta pueden haber llenado el contexto del "
            + "modelo (\(window) tokens). Si lo parece, acorta el mensaje o pega menos salida."
    }

    /// The budgets for one local turn and the reasoning budget to ask the backend for; `reasoningRequest` `nil` turns
    /// thinking off. A budget the backend does not enforce counts against the answer's limit, so only the answer is
    /// bounded then and the setting's budget goes through unchanged.
    public static func planned(answer: Int, reasoning: ReasoningSetting, enforcesBudget: Bool, window: Int?,
                               promptTokens: Int) -> (budget: ReplyBudget, reasoningRequest: Int?) {
        let budget = fitting(answer: answer, reasoning: enforcesBudget ? reasoning.budget : nil, window: window,
                             promptTokens: promptTokens)
        return (budget, reasoning.budget.map { budget.reasoningTokens ?? $0 })
    }

    /// `answer` and `reasoning` as asked when they fit `window` after `promptTokens`; otherwise the reasoning shrinks
    /// first, then the answer. `window` `nil` (remote models, Apple Intelligence) leaves both as asked.
    public static func fitting(answer: Int, reasoning: Int?, window: Int?, promptTokens: Int) -> ReplyBudget {
        let answer = max(0, answer)
        let reasoning = reasoning.map { max(0, $0) }
        guard let window, window > 0 else { return ReplyBudget(answerTokens: answer, reasoningTokens: reasoning) }
        let room = window - max(0, promptTokens) - closeAllowance
        let (asked, overflow) = answer.addingReportingOverflow(reasoning ?? 0)
        if !overflow, asked <= room { return ReplyBudget(answerTokens: answer, reasoningTokens: reasoning) }
        guard room >= minimumAnswer else {
            return ReplyBudget(answerTokens: 0, reasoningTokens: reasoning.map { _ in 0 }, limit: .noRoom(window: window))
        }
        if room > answer, reasoning != nil {
            return ReplyBudget(answerTokens: answer, reasoningTokens: room - answer, limit: .reasoning(room - answer))
        }
        let removed = (reasoning ?? 0) > 0
        return ReplyBudget(answerTokens: room, reasoningTokens: reasoning.map { _ in 0 },
                           limit: .answer(room, withoutReasoning: removed))
    }

    /// The reasoning and answer tokens a reply may take at most.
    public var totalTokens: Int {
        answerTokens + (reasoningTokens ?? 0)
    }
}

extension ReplyBudget.Clamp {
    /// The line under the reply; `nil` for ``noRoom(window:)``, which refuses the turn with ``refusal``.
    public var note: String? {
        switch self {
        case .answer(let tokens, withoutReasoning: false):
            "Respuesta limitada a \(tokens) tokens por el contexto del modelo."
        case .answer(let tokens, withoutReasoning: true):
            "Respuesta limitada a \(tokens) tokens, sin razonamiento, por el contexto del modelo."
        case .reasoning(let tokens):
            "Razonamiento limitado a \(tokens) tokens por el contexto del modelo."
        case .noRoom:
            nil
        }
    }

    /// Why the turn was not sent; `nil` unless ``noRoom(window:)``.
    public var refusal: String? {
        guard case .noRoom(let window) = self else { return nil }
        return "El mensaje no deja sitio para la respuesta en el contexto del modelo (\(window) tokens). Acórtalo o "
            + "pega menos salida."
    }
}

// MARK: - Cost estimate

/// The last measured decode speed of one model, so the model sheet can say what a full reply costs in time.
public struct MeasuredDecode: Codable, Equatable, Sendable {
    public let tokensPerSecond: Double
    /// The backend enforced the reasoning budget, so a reply may take the budget on top of the answer.
    public let reasoningCounts: Bool

    public init(tokensPerSecond: Double, reasoningCounts: Bool) {
        self.tokensPerSecond = tokensPerSecond
        self.reasoningCounts = reasoningCounts
    }

    /// The line under the settings: seconds for a reply that uses its whole budget, or `nil` without a usable speed.
    public func costLine(length: ReplyLength, reasoning: ReasoningSetting) -> String? {
        guard tokensPerSecond.isFinite, tokensPerSecond > 0 else { return nil }
        let tokens = length.tokens + (reasoningCounts ? reasoning.budget ?? 0 : 0)
        let seconds = Int((Double(tokens) / tokensPerSecond).rounded(.up))
        let rate = tokensPerSecond < 1 ? "menos de 1 token/s" : "\(Int(tokensPerSecond.rounded())) tokens/s"
        let time = seconds >= 90 ? "unos \(Int((Double(seconds) / 60).rounded())) min" : "unos \(seconds) s"
        return "Una respuesta completa tarda \(time) con este modelo (\(tokens) tokens a \(rate), última medida)."
    }
}

/// The JSON stored under one UserDefaults key: the last measured decode per model choice.
public enum MeasuredDecodeArchive {
    public static let defaultsKey = "terminal.decodeSpeed.v1"

    /// Empty for missing or unreadable data.
    public static func decode(_ data: Data?) -> [String: MeasuredDecode] {
        guard let data else { return [:] }
        return (try? JSONDecoder().decode([String: MeasuredDecode].self, from: data)) ?? [:]
    }

    public static func encode(_ entries: [String: MeasuredDecode]) -> Data? {
        try? JSONEncoder().encode(entries)
    }
}
