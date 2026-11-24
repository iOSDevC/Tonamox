import Foundation
import Testing
@testable import TerminalBridgeKit

@Suite struct BoxedGradingTests {
    @Test(arguments: ["\\boxed{391}", "$\\boxed{391}$", "La respuesta es $\\boxed{391}$.", "\\(\\boxed{391}\\)",
                      "$$\\boxed{391}$$", "\\[ \\boxed{391} \\]"])
    func boxedNumberIsTheBareValue(_ reply: String) {
        let verdict = CapabilityGrader.grade("calculo.multiplicacion", reply: reply)
        #expect(verdict.outcome == .passed, "\(verdict.reason)")
    }

    @Test(arguments: ["\\boxed{LISTO}", "$\\boxed{LISTO}$", "$\\boxed{\\text{LISTO}}$", "\\boxed{\\textbf{Listo}}."])
    func boxedWordIsTheBareWord(_ reply: String) {
        #expect(CapabilityGrader.grade("instrucciones.una-palabra", reply: reply).outcome == .passed)
    }

    @Test func unwrappedDropsTheBoxAndItsMath() {
        #expect(CapabilityGrader.unwrapped("\\boxed{754}") == "754")
        #expect(CapabilityGrader.unwrapped("$\\boxed{754}$") == "754")
        #expect(CapabilityGrader.unwrapped("$\\boxed{754}$.") == "754")
        #expect(CapabilityGrader.unboxed("\\boxed{\\frac{1}{2}} y \\boxed{3}") == "\\frac{1}{2} y 3")
        #expect(CapabilityGrader.unboxed("\\boxed{sin cerrar") == "\\boxed{sin cerrar")
        #expect(CapabilityGrader.unboxed("$x = \\boxed{5}$") == "$x = 5$")
    }

    @Test(arguments: ["\\[\n\\boxed{LISTO}\n\\]", "$$\n\\boxed{LISTO}\n$$", "\\[\r\n\\boxed{LISTO}\r\n\\]",
                      "\\(\t\\boxed{LISTO}\t\\)"])
    func displayMathOnItsOwnLinesIsTheBareWord(_ reply: String) {
        #expect(CapabilityGrader.unwrapped(reply) == "LISTO")
        #expect(CapabilityGrader.grade("instrucciones.una-palabra", reply: reply).outcome == .passed)
    }

    @Test func boxedWrongValueStillFails() {
        let verdict = CapabilityGrader.grade("calculo.multiplicacion", reply: "$\\boxed{392}$")
        #expect(verdict.outcome == .failed)
        #expect(verdict.reason == "Respondió 392; lo correcto es 391.")
    }

    @Test func boxInsideACodeBlockIsNotProse() {
        let verdict = CapabilityGrader.grade("instrucciones.una-palabra", reply: "```\n\\boxed{LISTO}\n```")
        #expect(verdict.outcome == .failed)
    }

    @Test func forcedReasoningCloseIsRemovedLikeAnyOther() {
        let reply = "<think>pienso…\n\nConsidering the limited time by the user, I have to give the solution based "
            + "on the thinking directly now.\n</think>\n\n$\\boxed{391}$"
        #expect(CapabilityGrader.grade("calculo.multiplicacion", reply: reply).outcome == .passed)
    }
}

@Suite struct ReasoningCutHeaderTests {
    @Test func cutHeaderCountsWholeSeconds() {
        #expect(ReasoningText.header(cutAfter: .milliseconds(400)) == "Razonamiento recortado")
        #expect(ReasoningText.header(cutAfter: .milliseconds(1400)) == "Razonamiento recortado tras 1 segundo")
        #expect(ReasoningText.header(cutAfter: .seconds(34)) == "Razonamiento recortado tras 34 segundos")
        #expect(ReasoningText.header(cutAfter: .milliseconds(1600)) == "Razonamiento recortado tras 2 segundos")
    }
}

