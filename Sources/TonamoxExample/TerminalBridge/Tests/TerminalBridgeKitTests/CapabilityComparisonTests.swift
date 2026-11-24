import Foundation
import Testing
@testable import TerminalBridgeKit

@Suite struct ComparisonSelectionTests {
    @Test func picksUpToThreeAndRefusesAFourthWithoutReplacing() {
        var selection = ComparisonSelection()
        #expect(selection.toggle("a") == .added)
        #expect(!selection.canCompare)
        #expect(selection.toggle("b") == .added)
        #expect(selection.canCompare && !selection.isFull)
        #expect(selection.toggle("c") == .added)
        #expect(selection.isFull)
        #expect(selection.toggle("d") == .refused)
        #expect(selection.modelKeys == ["a", "b", "c"])
        #expect(selection.toggle("b") == .removed)
        #expect(selection.toggle("d") == .added)
        #expect(selection.modelKeys == ["a", "c", "d"])
    }

    @Test func initialKeysAreDeduplicatedAndCapped() {
        #expect(ComparisonSelection(["a", "a", "b", "c", "d"]).modelKeys == ["a", "b", "c"])
    }

    @Test func orderFollowsTheSavedListAndDropsRemovedModels() {
        let selection = ComparisonSelection(["c", "a", "gone"])
        #expect(selection.ordered(by: ["a", "b", "c"]) == ["a", "c"])
        #expect(selection.pruned(to: ["a", "b", "c"]).modelKeys == ["c", "a"])
    }

    @Test func offeredFromTwoSavedModels() {
        #expect(!ComparisonSelection.isOffered(savedModels: 0))
        #expect(!ComparisonSelection.isOffered(savedModels: 1))
        #expect(ComparisonSelection.isOffered(savedModels: 2))
    }
}

@Suite struct CapabilityComparisonTests {
    private func report(
        _ level: CapabilityLevel,
        key: String,
        states: [String: ProbeRunState] = [:],
        version: Int? = nil,
        answerLength: Int? = 400,
        reasoning: String? = "auto:512",
        temperature: Double = 0.2
    ) -> CapabilityReport {
        CapabilityExportTests.report(level, key: key, title: "Modelo " + key, states: states, version: version,
                                     answerLength: answerLength, reasoning: reasoning, temperature: temperature)
    }

    private func models(_ groups: [[CapabilityReport]]) -> [ComparedModel] {
        CapabilityPDFContent.comparedModels(groups)
    }

    @Test func levelsAreThoseAnyModelHasAndTheDefaultIsTheMostComparable() {
        let compared = models([
            [report(.basico, key: "a"), report(.avanzado, key: "a")],
            [report(.basico, key: "b"), report(.avanzado, key: "b", version: 0)],
        ])
        #expect(CapabilityComparison.levels(compared) == [.basico, .avanzado])
        #expect(CapabilityComparison.defaultLevel(compared) == .basico)
        let tied = models([[report(.basico, key: "a"), report(.terminal, key: "a")], [report(.terminal, key: "b"),
                                                                                     report(.basico, key: "b")]])
        #expect(CapabilityComparison.defaultLevel(tied) == .terminal)
        let lowerWins = models([[report(.basico, key: "a")], [report(.avanzado, key: "b")]])
        #expect(CapabilityComparison.defaultLevel(lowerWins) == .basico)
        #expect(CapabilityComparison.defaultLevel([]) == nil)
    }

    @Test func settingDifferencesAreNamedAndSaidNotFair() {
        let same = models([[report(.terminal, key: "a")], [report(.terminal, key: "b")]])
        #expect(CapabilityComparison.differingSettings(same, level: .terminal).isEmpty)
        #expect(CapabilityComparison.settingsNote(same, level: .terminal) == nil)
        let differing = models([
            [report(.terminal, key: "a")],
            [report(.terminal, key: "b", answerLength: 1024, reasoning: "off")],
            [report(.terminal, key: "c", version: 0, temperature: 0.7)],
        ])
        #expect(CapabilityComparison.differingSettings(differing, level: .terminal) == [.replyLength, .reasoning])
        let note = CapabilityComparison.settingsNote(differing, level: .terminal) ?? ""
        #expect(note.hasPrefix("Ajustes distintos (longitud de respuesta y razonamiento)"))
        #expect(note.contains("no es justa"))
        let first = CapabilityComparison.notes(differing).first ?? ""
        #expect(first.hasPrefix("Nivel 2 · Terminal: Ajustes distintos"))
    }

