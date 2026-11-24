import Charts
import SwiftUI
import TerminalBridgeKit

/// The saved results as an A4 PDF: SwiftUI blocks measured one by one, paged by `PDFPageLayout`, and drawn page by
/// page with `ImageRenderer` into one PDF context. Always light, whatever the app's appearance.
enum CapabilityPDF {
    static let pageSize = CGSize(width: 595.28, height: 841.89)
    static let margin: CGFloat = 40
    static let spacing: CGFloat = 6
    static let footerHeight: CGFloat = 14
    static var contentWidth: CGFloat { pageSize.width - 2 * margin }
    static var contentHeight: CGFloat { pageSize.height - 2 * margin - footerHeight - spacing }

    // MARK: Documents

    /// One model's saved levels, following the same reply rule as the Markdown and JSON exports.
    static func report(
        _ reports: [CapabilityReport],
        options: CapabilityExportOptions,
        exportedAt: Date,
        chartStyle: CapabilityChartStyle
    ) -> Data {
        let levels = reports.sorted { $0.level.number < $1.level.number }
        let title = levels.max { $0.date < $1.date }?.modelTitle ?? ""
        var blocks = coverBlocks(levels, title: title, options: options, exportedAt: exportedAt)
        blocks += chartStyle == .bars ? summaryBlocks(levels) : donutSummaryBlocks(levels)
        blocks += probeTableBlocks(levels)
        blocks += notPassedBlocks(levels, options: options)
        return render(blocks, title: CapabilityText.title + " · " + title)
    }

    /// The models side by side; no replies. `includesMatrix`: the owner's selection of 2 or 3, which adds the
    /// per-probe matrix and says plainly when settings differ.
    static func comparison(
        _ models: [[CapabilityReport]],
        exportedAt: Date,
        chartStyle: CapabilityChartStyle,
        includesMatrix: Bool = false
    ) -> Data {
        let compared = CapabilityPDFContent.comparedModels(models)
        var blocks = [
            block(PDFText.title(CapabilityPDFContent.comparisonTitle)),
            block(PDFText.body("Exportado: " + CapabilityDateStyle.printed.string(from: exportedAt) + " · "
                + CapabilityPDFContent.paperNote, secondary: true)),
        ]
        let notes = includesMatrix
            ? CapabilityComparison.notes(compared) + [CapabilityPDFContent.olderBatteryNote(compared)].compactMap { $0 }
            : CapabilityPDFContent.comparisonNotes(compared)
        blocks += notes.map { block(PDFText.body($0, bold: true)) }
        let levels = CapabilityPDFContent.chartedLevels(compared)
        if levels.isEmpty {
            blocks.append(block(PDFText.body(CapabilityPDFContent.noComparableReports)))
        }
        let colours = includesMatrix ? ModelComparisonView.palette : BarsChart.palette
        blocks += levels.enumerated().flatMap { item in
            chartStyle == .bars
                ? comparisonCharts(compared, level: item.element, colours: colours)
                : comparisonDonuts(compared, level: item.element, tableID: 100 + 10 * item.offset)
        }
        blocks += table(title: CapabilityPDFContent.verdictTitle, columns: CapabilityPDFContent.verdictColumns,
                        widths: verdictWidths, rows: compared.map(CapabilityPDFContent.verdictCells), tableID: 1)
        let verdictLines = includesMatrix ? CapabilityComparison.verdictLines(compared) : []
        if !verdictLines.isEmpty {
            blocks.append(block(PDFText.heading(CapabilityComparison.verdictLinesTitle), keepsWithNext: true))
            blocks += verdictLines.map { block(PDFText.body($0)) }
        }
        let settingsRows = compared.flatMap { model in
            model.reports.map { CapabilityPDFContent.settingsCells(model, report: $0) }
        }
        blocks += table(title: CapabilityPDFContent.settingsTitle, columns: CapabilityPDFContent.settingsColumns,
                        widths: settingsWidths, rows: settingsRows, tableID: 2)
        if includesMatrix {
            blocks += matrixBlocks(compared)
        }
        return render(blocks, title: CapabilityText.title + " · " + CapabilityPDFContent.comparisonTitle)
    }