@Suite struct ReasoningSettingTests {
    @Test func storedValueDefaultsToMedium() {
        #expect(ReasoningSetting.stored(nil) == .medium)
        #expect(ReasoningSetting.stored("basura") == .medium)
        #expect(ReasoningSetting.stored("disabled") == .disabled)
        #expect(ReasoningSetting.stored("long") == .long)
        #expect(ReasoningSetting.allCases.map(\.title)
            == ["Desactivado", "Corto (256 tokens)", "Medio (512 tokens)", "Largo (1024 tokens)"])
        #expect(ReasoningSetting.allCases.map(\.budget) == [nil, 256, 512, 1024])
    }

    @Test func automaticFromAnOlderBuildBecomesMedium() throws {
        #expect(ReasoningSetting.stored("automatic") == .medium)
        #expect(ReasoningSetting.migratedRawValue("automatic") == "medium")
        #expect(ReasoningSetting.migratedRawValue("disabled") == nil)
        #expect(ReasoningSetting.migratedRawValue(nil) == nil)
        let suite = "ReasoningSettingTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("automatic", forKey: ReasoningSetting.defaultsKey)
        ReasoningSetting.migrate(defaults)
        #expect(defaults.string(forKey: ReasoningSetting.defaultsKey) == "medium")
        defaults.set("disabled", forKey: ReasoningSetting.defaultsKey)
        ReasoningSetting.migrate(defaults)
        #expect(defaults.string(forKey: ReasoningSetting.defaultsKey) == "disabled")
    }

    @Test func reportLabelsRoundTripToText() {
        #expect(ReasoningSetting.medium.reportLabel == "auto:512")
        #expect(ReasoningSetting.long.reportLabel == "auto:1024")
        #expect(ReasoningSetting.disabled.reportLabel == "off")
        #expect(ReasoningSetting.reportText("auto:512") == "Razonamiento: hasta 512 tokens.")
        #expect(ReasoningSetting.reportText("auto:256") == "Razonamiento: hasta 256 tokens.")
        #expect(ReasoningSetting.reportText("off") == "Razonamiento: desactivado.")
        #expect(ReasoningSetting.reportText(nil).hasPrefix("Razonamiento: sin dato"))
    }

    @Test func reportsWithoutTheFieldsStillDecode() throws {
        let report = CapabilityReport(modelKey: "gguf:a.gguf:1", modelTitle: "A", temperature: 0.2,
                                      reasoning: "auto:512", answerLength: 800, date: Date(timeIntervalSince1970: 0),
                                      results: [])
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(CapabilityReport.self, from: data)
        #expect(decoded.reasoning == "auto:512")
        #expect(decoded.answerLength == 800)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["reasoning"] = nil
        object["answerLength"] = nil
        let old = try JSONSerialization.data(withJSONObject: object)
        let older = try JSONDecoder().decode(CapabilityReport.self, from: old)
        #expect(older.reasoning == nil)
        #expect(older.answerLength == nil)
        #expect(older.modelKey == "gguf:a.gguf:1")
    }
}

@Suite struct ProseMarkdownTests {
    private static func runs(_ text: AttributedString) -> [(String, InlinePresentationIntent?)] {
        text.runs.map { (String(text[$0.range].characters), $0.inlinePresentationIntent) }
    }

    @Test func boldItalicAndCodeAreStyledWithTheirMarkersRemoved() {
        let text = ProseMarkdown.attributed("Usa **754** o *755* con `chmod`.")
        #expect(String(text.characters) == "Usa 754 o 755 con chmod.")
        let styled = Self.runs(text).filter { $0.1 != nil }
        #expect(styled.map(\.0) == ["754", "755", "chmod"])
        #expect(styled.map(\.1) == [.stronglyEmphasized, .emphasized, .code])
    }

    @Test func linksBecomeTextWithTheirAddress() {
        let text = ProseMarkdown.attributed("Lee [la guía](https://example.com/g) y [x](javascript:alert(1)).")
        #expect(text.runs.allSatisfy { $0.link == nil })
        #expect(String(text.characters).contains("la guía (https://example.com/g)"))
        #expect(!String(text.characters).contains("]("))
    }

    @Test func htmlAndLineBreaksStayAsWritten() {
        let prose = "Línea 1\n<script>alert(1)</script>\n  - item &amp;"
        let text = ProseMarkdown.attributed(prose)
        #expect(String(text.characters).contains("<script>alert(1)</script>"))
        #expect(String(text.characters).contains("Línea 1\n"))
        #expect(String(text.characters).contains("  - item"))
    }

    /// Formatting is for display only: commands come from the raw reply's blocks, untouched by it.
    @Test func commandsAreParsedFromTheRawReplyAsBefore() {
        let reply = "Ejecuta **esto**:\n```bash\nchmod 754 *.sh\n```\nResultado: $\\boxed{754}$"
        let segments = CodeBlockParser.parse(reply)
        let code = segments.compactMap { segment -> CodeBlock? in
            if case .code(let block) = segment { return block }
            return nil
        }
        #expect(code.count == 1)
        #expect(code.first?.candidates.map(\.text) == ["chmod 754 *.sh"])
        let prose = segments.compactMap { segment -> String? in
            if case .prose(let text) = segment { return text }
            return nil
        }
        #expect(prose.joined().contains("$\\boxed{754}$"))
    }
}
