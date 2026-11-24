import SwiftUI
import TerminalBridgeKit

/// A fenced block of a reply. Shell lines get their own row with send and copy buttons; other lines are shown
/// verbatim, without buttons: only a `CommandCandidate` goes through the outgoing-line checks.
struct CommandBlockView: View {
    let block: CodeBlock
    let entry: TerminalEntry
    @ObservedObject var chat: TerminalChatViewModel
    @ObservedObject var bridge: BridgeServer
    @ObservedObject var keyboard: BluetoothKeyboard
    let webServer: WebServerController

    private struct BlockLine: Identifiable {
        let id: Int
        let text: String
        let candidate: CommandCandidate?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !block.language.isEmpty {
                Text(verbatim: block.language)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            ForEach(lines) { line in
                if let candidate = line.candidate {
                    CommandLineRow(
                        candidate: candidate,
                        position: position(of: candidate),
                        isPossiblyTruncated: entry.possiblyTruncated.contains(candidate.id),
                        offersCapture: entry.role != .capture,
                        chat: chat,
                        bridge: bridge,
                        keyboard: keyboard,
                        webServer: webServer
                    )
                } else {
                    VerbatimCommandText(text: line.text, isSecondary: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !block.isShell {
                Text(verbatim: "Bloque marcado como «\(block.language)», no como shell: no se puede escribir desde aquí.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !block.isClosed {
                Text("El bloque no se cerró: la respuesta puede estar incompleta.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var lines: [BlockLine] {
        let byLine = Dictionary(uniqueKeysWithValues: block.candidates.map { ($0.lineIndex, $0) })
        return block.lines.indices.compactMap { index in
            makeLine(index: index, candidate: byLine[index])
        }
    }

    private func makeLine(index: Int, candidate: CommandCandidate?) -> BlockLine? {
        let text = block.lines[index]
        if candidate == nil && text.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        return BlockLine(id: index, text: text, candidate: candidate)
    }

    private func position(of candidate: CommandCandidate) -> String {
        "\(entry.replyOrdinal).\(entry.candidateIndex[candidate.id] ?? candidate.lineIndex)"
    }
}

/// One command line: the exact text that would be typed with its icon buttons (one send per available channel,
/// copy, and the "Más" menu: capture, network send, read-back line), its warnings and each channel's status.
struct CommandLineRow: View {
    let candidate: CommandCandidate
    /// "<reply>.<line>", used in the accessibility identifiers.
    let position: String
    let isPossiblyTruncated: Bool
    /// False for the app's own read-back and cleanup lines: capturing them would only nest captures.
    let offersCapture: Bool
    @ObservedObject var chat: TerminalChatViewModel
    @ObservedObject var bridge: BridgeServer
    @ObservedObject var keyboard: BluetoothKeyboard
    let webServer: WebServerController
    @AppStorage(KeyboardLayoutPreference.hostOSKey) private var hostOSRaw = KeyboardLayoutPreference.defaultHostOS
    @AppStorage(KeyboardLayoutPreference.layoutKey) private var layoutRaw = ""

    static let networkNote = "El ordenador envía a este iPhone la salida y los errores (de la última orden si hay "
        + "una tubería) por http sin cifrar. La orden se ejecuta dentro de una tubería, por eso cd, export y "
        + "similares no se permiten. Nada llega al modelo hasta que lo revises."

    private var sendState: CommandSendState { chat.sendState(for: candidate) }
    private var capture: CaptureLines? { chat.captures[candidate.id] }
    private var network: NetworkOutputLine? { chat.networkLines[candidate.id] }
    private var layout: HostKeyboardLayout {
        KeyboardLayoutPreference.resolve(hostOSRaw: hostOSRaw, layoutRaw: layoutRaw)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Verbatim and never truncated: the owner must see the whole line that will be typed.
            if capture == nil && network == nil {
                VStack(alignment: .leading, spacing: 6) {
                    CommandCodeRow(
                        text: candidate.text, textIdentifier: "command.text.\(position)", buttonsSortPriority: -1
                    ) { actionCluster }
                    warningsAndNotes
                }
                .accessibilityElement(children: .contain)
            } else {
                VerbatimCommandText(text: candidate.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("command.text.\(position)")
                warningsAndNotes
            }
            captureSection
            networkSection
            statusText
            if CommandRowActions.showsKeyboardStatus(
                keyboardActive: keyboard.isActive, keyboard: chat.keyboardState(for: candidate)
            ) {
                keyboardControls(.status)
            }
            ClipboardLineControls(candidate: candidate, position: position, chat: chat)
            if isTypeable, let reason = channelOffer.unavailableReason {
                Text(verbatim: reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("command.noChannel.\(position)")
            }
        }
        .alert(confirmationTitle, isPresented: confirmationBinding) {
            confirmationButtons
        } message: {
            Text(verbatim: confirmationMessage)
        }
    }

    // MARK: Pieces

    /// The original's rules, then any the capture wrapper adds (none today, pinned by a kit test).
    private var warningRules: [RiskyRule] {
        localWarnings.compactMap { RiskyRule(rawValue: $0) }
    }

    @ViewBuilder
    private var warningsAndNotes: some View {
        if !warningRules.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { warningChips }
                VStack(alignment: .leading, spacing: 4) { warningChips }
            }
        }
        notes
    }

    private var warningChips: some View {
        ForEach(warningRules, id: \.self) { rule in
            Label(rule.title, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .foregroundStyle(.orange)
                .background(.orange.opacity(0.15), in: Capsule())
                .accessibilityIdentifier("command.warning.\(position).\(rule.id)")
        }
    }

    @ViewBuilder
    private var notes: some View {
        if candidate.isPartOfMultilineCommand {
            Text(verbatim: CommandCandidate.multilineNote)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(Array(candidate.violations.enumerated()), id: \.offset) { item in
            Text(verbatim: item.element.message)
                .font(.caption)
                .foregroundStyle(.red)
        }
        if isPossiblyTruncated {
            Text("La respuesta terminó dentro del bloque: esta línea puede estar cortada.")
                .font(.caption)
                .foregroundStyle(.red)
        }
        if let macOnlyRefusal {
            Text(verbatim: macOnlyRefusal)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("command.channelRefusal.\(position)")
        }
    }

    @ViewBuilder
    private var captureSection: some View {
        if let capture {
            VStack(alignment: .leading, spacing: 4) {
                Text("Se enviará:")
                    .font(.caption.weight(.semibold))
                CommandCodeRow(
                    text: capture.wrapped, isSecondary: true, textIdentifier: "command.captureLine.\(position)"
                ) { actionCluster }
                Text(verbatim: "Archivo en el ordenador: " + capture.filePath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: CaptureNote.text(for: capture.host))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("command.capture.section.\(position)")
        } else if let refusal = chat.captureRefusals[candidate.id] {
            Text(verbatim: "Sin captura: " + refusal)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("command.captureRefusal.\(position)")
        }
    }

    @ViewBuilder
    private var networkSection: some View {
        if let network {
            VStack(alignment: .leading, spacing: 4) {
                Text("Se enviará:")
                    .font(.caption.weight(.semibold))
                CommandCodeRow(
                    text: network.line, isSecondary: true, textIdentifier: "command.networkLine.\(position)"
                ) { actionCluster }
                Text(verbatim: "\(network.line.utf8.count) de \(CommandTextPolicy.maxBytes) bytes. " + Self.networkNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let port = webServer.loopbackIngestPort {
                    let hint = NetworkOutputLine.loopbackForwardHint(port: port)
                    Text(verbatim: hint.explanation)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    VerbatimCommandText(text: hint.command, isSecondary: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("command.networkForward.\(position)")
                }
                networkPhaseText
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("command.network.section.\(position)")
        } else if chat.networkPending.contains(candidate.id) {
            HStack(spacing: 6) {
                ProgressView()
                Text("Creando el enlace de un solo uso…")
                    .font(.caption)
            }
        } else {
            if let refusal = chat.networkRefusals[candidate.id] {
                Text(verbatim: refusal)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("command.networkRefusal.\(position)")
            }
            networkPhaseText
        }
    }

    @ViewBuilder
    private var networkPhaseText: some View {
        if let phase = chat.networkPhases[candidate.id] {
            TimelineView(.explicit(Self.phaseChanges(phase))) { context in
                Text(verbatim: phase.text(now: context.date, time: WebServerView.timeFormatter.string(from:)))
                    .font(.caption)
                    .foregroundStyle(Self.phaseTint(phase, now: context.date))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("command.networkState.\(position)")
            }
        }
    }

    private static func phaseChanges(_ phase: NetworkTicketPhase) -> [Date] {
        guard case .open(let expiresAt) = phase else { return [] }
        return [expiresAt]
    }

    private static func phaseTint(_ phase: NetworkTicketPhase, now: Date) -> Color {
        switch phase {
        case .open where phase.isExpired(now: now), .cancelledByServerStop, .used(_, true): .orange
        case .open: .secondary
        case .used: .green
        }
    }

    private var moreMenu: some View {
        Menu {
            if offersCapture {
                Toggle(isOn: captureBinding) {
                    Label("Capturar salida", systemImage: "tray.and.arrow.down")
                }
                .disabled(!canToggleCapture || network != nil)
                .accessibilityIdentifier("command.capture.\(position)")
            }
            if offersCapture, webServer.ingestEndpoint != nil || network != nil {
                Toggle(isOn: networkBinding) {
                    Label("Enviar salida al iPhone por red", systemImage: "network")
                }
                .disabled(!canToggleNetwork)
                .accessibilityIdentifier("command.network.\(position)")
            }
            if let capture, chat.wasSent(capture) {
                Button {
                    chat.appendReadBack(for: capture)
                } label: {
                    Label("Línea para recuperar la salida", systemImage: "arrow.uturn.backward")
                }
                .accessibilityIdentifier("command.readBack.\(position)")
            }
        } label: {
            Image(systemName: CommandRowActions.moreSymbol)
                .font(.body)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel(Text(verbatim: CommandRowActions.moreLabel))
        .accessibilityHint(Text(verbatim: captureHint))
        .accessibilityIdentifier("command.more.\(position)")
    }

    /// Send buttons for every available channel, copy, then the menu; always acts on the outgoing line.
    @ViewBuilder
    private var actionCluster: some View {
        if channelOffer.channels.contains(.keyboard) {
            keyboardControls(.button)
        }
        if channelOffer.channels.contains(.helper) {
            helperButton
        }
        copyButton
        if hasMenuItems {
            moreMenu
        }
    }

    private var helperButton: some View {
        CommandIconButton(
            symbol: SendChannel.helper.symbol,
            label: SendChannel.helper.accessibilityLabel(CommandIconPhase(helper: sendState)),
            hint: blockedReason
                ?? (isKeyboardBusy ? "Esta línea se está tecleando por Bluetooth." : "Escribe la orden en la Mac sin pulsar Enter."),
            isInFlight: CommandIconPhase(helper: sendState) == .inFlight,
            successID: CommandRowActions.successID(helper: sendState),
            action: primaryAction
        )
        .disabled(!canTap)
        .disabled(isKeyboardBusy)
        .accessibilityIdentifier("command.write.\(position)")
    }

    private var copyButton: some View {
        let copyState = chat.clipboardState(for: candidate)
        return CommandIconButton(
            symbol: CommandRowActions.copySymbol,
            label: CommandRowActions.copyLabel,
            hint: ClipboardCopyFlow.blockedReason(
                copyState,
                helper: chat.helperActivity(for: candidate),
                keyboard: chat.keyboardActivity(for: candidate),
                isTypeable: isTypeable
            ) ?? "Copia la orden al portapapeles para pegarla en la Mac.",
            successID: CommandRowActions.successID(clipboard: copyState),
            announcement: CommandRowActions.copiedAnnouncement
        ) {
            chat.requestCopy(for: candidate)
        }
        .disabled(!canCopy)
        .accessibilityIdentifier("command.copy.\(position)")
    }

    private func keyboardControls(_ section: KeyboardLineControls.Part) -> some View {
        KeyboardLineControls(
            candidate: candidate,
            position: position,
            isTypeable: isOutgoingReady,
            helper: HelperLineActivity(sendState),
            layout: layout,
            section: section,
            chat: chat,
            keyboard: keyboard
        )
    }

    private var channelOffer: SendChannelOffer {
        SendChannelOffer.make(
            helperConnected: bridge.isConnected,
            helperInFlight: CommandRowActions.isInFlight(helper: sendState),
            keyboardActive: keyboard.isActive,
            keyboardInFlight: CommandRowActions.isInFlight(keyboard: chat.keyboardState(for: candidate))
        )
    }

    private var hasMenuItems: Bool {
        if offersCapture { return true }
        guard let capture else { return false }
        return chat.wasSent(capture)
    }

    @ViewBuilder
    private var statusText: some View {
        switch sendState {
        case .sent(_, let ack, let target):
            sentStatus(ack, target: target)
                .accessibilityIdentifier("command.state.\(position)")
        case .failed(_, let reason, _):
            Text(verbatim: reason)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("command.state.\(position)")
        case .idle, .confirming, .sending:
            EmptyView()
        }
    }

    @ViewBuilder
    private func sentStatus(_ ack: WriteAck, target: String) -> some View {
        switch ack.result {
        case .typed where ack.verified:
            Text(verbatim: "Escrito en \(target) · verificado. Pulsa Enter en la Mac para ejecutarla.")
                .font(.caption)
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        case .typed:
            // Copy mode cannot be detected before typing, so an unverified write is a visible warning.
            Text(verbatim: "Escrito en \(target) · no verificado: puede haber ido a un aviso o al modo copia de "
                + "screen. Revisa la terminal antes de pulsar Enter.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .alreadyTyped:
            Text(verbatim: "Ya estaba escrito en \(target); no se escribió otra vez.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .unrecognized(let value):
            Text(verbatim: "Respuesta desconocida de la Mac: \(value)")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    // MARK: Behaviour

    /// The line's own gates (policy, multi-line, possibly cut), unchanged from before the capture existed.
    private var isLineTypeable: Bool {
        candidate.isTypeable && !isPossiblyTruncated
    }

    /// The outgoing line (original or wrapped) passed the safeguards on both texts.
    private var isOutgoingReady: Bool {
        guard isLineTypeable, case .success = chat.outgoingLine(for: candidate) else { return false }
        return true
    }

    /// The helper and Universal Clipboard only reach a Mac, so a Linux or Windows capture cannot use them.
    private var macOnlyRefusal: String? {
        CaptureToggle.channelRefusal(capture: capture, channelReachesOnlyMac: true)
    }

    private var isTypeable: Bool {
        isOutgoingReady && macOnlyRefusal == nil
    }

    private var localWarnings: [String] {
        chat.localWarnings(for: candidate)
    }

    private var canToggleCapture: Bool {
        isLineTypeable && chat.canChangeCapture(for: candidate)
    }

    private var captureHint: String {
        if !isLineTypeable { return "Esta línea no se puede enviar." }
        if !offersCapture { return "Línea para recuperar la salida." }
        if !chat.canChangeCapture(for: candidate) {
            return "La captura solo se cambia antes de enviar la línea por cualquier canal."
        }
        return "Capturar la salida y otras opciones."
    }

    private var canToggleNetwork: Bool {
        guard isLineTypeable, chat.canChangeNetwork(for: candidate) else { return false }
        // Turning off is always offered; turning on needs a listening server.
        return network != nil || webServer.ingestEndpoint != nil
    }

    private var networkBinding: Binding<Bool> {
        Binding(
            get: { network != nil },
            set: { _ in
                chat.toggleNetworkOutput(for: candidate, position: position, host: layout.host, server: webServer)
            }
        )
    }

    private var captureBinding: Binding<Bool> {
        Binding(
            get: { capture != nil },
            set: { _ in chat.toggleCapture(for: candidate, host: layout.host) }
        )
    }

    private var canCopy: Bool {
        ClipboardCopyFlow.canTap(
            chat.clipboardState(for: candidate),
            helper: chat.helperActivity(for: candidate),
            keyboard: chat.keyboardActivity(for: candidate),
            isTypeable: isTypeable
        )
    }

    /// Why the button is off, when it is not obvious from the notes above.
    private var blockedReason: String? {
        CommandWriteFlow.blockedReason(sendState, isTypeable: isTypeable, isConnected: bridge.isConnected)
    }

    private var canTap: Bool {
        CommandWriteFlow.canTap(sendState, isTypeable: isTypeable, isConnected: bridge.isConnected)
    }

    /// The two outputs never type the same line at once.
    private var isKeyboardBusy: Bool {
        switch chat.keyboardState(for: candidate) {
        case .confirming, .typing: true
        case .idle, .typed, .failed: false
        }
    }

    private func primaryAction() {
        switch CommandWriteFlow.step(for: sendState, localWarnings: localWarnings, newID: UUID.init) {
        case .write(let writeID, let acknowledged):
            chat.write(candidate, writeID: writeID, acknowledged: acknowledged, bridge: bridge)
        case .confirm(let writeID):
            chat.beginConfirmation(for: candidate, writeID: writeID)
        case .nothing:
            break
        }
    }

    // MARK: Confirmation

    private var pending: CommandConfirmation? {
        CommandWriteFlow.confirmation(for: sendState, localWarnings: localWarnings)
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { pending != nil },
            set: { isShown in
                if !isShown { chat.cancelConfirmation(for: candidate) }
            }
        )
    }

    private var confirmationTitle: String {
        pending?.isRewrite == true ? "¿Escribir de nuevo?" : "Esta orden tiene avisos"
    }

    private var confirmationMessage: String {
        let warnings = (pending?.acknowledged ?? []).map { Self.warningLine($0) }
        let lead = pending?.isRewrite == true ? "Se escribirá otra vez en la terminal." : ""
        let tail = "Se escribe sin pulsar Enter: revísala en la Mac antes de ejecutarla."
        return ([lead] + warnings + [tail]).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    @ViewBuilder
    private var confirmationButtons: some View {
        // Values are captured now: the alert may reset the state before the button action runs.
        if let pending {
            let title = pending.acknowledged.isEmpty ? "Escribir" : "Escribir igualmente"
            Button(title, role: pending.acknowledged.isEmpty ? nil : .destructive) {
                chat.write(candidate, writeID: pending.writeID, acknowledged: pending.acknowledged, bridge: bridge)
            }
        }
        Button("Cancelar", role: .cancel) {
            chat.cancelConfirmation(for: candidate)
        }
    }

    static func warningLine(_ id: String) -> String {
        guard let rule = RiskyRule(rawValue: id) else { return "• " + id }
        return "• " + rule.title + ": " + rule.explanation
    }
}

/// The Bluetooth keyboard side of one line: its icon buttons, or its status and its own confirmation dialog.
struct KeyboardLineControls: View {
    /// The buttons sit in the row's trailing cluster, the status under the row; the dialog stays with the status.
    enum Part {
        case button
        case status
    }

    let candidate: CommandCandidate
    let position: String
    let isTypeable: Bool
    let helper: HelperLineActivity
    let layout: HostKeyboardLayout
    let section: Part
    @ObservedObject var chat: TerminalChatViewModel
    @ObservedObject var keyboard: BluetoothKeyboard

    static let optionNotice = "Esta orden usa la tecla Opción. Si Terminal tiene «Usar Opción como tecla Meta», "
        + "llegará como Escape más una tecla y puede alterar o enviar la línea."

    private var sendState: KeyboardSendState { chat.keyboardState(for: candidate) }

    var body: some View {
        switch section {
        case .button: buttons
        case .status: status
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 6) {
            statusText
            if let refusal = previewRefusal {
                Text(verbatim: refusal)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("command.bluetoothRefusal.\(position)")
            } else if let blockedReason {
                Text(verbatim: blockedReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert(confirmationTitle, isPresented: confirmationBinding) {
            confirmationButtons
        } message: {
            Text(verbatim: confirmationMessage)
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private var buttons: some View {
        if case .typing = sendState {
            CommandIconButton(symbol: "stop.fill", label: "Detener el tecleo", role: .destructive) {
                keyboard.cancelTyping(.cancelled)
            }
            .foregroundStyle(.red)
            .accessibilityIdentifier("command.bluetoothStop.\(position)")
        }
        CommandIconButton(
            symbol: SendChannel.keyboard.symbol,
            label: SendChannel.keyboard.accessibilityLabel(CommandIconPhase(keyboard: sendState)),
            hint: blockedReason ?? previewRefusal
                ?? "Teclea la orden en la ventana con el foco del ordenador, sin pulsar Enter.",
            isInFlight: CommandIconPhase(keyboard: sendState) == .inFlight,
            successID: CommandRowActions.successID(keyboard: sendState),
            action: primaryAction
        )
        .disabled(!canTap)
        .accessibilityIdentifier("command.bluetooth.\(position)")
    }

    @ViewBuilder
    private var statusText: some View {
        switch sendState {
        case .typing(_, let sent, let total):
            Text(verbatim: "Tecleando… \(sent)/\(total)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("command.bluetoothState.\(position)")
        case .typed(_, let layoutID, _, let unverified):
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "Tecleado por Bluetooth (\(HostKeyboardLayout.layout(layoutID).title)). "
                    + "Compruébalo en el ordenador antes de pulsar Enter.")
                    .foregroundStyle(.green)
                if !unverified.isEmpty {
                    Text(verbatim: "Incluye caracteres no verificados en esta distribución: \(unverified)")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("command.bluetoothState.\(position)")
        case .failed(_, let reason, _):
            Text(verbatim: reason)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("command.bluetoothState.\(position)")
        case .idle, .confirming:
            EmptyView()
        }
    }

    // MARK: Behaviour

    private var localWarnings: [String] {
        chat.localWarnings(for: candidate)
    }

    /// The plan the outgoing line (original or capture) would get now, warnings taken as acknowledged; nil for
    /// lines the helper rules reject.
    private var preview: Result<KeyboardTypingPlan, KeyboardTypingRefusal>? {
        guard isTypeable else { return nil }
        return chat.keyboardPreview(for: candidate, layout: layout)
    }

    /// Shown before any tap: the whole line is refused when one character cannot be typed on this layout, or
    /// when its capture was built for another system.
    private var previewRefusal: String? {
        if isTypeable, let reason = chat.keyboardChannelRefusal(for: candidate, layout: layout) { return reason }
        guard case .failure(let refusal)? = preview else { return nil }
        return refusal.message
    }

    private var isEncodable: Bool {
        guard case .success? = preview, chat.keyboardChannelRefusal(for: candidate, layout: layout) == nil else {
            return false
        }
        return true
    }

    private var needsOptionNotice: Bool {
        guard case .success(let plan)? = preview else { return false }
        return chat.needsOptionNotice(usesOptionChords: plan.usesOptionChords, keyboard: keyboard)
    }

    private var canTap: Bool {
        KeyboardWriteFlow.canTap(sendState, helper: helper, isTypeable: isEncodable, readiness: keyboard.readiness)
    }

    private var blockedReason: String? {
        KeyboardWriteFlow.blockedReason(sendState, helper: helper, isTypeable: isEncodable, readiness: keyboard.readiness)
    }

    private func primaryAction() {
        let step = KeyboardWriteFlow.step(
            for: sendState,
            helper: helper,
            localWarnings: localWarnings,
            needsOptionNotice: needsOptionNotice,
            newID: UUID.init
        )
        switch step {
        case .write(let jobID, let acknowledged):
            chat.typeOverBluetooth(
                candidate, jobID: jobID, acknowledged: acknowledged,
                expectedLayout: layout.id, layout: layout, keyboard: keyboard
            )
        case .confirm(let jobID):
            chat.beginKeyboardConfirmation(for: candidate, jobID: jobID, layoutID: layout.id)
        case .nothing:
            break
        }
    }

    // MARK: Confirmation

    private var pending: KeyboardConfirmation? {
        KeyboardWriteFlow.confirmation(
            for: sendState, helper: helper, localWarnings: localWarnings, needsOptionNotice: needsOptionNotice
        )
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { pending != nil },
            set: { isShown in
                if !isShown { chat.cancelKeyboardConfirmation(for: candidate) }
            }
        )
    }

    private var confirmationTitle: String {
        let causes = pending?.causes ?? []
        if causes.contains(.warnings) { return "Esta orden tiene avisos" }
        if causes.contains(.afterPartialTyping) { return "¿Teclear otra vez tras un corte?" }
        if causes.contains(.retype) || causes.contains(.helperAlreadyTyped) || causes.contains(.helperMayHaveTyped) {
            return "¿Teclear de nuevo?"
        }
        return "Esta orden usa la tecla Opción"
    }

    private var confirmationMessage: String {
        guard let pending else { return "" }
        let leads = pending.causes.compactMap { Self.lead($0) }
        let warnings = pending.acknowledged.map { CommandLineRow.warningLine($0) }
        let confirmed = HostKeyboardLayout.layout(pending.layoutID)
        let target = "Se teclea con la distribución «\(confirmed.title)» de \(confirmed.host.title), en la ventana "
            + "que tenga el foco en el ordenador y sin pulsar Enter: revísala allí antes de ejecutarla."
        return (leads + warnings + [target]).joined(separator: "\n")
    }

    private static func lead(_ cause: KeyboardConfirmation.Prompt) -> String? {
        switch cause {
        case .warnings: nil
        case .retype: "Esta línea ya se tecleó por Bluetooth; se tecleará otra vez."
        case .afterPartialTyping: "El intento anterior se cortó: borra en el ordenador el texto a medias antes de seguir."
        case .helperAlreadyTyped: "Esta línea ya se escribió con el ayudante de la Mac."
        case .helperMayHaveTyped: "El ayudante de la Mac falló al escribir esta línea y pudo haberla escrito: revisa el prompt."
        case .optionChords: optionNotice
        }
    }

    @ViewBuilder
    private var confirmationButtons: some View {
        // Values are captured now: the alert may reset the state before the button action runs.
        if let pending {
            let title = pending.acknowledged.isEmpty ? "Teclear" : "Teclear igualmente"
            Button(title, role: pending.acknowledged.isEmpty ? nil : .destructive) {
                if pending.causes.contains(.optionChords) { chat.acceptOptionNotice(keyboard: keyboard) }
                chat.typeOverBluetooth(
                    candidate, jobID: pending.jobID, acknowledged: pending.acknowledged,
                    expectedLayout: pending.layoutID, layout: layout, keyboard: keyboard
                )
            }
        }
        Button("Cancelar", role: .cancel) {
            chat.cancelKeyboardConfirmation(for: candidate)
        }
    }
}

/// The clipboard status of one line and its own confirmation dialog; the copy button is in the row's cluster.
struct ClipboardLineControls: View {
    let candidate: CommandCandidate
    let position: String
    @ObservedObject var chat: TerminalChatViewModel

    static let exposureNote = "Reemplazó lo que tenías en el portapapeles, y cualquier app de la Mac puede leerla "
        + "o cambiarla."
    static let reachNote = "Solo llega a la Mac con la misma cuenta de Apple y Bluetooth, Wi-Fi y Handoff activados "
        + "en los dos. Sin verificar en hardware."

    private var copyState: ClipboardCopyState { chat.clipboardState(for: candidate) }

    var body: some View {
        // A stack even when empty, so the alert stays attached to a view that exists.
        VStack(alignment: .leading, spacing: 4) {
            statusText
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .alert(confirmationTitle, isPresented: confirmationBinding) {
            confirmationButtons
        } message: {
            Text(verbatim: confirmationMessage)
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch copyState {
        case .copied(_, let text, let expiresAt):
            TimelineView(.explicit([expiresAt])) { context in
                if ClipboardCopyFlow.isExpired(copyState, now: context.date) {
                    Text("La copia caducó en el iPhone a las \(expiresAt, style: .time). Cópiala otra vez si la necesitas.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("command.copyState.\(position)")
                } else {
                    copiedStatus(text, expiresAt: expiresAt)
                }
            }
        case .failed(_, let reason):
            Text(verbatim: reason)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("command.copyState.\(position)")
        case .idle, .confirming:
            EmptyView()
        }
    }

    private func copiedStatus(_ text: String, expiresAt: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Copiada:")
                .foregroundStyle(.green)
            VerbatimCommandText(text: text, isSecondary: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Caduca a las \(expiresAt, style: .time). Pégala en la Mac con Cmd+V y revísala antes de pulsar Enter.")
            Text(verbatim: Self.exposureNote)
                .foregroundStyle(.orange)
            Text(verbatim: Self.reachNote)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("command.copyState.\(position)")
    }

    // MARK: Confirmation

    private var localWarnings: [String] {
        chat.localWarnings(for: candidate)
    }

    private var pending: ClipboardConfirmation? {
        ClipboardCopyFlow.confirmation(
            for: copyState,
            helper: chat.helperActivity(for: candidate),
            keyboard: chat.keyboardActivity(for: candidate),
            localWarnings: localWarnings
        )
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { pending != nil },
            set: { isShown in
                if !isShown { chat.cancelCopyConfirmation(for: candidate) }
            }
        )
    }

    private var confirmationTitle: String {
        pending?.causes.contains(.warnings) == true ? "Esta orden tiene avisos" : "¿Copiar para pegar?"
    }

    private var confirmationMessage: String {
        guard let pending else { return "" }
        let leads = pending.causes.compactMap { Self.lead($0) }
        let warnings = pending.acknowledged.map { CommandLineRow.warningLine($0) }
        let tail = "Se copia al portapapeles para pegarla en la Mac: revísala allí antes de pulsar Enter."
        return (leads + warnings + [tail]).joined(separator: "\n")
    }

    private static func lead(_ cause: ClipboardConfirmation.Prompt) -> String? {
        switch cause {
        case .warnings: nil
        case .helperTyped: "Esta línea ya se escribió con el ayudante de la Mac: si además la pegas, quedará dos veces."
        case .helperMayHaveTyped:
            "El ayudante de la Mac falló al escribir esta línea y pudo haberla escrito: revisa el prompt antes de pegar."
        case .keyboardTyped: "Esta línea ya se tecleó por Bluetooth: si además la pegas, quedará dos veces."
        case .keyboardMayHaveTyped:
            "El tecleo por Bluetooth de esta línea se cortó: borra en el ordenador el texto a medias antes de pegar."
        }
    }

    @ViewBuilder
    private var confirmationButtons: some View {
        // Values are captured now: the alert may reset the state before the button action runs.
        if let pending {
            let title = pending.acknowledged.isEmpty ? "Copiar" : "Copiar igualmente"
            Button(title, role: pending.acknowledged.isEmpty ? nil : .destructive) {
                chat.copy(candidate, copyID: pending.copyID, acknowledged: pending.acknowledged)
            }
        }
        Button("Cancelar", role: .cancel) {
            chat.cancelCopyConfirmation(for: candidate)
        }
    }
}

/// What a capture changes, per host, shown under the wrapped line.
enum CaptureNote {
    static let undetectable = "La app no detecta tus alias ni funciones que cambien la sesión."

    static func text(for host: HostOS) -> String {
        switch host {
        case .macOS:
            "Al terminar se copian al portapapeles de la Mac los últimos \(CaptureWrapper.readBackBytes) bytes: "
                + "usa «Pegar salida» aquí. Eso sustituye lo que tenías copiado, no caduca en la Mac, cualquier "
                + "programa de la Mac puede leerlo, Portapapeles Universal puede llevarlo a tus otros dispositivos "
                + "y los gestores de historial lo guardan. El archivo sigue en el ordenador hasta que envíes "
                + "«Limpiar capturas». Se ejecuta en un subshell: no cambia la carpeta, las variables ni las "
                + "opciones de la sesión, y su estado de salida es la línea [estado: N], no el del shell. " + undetectable
        case .linux:
            "La salida se queda en un archivo del ordenador; no vuelve al iPhone sin software extra. Se ejecuta en "
                + "un subshell: no cambia la carpeta, las variables ni las opciones de la sesión, y su estado de "
                + "salida es la línea [estado: N]. " + undetectable
        case .windows:
            "La salida se queda en un archivo del ordenador; no vuelve al iPhone sin software extra. Solo para "
                + "PowerShell 5.1 o 7 (en cmd.exe no funciona). El estado de salida del shell pasa a ser el de la "
                + "tubería. Los permisos del archivo no se han comprobado."
        }
    }
}