    /// From a page of its own: per level, a row per probe and a column per model.
    private static func matrixBlocks(_ compared: [ComparedModel]) -> [Block] {
        let legend = CapabilityPDFContent.legendLines(compared).map(ExportText.revealingInvisibles)
        var blocks = [block(PDFText.title(CapabilityComparison.matrixTitle), startsPage: true),
                      block(PDFText.body(legend.joined(separator: "   "), secondary: true)),
                      block(PDFText.body(CapabilityComparison.matrixLegend, secondary: true))]
        let widths: [CGFloat] = [14, 0] + Array(repeating: compared.count > 2 ? 104 : 130, count: compared.count)
        let columns = ["#", "Prueba"] + compared.map(\.letter)
        blocks += CapabilityComparison.levels(compared).enumerated().flatMap { item in
            let rows = CapabilityComparison.matrix(compared, level: item.element).map(CapabilityComparison.matrixCells)
            return table(title: item.element.label, columns: columns, widths: widths, rows: rows,
                         tableID: 20 + item.offset)
        }
        let marked = CapabilityComparison.levels(compared).contains { level in
            CapabilityComparison.matrix(compared, level: level).contains { $0.cells.contains(where: \.validatedByHand) }
        }
        if marked {
            blocks.append(block(PDFText.body(CapabilityComparison.validatedFootnote, secondary: true)))
        }
        return blocks
    }

    /// Room the heading above and the two-line legend below each chart take on its page.
    private static let chartHeadingAllowance: CGFloat = 70

    /// One chart per group of models that fits a page, each with its heading and its own legend. A model keeps its
    /// colour from chart to chart, even when another one has no bar in some.
    private static func comparisonCharts(
        _ compared: [ComparedModel],
        level: CapabilityLevel,
        colours: [Color]
    ) -> [Block] {
        let groups = CapabilityPDFContent.chartGroups(compared, level: level,
                                                      height: Double(contentHeight - chartHeadingAllowance))
        return groups.enumerated().flatMap { item in
            let part = groups.count > 1 ? " (\(item.offset + 1) de \(groups.count))" : ""
            let legend = CapabilityPDFContent.legendLines(item.element).map(ExportText.revealingInvisibles)
            let heading = level.label + " · % de aprobadas por capacidad" + part
            return [block(PDFText.heading(heading), keepsWithNext: true),
                    block(BarsChart(bars: CapabilityPDFContent.comparisonBars(item.element, level: level),
                                    series: item.element.map(\.letter), percent: true,
                                    colours: item.element.map { colour(of: $0, in: compared, from: colours) }),
                          keepsWithNext: true),
                    block(PDFText.body(legend.joined(separator: "   "), secondary: true))]
        }
    }

    /// Per level, a donut per model in letter order (an empty one says why a model has none), then the share per
    /// capability as a table, at most `CapabilityPDFContent.maxModelsPerChart` model columns per table.
    private static func comparisonDonuts(_ compared: [ComparedModel], level: CapabilityLevel, tableID: Int) -> [Block] {
        let legend = CapabilityPDFContent.legendLines(compared).map(ExportText.revealingInvisibles)
        var blocks = [block(PDFText.heading(level.label + " · " + CapabilityPDFContent.donutComparisonHeading),
                            keepsWithNext: true)]
        blocks += donutGridBlocks(DonutGrid.comparison(compared, level: level), keepsLastWithNext: true)
        blocks.append(block(PDFText.body(legend.joined(separator: "   "), secondary: true)))
        let groups = CapabilityChartStyle.tableGroups(compared)
        blocks += groups.enumerated().flatMap { item in
            let part = groups.count > 1 ? " (\(item.offset + 1) de \(groups.count))" : ""
            let cells = CapabilityComparison.capabilityRows(item.element, level: level).map { row in
                [row.area.title] + row.cells.map(\.shareText)
            }
            let width: CGFloat = item.element.count > 4 ? 46 : 80
            return table(title: level.label + " · " + CapabilityPDFContent.donutComparisonTableTitle + part,
                         columns: ["Capacidad"] + item.element.map(\.letter),
                         widths: [0] + Array(repeating: width, count: item.element.count), rows: cells,
                         tableID: tableID + item.offset)
        }
        return blocks
    }

