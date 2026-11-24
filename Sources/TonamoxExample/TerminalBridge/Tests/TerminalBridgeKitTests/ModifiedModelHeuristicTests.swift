import Foundation
import Testing
@testable import TerminalBridgeKit

@Suite struct ModifiedModelHeuristicTests {
    @Test(arguments: [
        "AtomicChat/LFM3-1.7B-Uncensored-AD-GGUF",
        "LFM3-1.7B-Uncensored-AD-Q4_K_M.gguf",
        "LFM3-1.7B-Uncensored-AD",
        "mlx-community/Josiefied-Qwen3-4B-abliterated-v1-4bit",
        "Meta-Llama-3.1-8B-Instruct-abliterated-Q4_K_M.gguf",
        "Llama 3.1 8B Abliterated (GGUF)",
        "mlx:llama32_3b_uncensored_gguf",
        "gguf:LFM3-1.7B-Uncensored-AD-Q4_K_M.gguf:1229000000",
        "Qwen3Uncensored",
        "someone/Qwen3-4B-Instruct-heretic",
        "someone/Mistral-7B-Decensored",
        "someone/Phi-4-unfiltered",
        "someone/Gemma-3-unaligned",
        "someone/llama-nsfw-chat",
        "someone/Qwen-Jailbroken-8B",
        "someone/jailbreak-llama",
        "someone/Qwen3-NoRefusal",
        "someone/qwen3-no-refusals",
        "someone/qwen3_refusal_removed",
        "someone/qwen3-refusals-removed",
        "UNCENSORED",
        "LlamaUncensored",
        "WizardUncensoredGGUF",
        "model-uncensoredv2",
        "Qwen3-AbliteratedV1"
    ])
    func namesWithATermAreMarked(_ name: String) {
        #expect(ModifiedModelHeuristic.matches(name))
    }

    @Test(arguments: [
        "censored",
        "someone/Censored-Model",
        "AtomicChat/LFM2.5-1.2B-Instruct-GGUF",
        "AtomicChat/Qwen3-4B-Instruct-2507-GGUF",
        "LiquidAI/LFM2-1.2B",
        "bartowski/Llama-3.2-3B-Instruct-GGUF",
        "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
        "mlx:qwen3_4b_mlx",
        "someone/heretical-poetry",
        "HERETICAL",
        "someone/Heretical-Llama",
        "someone/llamauncensored",
        "someone/refusal-classifier",
        "someone/nonrefusal",
        "Josiefied Qwen3 4B",
        ""
    ])
    func namesWithoutATermAreNotMarked(_ name: String) {
        #expect(!ModifiedModelHeuristic.matches(name))
    }

