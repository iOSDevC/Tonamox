import Foundation

/// Copy of «Evaluar con Claude». Amounts as the consent sheet writes them: "$0.0123".
public enum ClaudeJudgeText {
    public static let modelSetting = "Modelo juez"
    public static let confirmationTitle = "¿Evaluar con Claude?"
    public static let running = "Evaluando con Claude…"
    public static let cancel = "Cancelar evaluación"
    public static let apply = "Aplicar"
    public static let secondOpinionSection = "Segunda opinión (Claude)"
    public static let missingKey = "Falta la clave de Claude."
    public static let cloudNotAllowed = "Evaluar con Claude necesita permiso para enviar a la nube: actívalo en "
        + "«Claves API y envío remoto»."
    public static let unreadable = "Respuesta de Claude ilegible."
    public static let invalidJudgment = "Claude no devolvió un juicio válido."
    public static let cutOff = "Claude se quedó sin espacio antes de dar su juicio."
    public static let whatIsSent = "Se envían a Anthropic con tu clave, de cada una: la pregunta, lo esperado, el "
        + "resultado del calificador y la respuesta del modelo, sin su razonamiento."
    public static let secondOpinionNote = "Es una segunda opinión: no cambia los resultados hasta que pulses «"
        + apply + "»."

    public static func button(count: Int) -> String {
        "Evaluar con Claude (\(count))"
    }

    public static func sendButton(count: Int) -> String {
        count == 1 ? "Enviar 1 prueba a Claude" : "Enviar \(count) pruebas a Claude"
    }

    /// «Enviar 7 de 12 pruebas a Claude» when the session cap leaves room for only part of the batch.
    public static func sendButton(count: Int, of total: Int) -> String {
        count >= total ? sendButton(count: count) : "Enviar \(count) de \(total) pruebas a Claude"
    }

    /// Why the confirmation offers only the first `count`.
    public static func partialBatch(count: Int, of total: Int) -> String {
        "Lo que queda del límite de la sesión solo alcanza para las \(count) primeras de \(total); las demás "
            + "siguen pendientes."
    }

    /// Mode «Off» locks every remote path, this one included.
    public static var remoteOff: String { RemoteLock.remoteOff.message }

    public static func usd(_ value: Decimal) -> String {
        String(format: "$%.4f", NSDecimalNumber(decimal: value).doubleValue)
    }

    public static func estimateLine(_ estimate: ClaudeJudgeEstimate) -> String {
        "Coste estimado: entre " + usd(estimate.lowUSD) + " y " + usd(estimate.highUSD) + " (precios del "
            + ClaudeJudgePrices.checkedOn + ")."
    }

    public static func confirmationMessage(
        model: ClaudeJudgeModel,
        estimate: ClaudeJudgeEstimate,
        totalCount: Int? = nil
    ) -> String {
        let partial = totalCount.flatMap { total in
            estimate.requestCount < total ? partialBatch(count: estimate.requestCount, of: total) : nil
        }
        return [whatIsSent, modelSetting + ": " + model.title + ".", estimateLine(estimate), partial,
                secondOpinionNote].compactMap { $0 }.joined(separator: " ")
    }

    /// Why a batch is refused before anything is sent.
    public static func capExceeded(_ estimate: ClaudeJudgeEstimate, capUSD: Decimal, spentUSD: Decimal) -> String {
        let remaining = max(capUSD - spentUSD, 0)
        return "No se envía: el coste máximo estimado (" + usd(estimate.highUSD) + ") supera lo que queda del "
            + "límite de la sesión (" + usd(remaining) + ")."
    }

    public static func httpError(_ status: Int, type: String? = nil) -> String {
        "Claude respondió con el error \(status)" + (type.map { " (" + $0 + ")" } ?? "") + "."
    }

    public static func unexpectedStop(_ reason: String?) -> String {
        "Claude terminó sin dar su juicio (" + (reason ?? "sin motivo") + ")."
    }

    /// The explanation, when Claude gave one, folded to one line like a judgment's reason.
    public static func refused(category: String?, explanation: String? = nil) -> String {
        let why = explanation.map(ClaudeJudgment.oneLine).flatMap { $0.isEmpty ? nil : " — " + $0 } ?? ""
        return "Claude se negó a evaluar esta prueba" + (category.map { " (" + $0 + ")" } ?? "") + why
            + (why.isEmpty ? "." : "")
    }

    /// The row line for an outcome: the judgment, or why there is none.
    public static func outcomeLine(_ outcome: ClaudeJudgeOutcome) -> String {
        switch outcome {
        case .judged(let judgment): judgment.text
        case .refused(let category, let explanation):
            "Claude: " + refused(category: category, explanation: explanation)
        case .cutOff: "Claude: " + cutOff
        case .failed(let message): "Claude: no se pudo evaluar — " + message
        }
    }

    /// The two lines exports print under «Segunda opinión (Claude)»: the judgment, then who gave it and when.
    /// `withheldReason` stands in for the reason when the reply it is about is not shown.
    public static func exportLines(_ judgment: ClaudeJudgment, withheldReason: String? = nil) -> [String] {
        let first = withheldReason.map { judgment.verdictText + " — " + $0 } ?? judgment.text
        return [first, judgment.judgeModelText + " · " + ExportText.isoDate(judgment.date)]
    }
}
