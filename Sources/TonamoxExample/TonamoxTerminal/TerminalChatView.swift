import SwiftUI
import TerminalBridgeKit
import TonamoxCore
import UIKit

/// Root screen: connection indicator, screen status banner, replies with command rows and the input bar.
struct TerminalChatView: View {
    @ObservedObject var bridge: BridgeServer
    @ObservedObject var chat: TerminalChatViewModel
    @State private var draft = ""
    @State private var showsPairing = false
    @State private var showsModels = false

    static let noModelsText = "No hay modelos en este dispositivo. Descárgalos con la app de modelos."
    static let introText = "Pide lo que quieres hacer en la terminal. Cada orden se escribe en la Mac sin pulsar "
        + "Enter: la revisas allí y pulsas Enter tú."

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ConnectionStatusRow(bridge: bridge)
                if let banner = targetBanner {
                    StatusBannerView(banner: banner)
                }
                transcript
                Divider()
                inputBar
            }
            .navigationTitle("Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ConnectionDot(bridge: bridge)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showsModels = true
                    } label: {
                        Label("Modelo", systemImage: "cpu")
                    }
                    .accessibilityValue(chat.selectedChoice?.title ?? "ninguno")
                    .accessibilityIdentifier("terminal.modelButton")
                    Button {
                        showsPairing = true
                    } label: {
                        Label("Emparejar", systemImage: "link")
                    }
                    .accessibilityIdentifier("terminal.pairingButton")
                }
            }
            .sheet(isPresented: $showsPairing) {
                PairingView(bridge: bridge)
            }
            .sheet(isPresented: $showsModels) {
                ModelPickerView(chat: chat)
            }
        }
        .onAppear(perform: chat.refreshCatalog)
        .onSharedStorageChange([.models]) { chat.refreshCatalog() }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if chat.entries.isEmpty && !chat.isBusy {
                    emptyState
                }
                ForEach(chat.entries) { entry in
                    bubble(for: entry)
                }
                if chat.isBusy {
                    streamingBubble
                }
            }
            .padding()
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: Self.introText)
            if !chat.catalog.hasModels {
                Text(verbatim: Self.noModelsText)
                    .foregroundStyle(.secondary)
            }
            if let choice = chat.selectedChoice {
                Text(verbatim: "Modelo: \(choice.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.emptyState")
    }

    @ViewBuilder
    private func bubble(for entry: TerminalEntry) -> some View {
        switch entry.role {
        case .user:
            Text(verbatim: entry.text)
                .padding(10)
                .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityIdentifier("terminal.prompt")
        case .assistant:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(entry.segments.enumerated()), id: \.offset) { item in
                    segmentView(item.element, in: entry)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // A container, so the identifier does not override the identifiers of the rows inside.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("terminal.reply.\(entry.replyOrdinal)")
        case .notice:
            Text(verbatim: entry.text)
                .font(.caption)
                .foregroundStyle(entry.isError ? .red : .secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityIdentifier("terminal.notice")
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: ReplySegment, in entry: TerminalEntry) -> some View {
        switch segment {
        case .prose(let text):
            // Plain text on purpose: no Markdown, so no tappable links that would leave the app.
            Text(verbatim: text)
                .fixedSize(horizontal: false, vertical: true)
        case .code(let block):
            CommandBlockView(block: block, entry: entry, chat: chat, bridge: bridge)
        }
    }

    private var streamingBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            if chat.streamingText.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(verbatim: chat.progress.isEmpty ? "Pensando…" : chat.progress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(verbatim: chat.streamingText)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.streaming")
    }

    // MARK: Input

    private var inputBar: some View {
        HStack(spacing: 8) {
            CommandInputField(
                text: $draft,
                placeholder: "Pide una orden…",
                isEnabled: chat.selectedChoice != nil,
                onSubmit: submit
            )
            .frame(minHeight: 36)
            .fixedSize(horizontal: false, vertical: true)
            if chat.isBusy {
                Button("Detener", role: .destructive) {
                    chat.stop()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("terminal.stop")
            } else {
                Button("Enviar", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSend)
                    .accessibilityIdentifier("terminal.send")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var canSend: Bool {
        chat.selectedChoice != nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canSend, !chat.isBusy else { return }
        chat.send(draft)
        draft = ""
    }

    // MARK: Status

    private var targetBanner: StatusBanner? {
        guard bridge.isConnected, let status = bridge.latestStatus else { return nil }
        if status.target.state == .promptNotIdle, let target = bridge.pendingTypedTarget {
            return StatusBanner(text: TargetStatusText.pendingEnter(target), isWarning: false)
        }
        return TargetStatusText.banner(for: status).map { StatusBanner(text: $0, isWarning: true) }
    }
}

struct StatusBanner {
    let text: String
    /// False for the expected "press Enter on the Mac" state right after a write.
    let isWarning: Bool
}

struct StatusBannerView: View {
    let banner: StatusBanner

    var body: some View {
        Label {
            Text(verbatim: banner.text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: banner.isWarning ? "exclamationmark.triangle.fill" : "return")
        }
        .font(.footnote)
        .foregroundStyle(banner.isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(banner.isWarning ? Color.orange.opacity(0.12) : Color.blue.opacity(0.08))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(banner.isWarning ? "terminal.statusBanner" : "terminal.pendingEnter")
    }
}

/// Spanish banner text for a screen target that cannot take a write right now.
enum TargetStatusText {
    static func pendingEnter(_ target: String) -> String {
        "Orden escrita en \(target). Revísala en la Mac y pulsa Enter para ejecutarla (o bórrala con Ctrl-U) "
            + "antes de escribir otra."
    }

    static func banner(for status: StatusMessage) -> String? {
        let target = status.target
        switch target.state {
        case .ready:
            return nil
        case .sessionMissing:
            return "En la Mac: " + (status.hint ?? "screen -S \(target.session)")
        case .ambiguousSession:
            return "Hay varias sesiones de screen llamadas \(target.session)."
        case .windowMissing:
            return "No existe la ventana \(target.window) de la sesión \(target.session)."
        case .multipleWindows:
            return "La sesión \(target.session) tiene varias ventanas; usa una sesión con una sola."
        case .promptNotIdle:
            return "El shell de \(target.session) no está en un prompt vacío: "
                + "hay texto escrito o una pregunta pendiente."
        case .foregroundNotShell:
            return "Ventana ocupada por \(target.foreground ?? "otro programa")."
        case .screenUnavailable:
            return "screen no está disponible en la Mac."
        case .unrecognized(let value):
            return "Estado desconocido en la Mac: \(value)."
        }
    }
}

/// How the bridge connection is shown: a dot in the toolbar and a wrapping status row.
struct ConnectionLook {
    let text: String
    let tint: Color
    /// Stable token for UI tests, used in the row's accessibility identifier.
    let token: String
    /// What to do next, when there is something to do.
    var hint: String?

    #if targetEnvironment(simulator)
    static let runCommand = "tonamox-bridge run --simulator"
    #else
    static let runCommand = "tonamox-bridge run --device UDID"
    #endif

    @MainActor
    static func current(for bridge: BridgeServer) -> ConnectionLook {
        switch bridge.connectionState {
        case .connected:
            guard let target = bridge.targetLabel else {
                return ConnectionLook(text: "Conectando", tint: .yellow, token: "connecting")
            }
            return ConnectionLook(text: "Mac · \(target)", tint: .green, token: "connected")
        case .listening:
            if bridge.hasRecentRejection() {
                return ConnectionLook(
                    text: "Rechazado (\(bridge.rejectedAttempts))",
                    tint: .red,
                    token: "rejected",
                    hint: "Una Mac no supo el código. Si lo regeneraste, empareja otra vez en la Mac."
                )
            }
            return ConnectionLook(
                text: "Esperando Mac",
                tint: .gray,
                token: "listening",
                hint: "En la Mac: \(runCommand)"
            )
        case .stopped, .failed(.alreadyStarted), .failed(.stopped):
            return ConnectionLook(text: "Detenido", tint: .gray, token: "stopped")
        case .failed(.portInUse(let port)):
            return ConnectionLook(text: "Error: puerto \(port) en uso", tint: .red, token: "failed")
        case .failed(.failed):
            return ConnectionLook(
                text: "Error al escuchar en 127.0.0.1:\(BridgeConstants.defaultPort)",
                tint: .red,
                token: "failed"
            )
        }
    }
}

/// Only the coloured dot fits in the toolbar; the text lives in ConnectionStatusRow.
struct ConnectionDot: View {
    @ObservedObject var bridge: BridgeServer

    var body: some View {
        let look = ConnectionLook.current(for: bridge)
        Circle()
            .fill(look.tint)
            .frame(width: 10, height: 10)
            .accessibilityLabel(Text(verbatim: "Conexión: " + look.text))
            .accessibilityIdentifier("terminal.connectionDot")
    }
}

struct ConnectionStatusRow: View {
    @ObservedObject var bridge: BridgeServer

    var body: some View {
        let look = ConnectionLook.current(for: bridge)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(look.tint)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: look.text)
                    .font(.footnote.weight(.semibold))
                if let hint = look.hint {
                    Text(verbatim: hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("terminal.connection.\(look.token)")
            Spacer(minLength: 0)
            if case .failed = bridge.connectionState {
                Button("Reintentar") { bridge.start() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("terminal.connection.retry")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

/// UITextField without autocorrection or smart punctuation: curly quotes would make a command unusable.
struct CommandInputField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isEnabled: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(owner: self)
    }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField(frame: .zero)
        field.placeholder = placeholder
        field.borderStyle = .roundedRect
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.returnKeyType = .send
        field.clearButtonMode = .whileEditing
        field.accessibilityIdentifier = "terminal.input"
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.owner = self
        if field.text != text { field.text = text }
        field.isEnabled = isEnabled
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var owner: CommandInputField

        init(owner: CommandInputField) {
            self.owner = owner
        }

        @objc func textChanged(_ sender: UITextField) {
            owner.text = sender.text ?? ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            owner.onSubmit()
            return false
        }
    }
}
