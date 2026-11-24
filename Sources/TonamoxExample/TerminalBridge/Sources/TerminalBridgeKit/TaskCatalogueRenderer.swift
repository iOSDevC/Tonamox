import Foundation

/// One rendered line, ready for the normal command row (send, keyboard, copy all re-run their own gates).
public struct RenderedCatalogueLine: Hashable, Sendable {
    public let taskID: String
    public let variantID: String
    public let role: CatalogueVariantRole
    public let text: String
    public let expectedWarnings: [RiskyRule]
    /// The validated values the line was rendered from, by parameter id.
    public let values: [String: String]

    public func commandCandidate(id: UUID = UUID()) -> CommandCandidate {
        CommandCandidate(id: id, text: text, sourceLine: text, lineIndex: 0, isPartOfMultilineCommand: false)
    }
}

public enum CatalogueRenderError: Error, Hashable, Sendable {
    case unknownVariant(String)
    case unsupportedHost(HostOS)
    case unsupportedShell(CatalogueShell)
    case parameter(CatalogueParameterError)
    /// A destructive variant was asked for without this task's preview rendered for the same values.
    case previewRequired
    case policy([CommandTextViolation])
    /// The local rules disagree with the variant's metadata.
    case warningsMismatch(expected: [RiskyRule], found: [RiskyRule])
    /// Re-parsing the line did not give back the intended words; a quoting bug, never sent.
    case structureMismatch

    /// Spanish; always says nothing was produced.
    public var message: String {
        let suffix = " No se ha preparado ninguna orden."
        switch self {
        case .unknownVariant:
            return "Esta variante no existe en la tarea." + suffix
        case .unsupportedHost(let host):
            return "Esta tarea no está preparada para \(host.title)." + suffix
        case .unsupportedShell(let shell):
            return "Esta tarea no está preparada para \(shell.rawValue)." + suffix
        case .parameter(let error):
            return error.message + suffix
        case .previewRequired:
            return "Primero prepara la vista previa con los mismos valores." + suffix
        case .policy(let violations):
            return "La orden no cumple las reglas de texto: " + violations.map(\.message).joined(separator: "; ")
                + "." + suffix
        case .warningsMismatch:
            return "Las reglas de riesgo no coinciden con lo declarado en el catálogo." + suffix
        case .structureMismatch:
            return "La orden generada no tiene la forma esperada." + suffix
        }
    }
}

/// Renders catalogue variants into one shell line. Parameter values reach the line only through `quote`.
public enum TaskCatalogueRenderer {
    public static func render(
        _ task: CatalogueTask,
        variantID: String,
        values: [String: String],
        host: HostOS = .macOS,
        shell: CatalogueShell = .zsh,
        preview: RenderedCatalogueLine? = nil
    ) -> Result<RenderedCatalogueLine, CatalogueRenderError> {
        guard let variant = task.variant(variantID) else { return .failure(.unknownVariant(variantID)) }
        guard task.host == host else { return .failure(.unsupportedHost(host)) }
        guard task.shells.contains(shell) else { return .failure(.unsupportedShell(shell)) }
        let validated: [String: String]
        switch validate(task, variant: variant, values: values) {
        case .success(let checked): validated = checked
        case .failure(let error): return .failure(.parameter(error))
        }
        if variant.role == .destructive, !isMatchingPreview(preview, task: task, values: validated) {
            return .failure(.previewRequired)
        }
        let stages = variant.stages.map { stage in
            stage.map { renderWord($0, task: task, values: validated) }
        }
        let text = stages.map { stage in stage.map(\.typed).joined(separator: " ") }.joined(separator: " | ")
        let violations = CommandTextPolicy.validate(text)
        guard violations.isEmpty else { return .failure(.policy(violations)) }
        let intended = stages.map { stage in stage.map(\.intended) }
        guard hasOnlyInertUnquotedText(text), parsesBack(text, to: intended) else {
            return .failure(.structureMismatch)
        }
        let found = RiskyCommandRules.evaluate(text)
        guard found == variant.expectedWarnings else {
            return .failure(.warningsMismatch(expected: variant.expectedWarnings, found: found))
        }
        return .success(RenderedCatalogueLine(
            taskID: task.id,
            variantID: variant.id,
            role: variant.role,
            text: text,
            expectedWarnings: found,
            values: validated
        ))
    }

    /// The value as one shell word: bare when every character is inert in zsh and bash, otherwise single-quoted
    /// with each `'` written as `'\''`.
    public static func quote(_ value: String) -> String {
        if !value.isEmpty, value.unicodeScalars.allSatisfy(isInert) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// No `=` (zsh EQUALS at word start), `~`, globs, `%`, `!`, `^`, `#`, quotes or operators.
    static func isInert(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", "_", ".", "/", ":", "@", "+", ",", "-": true
        default: false
        }
    }

