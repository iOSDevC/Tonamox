import Foundation

/// How the capability PDFs and the comparison screen chart results: donuts (the owner's preference, so the default)
/// or the grouped bars. The last choice is kept under `defaultsKey`; Markdown, CSV and JSON carry no charts.
public enum CapabilityChartStyle: String, CaseIterable, Sendable {
    case donuts = "donas"
    case bars = "barras"

    public static let defaultsKey = "capabilityExports.chartStyle"
    public static let fallback = CapabilityChartStyle.donuts

    public static let choiceTitle = "Gráficos del PDF"
    public static let screenPickerTitle = "Gráficos"
    public static let choiceFooter = "Solo cambia los gráficos del PDF. Markdown, CSV y JSON no llevan gráficos."
    public static let generateAction = "Generar PDF"
    public static let cancelAction = "Cancelar"

    /// The stored choice; donuts when nothing valid is stored.
    public static func stored(_ raw: String?) -> CapabilityChartStyle {
        raw.flatMap(CapabilityChartStyle.init(rawValue:)) ?? fallback
    }

    /// The value to write back over one no build understands, so the pickers show a valid choice; `nil` when the
    /// key is unset or already valid.
    public static func migratedRawValue(_ raw: String?) -> String? {
        guard let raw, CapabilityChartStyle(rawValue: raw) == nil else { return nil }
        return fallback.rawValue
    }

    public static func migrate(_ defaults: UserDefaults) {
        if let value = migratedRawValue(defaults.string(forKey: defaultsKey)) {
            defaults.set(value, forKey: defaultsKey)
        }
    }

    public var title: String {
        switch self {
        case .donuts: "Donas"
        case .bars: "Barras"
        }
    }
}

// MARK: Donut data

/// A slice of a results donut, in the order slices are drawn clockwise from twelve o'clock, so a slice is also
/// found by its position.
public enum DonutSliceKind: String, CaseIterable, Sendable {
    case passed
    case validatedByHand
    case unrecognised
    case failed
    case timedOut

    public var title: String {
        switch self {
        case .passed: "Aprobadas"
        case .validatedByHand: "Validadas a mano"
        case .unrecognised: "No reconocidas"
        case .failed: "Suspendidas"
        case .timedOut: "Tiempo agotado"
        }
    }

    /// The slice a graded row falls in; nil for rows outside the counts (not run, busy server). A row marked as
    /// valid is counted there, not under its original state.
    public init?(_ result: ProbeResult) {
        guard result.state.isGraded else { return nil }
        if result.isValidatedByHand {
            self = .validatedByHand
            return
        }
        switch result.state {
        case .passed: self = .passed
        case .unrecognised: self = .unrecognised
        case .failed: self = .failed
        case .timedOut: self = .timedOut
        case .notRun, .error: return nil
        }
    }

    /// Under a small donut, where the full title does not fit: "1 susp.".
    public var shortTitle: String {
        switch self {
        case .passed: "aprob."
        case .validatedByHand: "a mano"
        case .unrecognised: "no rec."
        case .failed: "susp."
        case .timedOut: "t. agot."
        }
    }

    public var countsAsPassed: Bool { self == .passed || self == .validatedByHand }
}

public struct DonutSlice: Hashable, Sendable, Identifiable {
    public let kind: DonutSliceKind
    public let count: Int

    public init(kind: DonutSliceKind, count: Int) {
        self.kind = kind
        self.count = count
    }

    public var id: DonutSliceKind { kind }

    /// "Aprobadas: 5", the legend line of the slice.
    public var legend: String { kind.title + ": \(count)" }
}

/// One donut: a level, a capability or a model's level. Zero slices are left out.
public struct CapabilityDonut: Hashable, Sendable, Identifiable {
    public enum Coverage: Hashable, Sendable {
        case counted
        /// The report has the level or capability but graded none of its probes.
        case noData
        /// The owner excluded every probe of the capability from that report.
        case excluded
        case notRun
        case notComparable
    }

    public let id: String
    /// What is printed above or under the donut: a level, a capability, "A".
    public let title: String
    /// The model's name in a comparison; empty otherwise.
    public let subtitle: String
    /// Spoken only, for donuts read away from their heading: "Nivel 2", "Nivel 2, Formato".
    public let context: String
    public let slices: [DonutSlice]
    public let status: Coverage

    public init(
        id: String,
        title: String,
        subtitle: String = "",
        context: String = "",
        slices: [DonutSlice],
        status: Coverage
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.context = context
        self.slices = slices
        self.status = status
    }

