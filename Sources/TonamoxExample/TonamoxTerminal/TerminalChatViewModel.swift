import Combine
import Foundation
import TerminalBridgeKit
import TonamoxCore
import TonamoxServer
import UIKit
import UniformTypeIdentifiers

/// One bubble. Replies are parsed once, when they end, so candidate IDs stay stable for the write states.
struct TerminalEntry: Identifiable {
    enum Author {
        case user
        case assistant
        case notice
        /// Lines the app generated (read-back, cleanup); rendered and guarded like a reply's lines.
        case capture
    }

    /// What a "Pegar salida" turn sent: the bubble shows the size and, on request, the exact prompt.
    struct PastedTurn {
        /// "Salida pegada" or where a network output came from.
        var title = "Salida pegada"
        let byteCount: Int
        let prompt: String
        /// The prompt names the last captured command.
        var includesCommand = false
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
    var pasteDetail: PastedTurn?
    /// The reply's leading reasoning; `text` and `segments` hold the answer only.
    var reasoning: ReplyReasoning?
    /// Set on a Test Mode prompt and on its reply.
    var testQuestionID: Int?
    /// Display only: nothing reads it to send, copy or type.
    var testGrade: TestModeGrade?
    /// The Test Mode generation that recorded `testGrade`; nil when the session ignored it, so no override applies.
    var testGeneration: Int?
}

/// Single-turn chat: each prompt goes alone to the engine, nothing is stored on disk.
final class TerminalChatViewModel: ObservableObject {
    @Published private(set) var entries: [TerminalEntry] = []
    /// The answer part of the reply being streamed; the reasoning goes to `streamingReasoning`.
    @Published private(set) var streamingText = ""
    @Published private(set) var streamingReasoning: ReplyReasoning?
    @Published private(set) var progress = ""
    @Published private(set) var isBusy = false
    /// The capability battery holds the model: the chat sends nothing until it ends.
    @Published private(set) var isRunningCapabilityTests = false
    @Published private(set) var commandStates: [UUID: CommandSendState] = [:]
    @Published private(set) var keyboardStates: [UUID: KeyboardSendState] = [:]
    @Published private(set) var clipboardStates: [UUID: ClipboardCopyState] = [:]
    /// Capture wrappers by candidate id; set only while every channel of the line is idle.
    @Published private(set) var captures: [UUID: CaptureLines] = [:]
    @Published private(set) var captureRefusals: [UUID: String] = [:]
    /// Captured lines a channel finished sending, oldest first. Session only, never on disk.
    @Published private(set) var capturedHistory: [CaptureLines] = []
    /// Sanitised paste waiting in the preview; nothing reaches the model until the user sends it.
    @Published private(set) var pendingPaste: PastedOutput?
    /// Where `pendingPaste` came from; a network output carries its provenance into the preview.
    @Published private(set) var pendingPasteSource: PasteSource = .clipboard
    /// Network suffixes by candidate id; changed only while every channel of the line is idle, like a capture.
    @Published private(set) var networkLines: [UUID: NetworkOutputLine] = [:]
    @Published private(set) var networkRefusals: [UUID: String] = [:]
    @Published private(set) var networkPhases: [UUID: NetworkTicketPhase] = [:]
    /// Lines whose ticket is being made: their capture and network toggles wait.
    @Published private(set) var networkPending: Set<UUID> = []
    /// Tickets the server refused another post for; flags the line and the preview of its output.
    private var refusedTickets: Set<UUID> = []
    /// Made with the paste, so the preview shows the exact prompt that "Enviar al modelo" sends.
    private var pendingPasteNonce: String?
    /// A paste turn waiting for the preview sheet to finish dismissing, so a consent sheet can present.
    private var queuedPasteTurn: (prompt: String, entry: TerminalEntry)?
    /// Lines whose helper failure was the app's own refusal before anything reached the Mac.
    private var helperRefusedLocally: Set<UUID> = []
    /// The keyboard activation in which the Option-as-Meta notice was accepted.
    @Published private(set) var optionNoticeActivation: Int?
    @Published private(set) var catalog = CatalogListing()
    @Published var selectedChoiceID: String? {
        didSet { testSession.switchModel(to: selectedChoiceID) }
    }
    @Published var isTestModeOn = false
    /// Questions left and the score for the selected model; in memory, started over on a model change.
    @Published private(set) var testSession = TestModeSession()

    private struct TestSettlement {
        let id: Int
        let grade: TestModeGrade
        let generation: Int?
    }

    private enum StopCause {
        case user
        case background
    }

    private struct PreviewKey: Hashable {
        let line: UUID
        /// The outgoing text, so a plan built for the unwrapped line is never reused for the wrapped one.
        let text: String
        let layout: HostKeyboardLayoutID
    }

    private struct OutgoingKey: Hashable {
        let line: UUID
        let capture: CaptureID?
        let ticket: UUID?
    }

