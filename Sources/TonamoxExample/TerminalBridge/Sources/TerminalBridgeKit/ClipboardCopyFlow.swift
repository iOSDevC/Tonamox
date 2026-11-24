import Foundation

/// Where a "Copiar para pegar" line stands.
public indirect enum ClipboardCopyState: Hashable, Sendable {
    case idle
    case confirming(copyID: UUID, returningTo: ClipboardCopyState)
    case copied(copyID: UUID, text: String, expiresAt: Date)
    case failed(copyID: UUID, reason: String)
}

/// What the clipboard flow needs to know about the same line's helper and keyboard paths (read-only).
public enum LineChannelActivity: Hashable, Sendable {
    case none
    case inProgress
    case typed
    /// The write failed after it may have typed something.
    case mayHaveTyped

    public init(helper: CommandSendState) {
        switch helper {
        case .idle: self = .none
        case .confirming, .sending: self = .inProgress
        case .sent: self = .typed
        case .failed: self = .mayHaveTyped
        }
    }

    /// An open keyboard dialog counts as in progress, as the helper's does.
    public init(keyboard: KeyboardSendState) {
        switch keyboard {
        case .idle: self = .none
        case .confirming, .typing: self = .inProgress
        case .typed: self = .typed
        case .failed(_, _, let sentReports): self = sentReports > 0 ? .mayHaveTyped : .none
        }
    }
}

/// An open clipboard confirmation dialog.
public struct ClipboardConfirmation: Hashable, Sendable {
    public enum Prompt: Hashable, Sendable {
        case warnings
        case helperTyped
        case helperMayHaveTyped
        case keyboardTyped
        case keyboardMayHaveTyped
    }

    public let copyID: UUID
    /// Every reason that applies, shown together in one dialog.
    public let causes: [Prompt]
    /// RiskyRule wire ids.
    public let acknowledged: [String]

    public init(copyID: UUID, causes: [Prompt], acknowledged: [String]) {
        self.copyID = copyID
        self.causes = causes
        self.acknowledged = acknowledged
    }
}

/// The checked text and its pasteboard expiry; the app writes exactly `text`.
public struct ClipboardCopyPlan: Hashable, Sendable {
    /// Long enough to reach the Mac and paste, short enough that a stale command is unlikely to be pasted later.
    public static let lifetime: TimeInterval = 120

    public let text: String
    public let expiresAt: Date

    /// Policy and unacknowledged RiskyRules on `line.text`, plus the original's rules through `line.localWarnings`.
    /// Refuses while the helper or the keyboard is busy with the same line.
    public static func make(
        line: OutgoingLine,
        acknowledged: [String],
        helper: LineChannelActivity,
        keyboard: LineChannelActivity,
        now: Date
    ) -> Result<ClipboardCopyPlan, ClipboardCopyRefusal> {
        if helper == .inProgress || keyboard == .inProgress { return .failure(.channelBusy) }
        let violations = CommandTextPolicy.validate(line.text)
        guard violations.isEmpty else { return .failure(.policy(violations)) }
        let found = Set(RiskyCommandRules.evaluate(line.text).map(\.id) + line.localWarnings)
        let accepted = Set(acknowledged)
        let missing = RiskyRule.allCases.filter { found.contains($0.id) && !accepted.contains($0.id) }
        guard missing.isEmpty else { return .failure(.unacknowledgedWarnings(missing)) }
        return .success(ClipboardCopyPlan(text: line.text, expiresAt: now.addingTimeInterval(lifetime)))
    }
}

public enum ClipboardCopyRefusal: Error, Hashable, Sendable {
    case policy([CommandTextViolation])
    case unacknowledgedWarnings([RiskyRule])
    /// The helper is sending or the keyboard is typing this line.
    case channelBusy

    static let nothingCopied = " No se ha copiado nada."

    /// Spanish, always ends with "No se ha copiado nada."
    public var message: String {
        switch self {
        case .policy(let violations):
            "La línea no cumple las reglas de texto: " + violations.map(\.message).joined(separator: "; ") + "."
                + Self.nothingCopied
        case .unacknowledgedWarnings(let rules):
            "Faltan por aceptar avisos: " + rules.map(\.title).joined(separator: ", ") + "." + Self.nothingCopied
        case .channelBusy:
            ClipboardCopyFlow.otherChannelBusyReason + Self.nothingCopied
        }
    }
}

