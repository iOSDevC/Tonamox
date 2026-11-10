import Combine
import Foundation
import TerminalBridgeKit
import TonamoxCore

/// One bubble. Replies are parsed once, when they end, so candidate IDs stay stable for the write states.
struct TerminalEntry: Identifiable {
    enum Author {
        case user
        case assistant
        case notice
    }

    let id = UUID()
    let role: Author
    let text: String
    var segments: [ReplySegment] = []
    /// Position among assistant replies; part of the accessibility identifiers.
    var replyOrdinal = 0
    /// Position of each candidate inside this reply.
    var candidateIndex: [UUID: Int] = [:]
    /// The last line of a reply that ends inside an unclosed block may be cut mid-command.
    var possiblyTruncated: Set<UUID> = []
    var isError = false
}

/// Single-turn chat: each prompt goes alone to the engine, nothing is stored on disk.
final class TerminalChatViewModel: ObservableObject {
    @Published private(set) var entries: [TerminalEntry] = []
    @Published private(set) var streamingText = ""
    @Published private(set) var progress = ""
    @Published private(set) var isBusy = false
    @Published private(set) var commandStates: [UUID: CommandSendState] = [:]
    @Published private(set) var catalog = CatalogListing()
    @Published var selectedChoiceID: String?

    private enum StopCause {
        case user
        case background
    }

    private var work: Task<Void, Never>?
    private var activeEngine: (any ReplyEngine)?
    private var pendingStop: StopCause?
    private var replyCount = 0

    var selectedChoice: ModelChoice? {
        catalog.selectable.first { $0.id == selectedChoiceID }
    }

    // MARK: Models

    func refreshCatalog() {
        catalog = LocalModelCatalog.listing()
        if selectedChoice == nil {
            selectedChoiceID = catalog.selectable.first?.id
        }
        LocalModelCatalog.checkAppleModelIfNeeded { [weak self] in self?.refreshCatalog() }
    }

    // MARK: Sending

    func send(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy, let choice = selectedChoice else { return }
        entries.append(TerminalEntry(role: .user, text: trimmed))
        let engine: any ReplyEngine
        do {
            engine = try ReplyEngines.make(for: choice)
        } catch {
            appendNotice(Self.describe(error), isError: true)
            return
        }
        isBusy = true
        pendingStop = nil
        activeEngine = engine
        work = Task {
            await self.run(trimmed, engine: engine)
            self.isBusy = false
            self.progress = ""
            self.streamingText = ""
            self.activeEngine = nil
            self.work = nil
        }
    }

    /// Stops the load or the generation; the text generated so far stays on screen.
    func stop() {
        cancel(because: .user)
    }

    func interruptForBackground() {
        cancel(because: .background)
    }

    private func cancel(because cause: StopCause) {
        guard isBusy else { return }
        pendingStop = cause
        activeEngine?.cancelLoad()
        work?.cancel()
    }

    private func run(_ prompt: String, engine: any ReplyEngine) async {
        var failure: String?
        do {
            let stream = try await engine.reply(to: prompt) { [weak self] message in self?.progress = message }
            progress = ""
            for try await chunk in stream {
                streamingText += chunk
            }
        } catch let interrupted as GenerationInterrupted {
            if !interrupted.partialText.isEmpty { streamingText = interrupted.partialText }
            pendingStop = pendingStop ?? .background
        } catch is CancellationError {
            pendingStop = pendingStop ?? .user
        } catch {
            if Task.isCancelled {
                pendingStop = pendingStop ?? .user
            } else {
                failure = Self.describe(error)
            }
        }
        // Cancelling the consuming task ends the stream without an error.
        if Task.isCancelled, pendingStop == nil { pendingStop = .user }
        finishReply(streamingText)
        if let pendingStop { appendNotice(Self.notice(for: pendingStop), isError: false) }
        if let failure { appendNotice(failure, isError: true) }
    }

    private func finishReply(_ reply: String) {
        guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var entry = TerminalEntry(role: .assistant, text: reply)
        entry.segments = CodeBlockParser.parse(reply)
        entry.replyOrdinal = replyCount
        replyCount += 1
        let candidates = entry.segments.flatMap { Self.candidates(in: $0) }
        entry.candidateIndex = Dictionary(uniqueKeysWithValues: candidates.enumerated().map { ($1.id, $0) })
        // A token limit ends the stream like a normal reply, so any reply that stops inside a block counts.
        if !reply.hasSuffix("\n") {
            entry.possiblyTruncated = Self.lastLineOfUnclosedBlock(in: entry.segments)
        }
        entries.append(entry)
    }

    private func appendNotice(_ text: String, isError: Bool) {
        var notice = TerminalEntry(role: .notice, text: text)
        notice.isError = isError
        entries.append(notice)
    }

    private static func candidates(in segment: ReplySegment) -> [CommandCandidate] {
        guard case .code(let block) = segment else { return [] }
        return block.candidates
    }

