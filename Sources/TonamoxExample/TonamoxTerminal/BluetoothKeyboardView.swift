import SwiftUI
import TerminalBridgeKit
import UIKit
import UniformTypeIdentifiers

/// "Teclado Bluetooth": start/stop, connection state, host OS and layout, the probe and the diagnostics log.
struct BluetoothKeyboardView: View {
    @ObservedObject var keyboard: BluetoothKeyboard
    @Environment(\.dismiss) private var dismiss
    @AppStorage(KeyboardLayoutPreference.hostOSKey) private var hostOSRaw = KeyboardLayoutPreference.defaultHostOS
    @AppStorage(KeyboardLayoutPreference.layoutKey) private var layoutRaw = ""

    static let focusWarning = "El texto se escribe en la ventana que tenga el foco en el ordenador. Nunca se pulsa "
        + "Enter: revisa la orden allí y pulsa Enter tú. El teléfono no ve la salida."
    static let layoutWarning = "Si la distribución no coincide con la del ordenador saldrán otros caracteres; no "
        + "uses las variantes «Internacional». En Terminal de macOS, desactiva «Usar Opción como tecla Meta». No "
        + "toques el teclado del ordenador mientras se teclea: sus teclas Control o Comando se combinarían con las "
        + "de Tonamox."
    static let probeFooter = "Abre un editor de texto en el ordenador, pulsa Probar y compara carácter por carácter. "
        + "No pulses Enter."
    static let pairingText = "En el ordenador abre los ajustes de Bluetooth y conecta «"
        + HIDKeyboardDescriptor.deviceName + "»."
    static let unsupportedVariants = "No compatibles: «Estados Unidos-Internacional» de Windows, us(intl) y "
        + "us(altgr-intl) de Linux, «ABC - Extendido» y «EE. UU. Internacional - PC» de macOS."

    private var layout: HostKeyboardLayout {
        KeyboardLayoutPreference.resolve(hostOSRaw: hostOSRaw, layoutRaw: layoutRaw)
    }

    private var hostOSBinding: Binding<HostOS> {
        Binding(
            get: { HostOS(rawValue: hostOSRaw) ?? .macOS },
            set: { newValue in
                hostOSRaw = newValue.rawValue
                layoutRaw = HostKeyboardLayout.defaultLayout(for: newValue).id.rawValue
            }
        )
    }

