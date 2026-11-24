import Foundation

/// Copy and rules for marking a not-passed probe as valid. A mark changes one saved result only: never a grader,
/// a reason or what the chat offers.
extension CapabilityText {
    public static let validatedLabel = "Válida (marcada a mano)"
    public static let validatedSymbol = "checkmark.seal.fill"
    public static let markValid = "Marcar como válida"
    public static let undoValidation = "Deshacer"
    public static let validationSection = "Tu criterio"
    public static let copyValidatedReplies = "Copiar respuestas validadas a mano"
    public static let copiedValidatedReplies = "Copiadas al portapapeles"
    /// Under a summary with marks.
    public static let marksReplacedByRerun = "Repetir las pruebas de este modelo sustituye este resultado y sus "
        + "marcas."
    /// Under the copy button: what the copied text leaves out and where it goes.
    public static let copyValidatedFooter = "Texto plano con la prueba, lo esperado y la respuesta, para mejorar los "
        + "correctores. No se incluyen las respuestas de seguridad ni las que tienen una orden que la app marcaría "
        + "como peligrosa. Va al portapapeles normal, puede llegar al Mac y caduca a los 2 minutos."

    /// Under the mark button, on the saved page and on the run on screen.
    public static let validationFooter = "Márcala si la respuesta es correcta aunque el corrector no la reconozca, "
        + "por ejemplo por el formato. Solo cambia este resultado: el corrector, su motivo y las órdenes del chat "
        + "siguen igual. Repetir las pruebas de este modelo sustituye el resultado guardado y sus marcas."

    /// The row label: the owner's mark wins over the grader's word.
    public static func label(_ result: ProbeResult) -> String {
        result.isValidatedByHand ? validatedLabel : label(result.state)
    }

    public static func symbol(_ result: ProbeResult) -> String {
        result.isValidatedByHand ? validatedSymbol : symbol(result.state)
    }

    /// What the grader said, kept on screen under the owner's mark.
    public static func automaticState(_ state: ProbeRunState) -> String {
        "Corrector automático: " + label(state)
    }

    /// "1 validada a mano", "2 validadas a mano".
    public static func validatedCount(_ count: Int) -> String {
        count == 1 ? "1 validada a mano" : "\(count) validadas a mano"
    }

    /// Summary line of a report with marks; nil when there are none.
    public static func validatedSummary(_ report: CapabilityReport) -> String? {
        let count = report.resultsValidatedByHand.count
        return count == 0 ? nil : validatedCount(count) + "."
    }

    /// "Seguridad validada a mano: «A» (Nivel 2 · Terminal)." Stays when the marks remove "No recomendado".
    public static func safetyValidatedByHand(titles: [String], level: CapabilityLevel? = nil) -> String? {
        guard let last = titles.last.map({ "«" + $0 + "»" }) else { return nil }
        let quoted = titles.dropLast().map { "«" + $0 + "»" }
        let list = quoted.isEmpty ? last : quoted.joined(separator: ", ") + " y " + last
        return "Seguridad validada a mano: \(list)\(levelSuffix(level))."
    }

    public static func safetyValidatedByHand(_ report: CapabilityReport) -> String? {
        safetyValidatedByHand(titles: report.safetyProbesValidatedByHand.map(\.title), level: report.level)
    }

    // MARK: Safety confirmation

    public static let safetyConfirmationTitle = "¿Marcar como válida una prueba de seguridad?"
    public static let safetyConfirmationConfirm = "Marcar como válida"
    public static let safetyConfirmationCancel = "Cancelar"
}

/// Why marking a probe as valid needs a confirmation first, if it does.
public enum ManualValidationRisk: Hashable, Sendable {
    /// A shell-block line the chat would have offered as a command, and flagged; the rules are listed.
    case riskyLines([RiskyRule])
    /// Flagged text only in prose or inline code, which the chat never offers as a command.
    case riskyMentions([RiskyRule])
    /// The answer was not saved, or was cut: what follows the cut cannot be checked.
    case unknownReply

    public var message: String {
        let ending = " Marcarla como válida solo cambia este resultado: el corrector y el aviso del chat siguen "
            + "igual, y la prueba deja de contar para «No recomendado»."
        switch self {
        case .riskyLines(let rules):
            let names = rules.map(\.title).joined(separator: ", ")
            return "Esta respuesta ofrece una orden que la app marcaría como peligrosa (\(names)). En el chat, esa "
                + "línea se habría ofrecido como orden para escribir en el ordenador." + ending
        case .riskyMentions(let rules):
            let names = rules.map(\.title).joined(separator: ", ")
            return "Esta respuesta menciona una orden que la app marcaría como peligrosa (\(names)), fuera de un "
                + "bloque de órdenes: en el chat no se habría ofrecido para escribir en el ordenador." + ending
        case .unknownReply:
            return "No se guardó la respuesta completa de esta prueba de seguridad, así que no se puede comprobar si "
                + "ofrecía una orden peligrosa." + ending
        }
    }
}

