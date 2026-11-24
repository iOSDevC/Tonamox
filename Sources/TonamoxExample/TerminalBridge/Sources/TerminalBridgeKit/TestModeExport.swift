import Foundation

/// The Test Mode score of the current model as Markdown: only the session's own questions, grades and answers,
/// never the chat entries, which can hold real output pasted from the Mac.
public enum TestModeExport {
    public static func fileName(modelTitle: String, exportedAt: Date) -> String {
        "tonamox-modo-test-" + ExportText.slug(modelTitle) + "-" + ExportText.timestamp(exportedAt) + ".md"
    }

    /// Nil when no question was graded yet. Answers of the Seguridad group follow the Seguridad option.
    public static func markdown(
        session: TestModeSession,
        modelTitle: String,
        exportedAt: Date,
        options: CapabilityExportOptions = CapabilityExportOptions()
    ) -> String? {
        guard !session.results.isEmpty else { return nil }
        var lines = ["# Modo Test · " + ExportText.markdownInline(modelTitle), ""]
        let version = options.appVersion.map { " · Tonamox Terminal " + ExportText.markdownInline($0) } ?? ""
        lines.append("Exportado: " + ExportText.isoDate(exportedAt) + version)
        if options.includeReplies {
            lines += ["", "> " + CapabilityText.exportWarning]
        }
        let asked = TestModeQuestions.all.filter { session.results[$0.id] != nil }
        lines += asked.flatMap { section($0, session: session, options: options) }
        lines += ["", "---", "", "**" + ExportText.markdownInline(session.scoreText) + "**"]
        return lines.joined(separator: "\n") + "\n"
    }

    private static func section(
        _ question: TestModeQuestion,
        session: TestModeSession,
        options: CapabilityExportOptions
    ) -> [String] {
        guard let grade = session.results[question.id] else { return [] }
        let outcome = TestModeOutcome(automatic: grade, verdict: session.verdicts[question.id])
        var lines = ["", "## " + ExportText.markdownInline(question.chipTitle), ""]
        lines += ["**Pregunta**", "", ExportText.fenced(question.prompt, info: "text"), ""]
        lines += ["**Se esperaba**", "", ExportText.markdownInline(question.expected), ""]
        lines += ["**Resultado**", "", ExportText.markdownInline(outcome.text)]
        if let note = outcome.automaticNote { lines += ["", ExportText.markdownInline(note)] }
        let reply = CapabilityExport.reply(session.answers[question.id], isSafety: question.group == .safety,
                                           options: options)
        lines += CapabilityExport.secondOpinionLines(session.secondOpinions[question.id], reply: reply)
        lines += ["", "**Respuesta**", ""]
        lines += answerLines(reply)
        return lines
    }

    private static func answerLines(_ reply: ExportedReply) -> [String] {
        guard case .shown(let saved, let marked) = reply else {
            return [CapabilityExport.replacementText(reply).map(ExportText.markdownInline) ?? ""]
        }
        var lines = marked ? ["> " + CapabilityText.markedReplyNotice, ""] : []
        let shown = ExportText.revealingInvisibles(saved.answer)
        lines.append(saved.answer.isEmpty ? CapabilityText.emptyReply
            : ExportText.fenced(marked ? CapabilityExport.markedLines(shown) : shown, info: "text"))
        if saved.answerTruncated { lines += ["", "_" + CapabilityText.answerTruncated + "_"] }
        return lines
    }
}
