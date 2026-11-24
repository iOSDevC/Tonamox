import Foundation
import Testing
@testable import TerminalBridgeKit

/// One free-text parameter of one variant, with the word it occupies.
struct CatalogueSlot: Sendable, CustomTestStringConvertible {
    let task: CatalogueTask
    let variant: CatalogueTaskVariant
    let definition: CatalogueParameter
    let stage: Int
    let wordIndex: Int

    var testDescription: String { "\(task.id)/\(variant.id)/\(definition.id)" }

    /// The literal word right before the parameter in the template.
    var precedingWord: String? {
        guard wordIndex > 0 else { return nil }
        return variant.stages[stage][wordIndex - 1].leadingLiteral
    }

    static func slots(in task: CatalogueTask, _ variant: CatalogueTaskVariant) -> [CatalogueSlot] {
        variant.stages.enumerated().flatMap { stage, words in
            words.enumerated().compactMap { index, word in
                makeSlot(task, variant, word: word, stage: stage, index: index)
            }
        }
    }

    /// Only parameters that fill a whole word and accept free text.
    private static func makeSlot(
        _ task: CatalogueTask,
        _ variant: CatalogueTaskVariant,
        word: CatalogueWord,
        stage: Int,
        index: Int
    ) -> CatalogueSlot? {
        guard word.segments.count == 1, case .parameter(let id)? = word.segments.first,
              let definition = task.parameter(id), definition.kind.isFreeText else { return nil }
        return CatalogueSlot(task: task, variant: variant, definition: definition, stage: stage, wordIndex: index)
    }
}

extension CatalogueParameterKind {
    var isFreeText: Bool {
        switch self {
        case .path, .fileName, .processName, .textPattern, .host, .url: true
        case .port, .count, .choice: false
        }
    }
}

@Suite struct TaskCatalogueAdversarialTests {
    static let slots: [CatalogueSlot] = TaskCatalogue.macOS.flatMap { task in
        task.variants.flatMap { CatalogueSlot.slots(in: task, $0) }
    }

    /// Printable ASCII that a shell would treat as code, globs, expansions or options if unquoted.
    static let hostile: [String] = [
        "my file", "it's", #""q""#, "$(touch pwned)", "`id`", "a;b", "a && b", "a|b", "a || b", "a & b",
        "-rf", "--help", "-", "*", "?.txt", "[ab]", "{a,b}", "~", "~root", "$HOME", "${HOME}", "!!", "!-1", "^x^y",
        "#c", #"\n"#, #"a\"#, "' ; rm -rf ~ ; '", "x > /dev/disk0", "<(id)", "=ls", "%1", "a'b'c", "''", " lead",
        "trail ", "  ", "a\\'b", "(x)", "sudo rm -rf /", "x <<< y", "a=b", "https://a.b/$(id)", "https://x/?a=1&b=2;c|d",
        "!", "(", "https://x/[1-3]{a,b}",
    ]

    /// Refused at validation whatever the parameter kind.
    static let refused: [(String, String)] = [
        ("a\nb", "control"), ("a\tb", "control"), ("a\rb", "control"), ("\u{1B}[31m", "control"), ("x\u{7F}", "control"),
        ("ñandú", "nonASCII"), ("café", "nonASCII"), ("a\u{200B}b", "nonASCII"), ("a\u{00A0}b", "nonASCII"),
        ("", "empty"), (String(repeating: "a", count: 1_000), "tooLong"),
    ]

    @Test func everyFreeTextKindIsExercised() {
        let kinds = Set(Self.slots.map { "\($0.definition.kind)".prefix(while: { $0 != "(" }) })
        #expect(kinds == ["path", "fileName", "processName", "textPattern", "host", "url"])
    }

    @Test(arguments: slots)
    func hostileValuesNeverChangeTheCommandStructure(slot: CatalogueSlot) {
        var accepted = 0
        for raw in Self.hostile {
            var values = catalogueExampleValues(slot.task)
            values[slot.definition.id] = raw
            switch renderCatalogueVariant(slot.task, slot.variant, values: values) {
            case .success(let line):
                accepted += 1
                expectStructure(line, slot: slot, raw: raw)
            case .failure(.parameter):
                #expect(slot.definition.validate(raw).isFailure, "\(raw)")
            case .failure(let error):
                Issue.record("\(slot.testDescription) \(raw): \(error)")
            }
        }
        switch slot.definition.kind {
        case .path, .textPattern: #expect(accepted == Self.hostile.count)
        case .fileName: #expect(accepted == Self.hostile.filter { !$0.contains("/") }.count)
        case .host: #expect(accepted == 0)
        default: #expect(accepted >= 2)
        }
    }