    enum PasteSource {
        case clipboard
        case network(NetworkPaste, ticketID: UUID)
    }

    /// Not published: filled while rendering, and a plan depends only on the text and the layout.
    private var previewCache: [PreviewKey: Result<KeyboardTypingPlan, KeyboardTypingRefusal>] = [:]
    /// Not published: rows re-render on every streamed chunk, and a line's result depends only on its capture.
    private var outgoingCache: [OutgoingKey: Result<OutgoingLine, OutgoingLineRefusal>] = [:]
    private var work: Task<Void, Never>?
    private var activeEngine: (any ReplyEngine)?
    private var pendingStop: StopCause?
    private var replyCount = 0
    /// The Test Mode question of the running turn and the model it was sent to.
    private var activeTestQuestion: (id: Int, modelID: String)?
    private var splitter = ReasoningSplitter()
    private var reasoningID = UUID()
    /// A leading block can only start with the first chunk, so that is where the reasoning time starts.
    private var reasoningStart: ContinuousClock.Instant?
    private var reasoningEnd: ContinuousClock.Instant?
    /// Shared with the web server: one decode at a time on the loaded model.
    private let turnstile: GenerationTurnstile

    init(turnstile: GenerationTurnstile) {
        self.turnstile = turnstile
    }

    var selectedChoice: ModelChoice? {
        catalog.selectable.first { $0.id == selectedChoiceID }
    }

    // MARK: Models

    func refreshCatalog() {
        RemoteTargets.saveCloudPermission()
        catalog = LocalModelCatalog.listing()
        if selectedChoice == nil {
            selectedChoiceID = catalog.defaultSelectable.first?.id
        }
        LocalModelCatalog.checkAppleModelIfNeeded { [weak self] in self?.refreshCatalog() }
    }

    // MARK: Sending

    func send(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy, !isRunningCapabilityTests, selectedChoice != nil else { return }
        start(prompt: trimmed, userEntry: TerminalEntry(role: .user, text: trimmed))
    }

    /// Sends a Test Mode question exactly as a typed message; its chip goes away while the turn runs.
    func sendTestQuestion(_ id: Int) {
        guard !isBusy, !isRunningCapabilityTests, let choice = selectedChoice,
              let question = testSession.take(id) else { return }
        var entry = TerminalEntry(role: .user, text: question.prompt)
        entry.testQuestionID = question.id
        if !start(prompt: question.prompt, userEntry: entry) {
            // No turn will answer it: drop the captioned bubble so a resend does not show two.
            entries.removeAll { $0.id == entry.id }
            testSession.putBack(question.id, modelID: choice.id)
        }
    }

    func resetTestQuestions() {
        testSession.reset()
    }

    /// The owner's verdict over a graded reply; it changes the score only, never the grader.
    func applyTestOverride(_ action: TestModeOverrideAction, to entryID: UUID) {
        guard let entry = entries.first(where: { $0.id == entryID }), let id = entry.testQuestionID,
              let generation = entry.testGeneration else { return }
        testSession.apply(action, to: id, generation: generation, reply: entry.text)
    }

    static let testJudgeScope = "testMode"

    /// Questions graded incorrect or «Revisar tú» with no verdict and no second opinion yet. The key carries the
    /// generation, so a judgment that arrives after a reset is dropped.
    var testJudgeSubjects: [(key: String, subject: ClaudeJudgeSubject)] {
        let session = testSession
        return session.judgeableIDs.compactMap { id in
            guard session.secondOpinions[id] == nil, let question = TestModeQuestions.question(id: id),
                  let grade = session.results[id],
                  let subject = ClaudeJudgeSubject(question: question, grade: grade, answer: session.answers[id])
            else { return nil }
            return ("\(session.generation).\(id)", subject)
        }
    }

    /// Kept only while the question still holds the answer that was judged.
    func recordTestSecondOpinion(_ judgment: ClaudeJudgment, key: String, judgedAnswer: String) {
        let parts = key.split(separator: ".")
        guard parts.count == 2, let generation = Int(parts[0]), let id = Int(parts[1]),
              testSession.answers[id]?.answer == judgedAnswer else { return }
        testSession.recordSecondOpinion(judgment, for: id, generation: generation)
    }

    /// False when no turn started.
    @discardableResult
    private func start(prompt: String, userEntry: TerminalEntry) -> Bool {
        guard !isBusy, !isRunningCapabilityTests, let choice = selectedChoice else { return false }
        entries.append(userEntry)
        let engine: any ReplyEngine
        do {
            engine = try ReplyEngines.make(for: choice, turnstile: turnstile)
        } catch {
            appendNotice(Self.describe(error), isError: true)
            return false
        }
        activeTestQuestion = userEntry.testQuestionID.map { ($0, choice.id) }
        isBusy = true
        pendingStop = nil
        activeEngine = engine
        let turn = ReplyTurn(
            prompt: prompt, pastedOutputBytes: userEntry.pasteDetail?.byteCount,
            includesCapturedCommand: userEntry.pasteDetail?.includesCommand ?? false)
        work = Task {
            await self.run(turn, engine: engine)
            self.isBusy = false
            self.progress = ""
            self.streamingText = ""
            self.streamingReasoning = nil
            self.activeEngine = nil
            self.work = nil
            self.activeTestQuestion = nil
        }
        return true
    }

