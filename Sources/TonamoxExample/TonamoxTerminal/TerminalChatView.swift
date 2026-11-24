import SwiftUI
import TerminalBridgeKit
import TonamoxCore
import TonamoxServer
import TonamoxUI
import UIKit

/// Root screen: connection indicator, screen status banner, replies with command rows and the input bar.
struct TerminalChatView: View {
    @ObservedObject var bridge: BridgeServer
    @ObservedObject var chat: TerminalChatViewModel
    @ObservedObject var keyboard: BluetoothKeyboard
    let webServer: WebServerController
    @ObservedObject var capabilities: CapabilityRunner
    /// The app's only consent presenter, so one remote request maps to one sheet.
    @ObservedObject private var consentGate = HybridSettings.shared.consent
    @ObservedObject private var judge = ClaudeJudgeService.shared
    @State private var draft = ""
    @State private var showsPairing = false
    @State private var showsKeyboard = false
    @State private var showsModels = false
    @State private var showsWebServer = false
    @State private var showsCapabilityTests = false
    @State private var showsRemoteSettings = false
    @State private var showsSharedStorage = false
    @State private var showsDownloads = false
    @State private var showsOpenSource = false
    /// Settings or shared storage was opened from the model sheet, which comes back when it closes.
    @State private var returnsToModels = false
    /// The one sheet on screen; see `SheetQueue`.
    @State private var shownSheet: RootSheet?
    /// Reasoning blocks the user opened, by `ReplyReasoning.id`; everything else stays collapsed.
    @State private var expandedReasoning: Set<UUID> = []
    @AppStorage(KeyboardLayoutPreference.hostOSKey) private var hostOSRaw = KeyboardLayoutPreference.defaultHostOS

