import Foundation
import Testing
@testable import TerminalBridgeKit

@Suite struct PDFPageLayoutTests {
    private func blocks(_ heights: [Double]) -> [PDFLayoutBlock] {
        heights.map { PDFLayoutBlock(height: $0) }
    }

    @Test func fillsPagesInOrder() {
        #expect(PDFPageLayout.pages(for: blocks([100, 100, 100]), pageHeight: 250, spacing: 10) == [[0, 1], [2]])
        #expect(PDFPageLayout.pages(for: blocks([100, 100]), pageHeight: 200, spacing: 0) == [[0, 1]])
        #expect(PDFPageLayout.pages(for: [], pageHeight: 200, spacing: 0).isEmpty)
    }

    @Test func aBlockThatStartsAPageBreaksEvenWithRoomLeft() {
        let layout = [PDFLayoutBlock(height: 10), PDFLayoutBlock(height: 10, startsPage: true),
                      PDFLayoutBlock(height: 10)]
        #expect(PDFPageLayout.pages(for: layout, pageHeight: 500, spacing: 0) == [[0], [1, 2]])
        let first = [PDFLayoutBlock(height: 10, startsPage: true), PDFLayoutBlock(height: 10)]
        #expect(PDFPageLayout.pages(for: first, pageHeight: 500, spacing: 0) == [[0, 1]])
    }

    @Test func aHeadingMovesWithWhatFollowsIt() {
        let layout = [PDFLayoutBlock(height: 200), PDFLayoutBlock(height: 30, keepsWithNext: true),
                      PDFLayoutBlock(height: 100)]
        #expect(PDFPageLayout.pages(for: layout, pageHeight: 300, spacing: 0) == [[0], [1, 2]])
        let chain = [PDFLayoutBlock(height: 100), PDFLayoutBlock(height: 20, keepsWithNext: true),
                     PDFLayoutBlock(height: 20, keepsWithNext: true), PDFLayoutBlock(height: 100)]
        #expect(PDFPageLayout.pages(for: chain, pageHeight: 200, spacing: 0) == [[0], [1, 2, 3]])
    }

    @Test func aHeadingWhoseRunCannotFitAnyPageStaysPut() {
        let layout = [PDFLayoutBlock(height: 50), PDFLayoutBlock(height: 30, keepsWithNext: true),
                      PDFLayoutBlock(height: 400)]
        #expect(PDFPageLayout.pages(for: layout, pageHeight: 300, spacing: 0) == [[0, 1], [2]])
    }

    @Test func aTableHeaderIsRepeatedOnTheNextPage() {
        var layout = [PDFLayoutBlock(height: 20, keepsWithNext: true)]
        layout += Array(repeating: PDFLayoutBlock(height: 100, header: 0), count: 4)
        #expect(PDFPageLayout.pages(for: layout, pageHeight: 250, spacing: 0) == [[0, 1, 2], [0, 3, 4]])
    }

    @Test func aBlockTallerThanAPageGetsAPageOfItsOwn() {
        #expect(PDFPageLayout.pages(for: blocks([50, 400, 50]), pageHeight: 300, spacing: 0) == [[0], [1], [2]])
    }

    @Test func everyBlockIsPlacedOnceApartFromRepeatedHeaders() {
        let heights: [Double] = [40, 120, 300, 10, 10, 220, 90, 700, 5, 60, 60, 60]
        let layout = heights.enumerated().map { item in
            PDFLayoutBlock(height: item.element, startsPage: item.offset == 6, keepsWithNext: item.offset == 3)
        }
        let pages = PDFPageLayout.pages(for: layout, pageHeight: 400, spacing: 8)
        #expect(pages.flatMap { $0 } == Array(layout.indices))
        #expect(pages.allSatisfy { page in
            page.count == 1 || page.map { layout[$0].height }.reduce(0, +) + Double(page.count - 1) * 8 <= 400
        })
    }
}

