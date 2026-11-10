import SwiftUI
import TerminalBridgeKit

/// A fenced block of a reply. Shell lines get their own "Escribir" row; other lines are shown verbatim.
struct CommandBlockView: View {
    let block: CodeBlock
    let entry: TerminalEntry
    @ObservedObject var chat: TerminalChatViewModel
    @ObservedObject var bridge: BridgeServer

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
                        chat: chat,
                        bridge: bridge
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

/// One command line: the exact text that would be typed, its warnings and the "Escribir" button.
struct CommandLineRow: View {
    let candidate: CommandCandidate
    /// "<reply>.<line>", used in the accessibility identifiers.
    let position: String
    let isPossiblyTruncated: Bool
    @ObservedObject var chat: TerminalChatViewModel
    @ObservedObject var bridge: BridgeServer

    private var sendState: CommandSendState { chat.sendState(for: candidate) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Verbatim and never truncated: the owner must see the whole line that will be typed.
            VerbatimCommandText(text: candidate.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("command.text.\(position)")
            if !candidate.warnings.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { warningChips }
                    VStack(alignment: .leading, spacing: 4) { warningChips }
                }
            }
            notes
            HStack(spacing: 10) {
                actionButton
                statusText
            }
        }
        .alert(confirmationTitle, isPresented: confirmationBinding) {
            confirmationButtons
        } message: {
            Text(verbatim: confirmationMessage)
        }
    }

    // MARK: Pieces

    private var warningChips: some View {
        ForEach(candidate.warnings, id: \.self) { rule in
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
        if let blockedReason {
            Text(verbatim: blockedReason)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var actionButton: some View {
        Button(action: primaryAction) {
            buttonLabel
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .disabled(!canTap)
        .accessibilityHint(Text(verbatim: blockedReason ?? "Escribe la orden en la Mac sin pulsar Enter."))
        .accessibilityIdentifier("command.write.\(position)")
    }

    @ViewBuilder
    private var buttonLabel: some View {
        switch sendState {
        case .sending:
            HStack(spacing: 6) {
                ProgressView()
                Text("Enviando…")
            }
        case .sent:
            Label("Escribir de nuevo", systemImage: "keyboard")
        case .failed:
            Label("Reintentar", systemImage: "arrow.clockwise")
        case .idle, .confirming:
            Label("Escribir", systemImage: "keyboard")
        }
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

    private var isTypeable: Bool {
        candidate.isTypeable && !isPossiblyTruncated
    }

    private var localWarnings: [String] {
        candidate.warnings.map(\.id)
    }

    /// Why the button is off, when it is not obvious from the notes above.
    private var blockedReason: String? {
        CommandWriteFlow.blockedReason(sendState, isTypeable: isTypeable, isConnected: bridge.isConnected)
    }

    private var canTap: Bool {
        CommandWriteFlow.canTap(sendState, isTypeable: isTypeable, isConnected: bridge.isConnected)
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

    private static func warningLine(_ id: String) -> String {
        guard let rule = RiskyRule(rawValue: id) else { return "• " + id }
        return "• " + rule.title + ": " + rule.explanation
    }
}
