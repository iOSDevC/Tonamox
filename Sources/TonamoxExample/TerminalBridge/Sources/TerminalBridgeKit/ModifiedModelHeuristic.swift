import Foundation

/// Tells apart models whose safety training was removed (abliterated, "uncensored" and similar fine-tunes) by the
/// words in their names and Hugging Face tags. It is a heuristic over text only: a modified model whose repo id, file
/// name, display name and tags carry none of ``terms`` (nor the tag ``adultContentTag``) is missed, and a repo that
/// merely names a term (an NSFW classifier, say) is marked too. Nothing here looks at the weights.
public enum ModifiedModelHeuristic {
    public static let label = "Modificado: sin filtros de seguridad"
    /// Where a row or a table cell has no room for ``label``.
    public static let shortLabel = "Sin filtros"
    public static let symbol = "exclamationmark.shield"

    /// What is looked for, as written in the pattern.
    public static let terms = [
        "uncensored", "decensored", "abliterated", "abliteration", "heretic", "unfiltered", "unaligned", "nsfw",
        "jailbreak", "jailbroken", "no-refusal", "norefusal", "refusal-removed"
    ]

    /// Hugging Face's tag for repos with adult content; counted in tags only, since no name spells it.
    public static let adultContentTag = "not-for-all-audiences"

    /// A term counts at a word edge: a non-letter (digits, punctuation, the ends) or a lowercase-to-uppercase change,
    /// so "LlamaUncensored", "WizardUncensoredGGUF" and "llama_uncensored_gguf" match while "censored" alone,
    /// "heretical" and "HERETICAL" do not. A version suffix ("uncensoredv2") also ends a term. The edges are read
    /// on the original case; only the term itself is case-insensitive. "no refusal" and "refusal removed" take one
    /// optional separator and a plural.
    static let pattern = "(?:(?<![A-Za-z])|(?<=[a-z])(?=[A-Z]))"
        + "(?i:uncensored|decensored|abliterat(?:ed|ion)|heretic|unfiltered|unaligned|nsfw"
        + "|jailbreak|jailbroken|no[^a-z0-9]?refusals?|refusals?[^a-z0-9]?removed)"
        + "(?:(?![A-Za-z])|(?<=[a-z])(?=[A-Z])|(?=[vV][0-9]))"

    private static let expression: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            preconditionFailure("ModifiedModelHeuristic.pattern does not compile: \(error)")
        }
    }()

    /// True when any of the texts carries a term, or a tag is ``adultContentTag``.
    public static func applies(
        repoID: String? = nil,
        fileName: String? = nil,
        displayName: String? = nil,
        tags: [String] = []
    ) -> Bool {
        ([repoID, fileName, displayName].compactMap { $0 } + tags).contains(where: matches)
            || tags.contains { $0.caseInsensitiveCompare(adultContentTag) == .orderedSame }
    }

    /// For a GGUF on disk: ``applies(repoID:fileName:displayName:tags:)``, or its file name is one of
    /// `flaggedFileNames`, the catalogue entries flagged as uncensored whose names carry no term (Dolphin 3.0).
    public static func applies(
        fileName: String,
        repoID: String? = nil,
        displayName: String? = nil,
        flaggedFileNames: Set<String>
    ) -> Bool {
        flaggedFileNames.contains(fileName) || applies(repoID: repoID, fileName: fileName, displayName: displayName)
    }

    public static func matches(_ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // MARK: Reports

    /// Under the verdict of a modified model's reports: its Seguridad failures are expected. Nil for any other
    /// model and for reports with no Seguridad probes (Nivel 1), which can fail none. «No recomendado» is named
    /// only when one of the reports carries that verdict.
    public static func expectedFailuresNote(_ reports: [CapabilityReport]) -> String? {
        guard reports.contains(where: \.safetyFiltersRemoved),
              reports.contains(where: \.level.hasSafetyProbes) else { return nil }
        let note = "Este modelo se modificó para quitarle los filtros de seguridad: es de esperar que suspenda "
            + "pruebas de Seguridad, porque esas protecciones se eliminaron."
        return reports.contains(where: \.notRecommended) ? note + " El veredicto «No recomendado» se mantiene." : note
    }
}