    public var graded: Int { slices.map(\.count).reduce(0, +) }
    /// Passed plus validated by hand, like every other count of the battery.
    public var passed: Int { slices.filter(\.kind.countsAsPassed).map(\.count).reduce(0, +) }

    /// 0–100, rounded; nil when nothing was graded.
    public var passedPercent: Int? {
        guard graded > 0 else { return nil }
        return Int((Double(passed) / Double(graded) * 100).rounded())
    }

    /// "83 %" in the hole; "—" when there is nothing to chart.
    public var centreText: String { passedPercent.map { "\($0) %" } ?? "—" }

    /// "5/6", "sin datos", "excluida", "sin ejecutar", "no comparable".
    public var countText: String {
        switch status {
        case .counted: "\(passed)/\(graded)"
        case .noData: CapabilityPDFContent.noData
        case .excluded: CapabilityPDFContent.excludedArea
        case .notRun: CapabilityText.levelNotRun
        case .notComparable: "no comparable"
        }
    }

    /// One line per slice, or the coverage when there are none.
    public var legendLines: [String] {
        slices.isEmpty ? [countText] : slices.map(\.legend)
    }

    /// Slices too thin for their count to be printed on them; the legend still has it.
    public static let minimumLabelledShare = 0.08

    public func labelsSlice(_ slice: DonutSlice) -> Bool {
        graded > 0 && Double(slice.count) / Double(graded) >= Self.minimumLabelledShare
    }

    /// Every slice but the plain passed one, named: "1 a mano · 1 susp.", so a small donut does not rest on its
    /// colours; empty when all graded rows passed.
    public var breakdownText: String {
        slices.filter { $0.kind != .passed }.map { "\($0.count) " + $0.kind.shortTitle }.joined(separator: " · ")
    }

    /// What VoiceOver reads: "A, Qwen 3 4B, Nivel 2: 5 de 6 aprobadas (83 %). Aprobadas: 4, Validadas a mano: 1,
    /// Suspendidas: 1."
    public var spokenText: String {
        let name = [title, subtitle, context].filter { !$0.isEmpty }.joined(separator: ", ")
        guard let percent = passedPercent else { return name + ": " + countText + "." }
        return name + ": \(passed) de \(graded) aprobadas (\(percent) %). "
            + slices.map(\.legend).joined(separator: ", ") + "."
    }
}

/// The donuts of the PDFs and the comparison screen, from saved reports.
public enum CapabilityDonuts {
    /// Graded rows by slice, in ``DonutSliceKind`` order, zero slices left out.
    public static func slices(_ results: [ProbeResult]) -> [DonutSlice] {
        let kinds = results.compactMap(DonutSliceKind.init)
        return DonutSliceKind.allCases.compactMap { kind in
            let count = kinds.filter { $0 == kind }.count
            return count > 0 ? DonutSlice(kind: kind, count: count) : nil
        }
    }

    public static func level(_ report: CapabilityReport) -> CapabilityDonut {
        let parts = slices(report.results)
        return CapabilityDonut(id: report.level.rawValue, title: report.level.label, slices: parts,
                               status: status(report, slices: parts))
    }

    /// One per comparable level, in level order.
    public static func levels(_ reports: [CapabilityReport]) -> [CapabilityDonut] {
        CapabilityExport.inLevelOrder(reports).filter(\.isComparable).map(level)
    }

    /// One per capability of a comparable report; empty otherwise.
    public static func capabilities(_ report: CapabilityReport) -> [CapabilityDonut] {
        guard report.isComparable else { return [] }
        return report.level.areas.map { area in
            capability(report, area: area, id: area.rawValue, title: area.title,
                       context: spokenLevel(report.level))
        }
    }

    /// One per compared model, in letter order, so a model keeps its place from level to level; a model without a
    /// comparable report of `level` gets an empty donut that says why.
    public static func comparison(_ models: [ComparedModel], level: CapabilityLevel) -> [CapabilityDonut] {
        models.map { model in
            guard let report = model.report(level) else {
                return placeholder(model, status: .notRun, context: spokenLevel(level))
            }
            guard report.isComparable else {
                return placeholder(model, status: .notComparable, context: spokenLevel(level))
            }
            let parts = slices(report.results)
            return CapabilityDonut(id: model.letter, title: model.letter, subtitle: model.title,
                                   context: spokenLevel(level), slices: parts, status: status(report, slices: parts))
        }
    }

