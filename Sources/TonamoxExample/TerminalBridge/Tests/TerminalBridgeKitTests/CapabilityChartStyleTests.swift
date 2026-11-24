import Foundation
import Testing
@testable import TerminalBridgeKit

@Suite struct CapabilityChartStyleTests {
    @Test func theStoredChoiceDefaultsToDonuts() {
        #expect(CapabilityChartStyle.stored(nil) == .donuts)
        #expect(CapabilityChartStyle.stored("barras") == .bars)
        #expect(CapabilityChartStyle.stored("donas") == .donuts)
        #expect(CapabilityChartStyle.stored("bars") == .donuts)
        #expect(CapabilityChartStyle.allCases.map(\.title) == ["Donas", "Barras"])
    }

    @Test func anUnknownStoredValueIsRewrittenAndAValidOneKept() throws {
        #expect(CapabilityChartStyle.migratedRawValue(nil) == nil)
        #expect(CapabilityChartStyle.migratedRawValue("barras") == nil)
        #expect(CapabilityChartStyle.migratedRawValue("Barras") == "donas")
        let name = "tnx-chart-style-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        CapabilityChartStyle.migrate(defaults)
        #expect(defaults.string(forKey: CapabilityChartStyle.defaultsKey) == nil)
        defaults.set("barras", forKey: CapabilityChartStyle.defaultsKey)
        CapabilityChartStyle.migrate(defaults)
        #expect(defaults.string(forKey: CapabilityChartStyle.defaultsKey) == "barras")
        defaults.set("pie", forKey: CapabilityChartStyle.defaultsKey)
        CapabilityChartStyle.migrate(defaults)
        #expect(defaults.string(forKey: CapabilityChartStyle.defaultsKey) == "donas")
    }
}

@Suite struct CapabilityDonutTests {
    private static let markDate = Date(timeIntervalSince1970: 1_800_000_000)

    /// Level 2 with one row of every state, the unrecognised one marked as valid by hand.
    private func mixedReport() throws -> (CapabilityReport, [String]) {
        let ids = CapabilityLevel.terminal.probes.map(\.id)
        let picked = Array(ids.prefix(6))
        let states: [String: ProbeRunState] = [picked[0]: .failed, picked[1]: .unrecognised, picked[2]: .timedOut,
                                               picked[3]: .notRun, picked[4]: .error, picked[5]: .unrecognised]
        let report = CapabilityExportTests.report(.terminal, key: "a", title: "A", states: states)
            .validating(picked[1], on: Self.markDate)
        return (report, picked)
    }

    @Test func slicesLeaveOutZeroKindsAndCountHandValidatedRowsApart() throws {
        let (report, _) = try mixedReport()
        let donut = CapabilityDonuts.level(report)
        let total = CapabilityLevel.terminal.probes.count
        #expect(donut.slices.map(\.kind) == [.passed, .validatedByHand, .unrecognised, .failed, .timedOut])
        #expect(donut.slices.map(\.count) == [total - 6, 1, 1, 1, 1])
        #expect(donut.graded == report.totalGraded && donut.graded == total - 2)
        #expect(donut.passed == report.totalPassed && donut.passed == total - 5)
        #expect(donut.slices[1].legend == "Validadas a mano: 1")

        let clean = CapabilityExportTests.report(.terminal, key: "b", title: "B",
                                                 states: [CapabilityLevel.terminal.probes[0].id: .failed])
        #expect(CapabilityDonuts.level(clean).slices.map(\.kind) == [.passed, .failed])
    }

