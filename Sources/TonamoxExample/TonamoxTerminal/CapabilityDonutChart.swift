import Charts
import SwiftUI
import TerminalBridgeKit

/// A results donut: `SectorMark` slices in `DonutSliceKind` order from twelve o'clock, the count printed on every
/// slice wide enough to hold it and the share passed in the hole. Colour is never the only cue: position, the
/// counts and the legend say the same.
struct DonutChart: View {
    let donut: CapabilityDonut
    let diameter: CGFloat
    var centreFont = Font.system(size: 11, weight: .bold)
    var sliceFont = Font.system(size: 7, weight: .semibold)
    var labelsSlices = true

    /// On screen the diameter follows the text size; the fonts follow the diameter so they stay inside the ring.
    static func scaled(_ donut: CapabilityDonut, diameter: CGFloat) -> DonutChart {
        DonutChart(donut: donut, diameter: diameter,
                   centreFont: .system(size: diameter * DonutLayout.screenCentreFontRatio, weight: .bold),
                   sliceFont: .system(size: diameter * DonutLayout.screenSliceFontRatio, weight: .semibold))
    }

    /// Dark to light and two warm tones, so neighbours differ in lightness as well as hue.
    static func colour(_ kind: DonutSliceKind) -> Color {
        switch kind {
        case .passed: Color(red: 0.12, green: 0.23, blue: 0.48)
        case .validatedByHand: Color(red: 0.42, green: 0.60, blue: 0.86)
        case .unrecognised: Color(red: 0.72, green: 0.74, blue: 0.77)
        case .failed: Color(red: 0.75, green: 0.22, blue: 0.13)
        case .timedOut: Color(red: 0.96, green: 0.74, blue: 0.30)
        }
    }

    static func labelColour(_ kind: DonutSliceKind) -> Color {
        switch kind {
        case .passed, .failed: .white
        case .validatedByHand, .unrecognised, .timedOut: .black
        }
    }

    var body: some View {
        ZStack {
            if donut.slices.isEmpty {
                Circle()
                    .strokeBorder(Color.gray.opacity(0.25), lineWidth: diameter * 0.19)
            } else {
                Chart(donut.slices) { slice in
                    SectorMark(angle: .value("Pruebas", slice.count), innerRadius: .ratio(DonutLayout.innerRadiusRatio),
                               angularInset: 0.8)
                        .foregroundStyle(Self.colour(slice.kind))
                        .annotation(position: .overlay) {
                            if labelsSlices, donut.labelsSlice(slice) {
                                Text(verbatim: "\(slice.count)")
                                    .font(sliceFont)
                                    .foregroundStyle(Self.labelColour(slice.kind))
                            }
                        }
                }
                .chartLegend(.hidden)
            }
            Text(verbatim: donut.centreText)
                .font(centreFont)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .padding(.horizontal, diameter * DonutLayout.centreInsetRatio)
        }
        .frame(width: diameter, height: diameter)
    }
}

/// The colour key of the slice kinds, in drawing order.
struct DonutKindLegend: View {
    var font = Font.system(size: 7)
    var swatch: CGFloat = 7

    var body: some View {
        HStack(spacing: 10) {
            ForEach(DonutSliceKind.allCases, id: \.self) { kind in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(DonutChart.colour(kind))
                        .frame(width: swatch, height: swatch)
                    Text(verbatim: kind.title).font(font)
                }
            }
        }
    }
}

// MARK: PDF

/// One row of a PDF donut grid, exactly `DonutLayout.rowHeight` tall so the page plan made from the kit holds.
struct PDFDonutRow: View {
    let donuts: [CapabilityDonut]
    let cellSize: DonutLayout.Size
    /// Drops the fixed row height, for the smoke check that the content itself adds up to the planned height.
    var measuresContent = false

