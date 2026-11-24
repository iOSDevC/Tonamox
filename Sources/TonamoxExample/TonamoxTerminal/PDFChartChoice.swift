import SwiftUI
import TerminalBridgeKit

/// "Gráficos del PDF: Donas / Barras", asked before any PDF is built and preselected with the last choice. The pick
/// is stored only on "Generar PDF": the comparison screen behind reads the same key and Cancelar must leave it alone.
private struct PDFChartChoiceSheet: View {
    @AppStorage(CapabilityChartStyle.defaultsKey) private var storedStyle = CapabilityChartStyle.fallback
    @State private var pickedStyle: CapabilityChartStyle?
    @Environment(\.dynamicTypeSize) private var typeSize
    let onGenerate: (CapabilityChartStyle) -> Void
    let onCancel: () -> Void

    private var style: Binding<CapabilityChartStyle> {
        Binding { pickedStyle ?? storedStyle } set: { pickedStyle = $0 }
    }

    var body: some View {
        // Scrolls at large text sizes, where the content outgrows the short detent.
        ScrollView {
            content
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: CapabilityChartStyle.choiceTitle)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Picker(CapabilityChartStyle.choiceTitle, selection: style) {
                ForEach(CapabilityChartStyle.allCases, id: \.self) { item in
                    Text(verbatim: item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("pdfCharts.style")
            Text(verbatim: CapabilityChartStyle.choiceFooter)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Side by side the two labels break mid-word at accessibility sizes.
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    generateButton
                    cancelButton
                }
            } else {
                HStack {
                    cancelButton
                    Spacer()
                    generateButton
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cancelButton: some View {
        Button(CapabilityChartStyle.cancelAction, role: .cancel, action: onCancel)
            .accessibilityIdentifier("pdfCharts.cancel")
    }

    private var generateButton: some View {
        Button(CapabilityChartStyle.generateAction) {
            let chosen = style.wrappedValue
            storedStyle = chosen
            onGenerate(chosen)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("pdfCharts.generate")
    }
}

/// The PDF is built in `onDismiss`, once the choice sheet is gone, because the share sheet that follows cannot be
/// presented while this one is still dismissing.
private struct PDFChartChoiceModifier: ViewModifier {
    @Binding var isPresented: Bool
    let perform: (CapabilityChartStyle) -> Void
    @State private var chosen: CapabilityChartStyle?
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var sheetHeight: CGFloat = 230

    private var detents: Set<PresentationDetent> {
        typeSize.isAccessibilitySize ? [.large] : [.height(sheetHeight), .medium]
    }

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented, onDismiss: finish) {
            PDFChartChoiceSheet { style in
                chosen = style
                isPresented = false
            } onCancel: {
                chosen = nil
                isPresented = false
            }
            .presentationDetents(detents)
        }
    }

    private func finish() {
        guard let style = chosen else { return }
        chosen = nil
        perform(style)
    }
}

extension View {
    /// Asks for the PDF's chart style while `isPresented` is set, then calls `perform` with it; nothing on cancel.
    func pdfChartChoice(isPresented: Binding<Bool>, perform: @escaping (CapabilityChartStyle) -> Void) -> some View {
        modifier(PDFChartChoiceModifier(isPresented: isPresented, perform: perform))
    }
}