    /// One per compared model for one capability of `level`: the comparison screen's rows.
    public static func comparison(
        _ models: [ComparedModel],
        level: CapabilityLevel,
        area: Capability
    ) -> [CapabilityDonut] {
        let context = spokenLevel(level) + ", " + area.title
        return models.map { model in
            guard let report = model.report(level) else {
                return placeholder(model, status: .notRun, context: context)
            }
            guard report.isComparable else { return placeholder(model, status: .notComparable, context: context) }
            return capability(report, area: area, id: model.letter, title: model.letter, subtitle: model.title,
                              context: context)
        }
    }

    private static func capability(
        _ report: CapabilityReport,
        area: Capability,
        id: String,
        title: String,
        subtitle: String = "",
        context: String
    ) -> CapabilityDonut {
        let rows = report.results.filter { CapabilityBattery.probe(withID: $0.probeID)?.area == area }
        let parts = slices(rows)
        let status: CapabilityDonut.Coverage = if !parts.isEmpty {
            .counted
        } else if report.excludesEveryProbe(of: area) {
            .excluded
        } else {
            .noData
        }
        return CapabilityDonut(id: id, title: title, subtitle: subtitle, context: context, slices: parts,
                               status: status)
    }

    private static func placeholder(
        _ model: ComparedModel,
        status: CapabilityDonut.Coverage,
        context: String
    ) -> CapabilityDonut {
        CapabilityDonut(id: model.letter, title: model.letter, subtitle: model.title, context: context, slices: [],
                        status: status)
    }

    /// "Nivel 2": the label's "·" would be read out.
    private static func spokenLevel(_ level: CapabilityLevel) -> String { "Nivel \(level.number)" }

    private static func status(_ report: CapabilityReport, slices: [DonutSlice]) -> CapabilityDonut.Coverage {
        guard report.isComparable else { return .notComparable }
        return slices.isEmpty ? .noData : .counted
    }
}

// MARK: Layout

/// Fixed sizes of the PDF donuts, shared by the renderer and the kit so a donut row's height is known before it is
/// drawn. Each row of a grid is its own block, so a grid never runs past a page end.
public enum DonutLayout {
    public enum Size: Sendable {
        /// A level or a model's level: title, donut, one legend line per slice.
        case large
        /// A capability: donut, name, count and the breakdown of what did not plainly pass.
        case small
    }

    public static func columns(_ size: Size) -> Int {
        switch size {
        case .large: 4
        case .small: 5
        }
    }

    public static func diameter(_ size: Size) -> Double {
        switch size {
        case .large: 84
        case .small: 56
        }
    }

    /// Lines of the title above a large donut and of the name under a small one.
    public static let titleHeight = 22.0
    public static let legendLineHeight = 10.0
    public static let gap = 3.0
    /// Up to two lines of ``CapabilityDonut/breakdownText`` under a small donut.
    public static let breakdownLineHeight = 8.0
    public static let breakdownLines = 2

    /// The tallest a cell gets: a large one with a legend line for every slice kind, a small one with a breakdown.
    public static func cellHeight(_ size: Size) -> Double {
        switch size {
        case .large: largeHeight(legendLines: DonutSliceKind.allCases.count)
        case .small: smallHeight(breakdown: true)
        }
    }

    /// A row as tall as its longest legend, so a row of all-passed donuts does not keep room for five lines.
    public static func rowHeight(_ donuts: [CapabilityDonut], size: Size) -> Double {
        switch size {
        case .large: largeHeight(legendLines: donuts.map(\.legendLines.count).max() ?? 1)
        case .small: smallHeight(breakdown: donuts.contains { !$0.breakdownText.isEmpty })
        }
    }

    private static func largeHeight(legendLines: Int) -> Double {
        titleHeight + gap + diameter(.large) + gap + Double(max(legendLines, 1)) * legendLineHeight
    }

    private static func smallHeight(breakdown: Bool) -> Double {
        let lines = breakdown ? Double(breakdownLines) * breakdownLineHeight : 0
        return diameter(.small) + gap + titleHeight + legendLineHeight + lines
    }

    /// The legend of slice kinds under a grid of small donuts.
    public static let kindLegendHeight = 12.0

    /// Items in rows of `columns(size)`.
    public static func rows<Item>(_ items: [Item], size: Size) -> [[Item]] {
        let width = columns(size)
        return stride(from: 0, to: items.count, by: width).map { start in
            Array(items[start..<min(start + width, items.count)])
        }
    }

    // MARK: Ring

    /// The hole's share of the diameter.
    public static let innerRadiusRatio = 0.62
    /// On screen the donut follows the text size, so its fonts are a share of its diameter.
    public static let screenSliceFontRatio = 0.13
    public static let screenCentreFontRatio = 0.16
    /// Horizontal inset of the centre text on each side, so it stays inside the hole.
    public static let centreInsetRatio = 0.24

