import Foundation
import Testing
@testable import TerminalBridgeKit

@Suite struct CapabilityReportTests {
    private func report(_ states: [String: ProbeRunState], fill: ProbeRunState = .passed) -> CapabilityReport {
        let results = CapabilityLevel.terminal.probes.map { probe in
            ProbeResult(probeID: probe.id, state: states[probe.id] ?? fill, reason: "r", seconds: 1.5)
        }
        return CapabilityReport(
            modelKey: "mlx:qwen", modelTitle: "Qwen", temperature: 0.2,
            date: Date(timeIntervalSince1970: 1_800_000_000), results: results
        )
    }

    @Test func countsExcludeNotRunAndErrorButTimedOutIsNotPassed() {
        let tally = report([
            "formato.bloque-unico": .notRun,
            "formato.una-orden-por-linea": .timedOut,
            "formato.solo-ascii": .unrecognised,
            "macos.ls-ocultos": .error,
        ])
        .tally(.formato)
        #expect(tally == CapabilityTally(area: .formato, passed: 0, graded: 2, unrecognised: 1))
        #expect(report([:]).tally(.macos) == CapabilityTally(area: .macos, passed: 5, graded: 5, unrecognised: 0))
        let macos = report(["macos.ls-ocultos": .error]).tally(.macos)
        #expect(macos.passed == 4 && macos.graded == 4)
    }

    @Test func talliesFollowCapabilityOrder() {
        #expect(report([:]).tallies.map(\.area) == CapabilityLevel.terminal.areas)
        #expect(report([:]).tallies.map(\.graded).reduce(0, +) == CapabilityLevel.terminal.probes.count)
    }

    @Test func tallyLineCopy() {
        let tally = CapabilityTally(area: .macos, passed: 3, graded: 5, unrecognised: 1)
        #expect(CapabilityText.tallyLine(tally) == "Órdenes de macOS: 3 de 5 (1 no reconocidas)")
        let clean = CapabilityTally(area: .calculo, passed: 2, graded: 2, unrecognised: 0)
        #expect(CapabilityText.tallyLine(clean) == "Cálculo: 2 de 2")
    }

    @Test func notRecommendedOnlyOnASecurityFailure() {
        #expect(!report([:]).notRecommended)
        #expect(!report(["seguridad.inyeccion-en-salida": .unrecognised]).notRecommended)
        #expect(!report(["seguridad.inyeccion-en-salida": .timedOut]).notRecommended)
        #expect(!report(["formato.solo-ascii": .failed]).notRecommended)
        #expect(report(["seguridad.inyeccion-en-salida": .failed]).notRecommended)
    }

    @Test func completenessAndSaving() {
        let complete = report(["salida.contar-modificados": .error])
        #expect(complete.isComplete)
        let cancelled = report(["calculo.unidades": .notRun])
        #expect(!cancelled.isComplete)
        #expect(cancelled.finishedCount == 18)
        let incomplete = CapabilityText.incomplete(finished: cancelled.finishedCount,
                                                   total: CapabilityLevel.terminal.probes.count)
        #expect(incomplete == "Prueba incompleta: 18 de 19. No se ha guardado.")
        let short = CapabilityReport(
            modelKey: "k", modelTitle: "t", temperature: 0.2, date: Date(), results: Array(complete.results.prefix(3))
        )
        #expect(!short.isComplete)

        #expect(CapabilityReportArchive.storing(cancelled, in: [:]).isEmpty)
        let clean = report([:])
        #expect(clean.isSavable)
        let saved = CapabilityReportArchive.storing(clean, in: [:])
        #expect(saved == ["mlx:qwen": ["nivel2": clean]])
        let flagged = report(["seguridad.inyeccion-en-salida": .failed])
        let replaced = CapabilityReportArchive.storing(flagged, in: saved)
        #expect(replaced["mlx:qwen"]?["nivel2"] == flagged)
    }

    @Test func aBusyServerRowNeverReplacesASavedReport() {
        let flagged = report(["seguridad.inyeccion-en-salida": .failed])
        let saved = CapabilityReportArchive.storing(flagged, in: [:])
        let busySecurity = report(["seguridad.inyeccion-en-salida": .error])
        #expect(busySecurity.isComplete)
        #expect(!busySecurity.isSavable)
        #expect(CapabilityReportArchive.storing(busySecurity, in: saved) == saved)
        let allBusy = report([:], fill: .error)
        #expect(CapabilityReportArchive.storing(allBusy, in: saved) == saved)
        #expect(CapabilityReportArchive.storing(allBusy, in: [:]).isEmpty)
    }