    /// One block per grid row, so the page plan breaks between rows and never inside a donut, then the kind legend
    /// when the grid has one. `keepsLastWithNext` ties the last block to whatever follows the grid.
    static func donutGridBlocks(_ grid: DonutGrid, keepsLastWithNext: Bool) -> [Block] {
        var blocks = grid.rows.map { row in block(PDFDonutRow(donuts: row, cellSize: grid.cellSize)) }
        if grid.hasKindLegend, !blocks.isEmpty {
            blocks[blocks.count - 1].keepsWithNext = true
            blocks.append(block(PDFDonutKindLegend()))
        }
        if keepsLastWithNext, !blocks.isEmpty {
            blocks[blocks.count - 1].keepsWithNext = true
        }
        return blocks
    }

    private static func colour(of model: ComparedModel, in compared: [ComparedModel], from colours: [Color]) -> Color {
        let index = compared.firstIndex(of: model) ?? 0
        return colours[index % colours.count]
    }

    // MARK: Single-model sections

    private static func coverBlocks(
        _ levels: [CapabilityReport],
        title: String,
        options: CapabilityExportOptions,
        exportedAt: Date
    ) -> [Block] {
        var blocks = [
            block(PDFText.body(CapabilityText.title, secondary: true), startsPage: true),
            block(PDFText.title(ExportText.revealingInvisibles(title))),
            block(PDFText.body("Exportado: " + CapabilityDateStyle.printed.string(from: exportedAt) + " · "
                + CapabilityPDFContent.paperNote, secondary: true)),
        ]
        let filters = CapabilityExport.safetyFiltersLines(levels)
        if let mark = filters.first {
            blocks.append(block(PDFText.body(mark, bold: true)))
            blocks += filters.dropFirst().map { block(PDFText.body($0)) }
        }
        blocks += levels.map { report in
            block(CoverLevel(report: report))
        }
        if options.includeReplies {
            blocks.append(block(PDFText.body(CapabilityText.exportWarning, bold: true)))
        }
        blocks.append(block(PDFText.body(CapabilityText.footer, secondary: true)))
        return blocks
    }

    private static func summaryBlocks(_ levels: [CapabilityReport]) -> [Block] {
        var blocks = [block(PDFText.title(CapabilityPDFContent.summaryTitle), startsPage: true)]
        let byLevel = CapabilityPDFContent.levelBars(levels)
        if levels.count > 1, !byLevel.isEmpty {
            blocks.append(block(PDFText.heading(CapabilityPDFContent.byLevelTitle), keepsWithNext: true))
            blocks.append(block(BarsChart(bars: byLevel, series: twoSeries, percent: false)))
        }
        blocks += levels.flatMap(levelSummary)
        return blocks
    }

    private static let twoSeries = [CapabilityPDFContent.passedSeries, CapabilityPDFContent.gradedSeries]

    /// Donuts: a donut per comparable level (even a single one), then per level a grid of capability donuts.
    private static func donutSummaryBlocks(_ levels: [CapabilityReport]) -> [Block] {
        var blocks = [block(PDFText.title(CapabilityPDFContent.summaryTitle), startsPage: true)]
        let byLevel = DonutGrid.byLevel(levels)
        if !byLevel.rows.isEmpty {
            blocks.append(block(PDFText.heading(CapabilityPDFContent.donutByLevelTitle), keepsWithNext: true))
            blocks += donutGridBlocks(byLevel, keepsLastWithNext: false)
        }
        blocks += levels.flatMap { report in
            var level = [block(PDFText.heading(CapabilityPDFContent.levelHeading(report)), keepsWithNext: true)]
            level += CapabilityText.verdictLines(report).map { line in
                block(PDFText.body(line, bold: true), keepsWithNext: true)
            }
            let grid = DonutGrid.byCapability(report)
            if !grid.rows.isEmpty {
                level.append(block(PDFText.body(CapabilityPDFContent.donutByCapabilityTitle, secondary: true),
                                   keepsWithNext: true))
                level += donutGridBlocks(grid, keepsLastWithNext: false)
            }
            return level
        }
        return blocks
    }

