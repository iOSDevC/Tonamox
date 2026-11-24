import SwiftUI
import TerminalBridgeKit

/// The composer's model chip: the engine's short name and where it runs; a tap opens the model sheet. At large
/// text sizes it drops the place word, then the name, before squeezing «Enviar».
struct ModelChip: View {
    let choice: ModelChoice?
    /// The other selectable titles, so two quantizations of one model stay apart.
    var otherTitles: [String] = []
    let action: () -> Void

    var body: some View {
        let chip = ModelChipText(title: choice?.title, placement: choice?.source.placement, otherTitles: otherTitles)
        Button(action: action) {
            ViewThatFits(in: .horizontal) {
                content(name: chip.name, place: chip.place)
                content(name: chip.name, place: nil)
                content(name: nil, place: nil)
            }
            .padding(.horizontal, 14)
            .frame(minWidth: 44, minHeight: 44)
            .background(.fill.tertiary, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: chip.accessibilityLabel))
        .accessibilityHint(Text("Abre «\(ModelPickerText.sheetTitle)»."))
        .accessibilityIdentifier("terminal.modelButton")
    }

    private func content(name: String?, place: String?) -> some View {
        HStack(spacing: 4) {
            if let name {
                Text(verbatim: name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            } else {
                Image(systemName: "cpu")
                    .font(.subheadline.weight(.semibold))
            }
            if let place {
                Text(verbatim: place)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
        }
    }
}

/// The leading toolbar menu with every setting; a dot shows when the web server is on or has a problem.
struct SettingsMenuButton: View {
    let webServer: WebServerController
    let isRunningCapabilityTests: Bool
    let isTestModeOn: Bool
    let open: (SettingsMenuEntry) -> Void

    var body: some View {
        let status = webServer.status
        Menu {
            ForEach(SettingsMenuEntry.MenuSection.allCases, id: \.self) { section in
                Section {
                    ForEach(section.entries, id: \.self) { entry in
                        if entry == .testMode {
                            Toggle(isOn: Binding(get: { isTestModeOn }, set: { _ in open(entry) })) {
                                Label(entry.title, systemImage: entry.symbol)
                            }
                            .accessibilityIdentifier(entry.identifier)
                        } else {
                            entryButton(entry, status: status)
                        }
                    }
                }
            }
        } label: {
            Label(SettingsMenuEntry.menuTitle, systemImage: SettingsMenuEntry.menuSymbol)
                .overlay(alignment: .topTrailing) {
                    if status.isActive || status.isProblem {
                        Circle()
                            .fill(status.isProblem ? Color.orange : Color.green)
                            .frame(width: 8, height: 8)
                            .offset(x: 3, y: -3)
                    }
                }
        }
        .accessibilityValue(Text(verbatim: status.isActive || status.isProblem ? "Servidor web: " + status.title : ""))
        .accessibilityIdentifier(SettingsMenuEntry.menuIdentifier)
    }

    private func entryButton(_ entry: SettingsMenuEntry, status: WebServerStatus) -> some View {
        Button {
            open(entry)
        } label: {
            Label(entry.title, systemImage: entry.symbol)
            // Only a live state gets a second line; descriptions made the menu scroll.
            if let line = subtitle(for: entry, status: status) {
                Text(verbatim: line)
            }
        }
        // A delete or "Try it" mid-run would evict or swap the battery's weights.
        .disabled(entry == .downloads && isRunningCapabilityTests)
        .accessibilityIdentifier(entry.identifier)
    }

    /// The web server row shows its live state, as the old toolbar button's value did.
    private func subtitle(for entry: SettingsMenuEntry, status: WebServerStatus) -> String? {
        guard entry == .webServer, status.isActive || status.isProblem else { return nil }
        return status.title
    }
}

/// The one trailing toolbar button: the keyboard channel needs turning on every launch, and its state shows here.
struct KeyboardToolbarButton: View {
    @ObservedObject var keyboard: BluetoothKeyboard
    let action: () -> Void

    var body: some View {
        let readiness = keyboard.readiness
        Button(action: action) {
            Label("Teclado", systemImage: "keyboard")
                .overlay(alignment: .topTrailing) {
                    if keyboard.isActive {
                        Image(systemName: readiness == .ready ? "circle.fill" : "exclamationmark.circle.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(readiness == .ready ? Color.green : Color.orange)
                            .offset(x: 4, y: -4)
                    }
                }
        }
        .accessibilityValue(Text(verbatim: readiness.message ?? "listo"))
        .accessibilityIdentifier("terminal.keyboardButton")
    }
}
