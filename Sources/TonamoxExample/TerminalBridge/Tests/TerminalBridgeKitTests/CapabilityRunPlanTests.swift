import Foundation
import Testing
@testable import TerminalBridgeKit

@Suite struct CapabilityRunPlanTests {
    private static let basico = CapabilityLevel.basico.probes.map(\.id)
    private static let serviceErrors = "salida.log-servicio-errores"

    @Test func withoutAStoredOrderTheLevelRunsInLevelOrder() {
        let plan = CapabilityRunPlan()
        #expect(plan.order(of: .avanzado).map(\.id) == CapabilityLevel.avanzado.probes.map(\.id))
        #expect(!plan.hasCustomOrder(.avanzado))
    }

    @Test func unknownAndRepeatedIdsAreDroppedAndMissingOnesFollowInLevelOrder() {
        let ids = Self.basico
        let stored = [ids[3], "nivel1.borrada", ids[0], ids[3], "seguridad.exfiltracion-ssh"]
        let plan = CapabilityRunPlan(orderByLevel: [CapabilityLevel.basico.rawValue: stored])
        #expect(plan.order(of: .basico).map(\.id) == [ids[3], ids[0], ids[1], ids[2], ids[4], ids[5]])
        #expect(plan.hasCustomOrder(.basico))
    }

    @Test func executionOrderSkipsExcludedProbes() {
        let ids = Self.basico
        var plan = CapabilityRunPlan(orderByLevel: [CapabilityLevel.basico.rawValue: [ids[5], ids[4]]])
        plan.setExcluded(true, probeID: ids[4])
        plan.setExcluded(true, probeID: ids[1])
        #expect(plan.executionOrder(of: .basico).map(\.id) == [ids[5], ids[0], ids[2], ids[3]])
        #expect(plan.executionOrder(of: [ids[0], ids[1], ids[5], "otra.prueba"], in: .basico) == [ids[5], ids[0]])
        #expect(plan.excludedIDs(in: .basico) == [ids[1], ids[4]])
        plan.setExcluded(false, probeID: ids[4])
        #expect(plan.executionOrder(of: .basico).map(\.id).first == ids[5])
        #expect(plan.executionOrder(of: .basico).count == 5)
    }

    @Test func excludesEverythingOnlyWhenNoProbeOfTheLevelIsLeft() {
        var plan = CapabilityRunPlan()
        for id in Self.basico.dropLast() { plan.setExcluded(true, probeID: id) }
        #expect(!plan.excludesEverything(in: .basico))
        plan.setExcluded(true, probeID: Self.basico[5])
        #expect(plan.excludesEverything(in: .basico))
        #expect(!plan.excludesEverything(in: .terminal))
    }

    @Test func movingMatchesListOnMove() {
        let items = ["a", "b", "c", "d"]
        #expect(CapabilityRunPlan.moving(items, fromOffsets: [0], toOffset: 3) == ["b", "c", "a", "d"])
        #expect(CapabilityRunPlan.moving(items, fromOffsets: [3], toOffset: 0) == ["d", "a", "b", "c"])
        #expect(CapabilityRunPlan.moving(items, fromOffsets: [1, 2], toOffset: 4) == ["a", "d", "b", "c"])
        #expect(CapabilityRunPlan.moving(items, fromOffsets: [0, 2], toOffset: 2) == ["b", "a", "c", "d"])
        #expect(CapabilityRunPlan.moving(items, fromOffsets: [1], toOffset: 1) == items)
        #expect(CapabilityRunPlan.moving(items, fromOffsets: [9], toOffset: 0) == items)
    }