    private static func levelSummary(_ report: CapabilityReport) -> [Block] {
        var blocks = [block(PDFText.heading(CapabilityPDFContent.levelHeading(report)), keepsWithNext: true)]
        blocks += CapabilityText.verdictLines(report).map { line in
            block(PDFText.body(line, bold: true), keepsWithNext: true)
        }
        let bars = CapabilityPDFContent.capabilityBars(report)
        if !bars.isEmpty {
            blocks.append(block(PDFText.body(CapabilityPDFContent.byCapabilityTitle, secondary: true),
                                keepsWithNext: true))
            blocks.append(block(BarsChart(bars: bars, series: twoSeries, percent: false)))
        }
        return blocks
    }

    private static func probeTableBlocks(_ levels: [CapabilityReport]) -> [Block] {
        var blocks = [block(PDFText.title(CapabilityPDFContent.probesTitle), startsPage: true)]
        blocks += levels.enumerated().flatMap { item in
            let rows = CapabilityExport.numberedResults(item.element).map { row in
                CapabilityPDFContent.probeCells(number: row.number, result: row.result) { date in
                    CapabilityDateStyle.printed.string(from: date)
                }
            }
            return table(title: CapabilityPDFContent.levelHeading(item.element),
                         columns: CapabilityPDFContent.probeColumns, widths: probeWidths, rows: rows,
                         tableID: 10 + item.offset)
        }
        return blocks
    }

    private static func notPassedBlocks(_ levels: [CapabilityReport], options: CapabilityExportOptions) -> [Block] {
        let sections = levels.flatMap { report in
            CapabilityExport.numberedResults(report)
                .filter { $0.result.state != .passed && $0.result.state != .notRun }
                .map { probeSection(number: $0.number, result: $0.result, report: report, options: options) }
        }
        guard !sections.isEmpty else { return [] }
        return [block(PDFText.title(CapabilityPDFContent.notPassedTitle), startsPage: true)] + sections.flatMap { $0 }
    }

    private static func probeSection(
        number: Int,
        result: ProbeResult,
        report: CapabilityReport,
        options: CapabilityExportOptions
    ) -> [Block] {
        let probe = CapabilityBattery.probe(withID: result.probeID)
        var blocks = [
            block(PDFText.heading("\(number). " + (probe?.title ?? result.probeID) + " · " + report.level.label),
                  keepsWithNext: true),
            block(PDFText.body("Estado: " + CapabilityText.exportState(result)), keepsWithNext: true),
        ]
        if report.isComparable, let probe {
            blocks.append(block(PDFText.label(CapabilityText.askedSection), keepsWithNext: true))
            blocks += ExportText.chunks(probe.request).map { block(PDFText.mono($0)) }
            blocks.append(block(PDFText.label(CapabilityText.expectedSection), keepsWithNext: true))
            blocks.append(block(PDFText.body(probe.expectation)))
        }
        blocks += replyBlocks(CapabilityExport.reply(for: result, options: options))
        blocks.append(block(PDFText.label(CapabilityText.reasonSection), keepsWithNext: true))
        let why = ([result.reason] + (result.notes ?? [])).filter { !$0.isEmpty }
        blocks += why.map { block(PDFText.body(ExportText.revealingInvisibles($0))) }
        let opinion = CapabilityPDFContent.secondOpinionLines(result, options: options)
        if !opinion.isEmpty {
            blocks.append(block(PDFText.label(ClaudeJudgeText.secondOpinionSection), keepsWithNext: true))
            blocks += opinion.map { block(PDFText.body($0)) }
        }
        return blocks
    }

