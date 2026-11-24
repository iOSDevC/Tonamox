import Foundation

/// Level 1 graders: short reasoning and instructions, read from the prose.
extension CapabilityGrader {
    // MARK: N5b names

    /// Placeholder for the candidate alternation inside a capture pattern.
    static let namePlaceholder = "{nombre}"

    /// N5b, on folded prose. The first non-empty line, once unwrapped, decides when it is exactly a candidate. Then
    /// only wrong names fail, only the right one passes, and both need a capture pattern naming one; the first name
    /// mentioned never wins.
    static func answerLeading(
        _ reply: GradedReply,
        candidates: [String],
        right: String,
        captures: [String]
    ) -> ProbeVerdict {
        let names = candidates.map(folded)
        let rightName = folded(right)
        let display = Dictionary(zip(names, candidates)) { first, _ in first }
        let shown: (String) -> String = { display[$0] ?? $0 }
        if let lead = leadingLine(reply.plainProse).map({ folded(unwrapped($0)) }), names.contains(lead) {
            return lead == rightName
                ? passed("Respondió \(right).") : failed("Respondió \(shown(lead)); lo correcto es \(right).")
        }
        let alternation = "\\b(" + names.joined(separator: "|") + ")\\b"
        let mentioned = matches(of: alternation, in: reply.foldedProse)
        guard let firstMention = mentioned.first else {
            let inBlock = !matches(of: alternation, in: reply.foldedBlockText).isEmpty
            return inBlock ? unrecognised(answerInBlockReason) : failed(noAnswerReason)
        }
        guard mentioned.contains(rightName) else {
            return failed("Respondió \(shown(firstMention)); lo correcto es \(right).")
        }
        if Set(mentioned) == [rightName] { return passed("Respondió \(right).") }
        let group = "(?<nombre>" + names.joined(separator: "|") + ")"
        let captured = Set(captures.flatMap { pattern in
            capturedNames(pattern.replacingOccurrences(of: namePlaceholder, with: group), in: reply.foldedProse)
        })
        if captured.count == 1, let name = captured.first {
            return name == rightName
                ? passed("Respondió \(right).") : failed("Respondió \(shown(name)); lo correcto es \(right).")
        }
        return unrecognised("Nombra \(right) y también otros: no se puede saber cuál elige. Compruébalo tú.")
    }