/// The clipboard's copy decisions as pure functions, reusing `CommandWriteStep` and the acknowledgement rule.
public enum ClipboardCopyFlow {
    public static let otherChannelBusyReason = "Esta línea se está escribiendo por otro canal; espera a que termine."

    /// Asks on: unacknowledged local warnings (every copy, a copy re-arms the line), the helper or the keyboard
    /// typed or may have typed it. Copying again after a copy does not ask by itself. Busy channel: nothing.
    public static func step(
        for state: ClipboardCopyState,
        helper: LineChannelActivity,
        keyboard: LineChannelActivity,
        localWarnings: [String],
        newID: () -> UUID
    ) -> CommandWriteStep {
        guard helper != .inProgress, keyboard != .inProgress else { return .nothing }
        switch state {
        case .confirming:
            return .nothing
        case .idle, .copied, .failed:
            let copyID = newID()
            let causes = causes(helper: helper, keyboard: keyboard, localWarnings: localWarnings)
            return causes.isEmpty ? .write(writeID: copyID, acknowledged: []) : .confirm(writeID: copyID)
        }
    }

    public static func beginConfirmation(_ state: ClipboardCopyState, copyID: UUID) -> ClipboardCopyState {
        .confirming(copyID: copyID, returningTo: state)
    }

    /// Cancelling restores whatever the line showed before the dialog opened.
    public static func cancelConfirmation(_ state: ClipboardCopyState) -> ClipboardCopyState {
        guard case .confirming(_, let previous) = state else { return state }
        return previous
    }

    public static func confirmation(
        for state: ClipboardCopyState,
        helper: LineChannelActivity,
        keyboard: LineChannelActivity,
        localWarnings: [String]
    ) -> ClipboardConfirmation? {
        guard case .confirming(let copyID, _) = state else { return nil }
        return ClipboardConfirmation(
            copyID: copyID,
            causes: causes(helper: helper, keyboard: keyboard, localWarnings: localWarnings),
            acknowledged: CommandWriteFlow.acknowledgements(local: localWarnings, helper: [])
        )
    }

    /// `isTypeable` is false for lines the policy rejects, multi-line commands and possibly cut lines.
    public static func canTap(
        _ state: ClipboardCopyState,
        helper: LineChannelActivity,
        keyboard: LineChannelActivity,
        isTypeable: Bool
    ) -> Bool {
        guard isTypeable, !isConfirming(state) else { return false }
        return helper != .inProgress && keyboard != .inProgress
    }

    /// The visible reason a typeable line's copy is off; nil when it is on or its dialog is open.
    public static func blockedReason(
        _ state: ClipboardCopyState,
        helper: LineChannelActivity,
        keyboard: LineChannelActivity,
        isTypeable: Bool
    ) -> String? {
        guard isTypeable, !isConfirming(state) else { return nil }
        return helper == .inProgress || keyboard == .inProgress ? otherChannelBusyReason : nil
    }

    /// `.copied` whose expiresAt has passed reads as idle in the UI ("Caducada").
    public static func isExpired(_ state: ClipboardCopyState, now: Date) -> Bool {
        guard case .copied(_, _, let expiresAt) = state else { return false }
        return now >= expiresAt
    }

    private static func isConfirming(_ state: ClipboardCopyState) -> Bool {
        if case .confirming = state { return true }
        return false
    }

    private static func causes(
        helper: LineChannelActivity,
        keyboard: LineChannelActivity,
        localWarnings: [String]
    ) -> [ClipboardConfirmation.Prompt] {
        var causes: [ClipboardConfirmation.Prompt] = []
        if !localWarnings.isEmpty { causes.append(.warnings) }
        switch helper {
        case .typed: causes.append(.helperTyped)
        case .mayHaveTyped: causes.append(.helperMayHaveTyped)
        case .none, .inProgress: break
        }
        switch keyboard {
        case .typed: causes.append(.keyboardTyped)
        case .mayHaveTyped: causes.append(.keyboardMayHaveTyped)
        case .none, .inProgress: break
        }
        return causes
    }
}