    private static func replyBlocks(_ reply: ExportedReply) -> [Block] {
        if case .none = reply { return [] }
        var blocks = [block(PDFText.label(CapabilityText.repliedSection), keepsWithNext: true)]
        guard case .shown(let saved, let marked) = reply else {
            return blocks + [block(PDFText.body(CapabilityExport.replacementText(reply) ?? "", secondary: true))]
        }
        if marked {
            blocks.append(block(PDFText.body(CapabilityText.markedReplyNotice, bold: true), keepsWithNext: true))
        }
        blocks += replyText(saved.answer.isEmpty ? CapabilityText.emptyReply : saved.answer, marked: marked)
            .map { block(PDFText.mono($0, marked: marked)) }
        if saved.answerTruncated {
            blocks.append(block(PDFText.body(CapabilityText.answerTruncated, secondary: true)))
        }
        if let reasoning = saved.reasoning {
            blocks.append(block(PDFText.label(CapabilityText.reasoningSection, small: true), keepsWithNext: true))
            blocks += replyText(reasoning, marked: marked).map { block(PDFText.mono($0, marked: marked, small: true)) }
            if saved.reasoningTruncated {
                blocks.append(block(PDFText.body(CapabilityText.reasoningTruncated, secondary: true)))
            }
        }
        return blocks
    }

    private static func replyText(_ text: String, marked: Bool) -> [String] {
        let shown = ExportText.revealingInvisibles(text)
        return ExportText.chunks(marked ? CapabilityExport.markedLines(shown) : shown)
    }

    // MARK: Tables

    private static let probeWidths: [CGFloat] = [14, 104, 70, 76, 32, 52, 0]
    private static let verdictWidths: [CGFloat] = [14, 120, 0, 0, 0]
    private static let settingsWidths: [CGFloat] = [14, 96, 40, 92, 104, 0]

    /// A heading, a header row repeated on every page the table reaches, and one block per row.
    private static func table(
        title: String,
        columns: [String],
        widths: [CGFloat],
        rows: [[String]],
        tableID: Int
    ) -> [Block] {
        guard !rows.isEmpty else { return [] }
        let header = Block(view: AnyView(TableRow(cells: columns, widths: widths, isHeader: true)),
                           keepsWithNext: true, role: .header(tableID))
        let body = rows.enumerated().map { item in
            Block(view: AnyView(TableRow(cells: item.element.map(ExportText.revealingInvisibles), widths: widths,
                                         isShaded: item.offset.isMultiple(of: 2))),
                  role: .row(tableID))
        }
        return [block(PDFText.heading(title), keepsWithNext: true), header] + body
    }

    // MARK: Paging and drawing

    enum BlockRole: Hashable {
        case plain
        case header(Int)
        case row(Int)
    }

    struct Block {
        let view: AnyView
        var startsPage = false
        var keepsWithNext = false
        var role = BlockRole.plain
    }

    private static func block(_ view: some View, startsPage: Bool = false, keepsWithNext: Bool = false) -> Block {
        Block(view: AnyView(view), startsPage: startsPage, keepsWithNext: keepsWithNext)
    }

    static func render(_ blocks: [Block], title: String) -> Data {
        let headers = Dictionary(blocks.enumerated().compactMap { item -> (Int, Int)? in
            guard case .header(let table) = item.element.role else { return nil }
            return (table, item.offset)
        }) { first, _ in first }
        let layout = blocks.map { item -> PDFLayoutBlock in
            var header: Int?
            if case .row(let table) = item.role { header = headers[table] }
            return PDFLayoutBlock(height: Double(measuredHeight(item.view)), startsPage: item.startsPage,
                                  keepsWithNext: item.keepsWithNext, header: header)
        }
        let pages = PDFPageLayout.pages(for: layout, pageHeight: Double(contentHeight), spacing: Double(spacing))
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "Tonamox Terminal"]
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary) else { return Data() }
        for (index, page) in pages.enumerated() {
            draw(page.map { blocks[$0].view }, title: title,
                 pageText: CapabilityPDFContent.pageFooter(page: index + 1, of: pages.count), in: context)
        }
        context.closePDF()
        return data as Data
    }

    static func measuredHeight(_ view: AnyView) -> CGFloat {
        let renderer = ImageRenderer(content: view.frame(width: contentWidth, alignment: .leading)
            .environment(\.colorScheme, .light)
            .environment(\.dynamicTypeSize, printedTypeSize))
        renderer.proposedSize = ProposedViewSize(width: contentWidth, height: nil)
        var height: CGFloat = 0
        renderer.render { size, _ in height = size.height }
        return height
    }

    /// Paper does not follow the phone's text size: measuring and drawing must agree whatever the owner set.
    static let printedTypeSize = DynamicTypeSize.large

    private static func draw(_ views: [AnyView], title: String, pageText: String, in context: CGContext) {
        let renderer = ImageRenderer(content: PDFPage(blocks: views, title: title, pageText: pageText))
        renderer.proposedSize = ProposedViewSize(pageSize)
        context.beginPDFPage(nil)
        renderer.render { _, drawPage in drawPage(context) }
        context.endPDFPage()
    }
}