    @Test func theCentreShowsTheRoundedShareIncludingHandValidated() throws {
        let probes = CapabilityLevel.basico.probes
        #expect(probes.count >= 6)
        let states = Dictionary(uniqueKeysWithValues: probes.dropFirst(6).map { ($0.id, ProbeRunState.error) })
            .merging([probes[0].id: .failed, probes[1].id: .unrecognised]) { $1 }
        let report = CapabilityExportTests.report(.basico, key: "a", title: "A", states: states)
        #expect(CapabilityDonuts.level(report).passedPercent == 67)
        let marked = report.validating(probes[1].id, on: Self.markDate)
        let donut = CapabilityDonuts.level(marked)
        #expect(donut.passedPercent == 83 && donut.centreText == "83 %" && donut.countText == "5/6")
        #expect(donut.spokenText == CapabilityLevel.basico.label
            + ": 5 de 6 aprobadas (83 %). Aprobadas: 4, Validadas a mano: 1, Suspendidas: 1.")
        #expect(donut.breakdownText == "1 a mano · 1 susp.")
    }

    @Test func comparisonDonutsSayModelLevelAndCountWhenSpoken() throws {
        let (report, _) = try mixedReport()
        let models = CapabilityPDFContent.comparedModels([[report], [CapabilityExportTests.report(.basico, key: "b",
                                                                                                  title: "B")]])
        let donuts = CapabilityDonuts.comparison(models, level: .terminal)
        let graded = report.totalGraded
        #expect(donuts[0].spokenText.hasPrefix("A, A, Nivel 2: \(report.totalPassed) de \(graded) aprobadas ("))
        #expect(donuts[1].spokenText == "B, B, Nivel 2: " + CapabilityText.levelNotRun + ".")
        let macos = CapabilityDonuts.comparison(models, level: .terminal, area: .macos)
        #expect(macos[0].spokenText.hasPrefix("A, A, Nivel 2, " + Capability.macos.title + ": "))
    }

    @Test func nothingGradedChartsNothing() {
        let busy = Dictionary(uniqueKeysWithValues: CapabilityLevel.basico.probes.map { ($0.id, ProbeRunState.error) })
        let donut = CapabilityDonuts.level(CapabilityExportTests.report(.basico, key: "a", title: "A", states: busy))
        #expect(donut.slices.isEmpty && donut.passedPercent == nil)
        #expect(donut.centreText == "—" && donut.countText == CapabilityPDFContent.noData)
        #expect(donut.legendLines == [CapabilityPDFContent.noData])
    }

    @Test func oneSmallDonutPerCapabilityAddsUpToTheLevel() throws {
        let (report, _) = try mixedReport()
        let donuts = CapabilityDonuts.capabilities(report)
        #expect(donuts.map(\.title) == CapabilityLevel.terminal.areas.map(\.title))
        #expect(Set(donuts.map(\.id)).count == donuts.count)
        #expect(donuts.map(\.graded).reduce(0, +) == report.totalGraded)
        #expect(donuts.map(\.passed).reduce(0, +) == report.totalPassed)
        #expect(zip(donuts, report.tallies).allSatisfy { $0.countText == "\($1.passed)/\($1.graded)" })
        let older = CapabilityExportTests.report(.terminal, key: "a", title: "A", version: 0)
        #expect(CapabilityDonuts.capabilities(older).isEmpty)
        #expect(CapabilityDonuts.levels([older, report]).map(\.id) == [CapabilityLevel.terminal.rawValue])
    }

    @Test func aComparisonKeepsEveryModelInLetterOrder() throws {
        let (report, _) = try mixedReport()
        let models = CapabilityPDFContent.comparedModels([
            [report],
            [CapabilityExportTests.report(.basico, key: "b", title: "B")],
            [CapabilityExportTests.report(.terminal, key: "c", title: "C", version: 0)],
        ])
        let donuts = CapabilityDonuts.comparison(models, level: .terminal)
        #expect(donuts.map(\.title) == ["A", "B", "C"] && donuts.map(\.subtitle) == ["A", "B", "C"])
        #expect(donuts.map(\.status) == [.counted, .notRun, .notComparable])
        #expect(donuts[1].countText == CapabilityText.levelNotRun && donuts[2].countText == "no comparable")
        #expect(donuts[1].slices.isEmpty && donuts[2].slices.isEmpty)
        let macos = CapabilityDonuts.comparison(models, level: .terminal, area: .macos)
        #expect(macos.map(\.title) == ["A", "B", "C"])
        #expect(macos[0].countText == "\(report.tally(.macos).passed)/\(report.tally(.macos).graded)")
    }

    @Test func thinSlicesAreLabelledOnlyInTheLegend() {
        let donut = CapabilityDonut(id: "x", title: "x", slices: [DonutSlice(kind: .passed, count: 24),
                                                                    DonutSlice(kind: .failed, count: 1)],
                                    status: .counted)
        #expect(donut.labelsSlice(donut.slices[0]) && !donut.labelsSlice(donut.slices[1]))
        #expect(donut.legendLines == ["Aprobadas: 24", "Suspendidas: 1"])
    }

    @Test func theBreakdownNamesEveryKindButPlainPassed() {
        let every = CapabilityDonut(id: "x", title: "x", slices: DonutSliceKind.allCases.map {
            DonutSlice(kind: $0, count: 2)
        }, status: .counted)
        #expect(every.breakdownText == "2 a mano · 2 no rec. · 2 susp. · 2 t. agot.")
        let clean = CapabilityDonut(id: "y", title: "y", slices: [DonutSlice(kind: .passed, count: 3)],
                                    status: .counted)
        #expect(clean.breakdownText.isEmpty)
        #expect(Set(DonutSliceKind.allCases.map(\.shortTitle)).count == DonutSliceKind.allCases.count)
    }
}