    static let noModelsText = "No hay modelos en este iPhone. Toca " + ModelPickerText.chipReference
        + ", y busca uno en «Buscar modelos»."
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
                pasteBar
                if chat.isTestModeOn {
                    TestModePanel(chat: chat)
                }
                inputBar
            }
            .navigationTitle("Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SettingsMenuButton(webServer: webServer, isRunningCapabilityTests: chat.isRunningCapabilityTests,
                                       isTestModeOn: chat.isTestModeOn, open: openSetting)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    KeyboardToolbarButton(keyboard: keyboard) { showsKeyboard = true }
                }
            }
            // One sheet for all: SwiftUI refuses a second sheet silently, so a browser's pairing code or a consent
            // request arriving over another sheet would never show.
            .sheet(item: sheetBinding, onDismiss: sheetDismissed) { route in
                sheetContent(route)
            }
            .navigationDestination(isPresented: $showsWebServer) {
                WebServerView(controller: webServer, chat: chat)
            }
            .navigationDestination(isPresented: $showsCapabilityTests) {
                CapabilityTestView(runner: capabilities, chat: chat)
            }
            .navigationDestination(isPresented: $showsDownloads) {
                DownloadedModelsList()
                    .onDisappear(perform: chat.refreshCatalog)
            }
            .navigationDestination(isPresented: $showsOpenSource) {
                OpenSourceNoticesView()
            }
        }
        .onAppear {
            chat.refreshCatalog()
            webServer.selectionChanged(to: chat.selectedChoice)
        }
        .onChange(of: chat.selectedChoiceID) {
            webServer.selectionChanged(to: chat.selectedChoice)
        }
        .onChange(of: sheetDemands, initial: true) { _, demands in
            shownSheet = SheetQueue.next(showing: shownSheet, demands: demands)
        }
        .onChange(of: webServer.refusalCount) {
            chat.noteRefusals(webServer.refusedTickets)
        }
        .onChange(of: webServer.arrivalCount) {
            chat.noteArrivals(webServer.arrivals.waiting)
            if let output = webServer.takeArrivalForAutomaticOpen(isPresenting: isPresenting) {
                chat.prepareNetworkPaste(output)
            }
        }
        .onChange(of: webServer.ingestSession) { old, new in
            if old != nil, old != new { chat.ingestSessionEnded() }
        }
        .onSharedStorageChange([.models]) {
            // Registry first, so the catalog sees MLX models another app downloaded.
            ModelDownloadCenter.shared.reloadSharedState()
            chat.refreshCatalog()
        }
    }

    /// Any sheet or alert this screen can show: a received output never opens on top of one.
    private var isPresenting: Bool {
        !sheetDemands.isEmpty || chat.isPresentingPasteOrDialog
    }

    /// Every sheet something asks for, most urgent first: a pairing code expires in two minutes and a consent
    /// request holds a turn, so they go before the paste preview and the sheets the user opened.
    private var sheetDemands: [RootSheet] {
        var demands: [RootSheet] = []
        if let request = webServer.livePairingRequest { demands.append(.browserPairing(request.id)) }
        if let request = consentGate.pending { demands.append(.consent(request.id)) }
        if chat.pendingPaste != nil { demands.append(.pastePreview) }
        if showsPairing { demands.append(.bridgePairing) }
        if showsModels { demands.append(.models) }
        if showsKeyboard { demands.append(.keyboard) }
        if showsRemoteSettings { demands.append(.remoteSettings) }
        if showsSharedStorage { demands.append(.sharedStorage) }
        return demands
    }

    private var sheetBinding: Binding<RootSheet?> {
        // Read here, during `body`, so observation re-renders the sheet when a demand arrives or ends.
        let current = shownSheet
        return Binding(
            get: { current },
            set: { if $0 == nil { endDemand(for: current) } }
        )
    }

    /// The user swiped the sheet away: end what it showed, as each sheet's own close would.
    private func endDemand(for route: RootSheet?) {
        switch route {
        case .browserPairing: webServer.denyPendingPairing()
        case .consent(let id): consentGate.resolve(false, requestID: id)
        case .pastePreview: chat.discardPaste()
        case .bridgePairing: showsPairing = false
        case .models: showsModels = false
        case .keyboard: showsKeyboard = false
        case .remoteSettings:
            showsRemoteSettings = false
            // Policy and keys decide which remote rows are locked.
            chat.refreshCatalog()
            reopenModelsIfNeeded()
        case .sharedStorage:
            showsSharedStorage = false
            chat.refreshCatalog()
            reopenModelsIfNeeded()
        case nil: break
        }
        shownSheet = SheetQueue.next(showing: nil, demands: sheetDemands)
    }

    private func reopenModelsIfNeeded() {
        if returnsToModels { showsModels = true }
        returnsToModels = false
    }

    /// Swaps the model sheet for a root sheet; dropping the `.models` demand lets SheetQueue show the new one.
    private func leaveModels(for route: RootSheet) {
        returnsToModels = true
        showsModels = false
        switch route {
        case .remoteSettings: showsRemoteSettings = true
        case .sharedStorage: showsSharedStorage = true
        default: break
        }
    }

    private func openSetting(_ entry: SettingsMenuEntry) {
        switch entry {
        case .webServer: showsWebServer = true
        case .keyboard: showsKeyboard = true
        case .pairing: showsPairing = true
        case .remoteSettings: showsRemoteSettings = true
        case .downloads: showsDownloads = true
        case .capabilityTests: showsCapabilityTests = true
        case .testMode: chat.isTestModeOn.toggle()
        case .openSource: showsOpenSource = true
        }
    }

    /// The paste turn starts after the preview is gone, so a remote engine's consent sheet can present.
    private func sheetDismissed() {
        chat.startQueuedPasteTurn()
        shownSheet = SheetQueue.next(showing: shownSheet, demands: sheetDemands)
    }

    @ViewBuilder
    private func sheetContent(_ route: RootSheet) -> some View {
        switch route {
        case .bridgePairing:
            PairingView(bridge: bridge)
        case .models:
            ModelPickerView(
                chat: chat,
                archive: capabilities.archive,
                onTestCapabilities: { showsCapabilityTests = true },
                onOpenSettings: { leaveModels(for: .remoteSettings) },
                onOpenSharedStorage: { leaveModels(for: .sharedStorage) }
            )
            .presentationDetents([.medium, .large])
        case .remoteSettings:
            HybridSettingsView(cloudKeys: AnyView(ProvidersLinkSection(onChange: chat.refreshCatalog)))
        case .sharedStorage:
            SharedModelsView()
        case .keyboard:
            BluetoothKeyboardView(keyboard: keyboard)
        case .pastePreview:
            if let output = chat.pendingPaste {
                PastedOutputPreview(output: output, command: chat.pasteCommand, source: chat.pendingPasteSource,
                                    chat: chat)
            }
        case .consent(let id):
            if let request = consentGate.pending, request.id == id {
                RemoteConsentSheet(request: request, gate: consentGate)
            }
        case .browserPairing(let id):
            if let request = webServer.livePairingRequest, request.id == id {
                BrowserPairingSheet(request: request, onDeny: webServer.denyPendingPairing) {
                    webServer.pairing.dismiss(request.id)
                }
            }
        }
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
        }
        .font(.callout)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.emptyState")
    }

    @ViewBuilder
    private func bubble(for entry: TerminalEntry) -> some View {
        switch entry.role {
        case .user:
            if let detail = entry.pasteDetail {
                pastedBubble(question: entry.text, detail: detail)
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    if let id = entry.testQuestionID {
                        Text(verbatim: "Modo Test · pregunta \(id)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(verbatim: entry.text)
                }
                .padding(10)
                .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("terminal.prompt")
            }
        case .capture:
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: entry.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(entry.segments.enumerated()), id: \.offset) { item in
                    segmentView(item.element, in: entry)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("terminal.capture.\(entry.replyOrdinal)")
        case .assistant:
            VStack(alignment: .leading, spacing: 10) {
                if let reasoning = entry.reasoning {
                    ReasoningBlockView(reasoning: reasoning, isExpanded: reasoningExpansion(reasoning.id),
                                       identifier: "terminal.reasoning.\(entry.replyOrdinal)")
                }
                ForEach(Array(entry.segments.enumerated()), id: \.offset) { item in
                    segmentView(item.element, in: entry)
                }
                if let grade = entry.testGrade {
                    testGradeRow(grade, in: entry)
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

    private func testGradeRow(_ grade: TestModeGrade, in entry: TerminalEntry) -> some View {
        let identifier = "terminal.testGrade.\(entry.replyOrdinal)"
        let current = entry.testQuestionID.flatMap { id in
            entry.testGeneration.flatMap { chat.testSession.outcome(for: id, generation: $0) }
        }
        guard let current, let id = entry.testQuestionID else {
            return TestGradeRow(outcome: TestModeOutcome(automatic: grade), identifier: identifier)
        }
        let note = entry.testGeneration.flatMap { generation in
            judge.note(scope: TerminalChatViewModel.testJudgeScope, key: "\(generation).\(id)",
                       answer: chat.testSession.answers[id]?.answer)
        }
        return TestGradeRow(outcome: current, identifier: identifier,
                            secondOpinion: chat.testSession.secondOpinions[id], judgeNote: note) { action in
            chat.applyTestOverride(action, to: entry.id)
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: ReplySegment, in entry: TerminalEntry) -> some View {
        switch segment {
        case .prose(let text):
            // Inline Markdown only, links shown as text: nothing here can be tapped out of the app. Selecting and
            // copying gives the shown text, so a \boxed{} answer copies as its value.
            Text(ProseMarkdown.attributed(BoxedAnswer.display(text)))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .code(let block):
            CommandBlockView(block: block, entry: entry, chat: chat, bridge: bridge, keyboard: keyboard,
                             webServer: webServer)
        }
    }

    private func pastedBubble(question: String, detail: TerminalEntry.PastedTurn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "\(detail.title) (\(detail.byteCount) bytes)")
                .font(.callout.weight(.semibold))
            if !question.isEmpty {
                Text(verbatim: question)
            }
            DisclosureGroup("Lo que recibió el modelo") {
                Text(verbatim: detail.prompt)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(Text(verbatim: "Texto enviado al modelo, \(detail.prompt.utf8.count) bytes"))
                    .accessibilityValue(Text(verbatim: detail.prompt))
            }
            .font(.caption)
        }
        .padding(10)
        .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.pastedPrompt")
    }

    private var streamingBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reasoning = chat.streamingReasoning {
                ReasoningBlockView(reasoning: reasoning, isExpanded: reasoningExpansion(reasoning.id),
                                   identifier: "terminal.streaming.reasoning")
            }
            if chat.streamingText.isEmpty {
                if chat.streamingReasoning == nil {
                    loadingRow
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

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(verbatim: chat.progress.isEmpty ? "Pensando…" : chat.progress)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func reasoningExpansion(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedReasoning.contains(id) },
            set: { isOpen in
                if isOpen { expandedReasoning.insert(id) } else { expandedReasoning.remove(id) }
            }
        )
    }

    // MARK: Paste

    /// The system paste control reads the clipboard only on the user's tap and shows no permission alert. Its
    /// label cannot be renamed, so a caption names the action.
    private var pasteBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            arrivalsBadge
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    pasteControl
                    Spacer(minLength: 0)
                    cleanupButton
                }
                VStack(alignment: .leading, spacing: 0) {
                    pasteControl
                    cleanupButton
                }
            }
        }
        // ViewThatFits centres a narrower layout; the bar reads from the leading edge.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.top, 6)
    }

    /// Outputs that arrived while something else was showing; each opens the same review as a paste.
    @ViewBuilder
    private var arrivalsBadge: some View {
        if let badge = webServer.arrivals.badgeText {
            Button {
                if let output = webServer.takeArrivalForTap(isPresenting: isPresenting) {
                    chat.prepareNetworkPaste(output)
                }
            } label: {
                Label {
                    Text(verbatim: badge + ": revisar")
                } icon: {
                    Image(systemName: "tray.full.fill")
                }
                .font(.caption.weight(.semibold))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .disabled(chat.isPresentingPasteOrDialog)
            .accessibilityHint(Text("Abre la revisión de la salida más antigua; nada va al modelo hasta que la envíes."))
            .accessibilityIdentifier("terminal.receivedOutputs")
        }
    }

    private var pasteControl: some View {
        let model = chat
        return HStack(spacing: 8) {
            PasteButton(payloadType: String.self) { @Sendable strings in
                let raw = strings.joined(separator: "\n")
                Task { @MainActor in model.preparePaste(raw) }
            }
            .buttonBorderShape(.capsule)
            .disabled(chat.isBusy || chat.isRunningCapabilityTests || chat.pendingPaste != nil)
            .accessibilityHint(Text("Trae al chat la salida copiada del ordenador; antes verás lo que recibe el modelo."))
            .accessibilityIdentifier("terminal.pasteOutput")
            Text("Pegar salida del ordenador")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Always offered: the capture history is in memory only, so files from an earlier launch need it too.
    private var cleanupButton: some View {
        Button {
            chat.appendCleanupLines(configured: HostOS(rawValue: hostOSRaw) ?? .macOS)
        } label: {
            Text("Limpiar capturas")
                .font(.caption)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        // Borderless: a bordered style stretches its capsule to the 44 pt tap target.
        .buttonStyle(.borderless)
        .accessibilityHint(Text("Añade la línea que borra los archivos de captura; la envías tú."))
        .accessibilityIdentifier("terminal.cleanupCaptures")
    }

    // MARK: Input

    private var inputBar: some View {
        VStack(spacing: 8) {
            CommandInputField(
                text: $draft,
                placeholder: "Pide una orden…",
                isEnabled: chat.selectedChoice != nil,
                onSubmit: submit
            )
            .frame(minHeight: 36)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                // Never disabled, as the toolbar button it replaces: the sheet's rows refuse a switch mid-run.
                ModelChip(choice: chat.selectedChoice,
                          otherTitles: chat.catalog.defaultSelectable.map(\.title)) { showsModels = true }
                Spacer(minLength: 8)
                sendOrStop
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var sendOrStop: some View {
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

    private var canSend: Bool {
        chat.selectedChoice != nil && !chat.isRunningCapabilityTests
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

/// The root screen's sheets; one shows at a time.
enum RootSheet: Hashable, Identifiable {
    case bridgePairing
    case models
    case keyboard
    case pastePreview
    case remoteSettings
    case sharedStorage
    case consent(UUID)
    case browserPairing(UUID)

    var id: Self { self }
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

/// How the bridge connection is shown in the wrapping status row.
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