    private static func lastLineOfUnclosedBlock(in segments: [ReplySegment]) -> Set<UUID> {
        guard case .code(let block)? = segments.last, !block.isClosed, let last = block.candidates.last,
              last.lineIndex == block.lines.count - 1 else { return [] }
        return [last.id]
    }

    private static func notice(for cause: StopCause) -> String {
        switch cause {
        case .user: "Detenido."
        case .background: "Interrumpido: la app pasó a segundo plano."
        }
    }

    static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    // MARK: Writing

    func sendState(for candidate: CommandCandidate) -> CommandSendState {
        commandStates[candidate.id] ?? .idle
    }

    func beginConfirmation(for candidate: CommandCandidate, writeID: UUID) {
        commandStates[candidate.id] = CommandWriteFlow.beginConfirmation(sendState(for: candidate), writeID: writeID)
    }

    func cancelConfirmation(for candidate: CommandCandidate) {
        commandStates[candidate.id] = CommandWriteFlow.cancelConfirmation(sendState(for: candidate))
    }

    /// Types `candidate` on the Mac without Enter. Reuse `writeID` to retry: the helper answers `alreadyTyped`.
    func write(_ candidate: CommandCandidate, writeID: UUID, acknowledged: [String], bridge: BridgeServer) {
        if case .sending = sendState(for: candidate) { return }
        commandStates[candidate.id] = .sending(writeID: writeID)
        Task {
            do {
                let ack = try await bridge.write(text: candidate.text, id: writeID, acknowledgedWarnings: acknowledged)
                commandStates[candidate.id] = .sent(writeID: writeID, ack: ack, target: bridge.targetLabel ?? "la Mac")
                bridge.noteTyped(ack)
            } catch {
                commandStates[candidate.id] = .failed(
                    writeID: writeID,
                    reason: WriteFailureText.describe(error),
                    helperWarnings: WriteFailureText.helperWarnings(in: error)
                )
            }
        }
    }
}

/// Spanish text for write failures and helper error codes.
enum WriteFailureText {
    static func describe(_ error: any Error) -> String {
        guard let failure = error as? PhoneWriteError else { return TerminalChatViewModel.describe(error) }
        switch failure {
        case .notConnected:
            return "Sin conexión con la Mac."
        case .policy(let violations):
            return violations.map(\.message).joined(separator: "\n")
        case .unacknowledgedWarnings(let rules):
            return "Falta confirmar: " + rules.map(\.title).joined(separator: ", ")
        case .rejected(let report):
            return describe(report)
        case .disconnected:
            return "Se cortó la conexión antes de la respuesta. Reintentar no lo escribe dos veces."
        case .timedOut:
            return "La Mac no respondió a tiempo. Reintentar no lo escribe dos veces."
        case .alreadyInFlight:
            return "Ya se está enviando."
        }
    }

    static func helperWarnings(in error: any Error) -> [String] {
        guard case .rejected(let report)? = error as? PhoneWriteError else { return [] }
        return report.warnings ?? []
    }

    /// The helper's detail is appended only where the base message has no specifics of its own.
    static func describe(_ report: ErrorReport) -> String {
        let base = message(for: report.code)
        guard let detail = report.detail, !detail.isEmpty else { return base }
        switch report.code {
        case .foregroundNotShell:
            return detail
        case .screenFailed, .screenUnavailable, .unrecognized:
            return base + " (" + detail + ")"
        default:
            return base
        }
    }

    static func message(for code: BridgeErrorCode) -> String {
        switch code {
        case .policy: "La Mac rechazó el texto: solo ASCII imprimible, una línea, hasta 512 bytes."
        case .unacknowledgedWarnings: "La Mac pide confirmar avisos de esta orden."
        case .sessionMissing: "No hay sesión de screen."
        case .ambiguousSession: "Hay varias sesiones de screen con ese nombre."
        case .windowMissing: "La ventana de screen no existe."
        case .multipleWindows: "La sesión de screen tiene varias ventanas; usa una sesión con una sola."
        case .promptNotIdle:
            "La terminal de la Mac no está en un prompt vacío: ejecuta o borra (Ctrl-U) la línea escrita, o "
                + "responde la pregunta pendiente, y reintenta."
        case .foregroundNotShell: "La ventana está ocupada por otro programa."
        case .screenUnavailable: "screen no está disponible en la Mac."
        case .screenFailed: "screen falló al escribir."
        case .unsupportedIntent, .unsupportedMessage: "La Mac no entiende esta petición; actualiza tonamox-bridge."
        case .rateLimited: "Demasiado rápido; espera un momento y reintenta."
        case .busy: "La Mac está ocupada; reintenta."
        case .authFailed: "Falló la autenticación."
        case .unsupportedProtocol: "Versión de protocolo no compatible."
        case .unrecognized(let value): "Error desconocido: " + value
        }
    }
}