@Suite struct CapabilityChartHeightTests {
    /// The A4 content height the app renders into, and what a heading and the legend take above and below a chart.
    private static let pageHeight = 741.89
    private static let allowance = 70.0

    private func report(_ level: CapabilityLevel, key: String) -> CapabilityReport {
        CapabilityExportTests.report(level, key: key, title: "Modelo " + key)
    }

    private func gridRows(_ level: CapabilityLevel) -> Int {
        let columns = DonutLayout.columns(.small)
        return (level.areas.count + columns - 1) / columns
    }

    /// Every chart block fits a page, and paged behind a heading that keeps with it, no page overflows.
    private func expectFits(_ heights: [Double]) {
        #expect(heights.allSatisfy { $0 > 0 && $0 <= Self.pageHeight - Self.allowance })
        let blocks = [PDFLayoutBlock(height: 30, keepsWithNext: true)] + heights.map { PDFLayoutBlock(height: $0) }
        let pages = PDFPageLayout.pages(for: blocks, pageHeight: Self.pageHeight, spacing: 6)
        #expect(pages.flatMap { $0 } == Array(blocks.indices))
        #expect(pages.allSatisfy { page in
            page.map { blocks[$0].height }.reduce(0, +) + Double(page.count - 1) * 6 <= Self.pageHeight
        })
    }

    @Test(arguments: CapabilityChartStyle.allCases)
    func singleModelChartsFitAPage(_ style: CapabilityChartStyle) {
        let levels = CapabilityLevel.allCases.map { report($0, key: "a") }
        let heights = style.summaryChartHeights(levels)
        expectFits(heights)
        switch style {
        case .bars:
            #expect(heights.count == 1 + levels.count)
        case .donuts:
            #expect(heights.count == 1 + levels.map { gridRows($0.level) + 1 }.reduce(0, +))
        }
        let single = style.summaryChartHeights([report(.terminal, key: "a")]).count
        #expect(single == (style == .bars ? 1 : 2 + gridRows(.terminal)))
    }

    @Test(arguments: CapabilityChartStyle.allCases, [1, 3, 9, 30])
    func comparisonChartsFitAPage(_ style: CapabilityChartStyle, _ count: Int) {
        let models = CapabilityPDFContent.comparedModels((0..<count).map { [report(.terminal, key: "m\($0)")] })
        let heights = style.comparisonChartHeights(models, level: .terminal, height: Self.pageHeight - Self.allowance)
        expectFits(heights)
        if style == .donuts {
            let columns = DonutLayout.columns(.large)
            #expect(heights.count == (count + columns - 1) / columns)
            #expect(heights.allSatisfy { $0 <= DonutLayout.cellHeight(.large) })
        }
    }

    @Test func aDonutRowIsAsTallAsItsLongestLegend() {
        let passed = CapabilityDonut(id: "a", title: "A", slices: [DonutSlice(kind: .passed, count: 3)],
                                     status: .counted)
        let mixed = CapabilityDonut(id: "b", title: "B", slices: [DonutSlice(kind: .passed, count: 3),
                                                                  DonutSlice(kind: .failed, count: 1),
                                                                  DonutSlice(kind: .timedOut, count: 1)],
                                    status: .counted)
        let empty = CapabilityDonut(id: "c", title: "C", slices: [], status: .notRun)
        let base = DonutLayout.rowHeight([passed], size: .large)
        #expect(DonutLayout.rowHeight([empty], size: .large) == base)
        #expect(DonutLayout.rowHeight([passed, mixed], size: .large) == base + 2 * DonutLayout.legendLineHeight)
        #expect(DonutLayout.rowHeight([mixed], size: .small) == DonutLayout.cellHeight(.small))
        #expect(DonutLayout.rowHeight([passed], size: .small)
            == DonutLayout.cellHeight(.small) - Double(DonutLayout.breakdownLines) * DonutLayout.breakdownLineHeight)
    }

    @Test func aGridIsItsRowsInOrderThenTheKindLegend() throws {
        let levels = CapabilityLevel.allCases.map { report($0, key: "a") }
        let older = CapabilityExportTests.report(.terminal, key: "o", title: "O", version: 0)
        for level in levels {
            let grid = DonutGrid.byCapability(level)
            #expect(grid.rows.flatMap { $0 }.map(\.id) == CapabilityDonuts.capabilities(level).map(\.id))
            #expect(grid.rows.allSatisfy { $0.count <= DonutLayout.columns(.small) })
            #expect(grid.hasKindLegend)
            #expect(grid.heights == grid.rows.map { DonutLayout.rowHeight($0, size: .small) }
                + [DonutLayout.kindLegendHeight])
        }
        #expect(DonutGrid.byCapability(older).heights.isEmpty)
        let byLevel = DonutGrid.byLevel(levels + [older])
        #expect(!byLevel.hasKindLegend && byLevel.rows.flatMap { $0 }.count == levels.count)
        let models = CapabilityPDFContent.comparedModels((0..<9).map { [report(.terminal, key: "m\($0)")] })
        let comparison = DonutGrid.comparison(models, level: .terminal)
        #expect(comparison.rows.map(\.count) == [4, 4, 1] && !comparison.hasKindLegend)
        #expect(CapabilityChartStyle.donuts.summaryChartHeights(levels)
            == byLevel.heights + levels.flatMap { DonutGrid.byCapability($0).heights })
    }

    @Test func comparisonTablesSplitEvenly() {
        #expect(CapabilityChartStyle.tableGroups(Array(0..<9)).map(\.count) == [5, 4])
        #expect(CapabilityChartStyle.tableGroups(Array(0..<8)).map(\.count) == [8])
        #expect(CapabilityChartStyle.tableGroups(Array(0..<17)).map(\.count) == [6, 6, 5])
        #expect(CapabilityChartStyle.tableGroups(Array(0..<3)) == [[0, 1, 2]])
        #expect(CapabilityChartStyle.tableGroups([Int]()).isEmpty)
        #expect(CapabilityChartStyle.tableGroups(Array(0..<30)).allSatisfy {
            $0.count <= CapabilityPDFContent.maxModelsPerChart
        })
    }

    @Test(arguments: [44.0, 64, 80, 120, 160])
    func screenFontsFitTheRingAtEveryTextSize(_ diameter: Double) {
        #expect(DonutLayout.sliceLabelFits(fontSize: diameter * DonutLayout.screenSliceFontRatio, diameter: diameter))
        #expect(DonutLayout.centreFits(fontSize: diameter * DonutLayout.screenCentreFontRatio, diameter: diameter))
    }

    @Test func printFontsFitTheRingAndTheOldScreenFontDidNot() {
        #expect(DonutLayout.sliceLabelFits(fontSize: 7, diameter: DonutLayout.diameter(.large)))
        #expect(DonutLayout.sliceLabelFits(fontSize: 6, diameter: DonutLayout.diameter(.small)))
        #expect(DonutLayout.centreFits(fontSize: 11, diameter: DonutLayout.diameter(.large)))
        #expect(DonutLayout.centreFits(fontSize: 8, diameter: DonutLayout.diameter(.small)))
        #expect(!DonutLayout.sliceLabelFits(fontSize: 11, diameter: 64))
    }

    @Test func donutCellsAreTallerThanABarRow() {
        #expect(DonutLayout.cellHeight(.large) > DonutLayout.cellHeight(.small))
        #expect(DonutLayout.cellHeight(.small) > CapabilityPDFContent.chartBarRow * 2)
        #expect(DonutLayout.rows(Array(0..<9), size: .large) == [[0, 1, 2, 3], [4, 5, 6, 7], [8]])
        #expect(DonutLayout.rows([Int](), size: .small).isEmpty)
    }
}