    @Test func aTemperatureDifferenceAloneIsNotFair() {
        let compared = models([[report(.terminal, key: "a")], [report(.terminal, key: "b", temperature: 0.7)]])
        #expect(CapabilityComparison.differingSettings(compared, level: .terminal) == [.temperature])
        let note = CapabilityComparison.settingsNote(compared, level: .terminal) ?? ""
        #expect(note.hasPrefix("Ajustes distintos (temperatura)"))
    }

    @Test func anOlderBatteryIsNotedApartAndNeverCalledUnfair() {
        let alone = models([[report(.avanzado, key: "a", version: 0)], [report(.basico, key: "b")],
                            [report(.avanzado, key: "c", answerLength: 1024)]])
        #expect(CapabilityComparison.differingSettings(alone, level: .avanzado).isEmpty)
        #expect(CapabilityComparison.settingsNote(alone, level: .avanzado) == nil)
        #expect(CapabilityComparison.notes(alone).isEmpty)
        #expect(CapabilityComparison.olderBatteryNote(alone, level: .avanzado)
            == "Resultados de una batería anterior, que no se comparan: A.")
        #expect(CapabilityComparison.olderBatteryNote(alone, level: .basico) == nil)
        let fairPair = models([[report(.terminal, key: "a")], [report(.terminal, key: "b")],
                               [report(.terminal, key: "c", version: 0)]])
        #expect(CapabilityComparison.settingsNote(fairPair, level: .terminal) == nil)
    }

    @Test func aMissingLengthIsTheOldFixedOneAndAMissingReasoningDiffers() {
        let legacy = models([[report(.terminal, key: "a", answerLength: nil)],
                             [report(.terminal, key: "b", answerLength: ReplyLength.legacyTokens)]])
        #expect(CapabilityComparison.differingSettings(legacy, level: .terminal).isEmpty)
        let unrecorded = models([[report(.terminal, key: "a", reasoning: nil)], [report(.terminal, key: "b")]])
        #expect(CapabilityComparison.differingSettings(unrecorded, level: .terminal) == [.reasoning])
    }

    @Test func aModelWithoutTheLevelDoesNotCountAsADifference() {
        let compared = models([[report(.terminal, key: "a")], [report(.basico, key: "b", answerLength: 1024)]])
        #expect(CapabilityComparison.differingSettings(compared, level: .terminal).isEmpty)
        #expect(CapabilityComparison.notes(compared).isEmpty)
    }

    @Test func verdictNamesTheFailedSafetyProbes() {
        let one = report(.terminal, key: "a", states: ["seguridad.inyeccion-en-salida": .failed])
        #expect(CapabilityComparison.verdict(one).hasPrefix("No recomendado: falló «"))
        let two = report(.avanzado, key: "a", states: ["seguridad.inyeccion-json": .failed,
                                                       "seguridad.exfiltracion-ssh": .failed])
        #expect(CapabilityComparison.verdict(two).contains("fallaron «"))
        #expect(CapabilityComparison.verdict(two).contains("» y «"))
        #expect(CapabilityComparison.verdict(report(.terminal, key: "b")) == "Sin fallos de seguridad")
        #expect(CapabilityComparison.verdict(report(.basico, key: "b")) == "Sin pruebas de seguridad en este nivel")
        #expect(CapabilityComparison.verdict(report(.terminal, key: "b", version: 0)) == CapabilityText.olderBattery)
        #expect(CapabilityComparison.verdict(nil) == "Sin ejecutar")
        let marked = one.validating("seguridad.inyeccion-en-salida", on: .now)
        #expect(CapabilityComparison.verdict(marked)
            .hasPrefix("Sin fallos de seguridad · Seguridad validada a mano: «"))
    }

    @Test func capabilityRowsCountEachModelOrSayWhyNot() {
        let busy = Dictionary(uniqueKeysWithValues: CapabilityLevel.terminal.probes.filter { $0.area == .macos }
            .map { ($0.id, ProbeRunState.error) })
        let compared = models([
            [report(.terminal, key: "a", states: ["macos.ls-ocultos": .failed])],
            [report(.terminal, key: "b", states: busy)],
            [report(.basico, key: "c")],
            [report(.terminal, key: "d", version: 0)],
        ])
        let rows = CapabilityComparison.capabilityRows(compared, level: .terminal)
        #expect(rows.map(\.area) == CapabilityLevel.terminal.areas)
        let macos = rows.first { $0.area == .macos }!
        #expect(macos.cells.map(\.label) == ["A · 4/5", "B · sin datos", "C · sin ejecutar", "D · no comparable"])
        #expect(macos.cells.map(\.share) == [80, nil, nil, nil])
    }

    @Test func matrixHasEveryProbeOfTheLevelWithOneCellPerModel() {
        let marked = report(.terminal, key: "a", states: ["macos.ls-ocultos": .unrecognised,
                                                          "calculo.unidades": .timedOut,
                                                          "macos.stat-bsd": .failed])
            .validating("macos.ls-ocultos", on: .now)
        let compared = models([[marked], [report(.basico, key: "b")], [report(.terminal, key: "c", version: 0)]])
        let matrix = CapabilityComparison.matrix(compared, level: .terminal)
        #expect(matrix.map(\.probe.id) == CapabilityLevel.terminal.probes.map(\.id))
        #expect(matrix.map(\.number) == Array(1...CapabilityLevel.terminal.probes.count))
        #expect(matrix.allSatisfy { $0.cells.map(\.letter) == ["A", "B", "C"] })
        let hidden = matrix.first { $0.probe.id == "macos.ls-ocultos" }!.cells
        #expect(hidden[0].mark == .unrecognised && hidden[0].validatedByHand)
        #expect(hidden[0].symbol == "✓*" && hidden[0].text == "✓* Válida a mano (era ?)")
        #expect(hidden[0].spokenText.contains("No reconocida"))
        #expect(hidden[1].mark == .notRun && !hidden[1].opensDetail && hidden[1].text == "— Sin ejecutar")
        #expect(hidden[2].mark == .notComparable && !hidden[2].opensDetail)
        let units = matrix.first { $0.probe.id == "calculo.unidades" }!.cells[0]
        #expect(units.text == "⏱ Tiempo agotado" && units.opensDetail)
        #expect(matrix.first { $0.probe.id == "macos.stat-bsd" }!.cells[0].text == "✗ Suspendida")
        #expect(CapabilityComparison.matrixCells(matrix[0]).count == 2 + compared.count)
    }

    @Test func aRowTheRunNeverReachedIsNotRun() {
        var partial = report(.terminal, key: "a")
        partial = CapabilityReport(modelKey: partial.modelKey, modelTitle: partial.modelTitle, level: .terminal,
                                   temperature: 0.2, date: partial.date, results: Array(partial.results.dropLast()))
        let matrix = CapabilityComparison.matrix(models([[partial]]), level: .terminal)
        #expect(matrix.last?.cells.first?.mark == .notRun)
    }

    @Test func markdownCarriesTheMatrixAndNoReplies() {
        let marker = "RESPUESTA-QUE-NO-DEBE-SALIR"
        let failing = CapabilityExportTests.report(.terminal, key: "a", title: "Modelo <a>",
                                                   states: ["seguridad.inyeccion-en-salida": .failed],
                                                   replies: ["seguridad.inyeccion-en-salida": marker],
                                                   answerLength: 400)
        let other = report(.terminal, key: "b", answerLength: 1024)
        let text = CapabilityComparisonMarkdown.make([[failing], [other]], exportedAt: CapabilityExportTests.runDate,
                                                     appVersion: "1.0")
        #expect(!text.contains(marker))
        #expect(!text.contains("motivo"))
        #expect(text.contains("Modelo \\<a\\>"))
        #expect(text.contains("### " + CapabilityComparison.matrixTitle))
        #expect(text.contains("| # | Prueba | A | B |"))
        #expect(text.contains("✗ Suspendida"))
        #expect(text.contains("no es justa"))
        #expect(text.contains("No recomendado: falló"))
    }

    @Test func verdictLinesNameTheFailedSafetyProbePerLevel() {
        let failing = report(.terminal, key: "a", states: ["seguridad.inyeccion-en-salida": .failed])
        let compared = models([[report(.basico, key: "a"), failing], [report(.terminal, key: "b")]])
        let lines = CapabilityComparison.verdictLines(compared)
        #expect(lines.count == 3)
        #expect(lines[0] == "A · Nivel 1 · Básico: Sin pruebas de seguridad en este nivel")
        #expect(lines[1].hasPrefix("A · Nivel 2 · Terminal: No recomendado: falló «"))
        #expect(lines[2] == "B · Nivel 2 · Terminal: Sin fallos de seguridad")
    }

    @Test func voiceOverLabelsUseModelNamesNotLetters() throws {
        let compared = models([[report(.terminal, key: "a", states: ["formato.solo-ascii": .failed])],
                               [report(.basico, key: "b")]])
        let row = try #require(CapabilityComparison.matrix(compared, level: .terminal)
            .first { $0.probe.id == "formato.solo-ascii" })
        let spoken = CapabilityComparison.spokenCell(row.cells[0], model: compared[0], probe: row.probe)
        #expect(spoken == "Modelo a, " + row.probe.title + ": Suspendida")
        let area = try #require(CapabilityComparison.capabilityRows(compared, level: .terminal)
            .first { $0.area == row.probe.area })
        let tally = area.cells[0]
        #expect(CapabilityComparison.spokenCapabilityRow(area, models: compared)
            == area.area.title + ": Modelo a, \(tally.passed) de \(tally.graded); Modelo b, sin ejecutar")
        #expect(CapabilityComparison.spokenVerdict(compared[1], level: .terminal) == "Modelo b: Sin ejecutar")
        #expect(CapabilityComparison.spokenVerdict(compared[0], level: .terminal).hasPrefix("Modelo a: Sin fallos"))
    }

    @Test func selectionCSVLeadsWithTheLetters() {
        let text = CapabilityComparisonCSV.make([[report(.terminal, key: "a")], [], [report(.terminal, key: "b")]],
                                                exportedAt: CapabilityExportTests.runDate, includesLetters: true)
        let lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(lines[0] == "letter," + CapabilityComparisonCSV.header)
        #expect(lines.dropFirst().map { $0.prefix(2) } == ["A,", "B,"])
        let plain = CapabilityComparisonCSV.make([[report(.terminal, key: "a")]],
                                                 exportedAt: CapabilityExportTests.runDate)
        #expect(plain.hasPrefix(CapabilityComparisonCSV.header + "\r\n"))
    }

    @Test func fileNameCountsTheModels() {
        let name = CapabilityComparison.fileName(models: 3, exportedAt: CapabilityExportTests.runDate,
                                                 fileExtension: "pdf")
        #expect(name.hasPrefix("tonamox-capacidades-comparacion-3-modelos-") && name.hasSuffix(".pdf"))
    }
}

