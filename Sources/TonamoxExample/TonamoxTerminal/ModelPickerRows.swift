import SwiftUI
import TerminalBridgeKit
import TonamoxUI

/// Title, one line of what it is, an optional note or capability result, and a trailing mark.
struct ModelRowLabel: View {
    enum Mark {
        case none
        case checkmark
        case lock
        case chevron
    }

    let title: String
    let detail: String
    var note: String?
    var summary: CapabilitySummary?
    var safetyFiltersRemoved = false
    var symbol: String?
    var accessory: Mark = .none

    var body: some View {
        HStack(spacing: 12) {
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .multilineTextAlignment(.leading)
                    // Explicit colours: inside a List button, `.primary` resolves to the tint.
                    .foregroundStyle(accessory == .lock ? Color.secondary : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if safetyFiltersRemoved {
                    SafetyFiltersMark()
                }
                if let note {
                    Text(verbatim: note)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let summary {
                    summaryLine(summary)
                }
            }
            Spacer(minLength: 0)
            accessoryView
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private func summaryLine(_ summary: CapabilitySummary) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: summary.text)
            if summary.notRecommended {
                Label(CapabilitySummary.notRecommendedLabel, systemImage: CapabilitySummary.warningSymbol)
                    .foregroundStyle(.orange)
            } else if summary.isSafetyIncomplete {
                Label(CapabilityText.safetyIncompleteLabel, systemImage: CapabilityText.excludedSymbol)
            }
        }
        .font(.caption)
        .foregroundStyle(Color.secondary)
    }

    @ViewBuilder
    private var accessoryView: some View {
        switch accessory {
        case .none:
            EmptyView()
        case .checkmark:
            Image(systemName: "checkmark")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
        case .lock:
            Image(systemName: RemoteLock.symbol)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        case .chevron:
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(uiColor: .tertiaryLabel))
                .accessibilityHidden(true)
        }
    }

    /// What VoiceOver reads for a model row: name, what it is, where it runs, the safety mark, and any test result or
    /// lock.
    static func spokenLabel(
        title: String, detail: String, placement: ModelPlacement, summary: CapabilitySummary? = nil,
        safetyFiltersRemoved: Bool = false, lockReason: String? = nil
    ) -> String {
        var parts = [title, detail, placement.spokenPhrase]
        if safetyFiltersRemoved { parts.append(ModifiedModelHeuristic.label) }
        if let summary { parts.append(summary.accessibilityText) }
        if let lockReason { parts.append("Bloqueado: " + lockReason) }
        return parts.joined(separator: ", ")
    }
}

/// A cloud or local-network engine: the row selects it (or opens what unlocks it); the trailing info button picks
/// its model id or configures the server, as in the Wi-Fi list.
struct RemoteModelRow: View {
    let row: RemoteChoiceRow
    let isSelected: Bool
    let isRunningCapabilityTests: Bool
    let onTap: () -> Void
    let onDetail: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onTap) {
                ModelRowLabel(title: row.choice.title, detail: row.choice.detail, note: row.lock?.shortReason,
                              accessory: row.lock != nil ? .lock : (isSelected ? .checkmark : .none))
            }
            .buttonStyle(.borderless)
            .tint(.primary)
            // Only a usable row selects; a locked one opens a dialog or a form, which a run does not mind.
            .disabled(row.lock == nil && isRunningCapabilityTests)
            .accessibilityLabel(Text(verbatim: ModelRowLabel.spokenLabel(
                title: row.choice.title, detail: row.choice.detail, placement: row.choice.source.placement,
                lockReason: row.lock?.shortReason)))
            .accessibilityHint(row.lock != nil ? Text("Abre lo que falta para poder usar este motor.") : Text(""))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier("model.choice." + row.choice.id)
            Button(action: onDetail) {
                Image(systemName: "info.circle")
                    .imageScale(.large)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(verbatim: detailLabel))
            .accessibilityIdentifier(detailIdentifier)
        }
    }

    private var detailLabel: String {
        switch row.choice.kind {
        case .remote(.compatibleServer): "Configurar servidor"
        default: "Elegir modelo de " + row.choice.title
        }
    }

    private var detailIdentifier: String {
        switch row.choice.kind {
        case .remote(.preset(let id)): "model.cloudModel." + id.rawValue
        default: "model.remoteServer"
        }
    }
}
