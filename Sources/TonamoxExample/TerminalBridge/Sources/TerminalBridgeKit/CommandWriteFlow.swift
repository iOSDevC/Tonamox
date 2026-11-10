import Foundation

/// Where an "Escribir" line stands. `failed` keeps the write ID so a retry cannot type the line twice.
public indirect enum CommandSendState: Equatable, Sendable {
    case idle
    case confirming(writeID: UUID, returningTo: CommandSendState)
    case sending(writeID: UUID)
    case sent(writeID: UUID, ack: WriteAck, target: String)
    case failed(writeID: UUID, reason: String, helperWarnings: [String])
}

/// What a tap on a line's button leads to.
public enum CommandWriteStep: Equatable, Sendable {
    case write(writeID: UUID, acknowledged: [String])
    case confirm(writeID: UUID)
    case nothing
}

/// An open confirmation dialog: the write it would send and the warning ids it acknowledges.
public struct CommandConfirmation: Equatable, Sendable {
    public let writeID: UUID
    /// True when the line was already typed and is about to be typed again.
    public let isRewrite: Bool
    public let acknowledged: [String]

    public init(writeID: UUID, isRewrite: Bool, acknowledged: [String]) {
        self.writeID = writeID
        self.isRewrite = isRewrite
        self.acknowledged = acknowledged
    }
}

/// The phone's write decisions as pure functions, so the retry and confirmation rules are testable.
public enum CommandWriteFlow {
    public static let disconnectedReason = "Sin conexión con la Mac."

    /// Local warning ids first, then the extra ones the helper asked for.
    public static func acknowledgements(local: [String], helper: [String]) -> [String] {
        local + helper.filter { !local.contains($0) }
    }

    /// A retry reuses the failed write's ID, so a first attempt that did get typed comes back as
    /// `alreadyTyped`; typing a sent line again asks first and uses a new ID.
    public static func step(
        for state: CommandSendState,
        localWarnings: [String],
        newID: () -> UUID
    ) -> CommandWriteStep {
        switch state {
        case .idle:
            return start(writeID: newID(), localWarnings: localWarnings, helperWarnings: [])
        case .failed(let writeID, _, let helperWarnings):
            return start(writeID: writeID, localWarnings: localWarnings, helperWarnings: helperWarnings)
        case .sent:
            return .confirm(writeID: newID())
        case .confirming, .sending:
            return .nothing
        }
    }

    public static func beginConfirmation(_ state: CommandSendState, writeID: UUID) -> CommandSendState {
        .confirming(writeID: writeID, returningTo: state)
    }

    /// Cancelling restores whatever the line showed before the dialog opened.
    public static func cancelConfirmation(_ state: CommandSendState) -> CommandSendState {
        guard case .confirming(_, let previous) = state else { return state }
        return previous
    }

    public static func confirmation(for state: CommandSendState, localWarnings: [String]) -> CommandConfirmation? {
        guard case .confirming(let writeID, let previous) = state else { return nil }
        var helperWarnings: [String] = []
        var isRewrite = false
        switch previous {
        case .failed(_, _, let warnings):
            helperWarnings = warnings
        case .sent:
            isRewrite = true
        case .idle, .confirming, .sending:
            break
        }
        return CommandConfirmation(
            writeID: writeID,
            isRewrite: isRewrite,
            acknowledged: acknowledgements(local: localWarnings, helper: helperWarnings)
        )
    }

    /// `isTypeable` is false for lines the policy rejects, multi-line commands and possibly cut lines.
    public static func canTap(_ state: CommandSendState, isTypeable: Bool, isConnected: Bool) -> Bool {
        guard isTypeable else { return false }
        switch state {
        case .idle, .failed, .sent:
            return isConnected
        case .confirming, .sending:
            return false
        }
    }

    /// The visible reason a typeable line's button is off; nil when it is on or busy.
    public static func blockedReason(_ state: CommandSendState, isTypeable: Bool, isConnected: Bool) -> String? {
        guard isTypeable else { return nil }
        switch state {
        case .idle, .failed, .sent:
            return isConnected ? nil : disconnectedReason
        case .confirming, .sending:
            return nil
        }
    }

    private static func start(writeID: UUID, localWarnings: [String], helperWarnings: [String]) -> CommandWriteStep {
        let warnings = acknowledgements(local: localWarnings, helper: helperWarnings)
        return warnings.isEmpty ? .write(writeID: writeID, acknowledged: []) : .confirm(writeID: writeID)
    }
}
