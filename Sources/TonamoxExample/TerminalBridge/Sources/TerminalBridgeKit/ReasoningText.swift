import Foundation

/// Spanish text for the collapsible reasoning block above a reply.
public enum ReasoningText {
    /// Header while the model is still reasoning.
    public static let live = "Pensando…"

    /// Shown instead of an answer when the token limit ended the turn inside the reasoning.
    public static let unfinishedNote = "El modelo no terminó de razonar dentro del límite de tokens, así que no hay "
        + "respuesta."

    /// Header when a stop or an error ended the turn while the model was still reasoning.
    public static let interrupted = "Razonamiento interrumpido"

    public static let expandHint = "Muestra el razonamiento del modelo."
    public static let collapseHint = "Oculta el razonamiento del modelo."
    public static let expandedValue = "Desplegado"
    public static let collapsedValue = "Plegado"

    /// Header once the reasoning ended: whole seconds, rounded, with the right plural; under one second, no number.
    public static func header(thoughtFor duration: Duration) -> String {
        let parts = duration.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        guard seconds >= 1 else { return "Pensó un momento" }
        let whole = Int(seconds.rounded())
        return whole == 1 ? "Pensó durante 1 segundo" : "Pensó durante \(whole) segundos"
    }

    /// Header when the reasoning budget closed the block for the model, as ``header(thoughtFor:)`` otherwise.
    public static func header(cutAfter duration: Duration) -> String {
        let parts = duration.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        guard seconds >= 1 else { return "Razonamiento recortado" }
        let whole = Int(seconds.rounded())
        return whole == 1 ? "Razonamiento recortado tras 1 segundo" : "Razonamiento recortado tras \(whole) segundos"
    }

    /// The reasoning as the block shows it: without the blank lines models put around it.
    public static func shown(_ reasoning: String) -> String {
        reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