    private var layoutBinding: Binding<HostKeyboardLayoutID> {
        Binding(
            get: { layout.id },
            set: { layoutRaw = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                statusSection
                computerSection
                warningSection
                probeSection
                Section("Cómo emparejar") {
                    Text(verbatim: Self.pairingText)
                }
                logSection
            }
            .navigationTitle("Teclado Bluetooth")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                        .accessibilityIdentifier("keyboard.done")
                }
            }
        }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section {
            LabeledContent("Bluetooth", value: keyboard.managerStateText)
            LabeledContent("Conexión") {
                Text(verbatim: keyboard.connectionText)
                    .multilineTextAlignment(.trailing)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("keyboard.connection")
            LabeledContent("Bloq Mayús") {
                Text(verbatim: keyboard.capsLockText)
                    .multilineTextAlignment(.trailing)
            }
            .accessibilityElement(children: .combine)
            if let message = keyboard.readiness.message, keyboard.isActive {
                Text(verbatim: message)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("keyboard.readiness")
            }
            Button(role: keyboard.isActive ? .destructive : nil) {
                if keyboard.isActive { keyboard.stop() } else { keyboard.start() }
            } label: {
                Label(
                    keyboard.isActive ? "Detener" : "Activar teclado",
                    systemImage: keyboard.isActive ? "stop.circle" : "dot.radiowaves.left.and.right"
                )
            }
            .accessibilityIdentifier("keyboard.toggle")
        } header: {
            Text("Estado")
        } footer: {
            Text("La primera vez, iOS pide permiso para usar Bluetooth. Al pasar la app a segundo plano se corta "
                + "cualquier tecleo en curso.")
        }
    }

    private var computerSection: some View {
        Section {
            Picker("Sistema del ordenador", selection: hostOSBinding) {
                ForEach(HostOS.allCases, id: \.self) { hostOS in
                    Text(verbatim: hostOS.title).tag(hostOS)
                }
            }
            .accessibilityIdentifier("keyboard.hostOS")
            Picker("Distribución", selection: layoutBinding) {
                ForEach(HostKeyboardLayout.layouts(for: layout.host)) { option in
                    Text(verbatim: option.title).tag(option.id)
                }
            }
            .accessibilityIdentifier("keyboard.layout")
            Label {
                Text(verbatim: layout.verification.summary)
            } icon: {
                Image(systemName: layout.verification.isFullyVerified
                    ? "checkmark.seal" : "exclamationmark.triangle.fill")
            }
            .font(.footnote)
            .foregroundStyle(layout.verification.isFullyVerified ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("keyboard.verification")
        } header: {
            Text("Ordenador")
        } footer: {
            Text(verbatim: "En el ordenador elige la fuente de entrada «\(layout.hostInputSource)». "
                + Self.unsupportedVariants)
        }
    }

    private var warningSection: some View {
        Section("Aviso") {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: Self.focusWarning)
                Text(verbatim: Self.layoutWarning)
            }
            .font(.footnote)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("keyboard.warning")
        }
    }

    private var probeSection: some View {
        Section {
            VerbatimCommandText(text: layout.probeLine)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("keyboard.probeText")
            Button {
                keyboard.probe(layout)
            } label: {
                Label("Probar", systemImage: "keyboard")
            }
            .disabled(keyboard.readiness != .ready)
            .accessibilityHint(Text(verbatim: keyboard.readiness.message ?? Self.probeFooter))
            .accessibilityIdentifier("keyboard.probe")
            if let status = keyboard.probeStatus {
                Text(verbatim: status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("keyboard.probeStatus")
            }
        } header: {
            Text("Probar")
        } footer: {
            Text(verbatim: Self.probeFooter)
        }
    }

    private var logSection: some View {
        Section {
            ForEach(BluetoothKeyboard.ServiceKind.allCases, id: \.self) { kind in
                LabeledContent(kind.title) {
                    Text(verbatim: uuidFormText(kind))
                        .multilineTextAlignment(.trailing)
                }
                .font(.footnote)
            }
            KeyboardEventLogView(log: keyboard.eventLog, copy: copyLog)
        } header: {
            Text("Registro")
        } footer: {
            Text("Lo más reciente arriba. El registro no guarda el texto de las órdenes, y se borra al cerrar la app.")
        }
    }

    private func uuidFormText(_ kind: BluetoothKeyboard.ServiceKind) -> String {
        if let form = keyboard.acceptedUUIDForms[kind] { return "aceptado con " + form.title }
        if keyboard.failedServices.contains(kind) { return "rechazado" }
        return "sin publicar"
    }

    // Local only and short-lived, like the pairing code: the log holds the computer's Bluetooth identifiers.
    private func copyLog() {
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: keyboard.copyableLog()]],
            options: [.localOnly: true, .expirationDate: Date.now.addingTimeInterval(PairingView.copyLifetime)]
        )
    }
}

/// The log entries, observed apart from the keyboard so only this screen re-renders on each entry.
struct KeyboardEventLogView: View {
    @ObservedObject var log: KeyboardEventLog
    let copy: () -> Void

    var body: some View {
        Button(action: copy) {
            Label("Copiar registro", systemImage: "doc.on.doc")
        }
        .disabled(log.entries.isEmpty)
        .accessibilityIdentifier("keyboard.copyLog")
        if log.entries.isEmpty {
            Text("Sin eventos todavía.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(log.entries.reversed()) { event in
                    Text(verbatim: event.line)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("keyboard.log")
        }
    }
}