    private var cellWidth: CGFloat { CapabilityPDF.contentWidth / CGFloat(DonutLayout.columns(cellSize)) }
    private var height: CGFloat { CGFloat(DonutLayout.rowHeight(donuts, size: cellSize)) }
    private var legendLines: Int { donuts.map(\.legendLines.count).max() ?? 1 }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(donuts) { donut in
                cell(donut)
                    .frame(width: cellWidth, height: measuresContent ? nil : height, alignment: .top)
            }
        }
        .frame(width: CapabilityPDF.contentWidth, height: measuresContent ? nil : height, alignment: .topLeading)
        .foregroundStyle(Color.black)
        .environment(\.colorScheme, .light)
    }

    @ViewBuilder
    private func cell(_ donut: CapabilityDonut) -> some View {
        switch cellSize {
        case .large: large(donut)
        case .small: small(donut)
        }
    }

    private func large(_ donut: CapabilityDonut) -> some View {
        VStack(spacing: CGFloat(DonutLayout.gap)) {
            title(donut)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: cellWidth - 8, height: CGFloat(DonutLayout.titleHeight), alignment: .bottom)
            DonutChart(donut: donut, diameter: CGFloat(DonutLayout.diameter(.large)))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(legendRows(donut), id: \.text) { row in
                    HStack(spacing: 3) {
                        if let kind = row.kind {
                            RoundedRectangle(cornerRadius: 1.5).fill(DonutChart.colour(kind)).frame(width: 6, height: 6)
                        }
                        Text(verbatim: row.text).font(.system(size: 7))
                    }
                    .frame(height: CGFloat(DonutLayout.legendLineHeight))
                }
            }
            .frame(height: CGFloat(DonutLayout.legendLineHeight) * CGFloat(max(legendLines, 1)), alignment: .top)
        }
    }

    private func title(_ donut: CapabilityDonut) -> Text {
        let name = Text(verbatim: donut.title).font(.system(size: 9, weight: .bold))
        guard !donut.subtitle.isEmpty else { return name }
        let model = Text(verbatim: " · " + ExportText.revealingInvisibles(donut.subtitle)).font(.system(size: 7))
        return Text("\(name)\(model)")
    }

    private struct LegendRow {
        let kind: DonutSliceKind?
        let text: String
    }

    private func legendRows(_ donut: CapabilityDonut) -> [LegendRow] {
        guard !donut.slices.isEmpty else { return [LegendRow(kind: nil, text: donut.countText)] }
        return donut.slices.map { LegendRow(kind: $0.kind, text: $0.legend) }
    }

    private func small(_ donut: CapabilityDonut) -> some View {
        VStack(spacing: CGFloat(DonutLayout.gap)) {
            DonutChart(donut: donut, diameter: CGFloat(DonutLayout.diameter(.small)),
                       centreFont: .system(size: 8, weight: .bold), sliceFont: .system(size: 6, weight: .semibold))
            VStack(spacing: 1) {
                Text(verbatim: donut.title)
                    .font(.system(size: 7, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(verbatim: donut.countText)
                    .font(.system(size: 7))
                if hasBreakdown {
                    Text(verbatim: donut.breakdownText)
                        .font(.system(size: 6.5))
                        .foregroundStyle(Color(white: 0.3))
                        .multilineTextAlignment(.center)
                        .lineLimit(DonutLayout.breakdownLines)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(width: cellWidth - 6, height: textHeight, alignment: .top)
        }
    }

    /// Name, count and the breakdown when the row has one; fixed, so the row matches `DonutLayout.rowHeight`.
    private var textHeight: CGFloat {
        let breakdown = hasBreakdown ? DonutLayout.breakdownLineHeight * Double(DonutLayout.breakdownLines) : 0
        return CGFloat(DonutLayout.titleHeight + DonutLayout.legendLineHeight + breakdown)
    }

    /// The row keeps room for a breakdown when any of its donuts has one, so its cells line up.
    private var hasBreakdown: Bool { donuts.contains { !$0.breakdownText.isEmpty } }
}

/// The kind legend under a grid of small donuts.
struct PDFDonutKindLegend: View {
    var body: some View {
        DonutKindLegend()
            .frame(width: CapabilityPDF.contentWidth, height: CGFloat(DonutLayout.kindLegendHeight),
                   alignment: .leading)
            .foregroundStyle(Color.black)
            .environment(\.colorScheme, .light)
    }
}
