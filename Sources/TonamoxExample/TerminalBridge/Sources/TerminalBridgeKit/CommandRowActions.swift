import Foundation

/// A channel a command row's send button types through.
public enum SendChannel: String, CaseIterable, Hashable, Sendable {
    /// The phone acting as a Bluetooth keyboard.
    case keyboard
    /// The Mac helper over USB.
    case helper

    /// Distinct per channel so the owner sees where the line goes before tapping.
    public var symbol: String {
        switch self {
        case .keyboard: "keyboard"
        case .helper: "cable.connector"
        }
    }

    public func accessibilityLabel(_ phase: CommandIconPhase) -> String {
        let channel = switch self {
        case .keyboard: "con el teclado Bluetooth"
        case .helper: "por USB"
        }
        return switch phase {
        case .ready: "Escribir " + channel
        case .inFlight: (self == .keyboard ? "Tecleando " : "Enviando ") + channel
        case .done: "Escribir de nuevo " + channel
        case .failed: "Reintentar " + channel
        }
    }
}

/// What a row's icon button shows for its channel's state.
public enum CommandIconPhase: Hashable, Sendable {
    case ready
    case inFlight
    case done
    case failed

    public init(helper: CommandSendState) {
        switch helper {
        case .idle, .confirming: self = .ready
        case .sending: self = .inFlight
        case .sent: self = .done
        case .failed: self = .failed
        }
    }

    public init(keyboard: KeyboardSendState) {
        switch keyboard {
        case .idle, .confirming: self = .ready
        case .typing: self = .inFlight
        case .typed: self = .done
        case .failed: self = .failed
        }
    }

    public init(clipboard: ClipboardCopyState) {
        switch clipboard {
        case .idle, .confirming: self = .ready
        case .copied: self = .done
        case .failed: self = .failed
        }
    }
}

/// Which send buttons a row shows. Every available channel gets its own button, never a silent choice.
public struct SendChannelOffer: Hashable, Sendable {
    public let channels: [SendChannel]
    /// Set when no channel can send: `channels` is then `[.helper]`, shown disabled with this text.
    public let unavailableReason: String?

    public static let noChannelReason = CommandWriteFlow.disconnectedReason + " "
        + (KeyboardReadiness.off.message ?? "")

    /// A channel busy with this line stays offered after it goes away, so its progress is never hidden.
    public static func make(
        helperConnected: Bool,
        helperInFlight: Bool,
        keyboardActive: Bool,
        keyboardInFlight: Bool
    ) -> SendChannelOffer {
        var channels: [SendChannel] = []
        if keyboardActive || keyboardInFlight { channels.append(.keyboard) }
        if helperConnected || helperInFlight { channels.append(.helper) }
        guard channels.isEmpty else { return SendChannelOffer(channels: channels, unavailableReason: nil) }
        return SendChannelOffer(channels: [.helper], unavailableReason: noChannelReason)
    }
}

/// Labels, symbols and success markers of a command row's icon cluster.
public enum CommandRowActions {
    public static let copySymbol = "doc.on.doc"
    public static let copyLabel = "Copiar para pegar"
    public static let copiedAnnouncement = "Copiado"
    public static let moreSymbol = "ellipsis.circle"
    public static let moreLabel = "Más opciones"
    public static let successSymbol = "checkmark"

    public static func isInFlight(helper: CommandSendState) -> Bool {
        switch helper {
        case .confirming, .sending: true
        case .idle, .sent, .failed: false
        }
    }

    public static func isInFlight(keyboard: KeyboardSendState) -> Bool {
        switch keyboard {
        case .confirming, .typing: true
        case .idle, .typed, .failed: false
        }
    }

    /// Only a verified fresh write earns the checkmark: an unverified or repeated one shows its warning instead.
    public static func successID(helper: CommandSendState) -> UUID? {
        guard case .sent(let writeID, let ack, _) = helper, ack.result == .typed, ack.verified else { return nil }
        return writeID
    }

    public static func successID(keyboard: KeyboardSendState) -> UUID? {
        guard case .typed(let jobID, _, _, let unverified) = keyboard, unverified.isEmpty else { return nil }
        return jobID
    }

    /// The keyboard status (and its dialog) stays visible after the keyboard stops while the line still has a
    /// pending dialog, a typing job or a failure telling the owner to clear half-typed text.
    public static func showsKeyboardStatus(keyboardActive: Bool, keyboard: KeyboardSendState) -> Bool {
        if keyboardActive || isInFlight(keyboard: keyboard) { return true }
        if case .failed = keyboard { return true }
        return false
    }

    public static func successID(clipboard: ClipboardCopyState) -> UUID? {
        guard case .copied(let copyID, _, _) = clipboard else { return nil }
        return copyID
    }
}