/// One A4 page: the blocks from the top, clipped to the content box, and the footer at the bottom.
private struct PDFPage: View {
    let blocks: [AnyView]
    let title: String
    let pageText: String

    var body: some View {
        VStack(alignment: .leading, spacing: CapabilityPDF.spacing) {
            VStack(alignment: .leading, spacing: CapabilityPDF.spacing) {
                ForEach(blocks.indices, id: \.self) { index in
                    blocks[index].frame(width: CapabilityPDF.contentWidth, alignment: .leading)
                }
            }
            .frame(width: CapabilityPDF.contentWidth, height: CapabilityPDF.contentHeight, alignment: .topLeading)
            .clipped()
            // A long model title gives way before the page number does.
            HStack(spacing: 0) {
                Text(verbatim: ExportText.revealingInvisibles(title) + " · ")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: pageText)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .font(.system(size: 7))
            .foregroundStyle(PDFText.secondary)
            .frame(width: CapabilityPDF.contentWidth, height: CapabilityPDF.footerHeight, alignment: .trailing)
        }
        .padding(CapabilityPDF.margin)
        .frame(width: CapabilityPDF.pageSize.width, height: CapabilityPDF.pageSize.height, alignment: .topLeading)
        .background(Color.white)
        .foregroundStyle(Color.black)
        .environment(\.colorScheme, .light)
        .environment(\.dynamicTypeSize, CapabilityPDF.printedTypeSize)
    }
}

/// Text styles of the PDF: system fonts at print sizes, black on white.
private enum PDFText {
    static let secondary = Color(white: 0.35)
    static let codeBackground = Color(white: 0.94)

    static func title(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: 20, weight: .bold)).fixedSize(horizontal: false, vertical: true)
    }

    static func heading(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: 12, weight: .semibold)).padding(.top, 6)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func label(_ text: String, small: Bool = false) -> some View {
        Text(verbatim: text).font(.system(size: small ? 8 : 9, weight: .semibold)).padding(.top, 2)
    }

    static func body(_ text: String, bold: Bool = false, secondary isSecondary: Bool = false) -> some View {
        Text(verbatim: text)
            .font(.system(size: 9, weight: bold ? .semibold : .regular))
            .foregroundStyle(isSecondary ? secondary : Color.black)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Replies are inert text; a marked one (Seguridad or flagged) carries a bar on the left as well as `▌`.
    static func mono(_ text: String, marked: Bool = false, small: Bool = false) -> some View {
        Text(verbatim: text)
            .font(.system(size: small ? 6.5 : 7.5, design: .monospaced))
            .foregroundStyle(small ? secondary : Color.black)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
            .background(codeBackground)
            .overlay(alignment: .leading) {
                if marked { Rectangle().fill(Color.black).frame(width: 2) }
            }
    }
}

private struct CoverLevel: View {
    let report: CapabilityReport

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: CapabilityPDFContent.levelHeading(report))
                .font(.system(size: 11, weight: .semibold))
            Text(verbatim: "Ejecutado: " + CapabilityDateStyle.printed.string(from: report.date))
            ForEach(CapabilityPDFContent.settingsLines(report), id: \.self) { line in
                Text(verbatim: line)
            }
            if !report.isComparable {
                Text(verbatim: CapabilityText.olderBattery)
            }
        }
        .font(.system(size: 9))
        .padding(.top, 8)
    }
}

