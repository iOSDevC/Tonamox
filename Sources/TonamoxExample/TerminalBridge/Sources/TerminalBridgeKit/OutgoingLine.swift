import Foundation

/// The only text any channel (helper, Bluetooth, clipboard) may send for a line: the original, its capture
/// wrapper or the original with the network suffix, after the safeguards ran on both.
public struct OutgoingLine: Hashable, Sendable {
    public let candidateID: UUID
    /// The original, `CaptureLines.wrapped` or `NetworkOutputLine.line`.
    public let text: String
    public let capture: CaptureLines?
    public private(set) var network: NetworkOutputLine? = nil
    /// RiskyRule ids of the original, then any extra the final line adds, without duplicates.
    public let localWarnings: [String]

    public static func make(
        candidate: CommandCandidate,
        isPossiblyTruncated: Bool,
        capture: CaptureLines?,
        network: NetworkOutputLine? = nil
    ) -> Result<OutgoingLine, OutgoingLineRefusal> {
        if let reason = KeyboardWriteFlow.lineRefusal(candidate, isPossiblyTruncated: isPossiblyTruncated) {
            return .failure(.line(reason))
        }
        if capture != nil, network != nil { return .failure(.captureAndNetwork) }
        if let capture, capture.original != candidate.text { return .failure(.captureMismatch) }
        if let network, network.original != candidate.text { return .failure(.networkMismatch) }
        let originalViolations = CommandTextPolicy.validate(candidate.text)
        guard originalViolations.isEmpty else { return .failure(.policy(originalViolations)) }
        let text = capture?.wrapped ?? network?.line ?? candidate.text
        let finalViolations = CommandTextPolicy.validate(text)
        guard finalViolations.isEmpty else { return .failure(.policy(finalViolations)) }
        let original = RiskyCommandRules.evaluate(candidate.text).map(\.id)
        let final = RiskyCommandRules.evaluate(text).map(\.id)
        return .success(OutgoingLine(
            candidateID: candidate.id,
            text: text,
            capture: capture,
            network: network,
            localWarnings: original + final.filter { !original.contains($0) }
        ))
    }
}

public enum OutgoingLineRefusal: Error, Hashable, Sendable {
    /// `KeyboardWriteFlow.lineRefusal` text: multi-line command or possibly cut line.
    case line(String)
    /// The original or the final line fails `CommandTextPolicy`.
    case policy([CommandTextViolation])
    /// The capture was built for another text.
    case captureMismatch
    /// The network suffix was built for another text.
    case networkMismatch
    /// Capture and network suffix are exclusive: both put the command in a pipeline.
    case captureAndNetwork

    /// Spanish; always says nothing was sent.
    public var message: String {
        switch self {
        case .line(let reason):
            reason
        case .policy(let violations):
            "La línea no cumple las reglas de texto: " + violations.map(\.message).joined(separator: "; ")
                + ". No se ha enviado nada."
        case .captureMismatch:
            "La captura no corresponde a esta línea; vuelve a activarla. No se ha enviado nada."
        case .networkMismatch:
            "El envío por red no corresponde a esta línea; vuelve a activarlo. No se ha enviado nada."
        case .captureAndNetwork:
            "La captura y el envío por red no se combinan: desactiva uno. No se ha enviado nada."
        }
    }
}

public enum CaptureToggle {
    private static let macOnlyChannelReason = "Este canal solo llega a una Mac y la captura está preparada para "

    /// The wrapper can change only while nothing of the line may have been typed and no dialog is open, so a
    /// retry never reuses a helper write ID or a confirmation for a different text. A helper failure counts only
    /// when the app refused before sending (`helperRefusedLocally`); the keyboard and clipboard take a new ID on
    /// every tap, so a keyboard failure before the first report and a finished copy do not lock the line.
    public static func canChange(
        helper: CommandSendState,
        helperRefusedLocally: Bool,
        keyboard: KeyboardSendState,
        clipboard: ClipboardCopyState
    ) -> Bool {
        let helperFree: Bool
        switch helper {
        case .idle: helperFree = true
        case .failed: helperFree = helperRefusedLocally
        case .confirming, .sending, .sent: helperFree = false
        }
        let keyboardFree: Bool
        switch keyboard {
        case .idle: keyboardFree = true
        case .failed(_, _, let sentReports): keyboardFree = sentReports == 0
        case .confirming, .typing, .typed: keyboardFree = false
        }
        let clipboardFree: Bool
        switch clipboard {
        case .confirming: clipboardFree = false
        case .idle, .copied, .failed: clipboardFree = true
        }
        return helperFree && keyboardFree && clipboardFree
    }

    /// The helper and Universal Clipboard only reach a Mac; nil when the channel may send this capture.
    public static func channelRefusal(capture: CaptureLines?, channelReachesOnlyMac: Bool) -> String? {
        guard let capture, channelReachesOnlyMac, capture.host != .macOS else { return nil }
        return macOnlyChannelReason + capture.host.title + ". Desactiva la captura o elige macOS como sistema."
    }
}
