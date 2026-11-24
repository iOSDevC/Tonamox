import Foundation

/// How a typing job ended. Everything except `completed` drops the rest of the plan for good.
public enum KeyboardTransmissionEnd: Hashable, Sendable {
    case completed
    case cancelled
    case hostDisconnected
    case bluetoothOff
    case appInactive
    case keyHeldTooLong
    case capsLockTurnedOn
    case unsafeReport

    /// Spanish; partial endings say text may be left half typed.
    public var message: String {
        switch self {
        case .completed:
            return "Tecleado. Compruébalo en el ordenador antes de pulsar Enter."
        case .keyHeldTooLong:
            return "Una tecla se quedó pulsada demasiado tiempo y el ordenador pudo repetirla: "
                + "puede haber caracteres repetidos o texto a medias. Bórralo antes de seguir."
        default:
            return cause + " " + Self.partialNotice
        }
    }

    /// Like `message`, without the half-typed warning when nothing reached the host.
    public func message(afterSending sentReports: Int) -> String {
        guard self != .completed, sentReports == 0 else { return message }
        return cause + " " + KeyboardTypingRefusal.nothingSent
    }

    static let partialNotice = "Puede haber texto a medias en el ordenador. Bórralo antes de seguir."

    private var cause: String {
        switch self {
        case .completed: "Tecleado."
        case .cancelled: "Se canceló el tecleo."
        case .hostDisconnected: "El ordenador se desconectó mientras se tecleaba."
        case .bluetoothOff: "Bluetooth dejó de estar disponible mientras se tecleaba."
        case .appInactive: "La app dejó de estar activa mientras se tecleaba."
        case .keyHeldTooLong: "Una tecla se quedó pulsada demasiado tiempo."
        case .capsLockTurnedOn: "Se activó Bloq Mayús en el ordenador mientras se tecleaba."
        case .unsafeReport: "Se detuvo antes de enviar una pulsación no permitida."
        }
    }
}

/// Drives one plan report by report. Times are monotonic offsets supplied by the caller (testable).
public struct KeyboardTransmission: Sendable {
    private let reports: [HIDKeyboardReport]
    private let permittedModifiers: HIDModifierSet
    private var nextIndex = 0
    /// When the last accepted report pressed a key whose release has not been accepted yet.
    private var keyDownSince: Duration?

    public private(set) var sentReports = 0
    /// Nil while running; once set, `next()` is always nil.
    public private(set) var end: KeyboardTransmissionEnd?

    public init(plan: KeyboardTypingPlan) {
        reports = plan.reports
        permittedModifiers = plan.permittedModifiers
        if plan.reports.isEmpty { end = .completed }
    }

    public var totalReports: Int {
        reports.count
    }

    /// The next report to send, or nil when finished or ended. Repeats the same report until `didSend`.
    public mutating func next() -> HIDKeyboardReport? {
        guard end == nil, nextIndex < reports.count else { return nil }
        let candidate = reports[nextIndex]
        guard candidate.isPermitted(within: permittedModifiers) else {
            end = .unsafeReport
            return nil
        }
        return candidate
    }

    /// The report returned by `next()` was accepted by updateValue at `now`.
    public mutating func didSend(at now: Duration) {
        guard end == nil, nextIndex < reports.count else { return }
        let sent = reports[nextIndex]
        nextIndex += 1
        sentReports += 1
        if sent.keyUsage != 0 {
            keyDownSince = now
        } else if let since = keyDownSince {
            keyDownSince = nil
            // The release went out, but late enough that the host may already have repeated the key.
            if now - since > HIDKeyboardDescriptor.maxKeyHold {
                end = .keyHeldTooLong
                return
            }
        }
        if nextIndex == reports.count { end = .completed }
    }

    /// Called on every pump tick, including while the queue is full; ends with `.keyHeldTooLong` when a key-down
    /// has waited for its release longer than `HIDKeyboardDescriptor.maxKeyHold`.
    public mutating func check(at now: Duration) {
        guard end == nil, let since = keyDownSince, now - since > HIDKeyboardDescriptor.maxKeyHold else { return }
        end = .keyHeldTooLong
    }

    /// Host wrote LEDs; Caps Lock on ends the job with `.capsLockTurnedOn`.
    public mutating func hostLEDsChanged(_ leds: HIDKeyboardLEDs) {
        guard end == nil, leds.contains(.capsLock) else { return }
        end = .capsLockTurnedOn
    }

    /// Cancel, unsubscribe, power loss, background. Drops the rest; never resumes. `.completed` is not an abort
    /// reason and is recorded as `.cancelled`.
    public mutating func abort(_ reason: KeyboardTransmissionEnd) {
        guard end == nil else { return }
        end = reason == .completed ? .cancelled : reason
    }

    /// The report to attempt after an abort with sentReports > 0 (always `.released`), else nil.
    public var cleanupReport: HIDKeyboardReport? {
        guard let end, end != .completed, sentReports > 0 else { return nil }
        return .released
    }
}
