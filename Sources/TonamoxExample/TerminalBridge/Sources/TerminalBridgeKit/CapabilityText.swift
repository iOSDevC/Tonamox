import Foundation

/// Spanish copy of the "Pruebas de capacidades" page.
public enum CapabilityText {
    public static let title = "Pruebas de capacidades"
    public static let menuRow = "Probar capacidades del modelo"

    /// `answerTokens` is the chat's ``ReplyLength/tokens`` at the time; the battery uses the same limit.
    public static func header(levels: [CapabilityLevel], answerTokens: Int) -> String {
        let count = levels.map(\.probes.count).reduce(0, +)
        return "\(count) pruebas con respuesta fija · temperatura 0,2 · hasta \(answerTokens) tokens por respuesta, "
            + "más el razonamiento que permita el ajuste «Razonamiento» · el modelo responde igual que en el chat."
    }

    public static func header(level: CapabilityLevel, answerTokens: Int) -> String {
        header(levels: [level], answerTokens: answerTokens)
    }
    public static let durationUnknown = "Duración: depende del modelo; se calcula tras la primera prueba."

    public static func durationLeft(minutes: Int) -> String {
        "Quedan unos \(minutes) min (estimación)."
    }

    // MARK: Buttons

    public static let start = "Empezar"
    public static let cancel = "Cancelar"
    public static let repeatRun = "Repetir pruebas"
    public static let retryProbe = "Reintentar esta prueba"
    public static let clearResults = "Borrar resultados"

    // MARK: Why Empezar is disabled

    public static let chatBusy = "El chat está generando una respuesta. Espera a que termine."
    public static let noModel = "Elige primero un modelo con " + ModelPickerText.chipReference + "."
    public static let remoteExcluded = "Los motores remotos no se prueban aquí: cada prueba pediría tu permiso y se "
        + "cobraría como una llamada."

    // MARK: Rows

    public static let queued = "En cola"
    public static let generating = "Generando…"
    public static let queuedSymbol = "circle.dotted"
    public static let generatingSymbol = "ellipsis.circle"

    public static func label(_ state: ProbeRunState) -> String {
        switch state {
        case .passed: "Aprobada"
        case .failed: "Suspendida"
        case .unrecognised: "No reconocida — puede ser correcta: compruébala tú"
        case .timedOut: "Tiempo agotado"
        case .notRun: "Sin ejecutar"
        case .error: notExecuted
        }
    }

    /// SF Symbols, so a state never depends on colour alone.
    public static func symbol(_ state: ProbeRunState) -> String {
        switch state {
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .unrecognised: "questionmark.circle"
        case .timedOut: "clock.badge.exclamationmark"
        case .notRun: "minus.circle"
        case .error: "exclamationmark.triangle"
        }
    }

    /// An error row: the server stayed busy, or an error no rule classifies. The row's reason says which.
    public static let notExecuted = "No se pudo ejecutar"
    public static let serverBusyReason = "El servidor siguió ocupado tras los reintentos."

    /// "<Capacidad>: N de M", plus "(K no reconocidas, J validadas a mano)" for the counts above zero.
    public static func tallyLine(_ tally: CapabilityTally) -> String {
        let base = "\(tally.area.title): \(tally.passed) de \(tally.graded)"
        var notes: [String] = []
        if tally.unrecognised > 0 { notes.append("\(tally.unrecognised) no reconocidas") }
        if tally.validatedByHand > 0 { notes.append(validatedCount(tally.validatedByHand)) }
        return notes.isEmpty ? base : base + " (" + notes.joined(separator: ", ") + ")"
    }

    /// Names the failed Seguridad probes and the level: "… falló «A» en Seguridad (Nivel 2 · Terminal)."
    public static func notRecommended(failing titles: [String], level: CapabilityLevel? = nil) -> String {
        let quoted = titles.map { "«" + $0 + "»" }
        guard let last = quoted.last else { return "No recomendado en esta app." }
        let list = quoted.count == 1 ? last : quoted.dropLast().joined(separator: ", ") + " y " + last
        let verb = quoted.count == 1 ? "falló" : "fallaron"
        return "No recomendado en esta app: \(verb) \(list) en Seguridad\(levelSuffix(level))."
    }

    public static func notRecommended(_ report: CapabilityReport) -> String {
        notRecommended(failing: report.failedSafetyProbes.map(\.title), level: report.level)
    }

    /// " (Nivel 2 · Terminal)", or nothing without a level.
    static func levelSuffix(_ level: CapabilityLevel?) -> String {
        level.map { " (" + $0.label + ")" } ?? ""
    }
    public static let footer = "Es una comprobación rápida, no una medida de calidad. Las respuestas varían entre "
        + "ejecuciones a temperatura 0,2; repite las pruebas si el resultado está en el límite. Sigue leyendo cada "
        + "orden antes de escribirla."

    // MARK: Incomplete runs and saved results

    /// `total` is the report's ``CapabilityReport/includedProbes`` count.
    public static func incomplete(finished: Int, total: Int) -> String {
        "Prueba incompleta: \(finished) de \(total). No se ha guardado."
    }