    @Test func anyFieldOrTagIsEnough() {
        #expect(ModifiedModelHeuristic.applies(repoID: "a/b", fileName: "b-abliterated.gguf"))
        #expect(ModifiedModelHeuristic.applies(repoID: "a/b", displayName: "B Uncensored"))
        #expect(ModifiedModelHeuristic.applies(repoID: "a/b", tags: ["gguf", "abliteration"]))
        #expect(!ModifiedModelHeuristic.applies(repoID: "a/b", fileName: "b.gguf", displayName: "B",
                                               tags: ["gguf", "text-generation", "conversational"]))
        #expect(!ModifiedModelHeuristic.applies())
    }

    @Test func huggingFacesAdultContentTagCountsInTagsOnly() {
        #expect(ModifiedModelHeuristic.applies(repoID: "a/b", tags: ["gguf", "Not-For-All-Audiences"]))
        #expect(!ModifiedModelHeuristic.applies(repoID: "a/not-for-all-audiences"))
    }

    @Test func aCatalogueFlagMarksAFileWhoseNameCarriesNoTerm() {
        let dolphin = "Dolphin3.0-Qwen2.5-1.5B-Q4_K_M.gguf"
        #expect(!ModifiedModelHeuristic.applies(repoID: "bartowski/Dolphin3.0-Qwen2.5-1.5B-GGUF", fileName: dolphin,
                                                displayName: "Dolphin 3.0 Qwen2.5 1.5B (GGUF)"))
        #expect(ModifiedModelHeuristic.applies(fileName: dolphin, displayName: dolphin, flaggedFileNames: [dolphin]))
        #expect(!ModifiedModelHeuristic.applies(fileName: "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
                                                flaggedFileNames: [dolphin]))
        #expect(ModifiedModelHeuristic.applies(fileName: "b.gguf", repoID: "someone/B-abliterated-GGUF",
                                               flaggedFileNames: []))
    }

    @Test func everyListedTermMatchesOnItsOwn() {
        for term in ModifiedModelHeuristic.terms {
            #expect(ModifiedModelHeuristic.matches("x-" + term + "-y"), "\(term)")
        }
    }

    // MARK: Reports

    @Test func aReportTakesTheFlagFromItsNamesOrFromTheRun() {
        let plain = CapabilityExportTests.report(key: "mlx:qwen", title: "Qwen 3 4B")
        #expect(!plain.safetyFiltersRemoved)
        let named = CapabilityExportTests.report(key: "gguf:LFM3-1.7B-Uncensored-AD-Q4_K_M.gguf:12", title: "LFM3")
        #expect(named.safetyFiltersRemoved)
        let flagged = CapabilityReport(modelKey: "mlx:josiefied_qwen3_4b", modelTitle: "Josiefied Qwen3 4B",
                                       temperature: 0.2, date: CapabilityExportTests.runDate, results: [],
                                       safetyFiltersRemoved: true)
        #expect(flagged.safetyFiltersRemoved)
        #expect(flagged.validating("x", on: nil).safetyFiltersRemoved)
    }

    @Test func theFlagIsStoredOnlyWhenSetAndOldReportsComputeIt() throws {
        let flagged = CapabilityReport(modelKey: "mlx:josiefied_qwen3_4b", modelTitle: "Josiefied Qwen3 4B",
                                       temperature: 0.2, date: CapabilityExportTests.runDate, results: [],
                                       safetyFiltersRemoved: true)
        let stored = try JSONEncoder().encode(flagged)
        #expect(String(bytes: stored, encoding: .utf8)?.contains("\"safetyFiltersRemoved\":true") == true)
        #expect(try JSONDecoder().decode(CapabilityReport.self, from: stored).safetyFiltersRemoved)

        let plain = CapabilityExportTests.report()
        let plainText = String(bytes: try JSONEncoder().encode(plain), encoding: .utf8)
        #expect(plainText?.contains("safetyFiltersRemoved") == false)

        // A report saved before the flag existed.
        let old = #"{"modelKey":"gguf:LFM3-1.7B-Uncensored-AD-Q4_K_M.gguf:12","modelTitle":"LFM3","batteryVersion":1,"#
            + #""temperature":0.2,"date":0,"results":[]}"#
        #expect(try JSONDecoder().decode(CapabilityReport.self, from: Data(old.utf8)).safetyFiltersRemoved)
        let oldPlain = old.replacingOccurrences(of: "-Uncensored-AD", with: "")
        #expect(try !JSONDecoder().decode(CapabilityReport.self, from: Data(oldPlain.utf8)).safetyFiltersRemoved)
    }

    // MARK: Exports

    static let modified = "gguf:LFM3-1.7B-Uncensored-AD-Q4_K_M.gguf:12"

    @Test func jsonCarriesABooleanForEveryModel() throws {
        let options = CapabilityExportOptions()
        for (key, expected) in [(Self.modified, true), ("mlx:qwen", false)] {
            let data = try CapabilityExport.json([CapabilityExportTests.report(key: key)], options: options,
                                                 exportedAt: CapabilityExportTests.exportDate)
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["safetyFiltersRemoved"] as? Bool == expected)
        }
    }

    @Test func csvEndsEveryRowWithTheFlag() throws {
        let csv = CapabilityComparisonCSV.make([[CapabilityExportTests.report(key: Self.modified)],
                                                [CapabilityExportTests.report(key: "mlx:qwen", version: 0)]],
                                               exportedAt: CapabilityExportTests.exportDate)
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(lines[0].hasSuffix(",excluded,safety_filters_removed,claude_correcta,claude_incorrecta,claude_dudosa"))
        let flags = lines.dropFirst().map { $0.components(separatedBy: ",").dropLast(3).last ?? "" }
        #expect(Set(flags) == ["true", "false"])
        let header = lines[0].components(separatedBy: ",")
        #expect(lines.dropFirst().allSatisfy { $0.components(separatedBy: ",").count == header.count })
    }

    @Test func csvGivesEveryRowOfAModelItsModelFlag() {
        let old = CapabilityReport(modelKey: "mlx:josiefied_qwen3_4b", modelTitle: "Josiefied Qwen3 4B",
                                   level: .basico, temperature: 0.2, date: CapabilityExportTests.runDate, results: [])
        let new = CapabilityReport(modelKey: "mlx:josiefied_qwen3_4b", modelTitle: "Josiefied Qwen3 4B",
                                   temperature: 0.2, date: CapabilityExportTests.runDate, results: [],
                                   safetyFiltersRemoved: true)
        let csv = CapabilityComparisonCSV.make([[old, new]], exportedAt: CapabilityExportTests.exportDate)
        let flags = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }.dropFirst()
            .map { $0.components(separatedBy: ",").dropLast(3).last ?? "" }
        #expect(flags == ["true", "true"])
    }

    @Test func markdownAndPDFContentSayWhyItsSafetyFailuresAreExpected() throws {
        let failing = CapabilityExportTests.report(key: Self.modified, title: "LFM3 1.7B",
                                                   states: ["seguridad.inyeccion-en-salida": .failed])
        #expect(failing.notRecommended)
        let markdown = CapabilityExport.markdown([failing], options: .init(),
                                                 exportedAt: CapabilityExportTests.exportDate)
        #expect(markdown.contains("> **" + ModifiedModelHeuristic.label + ".**"))
        #expect(markdown.contains("se eliminaron"))
        #expect(markdown.contains(CapabilityText.notRecommended(failing)))
        let note = try #require(ModifiedModelHeuristic.expectedFailuresNote([failing]))
        #expect(note.hasSuffix("«No recomendado» se mantiene."))
        #expect(CapabilityExport.safetyFiltersLines([failing]) == [ModifiedModelHeuristic.label + ".", note])
        let plain = CapabilityExportTests.report()
        #expect(CapabilityExport.safetyFiltersLines([plain]).isEmpty)
        #expect(!CapabilityExport.markdown([plain], options: .init(), exportedAt: CapabilityExportTests.exportDate)
            .contains(ModifiedModelHeuristic.label))
    }

    @Test func theNoteNamesOnlyAVerdictAndProbesTheReportsHave() throws {
        let passing = CapabilityExportTests.report(key: Self.modified)
        #expect(!passing.notRecommended)
        let note = try #require(ModifiedModelHeuristic.expectedFailuresNote([passing]))
        #expect(note.contains("pruebas de Seguridad"))
        #expect(!note.contains("No recomendado"))

        let basic = CapabilityExportTests.report(.basico, key: Self.modified)
        #expect(!CapabilityLevel.basico.hasSafetyProbes)
        #expect(ModifiedModelHeuristic.expectedFailuresNote([basic]) == nil)
        #expect(CapabilityExport.safetyFiltersLines([basic]) == [ModifiedModelHeuristic.label + "."])
        #expect(ModifiedModelHeuristic.expectedFailuresNote([CapabilityExportTests.report()]) == nil)

        let models = CapabilityPDFContent.comparedModels([[basic]])
        #expect(CapabilityPDFContent.safetyFiltersNote(models) == "Modelo modificado, sin filtros de seguridad: A.")
        let passingNote = CapabilityPDFContent.safetyFiltersNote(CapabilityPDFContent.comparedModels([[passing]]))
        #expect(passingNote?.hasSuffix("esas protecciones se eliminaron.") == true)
        let failing = CapabilityExportTests.report(key: Self.modified,
                                                   states: ["seguridad.inyeccion-en-salida": .failed])
        let failingNote = CapabilityPDFContent.safetyFiltersNote(CapabilityPDFContent.comparedModels([[failing]]))
        #expect(failingNote?.hasSuffix("«No recomendado» se mantiene.") == true)
    }

    @Test func comparisonsMarkTheModifiedModel() {
        let models = CapabilityPDFContent.comparedModels([
            [CapabilityExportTests.report(key: "mlx:qwen", title: "Qwen")],
            [CapabilityExportTests.report(key: Self.modified, title: "LFM3")]
        ])
        #expect(CapabilityPDFContent.legendLines(models) == ["A · Qwen", "B · LFM3 · Sin filtros"])
        #expect(CapabilityPDFContent.verdictCells(models[1])[1] == "LFM3 · Sin filtros")
        let note = CapabilityPDFContent.safetyFiltersNote(models)
        #expect(note?.hasPrefix("Modelo modificado, sin filtros de seguridad: B.") == true)
        #expect(CapabilityPDFContent.comparisonNotes(models).first == note)
        #expect(CapabilityComparison.notes(models).first == note)
        #expect(CapabilityPDFContent.safetyFiltersNote([models[0]]) == nil)
        let markdown = CapabilityComparisonMarkdown.make(models.map(\.reports),
                                                         exportedAt: CapabilityExportTests.exportDate)
        #expect(markdown.contains("- **B** · LFM3 · **" + ModifiedModelHeuristic.label + "**"))
        #expect(markdown.contains("- **A** · Qwen\n"))
    }
}
