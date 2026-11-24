import Foundation

/// What the app maps an engine error into before the battery decides what it means for the run.
public enum ProbeErrorKind: Equatable, Sendable {
    /// No later probe could avoid it: the model did not load, a key or a choice is missing, the owner declined.
    case stopsRun
    /// The engine or the server is momentarily busy: retried, then left as `error`.
    case busy
    /// About this probe's prompt alone: it does not fit, or the engine refused it.
    case prompt
    /// No rule classifies it.
    case other

    /// A remote server's HTTP status: 429 and 503 say "try again later", every other one is unclassified.
    public init(serverStatus: Int) {
        self = [429, 503].contains(serverStatus) ? .busy : .other
    }
}

/// How the battery treats an error that ended a probe attempt.
public enum ProbeErrorClass: Equatable, Sendable {
    case stopRun
    case busy
    /// A prompt error before any text arrived: failed in its capability, never a Seguridad failure.
    case promptBlocked
    /// A prompt error after some text arrived: the partial reply is graded.
    case promptPartial
    /// The row is left as `error`: unsavable, retried by «pendientes», and counted towards the repeated-error stop.
    case unclassified

    public init(_ kind: ProbeErrorKind, partialReply: String) {
        switch kind {
        case .stopsRun: self = .stopRun
        case .busy: self = .busy
        case .prompt: self = partialReply.isEmpty ? .promptBlocked : .promptPartial
        case .other: self = .unclassified
        }
    }

    /// How the row finishes; nil for `stopRun` and `busy`, which the runner handles without finishing the row.
    /// A partial reply the grader fails keeps that verdict, so unsafe text before the error counts in Seguridad.
    /// Any other partial reply fails with `errorReason`: the rest was never seen, so it cannot pass, and an
    /// unblocked failure stays reviewable and can be marked as valid by hand.
    public func finishedRow(probeID: String, reply: String, errorReason: String) -> ProbeErrorRow? {
        switch self {
        case .stopRun, .busy:
            return nil
        case .promptBlocked:
            return ProbeErrorRow(state: .failed, reason: errorReason, notes: [], blockedBeforeReply: true)
        case .promptPartial:
            let verdict = CapabilityGrader.grade(probeID, reply: reply)
            guard verdict.outcome == .failed else {
                return ProbeErrorRow(state: .failed, reason: errorReason, notes: [], blockedBeforeReply: false)
            }
            return ProbeErrorRow(state: .failed, reason: verdict.reason, notes: verdict.notes + [errorReason],
                                 blockedBeforeReply: false)
        case .unclassified:
            return ProbeErrorRow(state: .error, reason: errorReason, notes: [], blockedBeforeReply: false)
        }
    }
}

/// The finished row for a probe-level error.
public struct ProbeErrorRow: Equatable, Sendable {
    public let state: ProbeRunState
    public let reason: String
    public let notes: [String]
    public let blockedBeforeReply: Bool
}

/// The same unclassified error on `limit` probes in a row is taken as the engine's, not the probes'.
public struct RepeatedProbeErrors: Sendable {
    public static let limit = 3

    private var lastDescription: String?
    private var count = 0

    public init() {}

    /// Records one finished probe: the unclassified error's description, or nil for any other outcome, which resets
    /// the count. True when the run should stop.
    public mutating func record(_ description: String?) -> Bool {
        guard let description else {
            lastDescription = nil
            count = 0
            return false
        }
        count = description == lastDescription ? count + 1 : 1
        lastDescription = description
        return count >= Self.limit
    }
}