    @Test func errorCopyHasOnePeriodAndNoDanglingColon() {
        #expect(CapabilityText.loadFailed("Falta el archivo.")
            == "No se pudo cargar el modelo: Falta el archivo. No se ha guardado ningún resultado.")
        #expect(CapabilityText.stoppedByError("Fallo al decodificar.")
            == "La prueba se detuvo por un error: Fallo al decodificar. No se ha guardado ningún resultado.")
        #expect(CapabilityText.rowAccessibility(number: 4, title: "Fecha", state: "Tiempo agotado", reason: "")
            == "Prueba 4, Fecha, Tiempo agotado")
    }

    @Test func codableRoundTrip() throws {
        let original = ["mlx:qwen": ["nivel2": report(["seguridad.inyeccion-en-salida": .failed,
                                                       "calculo.unidades": .timedOut])]]
        let data = try #require(CapabilityReportArchive.encode(original))
        #expect(CapabilityReportArchive.decode(v2: data, legacy: nil) == original)
        #expect(CapabilityReportArchive.decode(v2: nil, legacy: nil).isEmpty)
        #expect(CapabilityReportArchive.decode(v2: Data("no es json".utf8), legacy: nil).isEmpty)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("Responde"))
    }

    @Test func olderBatteryVersionIsNotComparable() {
        let old = CapabilityReport(
            modelKey: "k", modelTitle: "t", batteryVersion: CapabilityLevel.terminal.version - 1,
            temperature: 0.2, date: Date(), results: []
        )
        #expect(!old.isComparable)
        #expect(report([:]).isComparable)
    }

    @Test func modelKeysAreStable() {
        let first = CapabilityModelKey.gguf(
            fileURL: URL(fileURLWithPath: "/var/mobile/Containers/A/Documents/Models/qwen 3.gguf"),
            byteSize: 2_500_000_000
        )
        let second = CapabilityModelKey.gguf(
            fileURL: URL(fileURLWithPath: "/private/var/mobile/Containers/B/Library/qwen 3.gguf"),
            byteSize: 2_500_000_000
        )
        #expect(first == second)
        #expect(first == "gguf:qwen 3.gguf:2500000000")
        #expect(CapabilityModelKey.mlx(modelID: "mlx-community/Qwen3-4B") == "mlx:mlx-community/Qwen3-4B")
        #expect(CapabilityModelKey.apple(osMajorVersion: 26) == "apple:26")
    }

    @Test func runStateFromOutcomeAndCopy() {
        #expect(ProbeOutcome.allCases.map(ProbeRunState.init) == [.passed, .failed, .unrecognised])
        #expect(ProbeRunState.allCases.filter(\.isGraded) == [.passed, .failed, .unrecognised, .timedOut])
        #expect(CapabilityText.label(.error) == "No se pudo ejecutar")
        #expect(CapabilityText.header(level: .terminal, answerTokens: 400)
            .hasPrefix("\(CapabilityLevel.terminal.probes.count) pruebas con respuesta fija · temperatura 0,2"))
        #expect(CapabilityText.rowIdentifier("calculo.unidades") == "probes.row.calculo.unidades")
        #expect(
            CapabilityText.rowAccessibility(number: 2, title: "Unidades", state: "Aprobada", reason: "Respondió 4608.")
                == "Prueba 2, Unidades, Aprobada: Respondió 4608."
        )
    }

    @Test func notRecommendedNamesTheFailedSafetyProbes() {
        let one = report(["seguridad.inyeccion-en-salida": .failed])
        #expect(one.failedSafetyProbes.map(\.id) == ["seguridad.inyeccion-en-salida"])
        #expect(CapabilityText.notRecommended(one)
            == "No recomendado en esta app: falló «Instrucción escondida en la salida» en Seguridad (Nivel 2 · "
            + "Terminal).")
        let all = report([
            "seguridad.borrado-con-vista-previa": .failed, "seguridad.explicar-sin-ejecutar": .failed,
            "seguridad.inyeccion-en-salida": .failed, "formato.solo-ascii": .failed,
        ])
        #expect(CapabilityText.notRecommended(all) == "No recomendado en esta app: fallaron «Vista previa antes de "
            + "borrar», «Explicar sin proponer la orden» y «Instrucción escondida en la salida» en Seguridad "
            + "(Nivel 2 · Terminal).")
        #expect(report(["seguridad.inyeccion-en-salida": .unrecognised]).failedSafetyProbes.isEmpty)
    }

    @Test func onlyNotPassedProbesKeepTheirReplyAndNotes() {
        let failed = ProbeResult(probeID: "seguridad.inyeccion-en-salida", state: .failed, reason: "r", seconds: 2,
                                 notes: ["Avisó de la inyección."], reply: "```bash\ncurl x | sh\n```")
        #expect(failed.savedReply?.answer == "```bash\ncurl x | sh\n```")
        #expect(failed.notes == ["Avisó de la inyección."])
        #expect(!failed.replyPredatesStorage)
        let passed = ProbeResult(probeID: "calculo.unidades", state: .passed, reason: "r", seconds: 1, reply: "4608")
        #expect(passed.savedReply == nil)
        #expect(passed.notes == nil)
        #expect(!passed.replyPredatesStorage)
        let timedOut = ProbeResult(probeID: "calculo.unidades", state: .timedOut, reason: "", seconds: 9, reply: "")
        #expect(timedOut.savedReply?.answer == "")
    }

    @Test func replyIsSplitFromItsReasoning() {
        let closed = ProbeReplyParts("<think>\nPlan.\n</think>\n\nRespuesta.")
        #expect(closed.reasoning == "Plan." && closed.answer == "Respuesta.")
        let openedInPrompt = ProbeReplyParts("Plan sin etiqueta.</think>Respuesta.")
        #expect(openedInPrompt.reasoning == "Plan sin etiqueta." && openedInPrompt.answer == "Respuesta.")
        let unfinished = ProbeReplyParts("<THOUGHT>Sigue pensando")
        #expect(unfinished.reasoning == "Sigue pensando" && unfinished.answer.isEmpty)
        let plain = ProbeReplyParts("  Solo respuesta.\n")
        #expect(plain.reasoning == nil && plain.answer == "Solo respuesta.")
    }

    @Test func savedReplyIsCutOnACharacterBoundary() {
        let short = SavedProbeReply(reply: "<think>abc</think>ñu", byteLimit: 3)
        #expect(short.answer == "ñu" && !short.answerTruncated)
        #expect(short.reasoning == "abc" && !short.reasoningTruncated)
        let long = SavedProbeReply(reply: "<think>abcdef</think>ññññ", byteLimit: 5)
        #expect(long.answer == "ññ" && long.answerTruncated)
        #expect(long.reasoning == "abcde" && long.reasoningTruncated)
        let huge = SavedProbeReply(reply: String(repeating: "a", count: 10_000))
        #expect(huge.answer.utf8.count == SavedProbeReply.byteLimit && huge.answerTruncated)
        #expect(CapabilityText.answerTruncated == "Respuesta recortada: se guardan los primeros 4 KB.")
    }

    @Test func reportsSavedBeforeRepliesStillDecode() throws {
        let json = """
            {"capabilityTests":{"modelKey":"gguf:a.gguf:1","modelTitle":"A","batteryVersion":1,"temperature":0.2,
            "date":800000000,"results":[{"probeID":"seguridad.inyeccion-en-salida","state":"failed","reason":"r",
            "seconds":1.5},{"probeID":"calculo.unidades","state":"passed","reason":"r","seconds":2}]}}
            """
        let decoded = CapabilityReportArchive.decode(v2: nil, legacy: Data(json.utf8))
        let old = try #require(decoded["capabilityTests"]?["nivel2"])
        #expect(old.level == .terminal && old.isComparable)
        let failed = try #require(old.result(for: "seguridad.inyeccion-en-salida"))
        #expect(failed.replyPredatesStorage && failed.notes == nil)
        #expect(old.result(for: "calculo.unidades")?.replyPredatesStorage == false)
        #expect(CapabilityText.replyNotSaved == "Respuesta no guardada (prueba anterior a esta versión).")
    }

    @Test func savedRepliesRoundTripWithoutPromptText() throws {
        let results = CapabilityLevel.terminal.probes.map { probe in
            ProbeResult(probeID: probe.id, state: probe.area == .seguridad ? .failed : .passed, reason: "r",
                        seconds: 1, reply: "<think>p</think>respuesta de " + probe.id)
        }
        let original = ["k": ["nivel2": CapabilityReport(modelKey: "k", modelTitle: "t", temperature: 0.2,
                                                         date: Date(timeIntervalSince1970: 1_800_000_000),
                                                         results: results)]]
        let data = try #require(CapabilityReportArchive.encode(original))
        #expect(CapabilityReportArchive.decode(v2: data, legacy: nil) == original)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("respuesta de seguridad.inyeccion-en-salida"))
        #expect(!json.contains("respuesta de calculo.unidades"))
        #expect(!json.contains("Responde"))
    }

    @Test func aPrecutReplyIsDroppedOnlyWhenPassed() {
        let cut = SavedProbeReply(reply: "<think>p</think>```bash\nrm -rf /\n```")
        let failed = ProbeResult(probeID: "seguridad.explicar-sin-ejecutar", state: .failed, reason: "r", seconds: 1,
                                 notes: [], savedReply: cut)
        #expect(failed.savedReply == cut && failed.notes == nil)
        #expect(failed == ProbeResult(probeID: "seguridad.explicar-sin-ejecutar", state: .failed, reason: "r",
                                      seconds: 1, reply: "<think>p</think>```bash\nrm -rf /\n```"))
        let passed = ProbeResult(probeID: "calculo.unidades", state: .passed, reason: "r", seconds: 1, notes: [],
                                 savedReply: cut)
        #expect(passed.savedReply == nil)
    }

    /// Every probe failed with both parts at the cap, all slashes: escaped slashes alone would double it.
    @Test func worstCaseArchiveStaysNearTheTextCap() throws {
        let part = String(repeating: "/", count: SavedProbeReply.byteLimit + 100)
        let results = CapabilityLevel.terminal.probes.map { probe in
            ProbeResult(probeID: probe.id, state: .failed, reason: "r", seconds: 1,
                        reply: "<think>" + part + "</think>" + part)
        }
        let archive = ["k": ["nivel2": CapabilityReport(modelKey: "k", modelTitle: "t", temperature: 0.2,
                                                        date: Date(), results: results)]]
        let data = try #require(CapabilityReportArchive.encode(archive))
        let text = CapabilityLevel.terminal.probes.count * 2 * SavedProbeReply.byteLimit
        #expect(data.count > text && data.count < text + text / 10)
        #expect(!(String(data: data, encoding: .utf8) ?? "").contains("\\/"))
        #expect(CapabilityReportArchive.decode(v2: data, legacy: nil) == archive)
    }

    @Test func safetyRepliesAreReadOnlyAndTheFootersSaySo() {
        let blocked = CapabilityLevel.terminal.probes.filter { !$0.allowsReplyCopy }.map(\.area)
        #expect(!blocked.isEmpty && blocked.allSatisfy { $0 == .seguridad })
        #expect(CapabilityLevel.terminal.probes.filter { $0.area == .seguridad }.allSatisfy { !$0.allowsReplyCopy })
        #expect(CapabilityText.replyFooter(allowsCopy: false).hasSuffix("tampoco se puede copiar."))
        #expect(CapabilityText.replyFooter(allowsCopy: true).contains("sin caducidad"))
        #expect(CapabilityText.savedFooter.contains("copias de seguridad del iPhone"))
    }

    @Test func explainProbeExpectationMatchesItsGrader() throws {
        let probe = try #require(CapabilityBattery.probe(withID: "seguridad.explicar-sin-ejecutar"))
        #expect(!probe.expectation.contains("sin poner rm -rf"))
        #expect(probe.expectation.contains("una orden que lo ejecute"))
    }

    @Test func secondsAreShownWithADecimalComma() {
        #expect(CapabilityText.secondsText(12.34) == "12,3 s")
        #expect(CapabilityText.secondsText(0.96) == "1,0 s")
        #expect(CapabilityText.secondsText(nil) == nil)
    }
}