    private func expectStructure(_ line: RenderedCatalogueLine, slot: CatalogueSlot, raw: String) {
        let commands = ShellCommandParser.commands(in: ShellLexer.tokenize(line.text))
        #expect(commands.count == slot.variant.stages.count, "\(line.text)")
        #expect(commands.map { ShellCommandParser.resolve($0.words[...]).names } == slot.variant.programs.map { [$0] },
                "\(line.text)")
        #expect(commands.map(\.words.count) == slot.variant.stages.map(\.count), "\(line.text)")
        #expect(commands.allSatisfy { $0.redirectTargets.isEmpty && $0.hereStrings.isEmpty }, "\(line.text)")
        #expect(RiskyCommandRules.evaluate(line.text) == slot.variant.expectedWarnings, "\(line.text)")
        #expect(CommandTextPolicy.validate(line.text).isEmpty, "\(line.text)")
        #expect(TaskCatalogueRenderer.hasOnlyInertUnquotedText(line.text), "\(line.text)")
        #expect(shellSyntaxOutsideQuotes(line.text).isEmpty, "\(line.text)")
        guard slot.stage < commands.count, slot.wordIndex < commands[slot.stage].words.count else { return }
        #expect(commands[slot.stage].words[slot.wordIndex] == expectedWord(raw, kind: slot.definition.kind),
                "\(line.text)")
    }

    /// Independent of the renderer's tables, because `ShellLexer` keeps `$HOME` or `*` as plain words.
    private func shellSyntaxOutsideQuotes(_ line: String) -> String {
        let unquoted = line.replacingOccurrences(of: #"'\''"#, with: "")
            .replacingOccurrences(of: "'[^']*'", with: "", options: .regularExpression)
        let tildeAfterWordStart = unquoted.replacingOccurrences(of: "(^| )~", with: " ", options: .regularExpression)
        return String(tildeAfterWordStart.filter { "$`*?[]{};&<>()!#^=\"\\'~".contains($0) })
    }

    private func expectedWord(_ raw: String, kind: CatalogueParameterKind) -> String {
        switch kind {
        case .path: raw.hasPrefix("-") || raw == "!" || raw == "(" ? "./" + raw : raw
        case .processName: raw.replacingOccurrences(of: ".", with: "[.]")
        default: raw
        }
    }

    @Test(arguments: slots)
    func newlinesControlCharactersNonASCIIEmptyAndLongValuesAreRefused(slot: CatalogueSlot) {
        for (raw, reason) in Self.refused {
            var values = catalogueExampleValues(slot.task)
            values[slot.definition.id] = raw
            let result = renderCatalogueVariant(slot.task, slot.variant, values: values)
            guard case .failure(.parameter(let error)) = result else {
                Issue.record("\(slot.testDescription) accepted \(raw.debugDescription)")
                continue
            }
            #expect("\(error)".hasPrefix(reason), "\(raw.debugDescription): \(error)")
            #expect(error.message.contains("«\(slot.definition.label)»"))
        }
    }

    @Test(arguments: slots)
    func aLeadingDashCanNeverBeReadAsAnOption(slot: CatalogueSlot) {
        var values = catalogueExampleValues(slot.task)
        values[slot.definition.id] = "-x"
        let result = renderCatalogueVariant(slot.task, slot.variant, values: values)
        switch slot.definition.kind {
        case .path:
            let line = try? result.get()
            let word = line.flatMap { ShellCommandParser.commands(in: ShellLexer.tokenize($0.text))[slot.stage] }?
                .words[slot.wordIndex]
            #expect(word == "./-x")
        case .processName:
            #expect(slot.precedingWord == "--")
            #expect((try? result.get()) != nil)
        case .textPattern:
            #expect(slot.precedingWord == "-e")
            #expect((try? result.get()) != nil)
        case .fileName:
            #expect(slot.precedingWord == "-name")
            #expect((try? result.get()) != nil)
        case .host, .url:
            #expect(result.isFailure)
        case .port, .count, .choice:
            Issue.record("not a free-text slot")
        }
    }

    @Test func valuesAtTheLengthLimitRenderOrAreRefusedByTheLinePolicy() throws {
        let task = try #require(TaskCatalogue.task("files.searchText"))
        let quotes = String(repeating: "'", count: 120)
        let line = try TaskCatalogueRenderer.render(task, variantID: "run", values: ["pattern": quotes, "path": "x"]).get()
        #expect(line.text.utf8.count <= CommandTextPolicy.maxBytes)
        let words = ShellCommandParser.commands(in: ShellLexer.tokenize(line.text)).first?.words
        #expect(words == ["grep", "-rnF", "-e", quotes, "x"])
        let path = String(repeating: "a", count: 200)
        let escapedTooFar = TaskCatalogueRenderer.render(
            task, variantID: "run", values: ["pattern": quotes, "path": path]
        )
        #expect(escapedTooFar == .failure(.policy([.tooLong(bytes: 696)])))
        let tooLong = TaskCatalogueRenderer.render(
            task, variantID: "run", values: ["pattern": "x", "path": path + "a"]
        )
        #expect(tooLong == .failure(.parameter(.tooLong(label: "Carpeta", maxBytes: 200))))
    }
}