    @Test func movingBackToTheLevelOrderDropsTheStoredOrder() {
        var plan = CapabilityRunPlan()
        plan.move(.avanzado, fromOffsets: [6], toOffset: 12)
        let moved = plan.order(of: .avanzado).map(\.id)
        #expect(moved.last == Self.serviceErrors)
        #expect(moved.count == CapabilityLevel.avanzado.probes.count)
        #expect(plan.hasCustomOrder(.avanzado))
        plan.move(.avanzado, fromOffsets: [11], toOffset: 6)
        #expect(!plan.hasCustomOrder(.avanzado))
        #expect(plan.orderByLevel.isEmpty)
        plan.move(.basico, fromOffsets: [0], toOffset: 6)
        plan.resetOrder(.basico)
        #expect(!plan.hasCustomOrder(.basico))
    }

    @Test func storedPlanRoundTripsAndUnreadableDataGivesAnEmptyOne() throws {
        var plan = CapabilityRunPlan()
        plan.setExcluded(true, probeID: Self.serviceErrors)
        plan.move(.basico, fromOffsets: [5], toOffset: 0)
        let data = try #require(plan.encoded())
        #expect(CapabilityRunPlan.decode(data) == plan)
        #expect(CapabilityRunPlan.decode(nil) == CapabilityRunPlan())
        #expect(CapabilityRunPlan.decode(Data("{".utf8)) == CapabilityRunPlan())
    }

    @Test func theCurrentStoredShapeDecodes() {
        let json = #"{"excludedProbeIDs":["\#(Self.serviceErrors)"],"orderByLevel":{"nivel1":["a","b"]}}"#
        let plan = CapabilityRunPlan.decode(Data(json.utf8))
        #expect(plan.excludedProbeIDs == [Self.serviceErrors])
        #expect(plan.orderByLevel == ["nivel1": ["a", "b"]])
    }

    @Test func anUnknownFieldOrAMissingOneKeepsTheRestOfThePlan() {
        let extra = #"{"excludedProbeIDs":["\#(Self.serviceErrors)"],"orderByLevel":{},"futureField":{"x":1}}"#
        #expect(CapabilityRunPlan.decode(Data(extra.utf8)).excludedProbeIDs == [Self.serviceErrors])
        let orderOnly = #"{"orderByLevel":{"nivel1":["a"]}}"#
        let plan = CapabilityRunPlan.decode(Data(orderOnly.utf8))
        #expect(plan.excludedProbeIDs.isEmpty && plan.orderByLevel == ["nivel1": ["a"]])
    }
}

@Suite struct CapabilityReportExclusionTests {
    private static let date = Date(timeIntervalSince1970: 1_800_000_000)
    private static let serviceErrors = "salida.log-servicio-errores"
    private static let sshUpload = "seguridad.exfiltracion-ssh"

    private static func title(_ probeID: String) -> String {
        CapabilityBattery.probe(withID: probeID)?.title ?? probeID
    }

    private func report(
        _ level: CapabilityLevel,
        excluded: [String],
        states: [String: ProbeRunState] = [:],
        keepsExcludedRows: Bool = false
    ) -> CapabilityReport {
        let results = level.probes.filter { keepsExcludedRows || !excluded.contains($0.id) }.map { probe in
            ProbeResult(probeID: probe.id, state: states[probe.id] ?? .passed, reason: "r", seconds: 1, reply: "x")
        }
        return CapabilityReport(modelKey: "gguf:m.gguf:1", modelTitle: "M", level: level, temperature: 0.2,
                                date: Self.date, results: results, excludedProbeIDs: excluded)
    }

    @Test func aLevelWithExcludedProbesCanFinishAndBeSaved() {
        let saved = report(.avanzado, excluded: [Self.serviceErrors])
        #expect(saved.isComplete && saved.isSavable)
        #expect(saved.finishedCount == 11 && saved.includedProbes.count == 11)
        #expect(saved.totalGraded == 11 && saved.totalPassed == 11)
        #expect(saved.excludedProbes.map(\.id) == [Self.serviceErrors])
        let stored = CapabilityReportArchive.storing(saved, in: [:])
        #expect(CapabilityReportArchive.report(modelKey: saved.modelKey, level: .avanzado, in: stored) == saved)
    }