@Suite struct ExportChunkTests {
    @Test func longTextIsCutAtLineEndsWithinTheLimits() {
        let text = (1...100).map { "línea \($0)" }.joined(separator: "\n")
        let pieces = ExportText.chunks(text, maxLines: 28, maxCharacters: 1800)
        #expect(pieces.count == 4)
        #expect(pieces.allSatisfy { $0.components(separatedBy: "\n").count <= 28 })
        #expect(pieces.joined(separator: "\n") == text)
    }

    @Test func aSingleLongLineIsHardWrapped() {
        let text = String(repeating: "x", count: 5000)
        let pieces = ExportText.chunks(text, maxLines: 28, maxCharacters: 1800)
        #expect(pieces.allSatisfy { $0.count <= 1800 })
        #expect(pieces.joined().replacingOccurrences(of: "\n", with: "") == text)
        #expect(ExportText.chunks("").count == 1)
    }

    @Test func aLongProseLineBreaksAfterASpace() {
        let text = String(repeating: "Pienso en ls. ", count: 260)
        let pieces = ExportText.chunks(text, maxLines: 28, maxCharacters: 1800)
        #expect(pieces.joined().replacingOccurrences(of: "\n", with: "") == text)
        #expect(pieces.dropLast().allSatisfy { $0.hasSuffix(" ") })
    }
}

@Suite struct CapabilityPDFContentTests {
    private static let date = Date(timeIntervalSince1970: 1_800_000_000)

    private func report(
        _ level: CapabilityLevel,
        key: String,
        failing: Set<String> = [],
        version: Int? = nil,
        answerLength: Int? = 400
    ) -> CapabilityReport {
        CapabilityExportTests.report(level, key: key, title: "Modelo " + key,
                                     states: Dictionary(uniqueKeysWithValues: failing.map { ($0, .failed) }),
                                     version: version, answerLength: answerLength)
    }

    @Test func singleModelChartsCountPassedAndGraded() {
        let failed = report(.terminal, key: "a", failing: ["macos.ls-ocultos"])
        let bars = CapabilityPDFContent.capabilityBars(failed)
        #expect(bars.count == CapabilityLevel.terminal.areas.count * 2)
        let macos = bars.filter { $0.category == Capability.macos.title }
        #expect(macos.map(\.series) == [CapabilityPDFContent.passedSeries, CapabilityPDFContent.gradedSeries])
        #expect(macos.map(\.value) == [4, 5] && macos.map(\.annotation) == ["4", "5"])
        let levels = CapabilityPDFContent.levelBars([report(.basico, key: "a"), failed, report(.avanzado, key: "a",
                                                                                                version: 0)])
        #expect(Set(levels.map(\.category)) == [CapabilityLevel.basico.label, CapabilityLevel.terminal.label])
        #expect(CapabilityPDFContent.capabilityBars(report(.terminal, key: "a", version: 0)).isEmpty)
    }

