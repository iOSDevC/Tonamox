import Foundation

/// The owner's judgement on a graded Test Mode reply. It replaces the automatic grade in the score, never the
/// grader: nothing here changes what `TestModeGrader` returns next time.
public enum TestModeVerdict: String, Hashable, Sendable {
    case validated
    case rejected
}

/// A button under a Test Mode grade.
public enum TestModeOverrideAction: Hashable, Sendable {
    case validate
    case reject
    case undo

    public var title: String {
        switch self {
        case .validate: "Marcar como válida"
        case .reject: "Marcar como incorrecta"
        case .undo: "Deshacer"
        }
    }

    public var identifier: String {
        switch self {
        case .validate: "validate"
        case .reject: "reject"
        case .undo: "undo"
        }
    }
}

/// What a reply row shows: the automatic grade and, when set, the owner's verdict over it.
public struct TestModeOutcome: Hashable, Sendable {
    public static let validatedText = "Válida (marcada a mano)"
    public static let rejectedText = "Incorrecta (marcada a mano)"

    public let automatic: TestModeGrade
    public let verdict: TestModeVerdict?

    public init(automatic: TestModeGrade, verdict: TestModeVerdict? = nil) {
        self.automatic = automatic
        self.verdict = verdict
    }

    public var countsAsCorrect: Bool {
        switch verdict {
        case .validated: true
        case .rejected: false
        case nil: automatic == .correct
        }
    }

    /// Enters the "de M" of the score: graded automatically, or judged by the owner.
    public var isGraded: Bool { verdict != nil || automatic.isAutomatic }

    public var text: String {
        switch verdict {
        case .validated: Self.validatedText
        case .rejected: Self.rejectedText
        case nil: automatic.text
        }
    }

    /// Seals for a hand verdict, circles for the grader's: the difference never rests on colour.
    public var symbol: String {
        switch verdict {
        case .validated: "checkmark.seal.fill"
        case .rejected: "xmark.seal.fill"
        case nil: automatic.symbol
        }
    }

    /// Keeps the grader's word visible under a hand verdict.
    public var automaticNote: String? {
        verdict == nil ? nil : "Corrector automático: " + automatic.text
    }

    public var actions: [TestModeOverrideAction] {
        if verdict != nil { return [.undo] }
        switch automatic {
        case .correct: return [.reject]
        case .incorrect: return [.validate]
        case .review: return [.validate, .reject]
        case .notApplicable: return []
        }
    }
}