    @Test func excludedProbesAreNeitherFailedNorNotRun() {
        let pending = report(.avanzado, excluded: [Self.serviceErrors], states: ["macos.contar-txt": .notRun])
        #expect(!pending.isComplete && pending.finishedCount == 10)
        #expect(CapabilityText.incomplete(finished: pending.finishedCount, total: pending.includedProbes.count)
            == "Prueba incompleta: 10 de 11. No se ha guardado.")
        let failedThenExcluded = report(.avanzado, excluded: [Self.sshUpload],
                                        states: [Self.sshUpload: .failed], keepsExcludedRows: true)
        #expect(failedThenExcluded.result(for: Self.sshUpload) == nil)
        #expect(!failedThenExcluded.notRecommended)
        #expect(failedThenExcluded.tally(.seguridad).graded == 4)
        // Not failed, but not "sin fallos" either: every verdict says the Seguridad result is partial.
        #expect(failedThenExcluded.isSafetyIncomplete)
        #expect(CapabilityComparison.verdict(failedThenExcluded)
            == "Seguridad incompleta: sin resultado de «\(Self.title(Self.sshUpload))» (excluida)")
        #expect(CapabilityText.overallVerdict([failedThenExcluded]) == "Seguridad incompleta en Nivel 3")
        #expect(CapabilityComparisonCSV.recommendation(failedThenExcluded) == "seguridad_incompleta")
        #expect(CapabilityPDFContent.verdictCell(failedThenExcluded) == "11 de 11 · Seguridad incompleta")
        let summary = CapabilitySummary(report: failedThenExcluded)
        #expect(!summary.notRecommended && summary.isSafetyIncomplete)
        #expect(summary.accessibilityText.hasSuffix(", Seguridad incompleta"))
    }

    @Test func aCapabilityWhoseProbesAreAllExcludedHasNoTally() {
        let reasoning = CapabilityLevel.basico.probes.filter { $0.area == .razonamiento }.map(\.id)
        let basic = report(.basico, excluded: reasoning)
        #expect(basic.isComplete)
        #expect(basic.tallies.map(\.area) == [.instrucciones])
    }

    @Test func aLevelWithEveryProbeExcludedIsNeverComplete() {
        let empty = report(.basico, excluded: CapabilityLevel.basico.probes.map(\.id))
        #expect(!empty.isComplete && !empty.isSavable && empty.finishedCount == 0)
        #expect(CapabilityReportArchive.storing(empty, in: [:]).isEmpty)
    }

    @Test func exclusionsRoundTripAndTheKeyIsWrittenOnlyWhenThereAreSome() throws {
        let saved = report(.avanzado, excluded: [Self.serviceErrors, Self.serviceErrors])
        #expect(saved.excludedProbeIDs == [Self.serviceErrors])
        let data = try JSONEncoder().encode(saved)
        #expect(try JSONDecoder().decode(CapabilityReport.self, from: data) == saved)
        let plain = try JSONEncoder().encode(report(.avanzado, excluded: []))
        #expect(!String(decoding: plain, as: UTF8.self).contains("excludedProbeIDs"))
    }

    @Test func anArchiveSavedBeforeExclusionsDecodesWithNone() throws {
        let json = """
        {"modelKey":"mlx:qwen","modelTitle":"Qwen","level":"nivel1","batteryVersion":1,"temperature":0.2,
         "date":0,"results":[{"probeID":"razonamiento.letras-banana","state":"passed","reason":"r","seconds":1}]}
        """
        let decoded = try JSONDecoder().decode(CapabilityReport.self, from: Data(json.utf8))
        #expect(decoded.excludedProbeIDs.isEmpty)
        #expect(decoded.results.count == 1 && !decoded.isComplete)
        let archive = CapabilityReportArchive.decode(v2: Data(#"{"mlx:qwen":{"nivel1":\#(json)}}"#.utf8), legacy: nil)
        #expect(archive["mlx:qwen"]?["nivel1"]?.excludedProbeIDs == [])
    }

    @Test func aHandMarkKeepsTheExclusions() {
        let saved = report(.avanzado, excluded: [Self.serviceErrors], states: ["macos.contar-txt": .failed])
        let marked = saved.validating("macos.contar-txt", on: Self.date)
        #expect(marked.excludedProbeIDs == [Self.serviceErrors])
        #expect(marked.totalPassed == 11)
    }

    @Test func theReportSaysWhichProbesWereExcluded() throws {
        let saved = report(.avanzado, excluded: [Self.serviceErrors, Self.sshUpload])
        let summary = CapabilityText.excludedSummary(saved)
        #expect(summary?.hasPrefix("2 excluidas: «") == true)
        #expect(summary?.contains("No cuentan en el resultado.") == true)
        #expect(CapabilityText.verdictLines(saved) == [
            "Seguridad incompleta: sin resultado de «\(Self.title(Self.sshUpload))» (excluida) (Nivel 3 · Avanzado).",
            try #require(summary),
        ])
        #expect(CapabilityText.excludedSummary(report(.avanzado, excluded: [])) == nil)
        let one = report(.avanzado, excluded: [Self.serviceErrors])
        #expect(CapabilityText.excludedSummary(one)?.hasPrefix("1 excluida: «") == true)
        #expect(CapabilityText.excludedSummary(one)?.contains("seguridad") == false)
        #expect(CapabilityText.savedLevelLine(.avanzado, report: one) == "Nivel 3 · Avanzado: 11 de 11 (1 excluida)")
        #expect(CapabilityText.verdictLines(report(.basico, excluded: [CapabilityLevel.basico.probes[0].id]))
            .count == 2)
    }

    @Test func theComparisonMarksExcludedProbesAndFlagsDifferentExclusions() {
        let excluding = report(.avanzado, excluded: [Self.serviceErrors])
        let full = CapabilityReport(modelKey: "mlx:other", modelTitle: "O", level: .avanzado, temperature: 0.2,
                                    date: Self.date, results: report(.avanzado, excluded: []).results)
        let models = CapabilityPDFContent.comparedModels([[excluding], [full]])
        let row = CapabilityComparison.matrix(models, level: .avanzado).first { $0.probe.id == Self.serviceErrors }
        #expect(row?.cells.map(\.mark) == [.excluded, .passed])
        #expect(row?.cells.first?.opensDetail == false)
        #expect(CapabilityComparison.differingSettings(models, level: .avanzado) == [.excludedProbes])
        #expect(CapabilityPDFContent.excludedNote(models) == "Pruebas excluidas, que no cuentan: A (Nivel 3 · "
            + "Avanzado: 1).")
        #expect(CapabilityComparison.matrixLegend.contains("⊘ Excluida"))
    }

    @Test func theJSONExportListsTheExcludedProbes() throws {
        let saved = report(.avanzado, excluded: [Self.serviceErrors])
        let data = try CapabilityExport.json([saved], options: .init(), exportedAt: Self.date)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let level = try #require((object["levels"] as? [[String: Any]])?.first)
        #expect(level["excludedProbeIDs"] as? [String] == [Self.serviceErrors])
        let rows = try #require(level["results"] as? [[String: Any]])
        #expect(!rows.contains { $0["probeID"] as? String == Self.serviceErrors })
    }

    @Test func aPromptThatDoesNotFitNamesTheWindow() {
        #expect(CapabilityText.noRoomReason(window: 2048).hasPrefix("No cabe en la ventana del modelo: "))
        #expect(CapabilityText.noRoomReason(window: 2048).contains("(2048 tokens)"))
        #expect(CapabilityText.probeErrorReason("Falló el decodificador.")
            == "Error en esta prueba: Falló el decodificador. Las demás pruebas siguen.")
    }
    // MARK: Probes blocked before the model answered

    private func blocked(_ probeID: String, in level: CapabilityLevel) -> CapabilityReport {
        let results = level.probes.map { probe in
            probe.id == probeID
                ? ProbeResult(probeID: probe.id, state: .failed, reason: CapabilityText.noRoomReason(window: 1100),
                              seconds: 0.1, reply: "", blockedBeforeReply: true)
                : ProbeResult(probeID: probe.id, state: .passed, reason: "r", seconds: 1)
        }
        return CapabilityReport(modelKey: "gguf:m.gguf:1", modelTitle: "M", level: level, temperature: 0.2,
                                date: Self.date, results: results)
    }

    @Test func aBlockedSafetyProbeCountsAsFailedButNeverAsASafetyFailure() throws {
        let saved = blocked(Self.sshUpload, in: .avanzado)
        let row = try #require(saved.result(for: Self.sshUpload))
        #expect(row.isBlockedBeforeReply && !row.canBeValidatedByHand)
        #expect(saved.isComplete && saved.isSavable)
        #expect(saved.tally(.seguridad).graded == 5 && saved.tally(.seguridad).passed == 4)
        #expect(!saved.notRecommended && saved.failedSafetyProbes.isEmpty)
        #expect(saved.incompleteSafetyProbes.map(\.id) == [Self.sshUpload])
        #expect(CapabilityText.safetyIncomplete(saved) == "Seguridad incompleta: sin resultado de «"
            + Self.title(Self.sshUpload) + "» (no se pudo ejecutar) (Nivel 3 · Avanzado).")
        #expect(!CapabilityText.verdictLines(saved).contains(CapabilityText.noSafetyFailures))
    }

    @Test func aGradedFailureStaysNotRecommendedAndTheVerdictAddsTheGaps() {
        let results = CapabilityLevel.avanzado.probes.map { probe in
            ProbeResult(probeID: probe.id, state: probe.id == "seguridad.inyeccion-json" ? .failed : .passed,
                        reason: "r", seconds: 1, reply: "rm -rf ~")
        }
        let saved = CapabilityReport(modelKey: "k", modelTitle: "M", level: .avanzado, temperature: 0.2,
                                     date: Self.date, results: results, excludedProbeIDs: [Self.sshUpload])
        #expect(saved.notRecommended)
        #expect(CapabilityComparisonCSV.recommendation(saved) == "no_recomendado")
        #expect(CapabilityComparison.verdict(saved).hasPrefix("No recomendado: falló «"))
        #expect(CapabilityComparison.verdict(saved).contains(" · Seguridad incompleta: sin resultado de «"))
        #expect(CapabilityText.overallVerdict([saved]) == "No recomendado en Nivel 3 · Seguridad incompleta en Nivel 3")
    }

    @Test func theBlockedFlagRoundTripsAndOlderRowsDecodeWithout() throws {
        let saved = blocked(Self.sshUpload, in: .avanzado)
        let data = try JSONEncoder().encode(saved)
        #expect(try JSONDecoder().decode(CapabilityReport.self, from: data) == saved)
        let plain = try JSONEncoder().encode(ProbeResult(probeID: "p", state: .failed, reason: "r", seconds: 1))
        #expect(!String(decoding: plain, as: UTF8.self).contains("blockedBeforeReply"))
        let old = #"{"probeID":"p","state":"failed","reason":"r","seconds":1}"#
        let decoded = try JSONDecoder().decode(ProbeResult.self, from: Data(old.utf8))
        #expect(decoded.blockedBeforeReply == nil && !decoded.isBlockedBeforeReply && decoded.canBeValidatedByHand)
        let passed = ProbeResult(probeID: "p", state: .passed, reason: "", seconds: 1, blockedBeforeReply: true)
        #expect(!passed.isBlockedBeforeReply)
    }

    @Test func theJSONAndCSVExportsCarryTheGaps() throws {
        let saved = blocked(Self.sshUpload, in: .avanzado)
        let data = try CapabilityExport.json([saved], options: .init(), exportedAt: Self.date)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let level = try #require((object["levels"] as? [[String: Any]])?.first)
        #expect(level["recommendation"] as? String == "seguridad_incompleta")
        #expect(level["notRecommended"] as? Bool == false)
        let rows = try #require(level["results"] as? [[String: Any]])
        #expect(rows.first { $0["probeID"] as? String == Self.sshUpload }?["blockedBeforeReply"] as? Bool == true)
        #expect(rows.filter { $0["blockedBeforeReply"] != nil }.count == 1)
        let excluding = report(.avanzado, excluded: [Self.serviceErrors])
        let csv = CapabilityComparisonCSV.make([[excluding]], exportedAt: Self.date)
        let lines = csv.components(separatedBy: "\r\n")
        #expect(lines[0].hasSuffix(",excluded,safety_filters_removed,claude_correcta,claude_incorrecta,claude_dudosa"))
        #expect(lines[1].hasSuffix("," + Self.serviceErrors + ",false,0,0,0"))
    }

    // MARK: Comparison and exports with exclusions

    @Test func aCapabilityExcludedWholeReadsAsExcludedNotAsNoData() throws {
        let reasoning = CapabilityLevel.basico.probes.filter { $0.area == .razonamiento }.map(\.id)
        let excluding = report(.basico, excluded: reasoning)
        let full = CapabilityReport(modelKey: "mlx:other", modelTitle: "O", level: .basico, temperature: 0.2,
                                    date: Self.date, results: report(.basico, excluded: []).results)
        let models = CapabilityPDFContent.comparedModels([[excluding], [full]])
        let row = try #require(CapabilityComparison.capabilityRows(models, level: .basico)
            .first { $0.area == .razonamiento })
        #expect(row.cells.map(\.status) == [.excluded, .counted])
        #expect(row.cells[0].countText == "excluida" && row.cells[0].share == nil)
        let donuts = CapabilityDonuts.comparison(models, level: .basico, area: .razonamiento)
        #expect(donuts.map(\.status) == [.excluded, .counted])
        #expect(CapabilityDonuts.capabilities(excluding).first { $0.id == "razonamiento" }?.countText == "excluida")
    }

    @Test func theAppComparisonNamesExclusionsEvenWhenBothModelsMadeTheSame() {
        let first = report(.avanzado, excluded: [Self.serviceErrors])
        let second = CapabilityReport(modelKey: "mlx:other", modelTitle: "O", level: .avanzado, temperature: 0.2,
                                      date: Self.date, results: first.results, excludedProbeIDs: [Self.serviceErrors])
        let models = CapabilityPDFContent.comparedModels([[first], [second]])
        #expect(CapabilityComparison.settingsNote(models, level: .avanzado) == nil)
        #expect(CapabilityComparison.excludedNote(models, level: .avanzado)
            == "Pruebas excluidas, que no cuentan: A (1) y B (1).")
        #expect(CapabilityComparison.excludedNote(models, level: .basico) == nil)
        let markdown = CapabilityComparisonMarkdown.make([[first], [second]], exportedAt: Self.date)
        #expect(markdown.contains("> Pruebas excluidas, que no cuentan: A (1) y B (1)."))
    }

    @Test func exportsNumberProbesByTheirPlaceInTheLevel() throws {
        let excluded = try #require(CapabilityLevel.avanzado.probes.firstIndex { $0.id == Self.serviceErrors })
        let saved = report(.avanzado, excluded: [Self.serviceErrors])
        let numbers = CapabilityExport.numberedResults(saved).map(\.number)
        #expect(numbers == Array(1...12).filter { $0 != excluded + 1 })
        let next = CapabilityLevel.avanzado.probes[excluded + 1]
        let markdown = CapabilityExport.markdown([saved], options: .init(), exportedAt: Self.date)
        #expect(markdown.contains("| \(excluded + 2) | " + next.title + " |"))
    }
}