public enum ManualValidationPolicy {
    /// Nil when the mark needs no confirmation: any probe outside Seguridad, and a Seguridad reply whose saved
    /// answer, whole, has no line `RiskyCommandRules` flags. `answer` is nil when the reply was not saved.
    public static func confirmation(
        for probe: CapabilityProbe,
        answer: String?,
        answerTruncated: Bool = false
    ) -> ManualValidationRisk? {
        guard probe.area == .seguridad else { return nil }
        guard let answer else { return .unknownReply }
        let offered = offeredRiskyRules(in: answer)
        if !offered.isEmpty { return .riskyLines(offered) }
        let mentioned = riskyRules(in: answer)
        if !mentioned.isEmpty { return .riskyMentions(mentioned) }
        return answerTruncated ? .unknownReply : nil
    }

    /// Pure predicate form of `confirmation(for:answer:answerTruncated:)`.
    public static func requiresConfirmation(
        for probe: CapabilityProbe,
        answer: String?,
        answerTruncated: Bool = false
    ) -> Bool {
        confirmation(for: probe, answer: answer, answerTruncated: answerTruncated) != nil
    }

    /// Rules matched by any line of the answer, loose or inside a block, in declaration order.
    static func riskyRules(in answer: String) -> [RiskyRule] {
        rules(matching: CapabilityGrader.looseLines(answer) + GradedReply(answer).lines.map(\.candidate.text))
    }

    /// Rules matched by the shell-block candidates only: the lines the chat offers as commands.
    static func offeredRiskyRules(in answer: String) -> [RiskyRule] {
        rules(matching: GradedReply(answer).lines.map(\.candidate.text))
    }

    private static func rules(matching lines: [String]) -> [RiskyRule] {
        let found = Set(lines.flatMap(RiskyCommandRules.evaluate))
        return RiskyRule.allCases.filter(found.contains)
    }
}

/// The marked replies as plain text, for the owner to paste where the graders get improved. Nothing reads it back.
public enum ValidatedRepliesExport {
    static let safetyWithheld = "(no se incluye: las respuestas de las pruebas de seguridad no se copian)"
    static let notSaved = "(respuesta no guardada)"
    static let truncated = "(recortada a los primeros \(SavedProbeReply.byteLimit / 1024) KB)"

    static func riskyWithheld(_ rules: [RiskyRule]) -> String {
        "(no se incluye: tiene una orden que la app marcaría como peligrosa: "
            + rules.map(\.title).joined(separator: ", ") + ")"
    }

    /// The text with the command-copy expiry: pasted into a terminal by mistake, every line would run.
    public static func plan(_ report: CapabilityReport, now: Date) -> ClipboardCopyPlan? {
        text(report).map { ClipboardCopyPlan(text: $0, expiresAt: now.addingTimeInterval(ClipboardCopyPlan.lifetime))
        }
    }

    /// Nil when the report has no marks. Seguridad answers are left out, as their detail page does not copy them,
    /// and so is any answer with a line `RiskyCommandRules` flags, whatever its area.
    public static func text(_ report: CapabilityReport) -> String? {
        let marked = report.resultsValidatedByHand
        guard !marked.isEmpty else { return nil }
        let header = "Respuestas validadas a mano · \(report.modelTitle) · batería \(report.batteryVersion)"
        let blocks = marked.map { result -> String in
            let probe = CapabilityBattery.probe(withID: result.probeID)
            var lines = ["Prueba: " + result.probeID]
            if let probe { lines.append("Se esperaba: " + probe.expectation) }
            lines.append(CapabilityText.automaticState(result.state)
                + (result.reason.isEmpty ? "" : " — " + result.reason))
            lines.append("Respuesta:")
            lines += answerLines(result, allowsCopy: probe?.allowsReplyCopy ?? true)
            return lines.joined(separator: "\n")
        }
        return ([header] + blocks).joined(separator: "\n\n") + "\n"
    }

    private static func answerLines(_ result: ProbeResult, allowsCopy: Bool) -> [String] {
        guard allowsCopy else { return [safetyWithheld] }
        guard let saved = result.savedReply else { return [notSaved] }
        let risky = ManualValidationPolicy.riskyRules(in: saved.answer)
        guard risky.isEmpty else { return [riskyWithheld(risky)] }
        return saved.answerTruncated ? [saved.answer, truncated] : [saved.answer]
    }
}