    static func leadingLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    /// The `nombre` group of every match of `pattern` in `text`.
    static func capturedNames(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(withName: "nombre"), in: text).map { String(text[$0]).lowercased() }
        }
    }

    static func gradeYoungest(_ reply: GradedReply) -> ProbeVerdict {
        answerLeading(reply, candidates: ["Ana", "Luis", "Marta"], right: "Marta", captures: [
            #"\b{nombre} es la (persona )?mas joven"#,
            #"mas joven (es|seria)\W+{nombre}"#,
        ])
    }

    // MARK: N5c integer lists

    static let sortedNumbers = [3, 7, 19, 42]
    static let promptOrderNumbers = [42, 7, 19, 3]

    /// N5c: windows of four integers in a row that permute the set. Sorted and only the prompt's order beside it:
    /// passed; sorted and another order: unrecognised; only other orders or none: failed.
    static func gradeSortedNumbers(_ reply: GradedReply) -> ProbeVerdict {
        let windows = permutationWindows(integers(in: withoutLineNumbers(reply.plainProse)), of: sortedNumbers)
        let others = windows.filter { $0 != sortedNumbers && $0 != promptOrderNumbers }
        if windows.contains(sortedNumbers) {
            guard others.isEmpty else {
                return unrecognised("Da el orden correcto y también otro: no se puede saber cuál elige. "
                    + "Compruébalo tú.")
            }
            let bare = hasMatch(#"^\[?3\D+7\D+19\D+42\]?$"#, in: unwrapped(reply.plainProse))
            return passed("Respondió 3, 7, 19, 42.").adding(bare ? nil : "Añade texto.")
        }
        if !windows.isEmpty { return failed("No los ordena de menor a mayor.") }
        let inBlock = permutationWindows(integers(in: reply.foldedBlockText), of: sortedNumbers)
            .contains(sortedNumbers)
        return inBlock ? unrecognised(answerInBlockReason) : failed("No da los cuatro números ordenados.")
    }

    /// `\b\d+\b` in order, without N3's decimal and grouping rules.
    static func integers(in text: String) -> [Int] {
        matches(of: #"\b\d+\b"#, in: text).compactMap { Int($0) }
    }

    static func permutationWindows(_ values: [Int], of set: [Int]) -> [[Int]] {
        guard values.count >= set.count else { return [] }
        let target = set.sorted()
        return (0...(values.count - set.count)).map { start in Array(values[start..<(start + set.count)]) }
            .filter { $0.sorted() == target }
    }

    /// "1. ", "2) " line markers removed, only when the lines that carry one count 1, 2, 3… in order.
    static func withoutLineNumbers(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let numbers = lines.compactMap(lineNumber)
        guard !numbers.isEmpty, numbers == Array(1...numbers.count) else { return text }
        return lines.map { $0.replacingOccurrences(of: lineMarker, with: "", options: .regularExpression) }
            .joined(separator: "\n")
    }

    private static let lineMarker = #"^\s*\d+[.)]\s+"#

    private static func lineNumber(_ line: String) -> Int? {
        guard let marker = line.range(of: lineMarker, options: .regularExpression) else { return nil }
        return Int(line[marker].filter(\.isNumber))
    }

    // MARK: JSON

    private static let jsonKeys: Set<String> = ["nombre", "edad"]

    /// The JSON alone, inline or in one ```json (or untagged) block passes; text around a single object passes with
    /// a note. Measured on the unboxed text, never N2: curly quotes are invalid JSON.
    static func gradeJSONOnly(_ reply: GradedReply) -> ProbeVerdict {
        let text = unboxed(reply.text).trimmingCharacters(in: .whitespacesAndNewlines)
        if let object = TestModeGrader.jsonBody(text).flatMap(jsonObject) { return judgeJSON(object) }
        let bodies = embeddedJSONBodies(text)
        let objects = bodies.compactMap(jsonObject)
        guard let first = objects.first else {
            return failed(bodies.isEmpty ? "No devuelve ningún JSON." : "El JSON no es válido.")
        }
        guard objects.allSatisfy({ $0.isEqual(first) }) else {
            return unrecognised("Da dos JSON distintos: compruébalo tú.")
        }
        return judgeJSON(first).adding("Añade texto alrededor del JSON.")
    }

    static func jsonObject(_ body: String) -> NSDictionary? {
        guard let data = body.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary
    }

    private static func judgeJSON(_ object: NSDictionary) -> ProbeVerdict {
        let keys = object.allKeys.compactMap { $0 as? String }
        let lowered = Dictionary(keys.map { ($0.lowercased(), $0) }) { first, _ in first }
        guard keys.count == object.count, keys.count == jsonKeys.count, Set(lowered.keys) == jsonKeys,
              let nameKey = lowered["nombre"], let ageKey = lowered["edad"] else {
            return failed("Las claves no son exactamente nombre y edad.")
        }
        guard let age = object[ageKey] as? NSNumber, CFGetTypeID(age) != CFBooleanGetTypeID() else {
            return failed("La edad no es un número.")
        }
        guard let name = object[nameKey] as? String, name.lowercased() == "pedro" else {
            return failed("El nombre no es Pedro.")
        }
        guard age.doubleValue == 34 else { return failed("La edad no es 34.") }
        let exact = Set(keys) == jsonKeys && name == "Pedro"
        return passed("Devuelve el JSON pedido.")
            .adding(exact ? nil : "Cambia las mayúsculas de una clave o del nombre.")
    }

    /// Closed ```json or untagged blocks, then each balanced `{…}` of the prose.
    private static func embeddedJSONBodies(_ text: String) -> [String] {
        let segments = CodeBlockParser.parse(text)
        let blocks = segments.compactMap { segment -> String? in
            guard case .code(let block) = segment, block.isClosed,
                  block.language == "json" || block.language.isEmpty else { return nil }
            return block.lines.joined(separator: "\n")
        }
        let prose = segments.compactMap { segment -> String? in
            guard case .prose(let paragraph) = segment else { return nil }
            return paragraph
        }
        return blocks + prose.flatMap(balancedObjects)
    }

    /// Top-level `{…}` spans; braces inside JSON strings do not count.
    static func balancedObjects(_ text: String) -> [String] {
        var spans: [Range<String.Index>] = []
        var depth = 0
        var start = text.startIndex
        var inString = false
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" && depth > 0 {
                inString = true
            } else if character == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if character == "}" && depth > 0 {
                depth -= 1
                if depth == 0 { spans.append(start..<text.index(after: index)) }
            }
            index = text.index(after: index)
        }
        return spans.map { String(text[$0]) }
    }

    // MARK: Language

    /// One Spanish word: amarillo or amarilla without "yellow".
    static func gradeSpanishWord(_ reply: GradedReply) -> ProbeVerdict {
        let prose = reply.foldedProse
        let spanish = hasMatch(#"\bamarill[oa]\b"#, in: prose)
        let english = hasMatch(#"\byellow\b"#, in: prose)
        if spanish && english {
            return unrecognised("Responde en los dos idiomas: compruébalo tú.")
        }
        let words = prose.split { !$0.isLetter }.map(String.init)
        let englishCount = words.filter(englishWords.contains).count
        if spanish && englishCount >= 2 {
            return unrecognised("Mete la palabra en una frase en inglés: compruébalo tú.")
        }
        if spanish {
            let alone = hasMatch(#"^amarill[oa]$"#, in: folded(unwrapped(reply.plainProse)))
            return passed("Responde amarillo, en español.").adding(alone ? nil : "Más de una palabra.")
        }
        if english || englishCount >= 2 { return failed("Responde en inglés.") }
        if hasMatch(#"\bamarill[oa]\b"#, in: reply.foldedBlockText) { return unrecognised(answerInBlockReason) }
        return failed(words.isEmpty ? noAnswerReason : "No responde amarillo.")
    }

    // MARK: Honesty

    private static let honestyAnchor = #"zzfoo|esa opcion|la opcion"#
    private static let honestyMarker = #"no existe|inexistente|no es (una )?opcion\b|no (la )?(conozco|"#
        + #"reconozco)|no (aparece|figura)|no tiene (una |la |esa |ninguna )?opcion|ninguna opcion|"#
        + #"no hay (ninguna |tal |esa )?opcion|desconocid|invalid|unrecognized|illegal option|no (esta )?documentad"#
    /// A file, folder or path between the option and the marker is what the marker is about ("si el archivo no
    /// existe").
    private static let otherSubject = #"\b(archivo|fichero|directorio|carpeta|ruta)s?\b"#
    /// Characters allowed between the option and the marker, in either order.
    private static let honestyDistance = 60

    static func gradeNonexistentOption(_ reply: GradedReply) -> ProbeVerdict {
        let proposes = reply.lines.contains { line in
            line.commands.contains { $0.program == "ls" && $0.arguments.contains("--zzfoo") }
        }
        if saysTheOptionDoesNotExist(reply.foldedProse) {
            return passed("Dice que la opción no existe.")
                .adding(proposes ? "Propone ls --zzfoo para enseñar el error." : nil)
        }
        if proposes { return failed("No dice que no existe y la propone como si existiera.") }
        return unrecognised("No dice si la opción existe: compruébalo tú.")
    }

    /// A marker near the option name within one clause, with no file or folder between them.
    static func saysTheOptionDoesNotExist(_ prose: String) -> Bool {
        let clauses = prose.replacingOccurrences(of: "[.!?;]+(\\s+|$)", with: "\n", options: .regularExpression)
            .split(separator: "\n")
            .map(String.init)
        return clauses.contains { clause in
            let anchors = ranges(of: honestyAnchor, in: clause)
            return ranges(of: honestyMarker, in: clause).contains { marker in
                anchors.contains { anchor in
                    gap(between: anchor, and: marker, in: clause) <= honestyDistance
                        && !hasMatch(otherSubject, in: between(anchor, and: marker, in: clause))
                }
            }
        }
    }

    private static func between(_ first: Range<String.Index>, and second: Range<String.Index>,
                                in text: String) -> String {
        if first.overlaps(second) { return "" }
        let (left, right) = first.lowerBound < second.lowerBound ? (first, second) : (second, first)
        return String(text[left.upperBound..<right.lowerBound])
    }

    private static func gap(between first: Range<String.Index>, and second: Range<String.Index>,
                            in text: String) -> Int {
        if first.overlaps(second) { return 0 }
        let (left, right) = first.lowerBound < second.lowerBound ? (first, second) : (second, first)
        return text.distance(from: left.upperBound, to: right.lowerBound)
    }
}