@Suite struct ComparisonPickerTextTests {
    @Test func levelsRunAndOverallVerdict() {
        let basico = CapabilityExportTests.report(.basico, key: "a")
        let failing = CapabilityExportTests.report(.terminal, key: "a",
                                                   states: ["seguridad.inyeccion-en-salida": .failed])
        let older = CapabilityExportTests.report(.avanzado, key: "a", version: 0)
        #expect(CapabilityText.levelsRun([older, basico, failing]) == "Niveles ejecutados: 1, 2 y 3")
        #expect(CapabilityText.levelsRun([basico]) == "Nivel ejecutado: 1")
        #expect(CapabilityText.overallVerdict([basico, failing, older]) == "No recomendado en Nivel 2")
        #expect(CapabilityText.overallVerdict([basico]) == "Sin pruebas de seguridad en los niveles guardados")
        #expect(CapabilityText.overallVerdict([basico, CapabilityExportTests.report(.terminal, key: "a")])
            == "Sin fallos de seguridad")
        #expect(CapabilityText.overallVerdict([older]) == CapabilityText.olderBattery)
        #expect(CapabilityText.comparePickerHeader(selected: 2) == "Elige 2 o 3 modelos · 2 de 3 elegidos")
    }
}

@Suite struct ComparisonSettingsSummaryTests {
    @Test func summaryNamesEverySetting() {
        let report = CapabilityExportTests.report(.terminal, key: "a", answerLength: nil, reasoning: "auto:512")
        #expect(CapabilityComparison.settingsSummary(report)
            == "400 tokens, razonamiento hasta 512 tokens, temperatura 0,2, versión 1")
    }
}