    private static func validate(
        _ task: CatalogueTask,
        variant: CatalogueTaskVariant,
        values: [String: String]
    ) -> Result<[String: String], CatalogueParameterError> {
        var validated: [String: String] = [:]
        for id in variant.parameterIDs where validated[id] == nil {
            guard let definition = task.parameter(id) else { return .failure(.missing(label: id)) }
            guard let raw = values[id] else { return .failure(.missing(label: definition.label)) }
            switch definition.validate(raw) {
            case .success(let value): validated[id] = value
            case .failure(let error): return .failure(error)
            }
        }
        return .success(validated)
    }

    private static func isMatchingPreview(
        _ preview: RenderedCatalogueLine?,
        task: CatalogueTask,
        values: [String: String]
    ) -> Bool {
        guard let preview, preview.taskID == task.id, preview.role == .preview else { return false }
        return values.allSatisfy { preview.values[$0.key] == $0.value }
    }

    /// `typed` goes into the line; `intended` is the word the shell must see after removing quotes.
    private struct RenderedWord {
        var typed = ""
        var intended = ""
    }

    private static func renderWord(
        _ word: CatalogueWord,
        task: CatalogueTask,
        values: [String: String]
    ) -> RenderedWord {
        word.segments.reduce(into: RenderedWord()) { rendered, segment in
            switch segment {
            case .literal(let text):
                rendered.typed += text
                rendered.intended += text
            case .parameter(let id):
                guard let value = values[id], let kind = task.parameter(id)?.kind else { return }
                let piece = renderValue(value, kind: kind)
                rendered.typed += piece.typed
                rendered.intended += piece.intended
            }
        }
    }

    private static func renderValue(_ value: String, kind: CatalogueParameterKind) -> RenderedWord {
        switch kind {
        case .path:
            return renderPath(value)
        case .processName:
            let pattern = value.replacingOccurrences(of: ".", with: "[.]")
            return RenderedWord(typed: quote(pattern), intended: pattern)
        default:
            return RenderedWord(typed: quote(value), intended: value)
        }
    }

    /// `~` and `~/rest` keep the tilde unquoted so the shell expands it; a leading dash becomes "./-…".
    private static func renderPath(_ value: String) -> RenderedWord {
        if value == "~" || value == "~/" { return RenderedWord(typed: value, intended: value) }
        if value.hasPrefix("~/") {
            let rest = String(value.dropFirst(2))
            return RenderedWord(typed: "~/" + quote(rest), intended: value)
        }
        let guarded = value.hasPrefix("-") || findExpressionStarts.contains(value) ? "./" + value : value
        return RenderedWord(typed: quote(guarded), intended: guarded)
    }

    /// BSD find ends its path list at a lone `!` or `(` (checked with /usr/bin/find on macOS 27.2).
    static let findExpressionStarts: Set<String> = ["!", "("]

    /// Outside single quotes only inert characters, spaces, pipes, `%` and a word-initial `~` before `/` or a
    /// space. `ShellLexer` does not model expansions, so this is what proves `$`, globs and braces stayed quoted.
    static func hasOnlyInertUnquotedText(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        var index = 0
        var inQuote = false
        while index < scalars.count {
            let scalar = scalars[index]
            let startsWord = index == 0 || scalars[index - 1] == " "
            index += 1
            if inQuote {
                inQuote = scalar != "'"
            } else if scalar == "'" {
                inQuote = true
            } else if scalar == "\\" {
                guard index < scalars.count, scalars[index] == "'" else { return false }
                index += 1
            } else if scalar == "~" {
                let next = index < scalars.count ? scalars[index] : " "
                guard startsWord, next == "/" || next == " " else { return false }
            } else if !(isInert(scalar) || scalar == " " || scalar == "|" || scalar == "%") {
                return false
            }
        }
        return !inQuote
    }

    /// The line lexes to exactly these words, stages joined by plain pipes, with no other operator.
    static func parsesBack(_ text: String, to stages: [[String]]) -> Bool {
        let tokens = ShellLexer.tokenize(text)
        let onlyWordsAndPipes = tokens.allSatisfy { token in
            if case .word = token { return true }
            return token == .symbol(.pipe)
        }
        guard onlyWordsAndPipes else { return false }
        let parsed = tokens.split(separator: .symbol(.pipe), omittingEmptySubsequences: false).map { stage in
            stage.compactMap { token -> String? in
                if case .word(let word) = token { return word }
                return nil
            }
        }
        return parsed == stages
    }
}
