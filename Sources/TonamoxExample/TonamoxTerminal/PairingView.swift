import SwiftUI
import TerminalBridgeKit
import UIKit
import UniformTypeIdentifiers

/// The pairing code the owner types on the Mac, its fingerprint and the last helper that connected.
struct PairingView: View {
    @ObservedObject var bridge: BridgeServer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var copiedUntil: Date?
    @State private var confirmsRegenerate = false

    static let copyLifetime: TimeInterval = 120
    static let instructions = "En la Mac ejecuta «tonamox-bridge pair --stdin» y escribe este código. "
        + "No lo pongas como argumento: quedaría en el historial del shell."
    private static let codeColumns: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
    private static let largeTextColumns: [GridItem] = [GridItem(.flexible())]
    static let simulatorPairingHint = "En el simulador no se copia: usa «tonamox-bridge pair --new» y pasa el "
        + "código en SIMCTL_CHILD_TONAMOX_DEBUG_PAIRING_CODE (solo DEBUG)."

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ? Self.largeTextColumns : Self.codeColumns, spacing: 8) {
                        ForEach(Array(bridge.currentCode.groups.enumerated()), id: \.offset) { item in
                            Text(verbatim: item.element)
                                .font(.title3.monospaced().weight(.semibold))
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Código de emparejamiento")
                    .accessibilityValue(Text(verbatim: bridge.currentCode.formatted).speechSpellsOutCharacters())
                    .accessibilityIdentifier("pairing.code")
                } header: {
                    Text("Código de emparejamiento")
                } footer: {
                    Text(verbatim: Self.instructions)
                }

                Section {
                    LabeledContent("Huella") {
                        Text(verbatim: bridge.currentCode.fingerprint)
                            .font(.body.monospaced())
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("pairing.fingerprint")
                } footer: {
                    Text("La Mac muestra la misma huella cuando el emparejamiento es correcto.")
                }

                Section("Mac") {
                    LabeledContent("Última conexión") {
                        lastConnection
                    }
                    LabeledContent("Intentos rechazados", value: "\(bridge.rejectedAttempts)")
                }

                if let problem = bridge.storageProblem {
                    Section {
                        Text(verbatim: problem)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    // The Simulator syncs its pasteboard to the Mac's, so the secret is never copied there.
                    #if targetEnvironment(simulator)
                    Text(verbatim: Self.simulatorPairingHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("pairing.simulatorHint")
                    #else
                    Button {
                        copyCode()
                    } label: {
                        Label("Copiar código", systemImage: "doc.on.doc")
                    }
                    .accessibilityIdentifier("pairing.copy")
                    if let copiedUntil {
                        Text("Copiado solo en este dispositivo. Caduca a las \(copiedUntil, style: .time).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    #endif
                    Button(role: .destructive) {
                        confirmsRegenerate = true
                    } label: {
                        Label("Regenerar código", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .accessibilityIdentifier("pairing.regenerate")
                }
            }
            .navigationTitle("Emparejar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                        .accessibilityIdentifier("pairing.done")
                }
            }
            .alert("¿Regenerar el código?", isPresented: $confirmsRegenerate) {
                Button("Regenerar", role: .destructive) {
                    copiedUntil = nil
                    bridge.regeneratePairing()
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("La Mac emparejada dejará de conectarse hasta que la emparejes con el código nuevo.")
            }
        }
    }

    @ViewBuilder
    private var lastConnection: some View {
        if let connectedAt = bridge.lastConnectedAt {
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: bridge.helperName ?? "Mac")
                Text(connectedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Nunca en esta sesión")
                .foregroundStyle(.secondary)
        }
    }

    // Local only and short-lived: the code is a secret.
    #if !targetEnvironment(simulator)
    private func copyCode() {
        let expiry = Date.now.addingTimeInterval(Self.copyLifetime)
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: bridge.currentCode.formatted]],
            options: [.localOnly: true, .expirationDate: expiry]
        )
        copiedUntil = expiry
    }
    #endif
}
