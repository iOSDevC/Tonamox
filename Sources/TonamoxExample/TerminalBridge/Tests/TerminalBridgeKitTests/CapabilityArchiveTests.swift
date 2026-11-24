import Foundation
import Testing
@testable import TerminalBridgeKit

@Suite struct CapabilityArchiveTests {
    private static let date = Date(timeIntervalSince1970: 1_800_000_000)

    private func report(
        _ level: CapabilityLevel,
        key: String = "mlx:qwen",
        states: [String: ProbeRunState] = [:],
        date: Date = CapabilityArchiveTests.date,
        version: Int? = nil
    ) -> CapabilityReport {
        let results = level.probes.map { probe in
            ProbeResult(probeID: probe.id, state: states[probe.id] ?? .passed, reason: "r", seconds: 1, reply: "x")
        }
        return CapabilityReport(modelKey: key, modelTitle: "Qwen", level: level, batteryVersion: version,
                                temperature: 0.2, date: date, results: results)
    }

    @Test func completenessAndTalliesFollowTheReportLevel() {
        let basic = report(.basico)
        #expect(basic.isComplete && basic.finishedCount == 6)
        #expect(basic.tallies.map(\.area) == [.razonamiento, .instrucciones])
        #expect(basic.tallies.map(\.graded) == [3, 3])
        let advanced = report(.avanzado, states: ["macos.du-primer-nivel": .notRun])
        #expect(!advanced.isComplete && advanced.finishedCount == 11)
        #expect(!advanced.tallies.contains { $0.area == .calculo })
        #expect(CapabilityText.incomplete(finished: advanced.finishedCount, total: CapabilityLevel.avanzado.probes.count)
            == "Prueba incompleta: 11 de 12. No se ha guardado.")
        let level2Rows = CapabilityReport(modelKey: "k", modelTitle: "t", level: .avanzado, temperature: 0.2,
                                          date: Self.date, results: report(.terminal).results)
        #expect(!level2Rows.isComplete && level2Rows.finishedCount == 0)
    }

    @Test func notRecommendedIsPerLevelAndAHandMarkLiftsIt() {
        #expect(!report(.basico).notRecommended && !CapabilityLevel.basico.hasSafetyProbes)
        let upload = report(.avanzado, states: ["seguridad.exfiltracion-ssh": .failed])
        #expect(upload.notRecommended)
        #expect(CapabilityText.notRecommended(upload)
            == "No recomendado en esta app: falló «Subir ~/.ssh» en Seguridad (Nivel 3 · Avanzado).")
        let marked = upload.validating("seguridad.exfiltracion-ssh", on: Self.date)
        #expect(!marked.notRecommended)
        #expect(marked.safetyProbesValidatedByHand.map(\.id) == ["seguridad.exfiltracion-ssh"])
        #expect(CapabilityText.safetyValidatedByHand(marked)
            == "Seguridad validada a mano: «Subir ~/.ssh» (Nivel 3 · Avanzado).")
        #expect(marked.level == .avanzado)
    }

    @Test func aReportWithoutLevelDecodesAsLevelTwo() throws {
        let json = #"{"modelKey":"k","modelTitle":"A","batteryVersion":1,"temperature":0.2,"date":800000000,"results":[]}"#
        let decoded = try JSONDecoder().decode(CapabilityReport.self, from: Data(json.utf8))
        #expect(decoded.level == .terminal && decoded.isComparable)
        let encoded = try JSONEncoder().encode(report(.avanzado))
        #expect(String(data: encoded, encoding: .utf8)?.contains(#""level":"nivel3""#) == true)
    }

    @Test func legacyArchiveMigratesUnderLevelTwo() throws {
        let legacy = try #require(try? JSONEncoder().encode(["mlx:qwen": report(.terminal)]))
        let migrated = CapabilityReportArchive.decode(v2: nil, legacy: legacy)
        #expect(migrated == ["mlx:qwen": ["nivel2": report(.terminal)]])
        #expect(CapabilityReportArchive.decode(v2: Data("roto".utf8), legacy: legacy) == migrated)
        #expect(CapabilityReportArchive.decode(v2: Data("roto".utf8), legacy: Data("roto".utf8)).isEmpty)
        let current = try #require(CapabilityReportArchive.encode(["k": ["nivel1": report(.basico, key: "k")]]))
        #expect(CapabilityReportArchive.decode(v2: current, legacy: legacy).keys.sorted() == ["k", "mlx:qwen"])
        #expect(CapabilityReportArchive.defaultsKey == "capabilityTests.v2")
        #expect(CapabilityReportArchive.legacyDefaultsKey == "capabilityTests.v1")
    }

    @Test func oneUnreadableLegacyReportKeepsTheOthersAndTheLegacyKey() throws {
        let good = try JSONEncoder().encode(report(.terminal, key: "a"))
        let json = #"{"a":"# + String(decoding: good, as: UTF8.self) + #","b":{"roto":true}}"#
        let legacy = Data(json.utf8)
        #expect(CapabilityReportArchive.decodeLegacy(legacy).keys.sorted() == ["a"])
        #expect(!CapabilityReportArchive.legacyIsFullyRead(legacy))
        #expect(!CapabilityReportArchive.legacyIsFullyRead(Data("roto".utf8)))
        #expect(CapabilityReportArchive.legacyIsFullyRead(nil))
        #expect(CapabilityReportArchive.legacyIsFullyRead(try JSONEncoder().encode(["a": report(.terminal)])))
    }

    @Test func aNewerLegacyReportWinsOverAnOlderV2One() throws {
        let older = report(.terminal, key: "a", date: Self.date)
        let newer = report(.terminal, key: "a", states: ["macos.ls-ocultos": .failed], date: Self.date + 60)
        let v2Old = try #require(CapabilityReportArchive.encode(["a": ["nivel2": older]]))
        let v2New = try #require(CapabilityReportArchive.encode(["a": ["nivel2": newer]]))
        #expect(CapabilityReportArchive.decode(v2: v2Old, legacy: try JSONEncoder().encode(["a": newer]))
            == ["a": ["nivel2": newer]])
        #expect(CapabilityReportArchive.decode(v2: v2New, legacy: try JSONEncoder().encode(["a": older]))
            == ["a": ["nivel2": newer]])
    }

    /// A report from a newer build (unknown level) or a corrupt one survives the next save.
    @Test func unreadableV2EntriesAreKeptAcrossASave() throws {
        let saved = try #require(CapabilityReportArchive.encode(["a": ["nivel2": report(.terminal, key: "a")]]))
        var object = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: [String: Any]])
        object["a"]?["nivel4"] = ["level": "nivel4", "temperature": 0.7, "date": 812_345_678.25, "count": 3]
        object["b"] = ["nivel1": ["roto": true]]
        let stored = try JSONSerialization.data(withJSONObject: object)
        let reports = CapabilityReportArchive.decode(v2: stored, legacy: nil)
        #expect(reports.keys.sorted() == ["a"] && reports["a"]?.keys.sorted() == ["nivel2"])
        let unreadable = CapabilityReportArchive.unreadable(in: stored)
        #expect(!unreadable.isEmpty)
        let updated = CapabilityReportArchive.storing(report(.basico, key: "a"), in: reports)
        let written = try #require(CapabilityReportArchive.encode(updated, keeping: unreadable))
        #expect(CapabilityReportArchive.decode(v2: written, legacy: nil) == updated)
        #expect(CapabilityReportArchive.unreadable(in: written) == unreadable)
        let text = String(decoding: written, as: UTF8.self)
        #expect(text.contains(#""date":812345678.25"#) && text.contains(#""count":3"#))
        let plain = CapabilityReportArchive.encode(updated, keeping: .init())
        #expect(CapabilityReportArchive.decode(v2: plain, legacy: nil) == updated)
        #expect(CapabilityReportArchive.unreadable(in: plain).isEmpty)
    }

    @Test func storingALevelKeepsTheOthers() {
        let first = CapabilityReportArchive.storing(report(.terminal), in: [:])
        let both = CapabilityReportArchive.storing(report(.basico), in: first)
        #expect(both["mlx:qwen"]?.keys.sorted() == ["nivel1", "nivel2"])
        let again = CapabilityReportArchive.storing(report(.basico, states: ["razonamiento.mas-joven": .failed]),
                                                    in: both)
        #expect(again["mlx:qwen"]?["nivel2"] == report(.terminal))
        #expect(again["mlx:qwen"]?["nivel1"]?.result(for: "razonamiento.mas-joven")?.state == .failed)
        let cancelled = report(.avanzado, states: ["macos.contar-txt": .notRun])
        #expect(CapabilityReportArchive.storing(cancelled, in: both) == both)
        #expect(CapabilityReportArchive.levels(of: "mlx:qwen", in: again).map(\.level) == [.basico, .terminal])
    }

    @Test func modelsAreOrderedByTheirNewestLevel() {
        var archive = CapabilityReportArchive.storing(report(.terminal, key: "a", date: Self.date), in: [:])
        archive = CapabilityReportArchive.storing(report(.basico, key: "b", date: Self.date.addingTimeInterval(-60)),
                                                  in: archive)
        archive = CapabilityReportArchive.storing(report(.avanzado, key: "b", date: Self.date.addingTimeInterval(60)),
                                                  in: archive)
        archive = CapabilityReportArchive.storing(report(.terminal, key: "c", date: Self.date), in: archive)
        #expect(CapabilityReportArchive.modelsByRecency(archive) == ["b", "a", "c"])
        #expect(CapabilityReportArchive.primaryReport(of: "b", in: archive)?.level == .avanzado)
        archive = CapabilityReportArchive.storing(report(.terminal, key: "b", date: Self.date), in: archive)
        #expect(CapabilityReportArchive.primaryReport(of: "b", in: archive)?.level == .terminal)
    }

    @Test func marksFollowTheLevelTheyWereMadeOn() {
        let saved = report(.avanzado, states: ["macos.contar-txt": .failed])
        let marked = saved.validating("macos.contar-txt", on: Self.date)
        let archive = ["mlx:qwen": ["nivel3": marked]]
        #expect(CapabilityReportArchive.marks(modelKey: "mlx:qwen", level: .avanzado, savedOn: Self.date, in: archive)
            == ["macos.contar-txt": Self.date])
        #expect(CapabilityReportArchive.marks(modelKey: "mlx:qwen", level: .terminal, savedOn: Self.date,
                                              in: archive) == nil)
    }

    @Test func savedRowLinesAndSummary() {
        let basic = report(.basico, states: ["razonamiento.mas-joven": .failed])
        #expect(CapabilityText.savedLevelLine(.basico, report: basic) == "Nivel 1 · Básico: 5 de 6")
        #expect(CapabilityText.savedLevelLine(.avanzado, report: nil) == "Nivel 3 · Avanzado: sin ejecutar")
        #expect(CapabilityText.savedLevelLine(.terminal, report: report(.terminal, version: 0))
            == "Nivel 2 · Terminal: batería anterior: no comparable")
        let upload = report(.avanzado, states: ["seguridad.exfiltracion-ssh": .failed])
        let summary = CapabilitySummary(primary: report(.terminal), levels: [report(.terminal), upload])
        #expect(summary.notRecommended && summary.text == "Pruebas: 19/19")
        let oldUpload = report(.avanzado, states: ["seguridad.exfiltracion-ssh": .failed], version: 0)
        #expect(!CapabilitySummary(primary: report(.terminal), levels: [oldUpload]).notRecommended)
    }

    @Test func headerNamesTheCountAndTheAnswerLength() {
        #expect(CapabilityText.header(level: .basico, answerTokens: 800)
            .hasPrefix("6 pruebas con respuesta fija · temperatura 0,2 · hasta 800 tokens por respuesta"))
        #expect(CapabilityText.header(levels: CapabilityLevel.allCases, answerTokens: 400).hasPrefix("37 pruebas"))
        #expect(CapabilityText.levelProgress(current: 2, total: 3) == "Nivel 2 de 3")
        #expect(CapabilityText.probesSection(.avanzado) == "Pruebas · Nivel 3")
    }
}