    /// False while a chat turn runs or another run holds the gate.
    func beginCapabilityRun() -> Bool {
        guard !isBusy, !isRunningCapabilityTests else { return false }
        isRunningCapabilityTests = true
        return true
    }

    func endCapabilityRun() {
        isRunningCapabilityTests = false
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

    private func run(_ turn: ReplyTurn, engine: any ReplyEngine) async {
        var failure: String?
        resetSplit()
        do {
            let stream = try await engine.reply(to: turn) { [weak self] message in self?.progress = message }
            progress = ""
            for try await chunk in stream {
                take(chunk)
            }
        } catch let interrupted as GenerationInterrupted {
            if !interrupted.partialText.isEmpty { replaceSplit(with: interrupted.partialText) }
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
        let endedInsideReasoning = splitter.isInsideReasoning
        _ = splitter.finish()
        publishSplit(at: .now)
        var reasoning = streamingReasoning
        let endedOnItsOwn = pendingStop == nil && failure == nil
        reasoning?.endedWithoutAnswer = splitter.isReasoningUnterminated && endedOnItsOwn
        reasoning?.wasInterrupted = endedInsideReasoning && !endedOnItsOwn
        reasoning?.wasCut = endedOnItsOwn && engine.lastReplyReasoningCut
        let testGrade = settleTestQuestion(
            answer: splitter.answer, reasoningUnfinished: splitter.isReasoningUnterminated, endedOnItsOwn: endedOnItsOwn)
        finishReply(splitter.answer, reasoning: reasoning, test: testGrade)
        if let note = engine.lastReplyLimit?.note { appendNotice(note, isError: false) }
        if endedOnItsOwn, let window = engine.lastReplyFilledWindow {
            appendNotice(ReplyBudget.windowFilledNote(window: window), isError: false)
        }
        if let pendingStop { appendNotice(Self.notice(for: pendingStop), isError: false) }
        if let failure { appendNotice(failure, isError: true) }
    }

    private func resetSplit() {
        splitter = ReasoningSplitter()
        reasoningID = UUID()
        reasoningStart = nil
        reasoningEnd = nil
        streamingText = ""
        streamingReasoning = nil
    }

    private func take(_ chunk: String) {
        let now = ContinuousClock.now
        if reasoningStart == nil { reasoningStart = now }
        _ = splitter.consume(chunk)
        publishSplit(at: now)
    }

    /// An interrupted engine reports everything it generated; split it again, keeping the clock.
    private func replaceSplit(with partialText: String) {
        splitter = ReasoningSplitter()
        _ = splitter.consume(partialText)
        publishSplit(at: .now)
    }

    private func publishSplit(at now: ContinuousClock.Instant) {
        if splitter.isInsideReasoning {
            reasoningEnd = nil
        } else if splitter.hasReasoning, reasoningEnd == nil {
            reasoningEnd = now
        }
        streamingText = splitter.answer
        // An empty block (a model told not to think) shows nothing once it closed.
        guard splitter.hasReasoning,
              splitter.isInsideReasoning || splitter.isReasoningUnterminated
                || !ReasoningText.shown(splitter.reasoning).isEmpty else {
            streamingReasoning = nil
            return
        }
        var duration: Duration?
        if let reasoningStart, let reasoningEnd { duration = reasoningEnd - reasoningStart }
        streamingReasoning = ReplyReasoning(id: reasoningID, text: splitter.reasoning, duration: duration)
    }

    /// Grades a Test Mode turn that ended on its own, on the answer the splitter left; a stopped or failed turn
    /// puts its question back instead.
    private func settleTestQuestion(
        answer: String,
        reasoningUnfinished: Bool,
        endedOnItsOwn: Bool
    ) -> TestSettlement? {
        guard let active = activeTestQuestion, let question = TestModeQuestions.question(id: active.id) else {
            return nil
        }
        guard endedOnItsOwn else {
            testSession.putBack(active.id, modelID: active.modelID)
            return nil
        }
        let grade = TestModeGrader.grade(
            question, answer: answer, reasoningUnfinished: reasoningUnfinished, unboxing: BoxedAnswer.plain)
        let recorded = testSession.record(grade, for: active.id, modelID: active.modelID, answer: answer)
        return TestSettlement(id: active.id, grade: grade, generation: recorded ? testSession.generation : nil)
    }

    private func finishReply(
        _ reply: String,
        reasoning: ReplyReasoning?,
        test: TestSettlement? = nil
    ) {
        let hasAnswer = !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // A graded turn always gets a bubble, so an empty answer still shows its grade.
        guard hasAnswer || reasoning != nil || test != nil else { return }
        var entry = TerminalEntry(role: .assistant, text: reply)
        entry.reasoning = reasoning
        entry.testQuestionID = test?.id
        entry.testGrade = test?.grade
        entry.testGeneration = test?.generation
        // Commands come from the answer only: a fence inside the reasoning must never become a sendable line.
        entry.segments = hasAnswer ? CodeBlockParser.parse(reply) : []
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
        AppleSessionErrorText.message(for: error)
            ?? (error as? LocalizedError)?.errorDescription ?? String(describing: error)
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

    /// Types the line's outgoing text on the Mac without Enter. Reuse `writeID` to retry: the helper answers
    /// `alreadyTyped` (the capture cannot change until every channel is idle again, so the text is the same).
    func write(_ candidate: CommandCandidate, writeID: UUID, acknowledged: [String], bridge: BridgeServer) {
        if case .sending = sendState(for: candidate) { return }
        let line: OutgoingLine
        switch outgoingLine(for: candidate) {
        case .success(let built):
            line = built
        case .failure(let refusal):
            commandStates[candidate.id] = .failed(writeID: writeID, reason: refusal.message, helperWarnings: [])
            helperRefusedLocally.insert(candidate.id)
            return
        }
        if let reason = CaptureToggle.channelRefusal(capture: line.capture, channelReachesOnlyMac: true) {
            commandStates[candidate.id] = .failed(writeID: writeID, reason: reason, helperWarnings: [])
            helperRefusedLocally.insert(candidate.id)
            return
        }
        helperRefusedLocally.remove(candidate.id)
        commandStates[candidate.id] = .sending(writeID: writeID)
        Task {
            do {
                let ack = try await bridge.write(text: line.text, id: writeID, acknowledgedWarnings: acknowledged)
                commandStates[candidate.id] = .sent(writeID: writeID, ack: ack, target: bridge.targetLabel ?? "la Mac")
                bridge.noteTyped(ack)
                recordSent(line.capture)
            } catch {
                commandStates[candidate.id] = .failed(
                    writeID: writeID,
                    reason: WriteFailureText.describe(error),
                    helperWarnings: WriteFailureText.helperWarnings(in: error)
                )
            }
        }
    }

    // MARK: Bluetooth keyboard

    func keyboardState(for candidate: CommandCandidate) -> KeyboardSendState {
        keyboardStates[candidate.id] ?? .idle
    }

    /// The Option-as-Meta notice is asked once per keyboard activation.
    func needsOptionNotice(usesOptionChords: Bool, keyboard: BluetoothKeyboard) -> Bool {
        usesOptionChords && optionNoticeActivation != keyboard.activationCount
    }

    /// The plan the line's outgoing text would get on `layout`, local warnings taken as acknowledged; built once
    /// per text and layout. Nil when the outgoing line itself is refused.
    func keyboardPreview(
        for candidate: CommandCandidate,
        layout: HostKeyboardLayout
    ) -> Result<KeyboardTypingPlan, KeyboardTypingRefusal>? {
        guard case .success(let line) = outgoingLine(for: candidate) else { return nil }
        let key = PreviewKey(line: candidate.id, text: line.text, layout: layout.id)
        if let cached = previewCache[key] { return cached }
        let built = KeyboardTypingPlan.make(text: line.text, layout: layout, acknowledged: line.localWarnings)
        previewCache[key] = built
        return built
    }

    /// A capture is built for one host's shell; typing it into another would not work.
    func keyboardChannelRefusal(for candidate: CommandCandidate, layout: HostKeyboardLayout) -> String? {
        if let network = networkLines[candidate.id], network.host != layout.host {
            return "El envío por red se preparó para \(network.host.title) y el teclado está configurado para "
                + "\(layout.host.title). Desactívalo y vuelve a activarlo."
        }
        guard let capture = captures[candidate.id], capture.host != layout.host else { return nil }
        return "La captura se preparó para \(capture.host.title) y el teclado está configurado para "
            + "\(layout.host.title). Desactívala y vuelve a activarla."
    }

    func acceptOptionNotice(keyboard: BluetoothKeyboard) {
        optionNoticeActivation = keyboard.activationCount
    }

    func beginKeyboardConfirmation(for candidate: CommandCandidate, jobID: UUID, layoutID: HostKeyboardLayoutID) {
        keyboardStates[candidate.id] = KeyboardWriteFlow.beginConfirmation(
            keyboardState(for: candidate), jobID: jobID, layoutID: layoutID
        )
    }

    func cancelKeyboardConfirmation(for candidate: CommandCandidate) {
        keyboardStates[candidate.id] = KeyboardWriteFlow.cancelConfirmation(keyboardState(for: candidate))
    }

    /// Types `candidate` over Bluetooth without Enter. `expectedLayout` is the layout the user confirmed; any
    /// refusal happens before the first report.
    func typeOverBluetooth(
        _ candidate: CommandCandidate,
        jobID: UUID,
        acknowledged: [String],
        expectedLayout: HostKeyboardLayoutID,
        layout: HostKeyboardLayout,
        keyboard: BluetoothKeyboard
    ) {
        if case .typing = keyboardState(for: candidate) { return }
        let lineID = candidate.id
        guard layout.id == expectedLayout else {
            keyboardStates[lineID] = .failed(jobID: jobID, reason: KeyboardTypingRefusal.layoutChanged.message, sentReports: 0)
            return
        }
        let line: OutgoingLine
        switch outgoingLine(for: candidate) {
        case .success(let built):
            line = built
        case .failure(let refusal):
            keyboardStates[lineID] = .failed(jobID: jobID, reason: refusal.message, sentReports: 0)
            return
        }
        if let reason = keyboardChannelRefusal(for: candidate, layout: layout) {
            keyboardStates[lineID] = .failed(jobID: jobID, reason: reason, sentReports: 0)
            return
        }
        let plan: KeyboardTypingPlan
        switch KeyboardTypingPlan.make(text: line.text, layout: layout, acknowledged: acknowledged) {
        case .success(let built):
            plan = built
        case .failure(let refusal):
            keyboardStates[lineID] = .failed(jobID: jobID, reason: refusal.message, sentReports: 0)
            return
        }
        keyboardStates[lineID] = .typing(jobID: jobID, sentReports: 0, totalReports: plan.reports.count)
        let start = keyboard.type(plan, jobID: jobID, progress: { [weak self] sent, total in
            self?.keyboardStates[lineID] = .typing(jobID: jobID, sentReports: sent, totalReports: total)
        }, completion: { [weak self] outcome in
            self?.keyboardStates[lineID] = Self.finalState(outcome, jobID: jobID, plan: plan)
            if outcome.end == .completed { self?.recordSent(line.capture) }
        })
        if case .refused(let reason) = start {
            keyboardStates[lineID] = .failed(jobID: jobID, reason: reason, sentReports: 0)
        }
    }

    private static func finalState(
        _ outcome: KeyboardJobOutcome,
        jobID: UUID,
        plan: KeyboardTypingPlan
    ) -> KeyboardSendState {
        guard outcome.end == .completed else {
            return .failed(
                jobID: jobID,
                reason: outcome.end.message(afterSending: outcome.sentReports),
                sentReports: outcome.sentReports
            )
        }
        return .typed(
            jobID: jobID,
            layoutID: plan.layoutID,
            keystrokes: plan.keystrokeCount,
            unverified: String(plan.unverifiedCharacters)
        )
    }

    // MARK: Outgoing line and capture

    func isPossiblyTruncated(_ candidate: CommandCandidate) -> Bool {
        entries.contains { $0.possiblyTruncated.contains(candidate.id) }
    }

    /// The only text a channel may send for `candidate`: the original or its capture wrapper, after the
    /// safeguards ran on both.
    func outgoingLine(for candidate: CommandCandidate) -> Result<OutgoingLine, OutgoingLineRefusal> {
        let capture = captures[candidate.id]
        let network = networkLines[candidate.id]
        let key = OutgoingKey(line: candidate.id, capture: capture?.id, ticket: network?.ticketID)
        if let cached = outgoingCache[key] { return cached }
        let built = OutgoingLine.make(
            candidate: candidate,
            isPossiblyTruncated: isPossiblyTruncated(candidate),
            capture: capture,
            network: network
        )
        outgoingCache[key] = built
        return built
    }

    /// RiskyRule ids every channel must get acknowledged for this line; the original's when the line is refused.
    func localWarnings(for candidate: CommandCandidate) -> [String] {
        guard case .success(let line) = outgoingLine(for: candidate) else { return candidate.warnings.map(\.id) }
        return line.localWarnings
    }

    func canChangeCapture(for candidate: CommandCandidate) -> Bool {
        guard !networkPending.contains(candidate.id) else { return false }
        return CaptureToggle.canChange(
            helper: sendState(for: candidate),
            helperRefusedLocally: helperRefusedLocally.contains(candidate.id),
            keyboard: keyboardState(for: candidate),
            clipboard: clipboardState(for: candidate)
        )
    }

    /// Turns the wrapper on (a new random file per turn-on) or off. A refused wrap leaves the line unwrapped and
    /// keeps the reason for the row.
    func toggleCapture(for candidate: CommandCandidate, host: HostOS) {
        guard canChangeCapture(for: candidate), networkLines[candidate.id] == nil else { return }
        let lineID = candidate.id
        // A local refusal never reached the Mac; clearing it makes the next tap take a fresh write ID.
        if helperRefusedLocally.remove(lineID) != nil { commandStates[lineID] = nil }
        if captures[lineID] != nil {
            captures[lineID] = nil
            captureRefusals[lineID] = nil
            return
        }
        if let reason = KeyboardWriteFlow.lineRefusal(candidate, isPossiblyTruncated: isPossiblyTruncated(candidate)) {
            captureRefusals[lineID] = reason
            return
        }
        switch CaptureWrapper.wrap(candidate.text, host: host, id: CaptureID.random()) {
        case .success(let lines):
            captures[lineID] = lines
            captureRefusals[lineID] = nil
        case .failure(let refusal):
            captureRefusals[lineID] = refusal.message
        }
    }

    func wasSent(_ capture: CaptureLines) -> Bool {
        capturedHistory.contains { $0.id == capture.id }
    }

    /// Called when a channel finished with a captured line; the newest is the paste's default command.
    private func recordSent(_ capture: CaptureLines?) {
        guard let capture else { return }
        capturedHistory.removeAll { $0.id == capture.id }
        capturedHistory.append(capture)
    }

    /// Hosts with captures this session plus `configured`, in a fixed order, for the cleanup lines. The history is
    /// in memory only, so the configured host covers files left by an earlier launch.
    func cleanupHosts(configured: HostOS) -> [HostOS] {
        HostOS.allCases.filter { host in host == configured || capturedHistory.contains { $0.host == host } }
    }

    func appendReadBack(for capture: CaptureLines) {
        let caption = capture.returnsToClipboard
            ? "Línea de la app: copia al portapapeles de la Mac los últimos \(CaptureWrapper.readBackBytes) bytes "
                + "guardados en \(capture.filePath). Después usa «Pegar salida»."
            : "Línea de la app: muestra en la pantalla del ordenador el final de \(capture.filePath). En "
                + "\(capture.host.title) no vuelve al iPhone."
        appendCaptureLines([capture.readBack], caption: caption)
    }

    func appendCleanupLines(configured: HostOS) {
        for host in cleanupHosts(configured: configured) {
            appendCaptureLines([CaptureWrapper.cleanupLine(host: host)], caption: Self.cleanupCaption(host))
        }
    }

    private static func cleanupCaption(_ host: HostOS) -> String {
        "Línea de la app para \(host.title): borra los archivos de captura de esta app. Envíala al final de la "
            + "sesión, solo a ese ordenador."
    }

    /// App-generated lines get ordinary rows: the same parser, numbering and safeguards as a reply's lines.
    private func appendCaptureLines(_ lines: [String], caption: String) {
        var entry = TerminalEntry(role: .capture, text: caption)
        entry.segments = CodeBlockParser.parse("```bash\n" + lines.joined(separator: "\n") + "\n```\n")
        entry.replyOrdinal = replyCount
        replyCount += 1
        let candidates = entry.segments.flatMap { Self.candidates(in: $0) }
        entry.candidateIndex = Dictionary(uniqueKeysWithValues: candidates.enumerated().map { ($1.id, $0) })
        entries.append(entry)
    }

    // MARK: Output over the network

    func canChangeNetwork(for candidate: CommandCandidate) -> Bool {
        canChangeCapture(for: candidate) && captures[candidate.id] == nil
    }

    /// Turns the network suffix on (a new one-time ticket) or off (the ticket is cancelled). The line is checked
    /// with the capture's rules before a ticket exists and with its full length after; a refusal keeps the line
    /// as it was and shows the reason.
    func toggleNetworkOutput(
        for candidate: CommandCandidate,
        position: String,
        host: HostOS,
        server: WebServerController
    ) {
        let lineID = candidate.id
        guard canChangeNetwork(for: candidate) else { return }
        if helperRefusedLocally.remove(lineID) != nil { commandStates[lineID] = nil }
        if let existing = networkLines[lineID] {
            networkLines[lineID] = nil
            networkPhases[lineID] = nil
            networkRefusals[lineID] = nil
            Task { await server.cancelTicket(existing.ticketID) }
            return
        }
        networkPhases[lineID] = nil
        if let reason = KeyboardWriteFlow.lineRefusal(candidate, isPossiblyTruncated: isPossiblyTruncated(candidate)) {
            networkRefusals[lineID] = reason
            return
        }
        if let refusal = NetworkOutputLine.refusal(for: candidate.text, host: host) {
            networkRefusals[lineID] = refusal.message
            return
        }
        networkPending.insert(lineID)
        let label = NetworkOutputLine.ticketLabel(position: position, original: candidate.text)
        Task {
            defer { networkPending.remove(lineID) }
            switch await server.makeLineTicket(label: label) {
            case .refused(let message):
                networkRefusals[lineID] = message
            case .made(let ticket, let suffix):
                let made = NetworkOutputLine.make(original: candidate.text, suffix: suffix, host: host,
                                                  ticketID: ticket.id)
                switch made {
                case .success(let line) where !channelsFree(lineID) || captures[lineID] != nil:
                    // A channel sent the original while the ticket was being made: the line must not change now.
                    await server.cancelTicket(line.ticketID)
                    networkRefusals[lineID] = "La orden se envió mientras se creaba el enlace; no se añadió nada."
                case .success(let line):
                    networkLines[lineID] = line
                    networkPhases[lineID] = .open(expiresAt: ticket.expiresAt)
                    networkRefusals[lineID] = nil
                case .failure(let refusal):
                    await server.cancelTicket(ticket.id)
                    networkRefusals[lineID] = refusal.message
                }
            }
        }
    }

    /// The server run that issued the tickets ended, and its tickets with it. Lines nothing has sent go back to
    /// the original; lines already sent keep their text so the row still shows what was typed.
    func ingestSessionEnded() {
        for lineID in networkLines.keys {
            networkPhases[lineID] = networkPhases[lineID]?.endedByServerStop() ?? .cancelledByServerStop
            if channelsFree(lineID) { networkLines[lineID] = nil }
        }
    }

    private func channelsFree(_ lineID: UUID) -> Bool {
        CaptureToggle.canChange(
            helper: commandStates[lineID] ?? .idle,
            helperRefusedLocally: helperRefusedLocally.contains(lineID),
            keyboard: keyboardStates[lineID] ?? .idle,
            clipboard: clipboardStates[lineID] ?? .idle
        )
    }

    /// Marks the tickets of these arrivals used.
    func noteArrivals(_ outputs: [ReceivedOutput]) {
        for output in outputs {
            guard let lineID = networkLines.first(where: { $0.value.ticketID == output.ticketID })?.key,
                  let phase = networkPhases[lineID] else { continue }
            networkPhases[lineID] = phase.arrived(at: output.receivedAt,
                                                  laterPostRefused: refusedTickets.contains(output.ticketID))
        }
    }

    /// The server refused another post for these tickets: flag their lines and the preview showing one's output.
    func noteRefusals(_ tickets: Set<UUID>) {
        let fresh = tickets.subtracting(refusedTickets)
        guard !fresh.isEmpty else { return }
        refusedTickets.formUnion(fresh)
        for (lineID, line) in networkLines where fresh.contains(line.ticketID) {
            networkPhases[lineID] = networkPhases[lineID]?.refusingLaterPost()
        }
        if case .network(let paste, let ticketID) = pendingPasteSource, fresh.contains(ticketID) {
            pendingPasteSource = .network(paste.markingLaterPostRefused(), ticketID: ticketID)
        }
    }

    /// Opens the paste preview with a received output: same sanitiser, cap and framing as a clipboard paste.
    func prepareNetworkPaste(_ output: ReceivedOutput) {
        guard pendingPaste == nil, queuedPasteTurn == nil else { return }
        let command = networkLines.values.first { $0.ticketID == output.ticketID }?.original
        let facts = output.facts(laterPostRefused: refusedTickets.contains(output.ticketID))
        guard let paste = NetworkPaste.make(text: output.text, facts: facts, command: command) else {
            appendNotice(NetworkPaste.emptyMessage, isError: false)
            return
        }
        setPendingPaste(paste.output, source: .network(paste, ticketID: output.ticketID))
    }

    /// A sheet or an alert of this screen is up, or the paste sheet is still closing: no other sheet opens now.
    var isPresentingPasteOrDialog: Bool {
        if pendingPaste != nil || queuedPasteTurn != nil { return true }
        let helper = commandStates.values.contains { if case .confirming = $0 { true } else { false } }
        let keys = keyboardStates.values.contains { if case .confirming = $0 { true } else { false } }
        let copies = clipboardStates.values.contains { if case .confirming = $0 { true } else { false } }
        return helper || keys || copies
    }

    // MARK: Clipboard

    func clipboardState(for candidate: CommandCandidate) -> ClipboardCopyState {
        clipboardStates[candidate.id] ?? .idle
    }

    func helperActivity(for candidate: CommandCandidate) -> LineChannelActivity {
        LineChannelActivity(helper: sendState(for: candidate))
    }

    func keyboardActivity(for candidate: CommandCandidate) -> LineChannelActivity {
        LineChannelActivity(keyboard: keyboardState(for: candidate))
    }

    /// "Copiar para pegar": copies at once or opens the line's clipboard dialog.
    func requestCopy(for candidate: CommandCandidate) {
        let step = ClipboardCopyFlow.step(
            for: clipboardState(for: candidate),
            helper: helperActivity(for: candidate),
            keyboard: keyboardActivity(for: candidate),
            localWarnings: localWarnings(for: candidate),
            newID: UUID.init
        )
        switch step {
        case .write(let copyID, let acknowledged):
            copy(candidate, copyID: copyID, acknowledged: acknowledged)
        case .confirm(let copyID):
            clipboardStates[candidate.id] = ClipboardCopyFlow.beginConfirmation(clipboardState(for: candidate), copyID: copyID)
        case .nothing:
            break
        }
    }

    func cancelCopyConfirmation(for candidate: CommandCandidate) {
        clipboardStates[candidate.id] = ClipboardCopyFlow.cancelConfirmation(clipboardState(for: candidate))
    }

    /// Puts the outgoing text on the general pasteboard after the same checks as the other channels.
    func copy(_ candidate: CommandCandidate, copyID: UUID, acknowledged: [String]) {
        let lineID = candidate.id
        let line: OutgoingLine
        switch outgoingLine(for: candidate) {
        case .success(let built):
            line = built
        case .failure(let refusal):
            clipboardStates[lineID] = .failed(copyID: copyID, reason: refusal.message)
            return
        }
        if let reason = CaptureToggle.channelRefusal(capture: line.capture, channelReachesOnlyMac: true) {
            clipboardStates[lineID] = .failed(copyID: copyID, reason: reason)
            return
        }
        let made = ClipboardCopyPlan.make(
            line: line,
            acknowledged: acknowledged,
            helper: helperActivity(for: candidate),
            keyboard: keyboardActivity(for: candidate),
            now: .now
        )
        switch made {
        case .success(let plan):
            ClipboardWriter.write(plan)
            clipboardStates[lineID] = .copied(copyID: copyID, text: plan.text, expiresAt: plan.expiresAt)
            recordSent(line.capture)
        case .failure(let refusal):
            clipboardStates[lineID] = .failed(copyID: copyID, reason: refusal.message)
        }
    }

    // MARK: Pasted output

    /// Sanitises what the system paste control returned; the preview shows exactly the result.
    func preparePaste(_ raw: String) {
        switch PastedOutput.sanitize(raw) {
        case .success(let output):
            setPendingPaste(output, source: .clipboard)
        case .failure(let refusal):
            appendNotice(refusal.message, isError: false)
        }
    }

    private func setPendingPaste(_ output: PastedOutput, source: PasteSource) {
        // One retry when the nonce happens to occur in the output; the preview then says it cannot be sent.
        let first = PastedOutputPrompt.makeNonce()
        pendingPasteNonce = output.text.contains(first) ? PastedOutputPrompt.makeNonce() : first
        pendingPasteSource = source
        pendingPaste = output
    }

    /// The command the preview offers as context: the line that carried the ticket, or the newest capture.
    var pasteCommand: String? {
        switch pendingPasteSource {
        case .clipboard: capturedHistory.last?.original
        case .network(let paste, _): paste.command
        }
    }

    func discardPaste() {
        pendingPaste = nil
        pendingPasteNonce = nil
        pendingPasteSource = .clipboard
    }

    /// The exact turn "Enviar al modelo" sends; nil when the nonce occurs in the output, question or command.
    func pastePrompt(question: String, command: String?) -> String? {
        guard let output = pendingPaste, let nonce = pendingPasteNonce else { return nil }
        return PastedOutputPrompt.make(output: output, question: question, command: command, nonce: nonce)
    }

    /// Sends the pending paste as one delimited turn. The reply is parsed like any other: any command it
    /// proposes still needs a tap on a channel.
    func sendPastedOutput(question: String, command: String?) {
        guard let output = pendingPaste, !isBusy, !isRunningCapabilityTests, selectedChoice != nil else { return }
        guard let prompt = pastePrompt(question: question, command: command) else {
            discardPaste()
            appendNotice("No se pudo delimitar la salida pegada; no se envió nada al modelo.", isError: true)
            return
        }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let keptCommand = command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        var entry = TerminalEntry(role: .user, text: trimmed.isEmpty ? PastedOutputPrompt.defaultQuestion : trimmed)
        entry.pasteDetail = TerminalEntry.PastedTurn(
            byteCount: output.byteCount, prompt: prompt, includesCommand: keptCommand)
        if case .network(let paste, _) = pendingPasteSource {
            entry.pasteDetail?.title = "Salida recibida por red de \(paste.facts.peer)"
        }
        queuedPasteTurn = (prompt, entry)
        discardPaste()
    }

    /// Runs the turn `sendPastedOutput` queued; called from the preview sheet's `onDismiss`.
    func startQueuedPasteTurn() {
        guard let queued = queuedPasteTurn else { return }
        queuedPasteTurn = nil
        start(prompt: queued.prompt, userEntry: queued.entry)
    }
}

/// The only place the app writes a command, or text that may hold commands, to the pasteboard.
enum ClipboardWriter {
    /// Not `.localOnly`: Universal Clipboard has to carry the line to the Mac. The pairing code in PairingView is
    /// local-only because it is a secret. A line with the network suffix carries a one-time ingest ticket; it goes
    /// the same way, since the Mac needs it and it dies on use, on stop and after 10 minutes. The expiry exists
    /// because pasting a command late is dangerous. The battery's export of hand-validated replies comes here too
    /// (`ValidatedRepliesExport.plan`): multi-line, it would run line by line if pasted into a terminal.
    static func write(_ plan: ClipboardCopyPlan) {
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: plan.text]],
            options: [.expirationDate: plan.expiresAt]
        )
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
