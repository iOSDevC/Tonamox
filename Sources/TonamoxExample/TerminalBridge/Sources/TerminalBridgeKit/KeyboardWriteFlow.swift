import Foundation

/// Whether the Bluetooth keyboard can type right now, derived from peripheral facts.
public enum KeyboardReadiness: Hashable, Sendable {
    case ready
    /// The user has not activated the keyboard.
    case off
    /// poweredOff / unauthorized / unsupported, Spanish text.
    case bluetoothUnavailable(String)
    /// Advertising, no central subscribed.
    case waitingForHost
    /// More than one central subscribed: refuse, never fan out.
    case multipleHosts(Int)
    /// The last host LED report has Caps Lock set.
    case capsLockOn
    /// Another line is being typed.
    case busy

    /// Nil for `.ready`.
    public var message: String? {
        switch self {
        case .ready: nil
        case .off: "El teclado Bluetooth no está activado."
        case .bluetoothUnavailable(let problem): problem
        case .waitingForHost: "Ningún ordenador conectado al teclado Bluetooth."
        case .multipleHosts(let count):
            "Hay más de un ordenador conectado (\(count)); deja conectado solo el que debe recibir la orden."
        case .capsLockOn: "Bloq Mayús está activado en el ordenador; desactívalo antes de teclear."
        case .busy: "Ya se está tecleando otra línea."
        }
    }

    /// Precedence: off, bluetoothUnavailable, waitingForHost, multipleHosts, capsLockOn, busy, ready.
    /// `leds == nil` (host never wrote the LED report) does not block.
    public static func evaluate(
        isActive: Bool,
        bluetoothProblem: String?,
        subscriberCount: Int,
        leds: HIDKeyboardLEDs?,
        isBusy: Bool
    ) -> KeyboardReadiness {
        guard isActive else { return .off }
        if let bluetoothProblem { return .bluetoothUnavailable(bluetoothProblem) }
        guard subscriberCount > 0 else { return .waitingForHost }
        guard subscriberCount == 1 else { return .multipleHosts(subscriberCount) }
        if leds?.contains(.capsLock) == true { return .capsLockOn }
        return isBusy ? .busy : .ready
    }
}

/// Where an "Escribir por Bluetooth" line stands.
public indirect enum KeyboardSendState: Hashable, Sendable {
    case idle
    case confirming(jobID: UUID, layoutID: HostKeyboardLayoutID, returningTo: KeyboardSendState)
    case typing(jobID: UUID, sentReports: Int, totalReports: Int)
    case typed(jobID: UUID, layoutID: HostKeyboardLayoutID, keystrokes: Int, unverified: String)
    case failed(jobID: UUID, reason: String, sentReports: Int)
}

/// An open keyboard confirmation dialog.
public struct KeyboardConfirmation: Hashable, Sendable {
    public enum Prompt: Hashable, Sendable {
        case warnings
        case retype
        case afterPartialTyping
        case helperAlreadyTyped
        case helperMayHaveTyped
        case optionChords
    }

    public let jobID: UUID
    /// Typing refuses with `.layoutChanged` if it differs.
    public let layoutID: HostKeyboardLayoutID
    /// Every reason that applies, shown together in one dialog.
    public let causes: [Prompt]
    /// RiskyRule wire ids, as for the helper.
    public let acknowledged: [String]

    public init(jobID: UUID, layoutID: HostKeyboardLayoutID, causes: [Prompt], acknowledged: [String]) {
        self.jobID = jobID
        self.layoutID = layoutID
        self.causes = causes
        self.acknowledged = acknowledged
    }
}

/// What the keyboard flow needs to know about the same line's helper path (read-only; the helper flow
/// itself is unchanged).
public enum HelperLineActivity: Hashable, Sendable {
    case none
    case inProgress
    case typed
    /// The helper write failed; a timeout or a cut connection may still have typed the line.
    case mayHaveTyped

    public init(_ state: CommandSendState) {
        switch state {
        case .idle: self = .none
        case .confirming, .sending: self = .inProgress
        case .sent: self = .typed
        case .failed: self = .mayHaveTyped
        }
    }
}

/// The keyboard's write decisions as pure functions. Reuses `CommandWriteStep` and the helper's
/// acknowledgement rule; a keyboard has no write-ID dedupe, so every retype asks.
public enum KeyboardWriteFlow {
    public static let helperBusyReason = "El ayudante de la Mac está escribiendo esta línea."
    public static let possiblyTruncatedReason = "La respuesta terminó dentro del bloque: esta línea puede estar cortada."