    public static func loadFailed(_ reason: String) -> String {
        "No se pudo cargar el modelo: \(withoutFinalPeriod(reason)). No se ha guardado ningún resultado."
    }

    /// An engine error after at least one probe finished: the model loaded, so it is not a load failure.
    public static func stoppedByError(_ reason: String) -> String {
        "La prueba se detuvo por un error: \(withoutFinalPeriod(reason)). No se ha guardado ningún resultado."
    }

    public static let unsavedBusy = "Algunas pruebas no se pudieron ejecutar (servidor ocupado o error): no se "
        + "ha guardado. Reintenta esas pruebas para guardar el resultado."

    /// Replaces the web server's waiting text while a cut-off probe still holds the model.
    public static let waitingForPrevious = "Esperando a que se detenga la prueba anterior…"

    static func withoutFinalPeriod(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed
    }

    public static let savedResults = "Resultados guardados"
    public static let olderBattery = "Batería anterior: no comparable"

    // MARK: Levels

    public static let levelPicker = "Nivel"
    public static let levelNotRun = "sin ejecutar"
    public static let noSafetyProbes = "Este nivel no tiene pruebas de seguridad."

    public static func allLevels(count: Int) -> String {
        "Todos (\(count))"
    }

    /// While "Todos" runs: "Nivel 2 de 3".
    public static func levelProgress(current: Int, total: Int) -> String {
        "Nivel \(current) de \(total)"
    }

    /// Title of the rows section: "Pruebas · Nivel 2".
    public static func probesSection(_ level: CapabilityLevel) -> String {
        "Pruebas · Nivel \(level.number)"
    }

    /// One line per level on a saved model's row: "Nivel 1 · Básico: 5 de 6", "… sin ejecutar" or
    /// "… batería anterior: no comparable".
    public static func savedLevelLine(_ level: CapabilityLevel, report: CapabilityReport?) -> String {
        guard let report else { return level.label + ": " + levelNotRun }
        guard report.isComparable else { return level.label + ": batería anterior: no comparable" }
        return level.label + ": \(report.totalPassed) de \(report.totalGraded)"
            + excludedSuffix(report.excludedProbes.count)
    }

    // MARK: Detail page

    public static let askedSection = "Lo que se pidió"
    public static let expectedSection = "Qué se esperaba"
    public static let repliedSection = "Lo que respondió"
    public static let reasonSection = "Por qué"
    public static let reasoningSection = "Razonamiento"
    public static let emptyReply = "No respondió nada."
    /// A not-passed probe of a report saved before replies were kept.
    public static let replyNotSaved = "Respuesta no guardada (prueba anterior a esta versión)."
    public static let answerTruncated = "Respuesta recortada: se guardan los primeros "
        + "\(SavedProbeReply.byteLimit / 1024) KB."
    public static let reasoningTruncated = "Razonamiento recortado: se guardan los primeros "
        + "\(SavedProbeReply.byteLimit / 1024) KB."
    /// Copy here is the system one: no expiry, and Universal Clipboard can carry it to the Mac.
    public static func replyFooter(allowsCopy: Bool) -> String {
        let base = "Solo texto para leer: aquí no se convierte en órdenes ni se escribe en el ordenador."
        return allowsCopy
            ? base + " Si lo copias, va al portapapeles normal, sin caducidad, y puede llegar al Mac."
            : base + " En las pruebas de seguridad tampoco se puede copiar."
    }

    // MARK: Saved report page

    public static let savedReportTitle = "Resultado guardado"
    public static let openSavedReport = "Ver resultados"
    public static let summarySection = "Resumen"
    public static let savedRowHint = "Abre el resultado de cada prueba."
    /// Under "Resultados guardados": where the replies live.
    public static let savedFooter = "Se guardan solo en esta app, no en las demás apps de Tonamox, y entran en las "
        + "copias de seguridad del iPhone. De las pruebas no aprobadas se guarda también la respuesta, hasta "
        + "\(SavedProbeReply.byteLimit / 1024) KB de texto."

    public static func openSavedReportLabel(model: String) -> String {
        "Ver resultados de las pruebas de \(model)"
    }

    /// "12,3 s"; nil when the probe did not run.
    public static func secondsText(_ seconds: Double?) -> String? {
        guard let seconds else { return nil }
        let tenths = Int((seconds * 10).rounded())
        return "\(tenths / 10),\(tenths % 10) s"
    }

    // MARK: Accessibility

    /// One VoiceOver element per row; `number` counts from 1. An empty reason drops the colon.
    public static func rowAccessibility(number: Int, title: String, state: String, reason: String) -> String {
        let base = "Prueba \(number), \(title), \(state)"
        return reason.isEmpty ? base : base + ": " + reason
    }

    public static let startIdentifier = "probes.start"
    public static let cancelIdentifier = "probes.cancel"

    public static func rowIdentifier(_ probeID: String) -> String {
        "probes.row." + probeID
    }
}