@Suite struct TaskCatalogueParameterTests {
    private func parameter(_ kind: CatalogueParameterKind) -> CatalogueParameter {
        CatalogueParameter(id: "v", label: "Valor", kind: kind, example: "1")
    }

    @Test func countsAndPortsAcceptOnlyPlainDigitsInRange() {
        let count = parameter(.count(1...20))
        #expect(count.validate("20") == .success("20"))
        #expect(count.validate("0") == .failure(.outOfRange(label: "Valor", range: 1...20)))
        #expect(count.validate("21") == .failure(.outOfRange(label: "Valor", range: 1...20)))
        let notNumbers = ["-5", "+5", " 5", "5 ", "1e3", "0x10", "٣", "5;", "99999999999999999999"]
        #expect(notNumbers.allSatisfy { count.validate($0).isFailure })
        #expect(count.validate("1e3") == .failure(.notANumber(label: "Valor")))
        let port = parameter(.port)
        #expect(port.validate("65535") == .success("65535"))
        #expect(port.validate("0").isFailure && port.validate("65536").isFailure)
        #expect(CatalogueParameterError.outOfRange(label: "Puerto", range: 1...65535).message
            == "«Puerto» debe estar entre 1 y 65535.")
    }

    @Test func choicesAcceptOnlyTheirOwnValues() {
        let choice = parameter(.choice([CatalogueChoice(value: "en0", title: "en0")]))
        #expect(choice.validate("en0") == .success("en0"))
        #expect(choice.validate("en0;id") == .failure(.notAChoice(label: "Valor", choices: ["en0"])))
        #expect(choice.validate("EN0").isFailure)
    }

    @Test func kindSpecificRulesHaveSpanishMessages() {
        #expect(parameter(.fileName).validate("a/b") == .failure(.slashInFileName(label: "Valor")))
        #expect(parameter(.processName).validate(".*") == .failure(.processNameCharacters(label: "Valor")))
        #expect(parameter(.processName).validate("Google Chrome") == .success("Google Chrome"))
        #expect(parameter(.host).validate("-oProxy").isFailure)
        #expect(parameter(.host).validate(".local").isFailure)
        #expect(parameter(.host).validate("192.168.1.1") == .success("192.168.1.1"))
        #expect(parameter(.url).validate("ftp://x").isFailure)
        #expect(parameter(.url).validate("https://").isFailure)
        #expect(parameter(.url).validate("https://a b").isFailure)
        #expect(parameter(.url).validate("HTTPS://example.com") == .success("HTTPS://example.com"))
        #expect(CatalogueParameterError.nonASCII(label: "Carpeta").message.hasPrefix("«Carpeta» contiene acentos"))
        #expect(CatalogueParameterError.controlCharacter(label: "Texto").message.contains("salto de línea"))
    }
}

extension Result {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}
