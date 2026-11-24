import Charts
import SwiftUI
import TerminalBridgeKit

/// "Comparar modelos": the saved models, newest first, to pick 2 or 3 from. A fourth pick is refused with a message
/// under its row; an earlier pick is never swapped out.
struct ComparisonPickerView: View {
    @ObservedObject var store: CapabilityResultStore
    @State private var selection = ComparisonSelection()
    @State private var refusedKey: String?
    @State private var showsComparison = false

    var body: some View {
        let saved = store.savedModels
        List {
            Section {
                ForEach(saved, id: \.self) { modelKey in
                    pickerRow(modelKey, saved: saved)
                    if refusedKey == modelKey {
                        Label {
                            Text(verbatim: CapabilityText.comparePickerRefused)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.circle")
                        }
                        .font(.callout)
                        .accessibilityIdentifier("compare.picker.refused")
                    }
                }
            } header: {
                Text(verbatim: CapabilityText.comparePickerHeader(selected: selection.count))
                    .accessibilityIdentifier("compare.picker.header")
            } footer: {
                Text(verbatim: CapabilityText.comparePickerFooter)
            }
            Section {
                Button(CapabilityText.compareAction(selected: selection.count)) {
                    showsComparison = true
                }
                .disabled(!selection.canCompare)
                .accessibilityIdentifier("compare.picker.compare")
                if !selection.canCompare {
                    Text(verbatim: CapabilityText.comparePickerNeedsMore)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(CapabilityText.comparePickerTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showsComparison) {
            ModelComparisonView(store: store, modelKeys: selection.ordered(by: store.savedModels))
        }
        .onChange(of: saved) {
            selection = selection.pruned(to: store.savedModels)
        }
    }

    private func pickerRow(_ modelKey: String, saved: [String]) -> some View {
        let levels = store.levels(of: modelKey)
        let newest = levels.max { $0.date < $1.date }
        let isSelected = selection.contains(modelKey)
        let letter = selection.ordered(by: saved).firstIndex(of: modelKey).map(CapabilityPDFContent.letter)
        return Button {
            toggle(modelKey)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: newest?.modelTitle ?? modelKey)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.primary)
                    if CapabilityExport.safetyFiltersRemoved(levels) {
                        SafetyFiltersMark()
                    }
                    if let newest {
                        Text(verbatim: CapabilityDateStyle.saved.string(from: newest.date))
                    }
                    Text(verbatim: CapabilityText.levelsRun(levels))
                    Text(verbatim: CapabilityText.overallVerdict(levels))
                        .fontWeight(.semibold)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let letter {
                    Text(verbatim: letter)
                        .font(.callout.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .overlay(Capsule().stroke(Color.accentColor))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("compare.picker.row." + modelKey)
    }

    private func toggle(_ modelKey: String) {
        if selection.toggle(modelKey) == .refused {
            refusedKey = modelKey
            AccessibilityNotification.Announcement(CapabilityText.comparePickerRefused).post()
        } else {
            refusedKey = nil
        }
    }
}

/// A saved probe opened from a comparison cell.
private struct OpenedProbe: Hashable {
    let modelKey: String
    let level: CapabilityLevel
    let probeID: String
    let context: String
}

/// 2 or 3 saved models side by side for one level: verdicts, passed out of graded per capability as donuts or bars
/// (the PDFs' stored chart style), and a probe-by-probe matrix whose cells open the probe's detail page, read-only.
/// States are symbols and words, models letters, so nothing rests on colour.
struct ModelComparisonView: View {
    @ObservedObject var store: CapabilityResultStore
    /// In the saved list's order: A, B, C.
    let modelKeys: [String]
    @State private var chosenLevel: CapabilityLevel?
    @State private var opened: OpenedProbe?
    @State private var pendingShare: SharedExport?
    @State private var choosesPDFCharts = false
    @AppStorage(CapabilityChartStyle.defaultsKey) private var chartStyle = CapabilityChartStyle.fallback
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .caption) private var barRow: CGFloat = 22
    @ScaledMetric(relativeTo: .caption) private var donutDiameter: CGFloat = 64
    /// Three columns fit an iPhone's width at the default text size; larger text scrolls sideways.
    @ScaledMetric(relativeTo: .caption) private var cellColumn: CGFloat = 100

    static let palette: [Color] = [.blue, .orange, .green]

    private var reportsByModel: [[CapabilityReport]] {
        Self.reports(in: store, modelKeys: modelKeys)
    }

    /// What the page shows and its exports carry: the picked models' saved levels, in `modelKeys` order.
    static func reports(in store: CapabilityResultStore, modelKeys: [String]) -> [[CapabilityReport]] {
        modelKeys.map(store.levels(of:)).filter { !$0.isEmpty }
    }

    var body: some View {
        let models = CapabilityPDFContent.comparedModels(reportsByModel)
        let levels = CapabilityComparison.levels(models)
        let level = chosenLevel.flatMap { levels.contains($0) ? $0 : nil } ?? CapabilityComparison.defaultLevel(models)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                legendCard(models)
                Picker(CapabilityChartStyle.screenPickerTitle, selection: $chartStyle) {
                    ForEach(CapabilityChartStyle.allCases, id: \.self) { item in
                        Text(verbatim: item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel(Text(verbatim: CapabilityChartStyle.screenPickerTitle))
                .accessibilityIdentifier("compare.chartStyle")
                if levels.count > 1, let level {
                    Picker(CapabilityText.compareLevelPicker, selection: levelBinding(level)) {
                        ForEach(levels, id: \.self) { item in
                            Text(verbatim: "Nivel \(item.number)").tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("compare.level")
                }
                if let level {
                    Text(verbatim: level.label)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    if let note = CapabilityComparison.settingsNote(models, level: level) {
                        settingsWarning(note)
                    }
                    if let note = CapabilityComparison.olderBatteryNote(models, level: level) {
                        Label(note, systemImage: "info.circle")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("compare.olderBattery")
                    }
                    if let note = CapabilityComparison.excludedNote(models, level: level) {
                        Label(note, systemImage: CapabilityText.excludedSymbol)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("compare.excluded")
                    }
                    verdictCard(models, level: level)
                    capabilityCard(models, level: level)
                    matrixCard(models, level: level)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(CapabilityText.compareModels)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                exportMenu
            }
        }
        .navigationDestination(item: $opened) { item in
            detail(item)
        }
        .onAppear(perform: ExportDirectory.clear)
        .onDisappear(perform: ExportDirectory.clear)
        .exportShareSheet($pendingShare)
        .pdfChartChoice(isPresented: $choosesPDFCharts) { style in
            pendingShare = try? ExportFile.selection(reportsByModel, format: .pdf(style)).write()
        }
        .accessibilityIdentifier("compare.page")
    }

    private func levelBinding(_ level: CapabilityLevel) -> Binding<CapabilityLevel> {
        Binding {
            level
        } set: { chosen in
            chosenLevel = chosen
        }
    }

    // MARK: Export

    private var exportMenu: some View {
        Menu {
            exportButton(nil, title: CapabilityText.exportSelectionPDF, symbol: "chart.bar.doc.horizontal")
            exportButton(.csv, title: CapabilityText.exportSelectionCSV, symbol: "tablecells")
            exportButton(.markdown, title: CapabilityText.exportSelectionMarkdown, symbol: "doc.plaintext")
        } label: {
            Label(CapabilityText.exportMenu, systemImage: "square.and.arrow.up")
        }
        .accessibilityIdentifier("compare.export")
    }

    /// `nil` is the PDF, which asks for its charts first.
    private func exportButton(_ format: ExportFile.SelectionFormat?, title: String, symbol: String) -> some View {
        Button {
            guard let format else {
                choosesPDFCharts = true
                return
            }
            pendingShare = try? ExportFile.selection(reportsByModel, format: format).write()
        } label: {
            Label(title, systemImage: symbol)
        }
    }

    // MARK: Cards

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func swatch(_ index: Int) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Self.palette[index % Self.palette.count])
            .frame(width: 12, height: 12)
            .accessibilityHidden(true)
    }

    private func legendCard(_ models: [ComparedModel]) -> some View {
        card(CapabilityText.compareModelsSection) {
            ForEach(Array(models.enumerated()), id: \.element.modelKey) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // Donut slices are coloured by result, not by model.
                    if chartStyle == .bars {
                        swatch(item.offset)
                    }
                    Text(verbatim: item.element.letter)
                        .font(.callout.weight(.bold))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: item.element.title)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        if item.element.safetyFiltersRemoved {
                            SafetyFiltersMark()
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("compare.legend." + item.element.letter)
            }
        }
    }

    private func settingsWarning(_ note: String) -> some View {
        Label {
            Text(verbatim: note)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.callout.weight(.semibold))
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("compare.settingsDiffer")
    }

    private func verdictCard(_ models: [ComparedModel], level: CapabilityLevel) -> some View {
        card(CapabilityText.compareVerdictSection) {
            if chartStyle == .donuts {
                kindLegend
                donutGrid(CapabilityDonuts.comparison(models, level: level))
            }
            ForEach(models, id: \.modelKey) { model in
                let report = model.report(level)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: model.letter + " · " + CapabilityComparison.verdict(report))
                        .font(.callout.weight(.semibold))
                    if let report {
                        Text(verbatim: CapabilityComparison.settingsSummary(report))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: CapabilityComparison.spokenVerdict(model, level: level)))
                .accessibilityIdentifier("compare.verdict." + model.letter)
            }
        }
    }

    private func capabilityCard(_ models: [ComparedModel], level: CapabilityLevel) -> some View {
        card(CapabilityText.compareCapabilitySection) {
            if chartStyle == .donuts {
                kindLegend
            }
            ForEach(CapabilityComparison.capabilityRows(models, level: level), id: \.area) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: row.area.title)
                        .font(.callout.weight(.semibold))
                    Text(verbatim: row.cells.map(\.label).joined(separator: "   "))
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    if chartStyle == .donuts {
                        donutGrid(CapabilityDonuts.comparison(models, level: level, area: row.area))
                    } else {
                        bars(row, letters: models.map(\.letter))
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: CapabilityComparison.spokenCapabilityRow(row, models: models)))
                .accessibilityIdentifier("compare.capability." + row.area.rawValue)
            }
        }
    }

    /// One bar per model, the letter on the axis and the count beside it; the line above says the same in words.
    private func bars(_ row: ComparisonCapabilityRow, letters: [String]) -> some View {
        Chart(row.cells, id: \.letter) { cell in
            BarMark(x: .value("Aprobadas (%)", cell.share ?? 0), y: .value("Modelo", cell.letter),
                    height: .ratio(0.6))
                .foregroundStyle(by: .value("Modelo", cell.letter))
                .annotation(position: .trailing, alignment: .leading, spacing: 4) {
                    Text(verbatim: cell.countText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
        }
        .chartForegroundStyleScale(domain: letters, range: Array(Self.palette.prefix(letters.count)))
        .chartXScale(domain: 0...140)
        .chartXAxis {
            AxisMarks(values: [0, 50, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let percent = value.as(Int.self) {
                        Text(verbatim: "\(percent) %")
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .frame(height: barRow * CGFloat(row.cells.count) + 28)
        .accessibilityHidden(true)
    }

    /// The slice colours; every donut's label and count also say what they hold.
    private var kindLegend: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading,
                  spacing: 4) {
            ForEach(DonutSliceKind.allCases, id: \.self) { kind in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(DonutChart.colour(kind)).frame(width: 12, height: 12)
                    Text(verbatim: kind.title).font(.caption)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// One donut per model in letter order, the letter, the count and what did not plainly pass under each.
    private func donutGrid(_ donuts: [CapabilityDonut]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: donutDiameter + 16), alignment: .top)], alignment: .leading,
                  spacing: 8) {
            ForEach(donuts) { donut in
                VStack(spacing: 4) {
                    DonutChart.scaled(donut, diameter: donutDiameter)
                    Text(verbatim: donut.title)
                        .font(.callout.weight(.bold))
                    Text(verbatim: donut.countText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !donut.breakdownText.isEmpty {
                        Text(verbatim: donut.breakdownText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: donut.spokenText))
            }
        }
        .accessibilityIdentifier("compare.donuts")
    }

    // MARK: Matrix

    private func matrixCard(_ models: [ComparedModel], level: CapabilityLevel) -> some View {
        let rows = CapabilityComparison.matrix(models, level: level)
        return card(CapabilityComparison.matrixTitle) {
            Text(verbatim: CapabilityText.compareMatrixHint)
                .font(.caption)
                .foregroundStyle(.secondary)
            if typeSize.isAccessibilitySize {
                stackedMatrix(rows, models: models, level: level)
            } else {
                ScrollView(.horizontal) {
                    gridMatrix(rows, models: models, level: level)
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .accessibilityIdentifier("compare.matrix")
            }
            Text(verbatim: CapabilityComparison.matrixLegend)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if rows.contains(where: { $0.cells.contains(where: \.validatedByHand) }) {
                Text(verbatim: CapabilityComparison.validatedFootnote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The probe's title across the row, the models' cells under it, each with its letter, so a cell still says
    /// whose it is after a sideways scroll.
    private func gridMatrix(_ rows: [ComparisonMatrixRow], models: [ComparedModel],
                            level: CapabilityLevel) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 6) {
            ForEach(rows, id: \.probe.id) { row in
                if row.number > 1 {
                    Divider()
                }
                GridRow {
                    Text(verbatim: "\(row.number). \(row.probe.title)")
                        .font(.caption.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .gridCellColumns(models.count)
                        .accessibilityHidden(true)
                }
                GridRow(alignment: .top) {
                    ForEach(row.cells.indices, id: \.self) { index in
                        cellButton(row.cells[index], row: row, model: models[index], level: level)
                            .frame(width: cellColumn, alignment: .leading)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Large text: one block per probe, a line per model, nothing to scroll sideways.
    private func stackedMatrix(_ rows: [ComparisonMatrixRow], models: [ComparedModel],
                               level: CapabilityLevel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(rows, id: \.probe.id) { row in
                Divider()
                Text(verbatim: "\(row.number). \(row.probe.title)")
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
                ForEach(row.cells.indices, id: \.self) { index in
                    cellButton(row.cells[index], row: row, model: models[index], level: level)
                }
            }
        }
    }

    private func cellButton(_ cell: ComparisonCell, row: ComparisonMatrixRow, model: ComparedModel,
                            level: CapabilityLevel) -> some View {
        Button {
            opened = OpenedProbe(modelKey: cell.modelKey, level: level, probeID: row.probe.id,
                                 context: model.letter + " · " + model.title + " · " + level.label)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: cell.letter)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.primary)
                Text(verbatim: cell.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!cell.opensDetail)
        .accessibilityLabel(Text(verbatim: CapabilityComparison.spokenCell(cell, model: model, probe: row.probe)))
        .accessibilityHint(Text(verbatim: cell.opensDetail ? CapabilityText.compareMatrixHint : ""))
        .accessibilityIdentifier("compare.cell." + cell.letter + "." + row.probe.id)
    }

    @ViewBuilder
    private func detail(_ item: OpenedProbe) -> some View {
        if let probe = CapabilityBattery.probe(withID: item.probeID),
           let result = store.report(modelKey: item.modelKey, level: item.level)?.result(for: item.probeID) {
            ProbeDetailPage(facts: ProbeDetailFacts(probe: probe, result: result), context: item.context)
        }
    }
}
