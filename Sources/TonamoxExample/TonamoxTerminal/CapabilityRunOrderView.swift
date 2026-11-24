import SwiftUI
import TerminalBridgeKit

/// «Orden de ejecución»: per level of the picker's choice, its probes in the order a run executes them, dragged to
/// reorder, each with its exclude switch. Locked while a run goes.
struct CapabilityRunOrderView: View {
    @ObservedObject var runner: CapabilityRunner
    let levels: [CapabilityLevel]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(levels, id: \.self) { level in
                    levelSection(level)
                }
            }
            // Always in edit mode, so the drag handles show without an Editar button.
            .environment(\.editMode, .constant(.active))
            .navigationTitle(CapabilityText.runOrder)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                        .accessibilityIdentifier("probes.runOrder.done")
                }
            }
            .disabled(!runner.canEditRunPlan)
        }
    }

    private func levelSection(_ level: CapabilityLevel) -> some View {
        Section {
            ForEach(Array(runner.runPlan.order(of: level).enumerated()), id: \.element.id) { item in
                row(item.element, position: item.offset + 1)
            }
            .onMove { source, destination in
                runner.moveProbes(in: level, fromOffsets: source, toOffset: destination)
            }
            Button(CapabilityText.resetOrder, systemImage: "arrow.counterclockwise") {
                runner.resetOrder(of: level)
            }
            .disabled(!runner.runPlan.hasCustomOrder(level))
            .accessibilityIdentifier(CapabilityText.resetOrderIdentifier + "." + level.rawValue)
        } header: {
            Text(verbatim: level.label)
        } footer: {
            Text(verbatim: CapabilityText.runOrderFooter)
        }
    }

    private func row(_ probe: CapabilityProbe, position: Int) -> some View {
        let isExcluded = runner.runPlan.isExcluded(probe.id)
        return Toggle(isOn: Binding(
            get: { !runner.runPlan.isExcluded(probe.id) },
            set: { runner.setExcluded(!$0, probeID: probe.id) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(position). \(probe.title)")
                    .strikethrough(isExcluded)
                Text(verbatim: isExcluded ? CapabilityText.excluded : probe.area.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(isExcluded ? .secondary : .primary)
        .accessibilityIdentifier(CapabilityText.runOrderRowIdentifier(probe.id))
    }
}