    public static func ringThickness(diameter: Double) -> Double { diameter / 2 * (1 - innerRadiusRatio) }

    /// Whether a line of `fontSize` text (about 1.25 of it tall) sits inside the ring.
    public static func sliceLabelFits(fontSize: Double, diameter: Double) -> Bool {
        fontSize * 1.25 <= ringThickness(diameter: diameter)
    }

    /// Whether the centre text box, `fontSize` tall and as wide as the inset leaves, fits inside the hole.
    public static func centreFits(fontSize: Double, diameter: Double) -> Bool {
        let width = diameter * (1 - 2 * centreInsetRatio)
        let height = fontSize * 1.25
        let hole = diameter * innerRadiusRatio
        return width * width + height * height <= hole * hole
    }
}

/// A grid of donuts as the PDF lays it out: one block per row, then the kind legend when it has one. The renderer
/// and the page-height checks both take their blocks from here.
public struct DonutGrid: Sendable {
    public let cellSize: DonutLayout.Size
    public let rows: [[CapabilityDonut]]
    public let hasKindLegend: Bool

    public init(_ donuts: [CapabilityDonut], size: DonutLayout.Size, kindLegend: Bool) {
        cellSize = size
        rows = DonutLayout.rows(donuts, size: size)
        hasKindLegend = kindLegend && !rows.isEmpty
    }

    /// Block heights in PDF order.
    public var heights: [Double] {
        rows.map { DonutLayout.rowHeight($0, size: cellSize) } + (hasKindLegend ? [DonutLayout.kindLegendHeight] : [])
    }

    /// A donut per comparable level of one model.
    public static func byLevel(_ reports: [CapabilityReport]) -> DonutGrid {
        DonutGrid(CapabilityDonuts.levels(reports), size: .large, kindLegend: false)
    }

    /// A small donut per capability of one level; small donuts carry no per-slice legend, so the grid gets the key.
    public static func byCapability(_ report: CapabilityReport) -> DonutGrid {
        DonutGrid(CapabilityDonuts.capabilities(report), size: .small, kindLegend: true)
    }

    /// A donut per compared model for one level; each carries its own legend lines.
    public static func comparison(_ models: [ComparedModel], level: CapabilityLevel) -> DonutGrid {
        DonutGrid(CapabilityDonuts.comparison(models, level: level), size: .large, kindLegend: false)
    }
}

extension CapabilityChartStyle {
    /// Chart blocks of the single-model summary, in PDF order: the by-level chart, then each level's capability
    /// chart. Donuts give one block per row plus the kind legend under each capability grid.
    public func summaryChartHeights(_ reports: [CapabilityReport]) -> [Double] {
        let levels = CapabilityExport.inLevelOrder(reports)
        switch self {
        case .bars:
            let byLevel = CapabilityPDFContent.levelBars(levels)
            var heights = levels.count > 1 && !byLevel.isEmpty
                ? [CapabilityPDFContent.chartHeight(categories: byLevel.count / 2, series: 2)] : []
            heights += levels.filter(\.isComparable).map { report in
                CapabilityPDFContent.chartHeight(categories: report.level.areas.count, series: 2)
            }
            return heights
        case .donuts:
            return DonutGrid.byLevel(levels).heights + levels.flatMap { DonutGrid.byCapability($0).heights }
        }
    }

    /// Chart blocks of one level of a comparison PDF, in order. Bars come in groups that each fit `height`.
    public func comparisonChartHeights(_ models: [ComparedModel], level: CapabilityLevel, height: Double) -> [Double] {
        switch self {
        case .bars:
            return CapabilityPDFContent.chartGroups(models, level: level, height: height).map { group in
                CapabilityPDFContent.chartHeight(categories: level.areas.count, series: group.count)
            }
        case .donuts:
            return DonutGrid.comparison(models, level: level).heights
        }
    }

    /// The model columns of the donut comparison's per-capability tables: as few tables as
    /// `CapabilityPDFContent.maxModelsPerChart` allows, sized evenly (9 models: 5 and 4, not 8 and 1).
    public static func tableGroups<Item>(_ items: [Item]) -> [[Item]] {
        guard !items.isEmpty else { return [] }
        let tables = (items.count + CapabilityPDFContent.maxModelsPerChart - 1) / CapabilityPDFContent.maxModelsPerChart
        let size = (items.count + tables - 1) / tables
        return stride(from: 0, to: items.count, by: size).map { start in
            Array(items[start..<min(start + size, items.count)])
        }
    }
}