    /// The line-level gates the view also applies, re-checked before a plan is built. Nil when the line may be typed.
    public static func lineRefusal(_ candidate: CommandCandidate, isPossiblyTruncated: Bool) -> String? {
        if candidate.isPartOfMultilineCommand { return CommandCandidate.multilineNote + " No se ha enviado nada." }
        if isPossiblyTruncated { return possiblyTruncatedReason + " No se ha enviado nada." }
        return nil
    }

    /// Asks when any of these hold: unacknowledged local warnings; the line was typed by keyboard before or
    /// failed after a partial typing; the helper typed it or its write failed; the plan uses Option chords on macOS and
    /// the notice was not accepted since the keyboard was activated. confirming/typing, or helper
    /// inProgress: nothing.
    public static func step(
        for state: KeyboardSendState,
        helper: HelperLineActivity,
        localWarnings: [String],
        needsOptionNotice: Bool,
        newID: () -> UUID
    ) -> CommandWriteStep {
        guard helper != .inProgress else { return .nothing }
        switch state {
        case .confirming, .typing:
            return .nothing
        case .idle, .typed, .failed:
            let causes = causes(
                previous: state, helper: helper, localWarnings: localWarnings, needsOptionNotice: needsOptionNotice
            )
            let jobID = newID()
            return causes.isEmpty ? .write(writeID: jobID, acknowledged: []) : .confirm(writeID: jobID)
        }
    }

    public static func beginConfirmation(
        _ state: KeyboardSendState,
        jobID: UUID,
        layoutID: HostKeyboardLayoutID
    ) -> KeyboardSendState {
        .confirming(jobID: jobID, layoutID: layoutID, returningTo: state)
    }

    /// Cancelling restores whatever the line showed before the dialog opened.
    public static func cancelConfirmation(_ state: KeyboardSendState) -> KeyboardSendState {
        guard case .confirming(_, _, let previous) = state else { return state }
        return previous
    }

    public static func confirmation(
        for state: KeyboardSendState,
        helper: HelperLineActivity,
        localWarnings: [String],
        needsOptionNotice: Bool
    ) -> KeyboardConfirmation? {
        guard case .confirming(let jobID, let layoutID, let previous) = state else { return nil }
        return KeyboardConfirmation(
            jobID: jobID,
            layoutID: layoutID,
            causes: causes(
                previous: previous, helper: helper, localWarnings: localWarnings, needsOptionNotice: needsOptionNotice
            ),
            acknowledged: CommandWriteFlow.acknowledgements(local: localWarnings, helper: [])
        )
    }

    /// `isTypeable` is false for lines the policy rejects, multi-line commands and possibly cut lines.
    public static func canTap(
        _ state: KeyboardSendState,
        helper: HelperLineActivity,
        isTypeable: Bool,
        readiness: KeyboardReadiness
    ) -> Bool {
        guard isTypeable, helper != .inProgress, !isBusy(state) else { return false }
        return readiness == .ready
    }

    /// The visible reason a typeable line's button is off; nil when it is on or this line is busy.
    public static func blockedReason(
        _ state: KeyboardSendState,
        helper: HelperLineActivity,
        isTypeable: Bool,
        readiness: KeyboardReadiness
    ) -> String? {
        guard isTypeable, !isBusy(state) else { return nil }
        if helper == .inProgress { return helperBusyReason }
        return readiness.message
    }

    private static func isBusy(_ state: KeyboardSendState) -> Bool {
        switch state {
        case .confirming, .typing: true
        case .idle, .typed, .failed: false
        }
    }

    private static func causes(
        previous: KeyboardSendState,
        helper: HelperLineActivity,
        localWarnings: [String],
        needsOptionNotice: Bool
    ) -> [KeyboardConfirmation.Prompt] {
        var causes: [KeyboardConfirmation.Prompt] = []
        if !localWarnings.isEmpty { causes.append(.warnings) }
        switch previous {
        case .typed:
            causes.append(.retype)
        case .failed(_, _, let sentReports) where sentReports > 0:
            causes.append(.afterPartialTyping)
        case .idle, .failed, .confirming, .typing:
            break
        }
        switch helper {
        case .typed: causes.append(.helperAlreadyTyped)
        case .mayHaveTyped: causes.append(.helperMayHaveTyped)
        case .none, .inProgress: break
        }
        if needsOptionNotice { causes.append(.optionChords) }
        return causes
    }
}