/// `widths`: 0 shares what is left. Header rows are bold with a rule under them.
private struct TableRow: View {
    let cells: [String]
    let widths: [CGFloat]
    var isHeader = false
    var isShaded = false

    private var flexibleWidth: CGFloat {
        let fixed = widths.reduce(0, +) + CGFloat(max(cells.count - 1, 0)) * 4 + 8
        let flexible = max(widths.filter { $0 == 0 }.count, 1)
        return max((CapabilityPDF.contentWidth - fixed) / CGFloat(flexible), 20)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(cells.indices, id: \.self) { index in
                Text(verbatim: cells[index])
                    .font(.system(size: 7, weight: isHeader ? .semibold : .regular))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: width(index), alignment: .leading)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(width: CapabilityPDF.contentWidth, alignment: .leading)
        .background(isShaded ? Color(white: 0.96) : Color.white)
        .overlay(alignment: .bottom) {
            if isHeader { Rectangle().fill(Color.black).frame(height: 0.5) }
        }
    }

    private func width(_ index: Int) -> CGFloat {
        let fixed = index < widths.count ? widths[index] : 0
        return fixed > 0 ? fixed : flexibleWidth
    }
}

/// Horizontal grouped bars; every bar carries its value or model letter, so no series rests on colour alone.
private struct BarsChart: View {
    let bars: [CapabilityChartBar]
    let series: [String]
    let percent: Bool
    /// One per series; nil takes ``palette`` in series order.
    var colours: [Color]?

    static let palette = [Color(red: 0.12, green: 0.23, blue: 0.48), Color(red: 0.70, green: 0.75, blue: 0.80),
                                  Color(red: 0.85, green: 0.45, blue: 0.10), Color(red: 0.18, green: 0.52, blue: 0.34),
                                  Color(red: 0.52, green: 0.27, blue: 0.60), Color(red: 0.70, green: 0.20, blue: 0.20)]

    private var seriesColours: [Color] {
        colours ?? series.indices.map { Self.palette[$0 % Self.palette.count] }
    }

    private var categories: Int { Set(bars.map(\.category)).count }

    /// Fixed print size: the default legend font follows the phone's text size.
    private func legendItem(_ index: Int) -> some View {
        HStack(spacing: 3) {
            Rectangle().fill(seriesColours[index]).frame(width: 7, height: 7)
            Text(verbatim: series[index]).font(.system(size: 7))
        }
    }

    private var upperBound: Double {
        percent ? 125 : max(bars.map(\.value).max() ?? 1, 1) * 1.25
    }

    var body: some View {
        Chart(bars) { bar in
            BarMark(x: .value("Valor", bar.value), y: .value("Capacidad", bar.category), height: .fixed(8))
                .position(by: .value("Serie", bar.series))
                .foregroundStyle(by: .value("Serie", bar.series))
                .annotation(position: .trailing, alignment: .leading, spacing: 2) {
                    Text(verbatim: bar.annotation)
                        .font(.system(size: 6.5))
                        .foregroundStyle(Color.black)
                }
        }
        .chartForegroundStyleScale(domain: series, range: seriesColours)
        .chartXScale(domain: 0...upperBound)
        .chartXAxis {
            if percent {
                AxisMarks(values: [0, 25, 50, 75, 100]) { _ in
                    AxisGridLine()
                    AxisValueLabel().font(.system(size: 7))
                }
            } else {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisGridLine()
                    AxisValueLabel().font(.system(size: 7))
                }
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisValueLabel().font(.system(size: 7))
            }
        }
        .chartLegend(position: .bottom, alignment: .leading) {
            HStack(spacing: 8) {
                ForEach(series.indices, id: \.self, content: legendItem)
            }
        }
        .frame(width: CapabilityPDF.contentWidth,
               height: CGFloat(CapabilityPDFContent.chartHeight(categories: categories, series: series.count)))
        .environment(\.colorScheme, .light)
    }
}