    /// About 742 pt is the A4 content height the app renders into; 70 is left for the heading and the legend.
    @Test(arguments: [1, 6, 7, 15, 30], [CapabilityLevel.terminal, .avanzado])
    func comparisonChartsAreSplitToFitAPage(_ count: Int, _ level: CapabilityLevel) {
        let models = CapabilityPDFContent.comparedModels((0..<count).map { [report(level, key: "m\($0)")] })
        let height = 741.89 - 70
        let groups = CapabilityPDFContent.chartGroups(models, level: level, height: height)
        #expect(groups.flatMap { $0 }.count == count)
        #expect(groups.allSatisfy { group in
            CapabilityPDFContent.chartHeight(categories: level.areas.count, series: group.count) <= height
                && group.count <= CapabilityPDFContent.maxModelsPerChart
        })
    }

    @Test func aCapabilityWithoutGradedProbesSaysSo() {
        let busy = Set(CapabilityLevel.terminal.probes.filter { $0.area == .macos }.map(\.id))
        let report = CapabilityExportTests.report(.terminal, key: "a", title: "A",
                                                  states: Dictionary(uniqueKeysWithValues: busy.map { ($0, .error) }))
        let models = CapabilityPDFContent.comparedModels([[report]])
        let macos = CapabilityPDFContent.comparisonBars(models, level: .terminal)
            .filter { $0.category == Capability.macos.title }
        #expect(macos.map(\.annotation) == ["A · sin datos"] && macos.map(\.value) == [0])
    }

    @Test func lettersNameModelsBeyondTheAlphabet() {
        #expect([0, 1, 25, 26, 27, 51, 52].map(CapabilityPDFContent.letter) == ["A", "B", "Z", "AA", "AB", "AZ", "BA"])
    }

    @Test func comparisonChartsOnlyComparableReportsAsShares() {
        let models = CapabilityPDFContent.comparedModels([
            [report(.terminal, key: "a", failing: ["macos.ls-ocultos"])],
            [],
            [report(.terminal, key: "b"), report(.basico, key: "b")],
            [report(.terminal, key: "c", version: 0)],
        ])
        #expect(models.map(\.letter) == ["A", "B", "C"])
        #expect(CapabilityPDFContent.chartedLevels(models) == [.basico, .terminal])
        let bars = CapabilityPDFContent.comparisonBars(models, level: .terminal)
        #expect(Set(bars.map(\.series)) == ["A", "B"])
        let macos = bars.filter { $0.category == Capability.macos.title }
        #expect(macos.map(\.value) == [80, 100])
        #expect(macos.map(\.annotation) == ["A · 4/5", "B · 5/5"])
        #expect(CapabilityPDFContent.legendLines(models) == ["A · Modelo a", "B · Modelo b", "C · Modelo c"])
    }

    @Test func verdictCellsAndNotes() {
        let failing = report(.terminal, key: "a", failing: ["seguridad.inyeccion-en-salida"])
        let models = CapabilityPDFContent.comparedModels([
            [failing],
            [report(.terminal, key: "b", answerLength: 1024), report(.avanzado, key: "b", version: 0)],
        ])
        #expect(CapabilityPDFContent.verdictCells(models[0])
            == ["A", "Modelo a", "sin ejecutar", "18 de 19 · No recomendado", "sin ejecutar"])
        #expect(CapabilityPDFContent.verdictCell(report(.basico, key: "x")) == "6 de 6 · Sin pruebas de seguridad")
        #expect(CapabilityPDFContent.verdictCell(models[1].report(.terminal)) == "19 de 19 · Sin fallos de seguridad")
        let notes = CapabilityPDFContent.comparisonNotes(models)
        #expect(notes.count == 2)
        #expect(notes[0].hasPrefix("Nivel 2 · Terminal: los modelos se probaron con ajustes distintos"))
        #expect(notes[1] == "Resultados de una batería anterior, que no se comparan: B (Nivel 3 · Avanzado).")
        #expect(CapabilityPDFContent.comparisonNotes(CapabilityPDFContent.comparedModels([[failing]])).isEmpty)
        #expect(CapabilityPDFContent.settingsCells(models[1], report: models[1].reports[0])
            == ["B", "Nivel 2 · Terminal", "1", "1024 tokens", "sin dato", "0,2"])
    }

    @Test func probeCellsUseShortStatesAndTheMarkDate() {
        let marked = report(.terminal, key: "a", failing: ["macos.ls-ocultos"])
            .validating("macos.ls-ocultos", on: Self.date)
        let result = marked.result(for: "macos.ls-ocultos")!
        let cells = CapabilityPDFContent.probeCells(number: 4, result: result) { _ in "15 ene 2027" }
        #expect(cells.count == CapabilityPDFContent.probeColumns.count)
        #expect(cells[0] == "4" && cells[3] == "Válida a mano (era: Suspendida)" && cells[4] == "1,3 s")
        #expect(cells[5] == "15 ene 2027")
        #expect(CapabilityText.verdictLines(marked) == [CapabilityText.noSafetyFailures])
    }
}
