import Combine
import Foundation
import SwiftUI
import TerminalBridgeKit
import TonamoxAppleIntelligence
import TonamoxCore
import TonamoxServer

/// One probe on the page. A reply that did not pass goes into the saved report, capped; a passing one never does.
struct ProbeRow: Identifiable, Equatable {
    enum RowPhase: Equatable {
        case queued
        case generating
        case finished(ProbeRunState)
    }

    let probe: CapabilityProbe
    var phase: RowPhase = .queued
    var reply = ""
    /// Load or turnstile text while nothing has arrived yet.
    var progress = ""
    var reason = ""
    var notes: [String] = []
    var seconds: Double?
    /// Cut once when the row finishes: `result` runs on every streamed chunk of later probes.
    var savedReply: SavedProbeReply?
    /// When the owner marked this row as valid; a fresh run or a retry starts without it.
    var validatedOn: Date?
    /// Claude's word on `savedReply`; a new attempt drops it.
    var secondOpinion: ClaudeJudgment?
    /// New for every attempt, so a judgment or note of an earlier attempt never lands on this one, even with the
    /// same answer.
    var attemptID = UUID()
    /// Left out of every run; whatever the row held stays, out of the report, until it is included again.
    var isExcluded = false
    /// Failed before the model answered (prompt did not fit, the engine refused it): never a Seguridad failure.
    var blockedBeforeReply = false

    var id: String { probe.id }

    /// What «Evaluar con Claude» keys this attempt's request by.
    var judgeKey: String { attemptID.uuidString + "." + probe.id }

    var stateLabel: String {
        if isExcluded { return CapabilityText.excluded }
        return switch phase {
        case .queued: CapabilityText.queued
        case .generating: CapabilityText.generating
        case .finished: CapabilityText.label(result)
        }
    }

    var stateSymbol: String {
        if isExcluded { return CapabilityText.excludedSymbol }
        return switch phase {
        case .queued: CapabilityText.queuedSymbol
        case .generating: CapabilityText.generatingSymbol
        case .finished: CapabilityText.symbol(result)
        }
    }

    var result: ProbeResult {
        guard case .finished(let state) = phase else {
            return ProbeResult(probeID: probe.id, state: .notRun, reason: "", seconds: nil)
        }
        return ProbeResult(probeID: probe.id, state: state, reason: reason, seconds: seconds, notes: notes,
                           savedReply: savedReply, blockedBeforeReply: blockedBeforeReply).validated(on: validatedOn)
            .judged(secondOpinion)
    }

    /// Finished with an outcome, as opposed to cut off by a stop (`notRun`).
    var hasRun: Bool {
        if case .finished(let state) = phase { return state != .notRun }
        return false
    }

    mutating func finish(_ state: ProbeRunState) {
        phase = .finished(state)
        savedReply = state == .passed ? nil : SavedProbeReply(reply: reply)
        secondOpinion = nil
        blockedBeforeReply = false
    }
}

/// Runs the levels of the fixed battery against the chat's selected model, one probe at a time and one level after
/// another with the same engine. It holds only the engine
/// factory's inputs and the chat gate: replies never reach the bridge, the keyboard, the pasteboard, the web
/// server's clients or the chat transcript.
final class CapabilityRunner: ObservableObject {
    enum RunPhase: Equatable {
        case idle
        case running
        case finished
        case incomplete
        /// The engine failed before any probe finished.
        case loadFailed(String)
        /// The engine failed after at least one probe finished.
        case stopped(String)
    }

    enum StopCause {
        case user
        case background
    }

    /// No delta within this time of the request: covers the load and the turnstile queue.
    static let firstDeltaLimit: Duration = .seconds(300)
    static let busyRetries = 3

    @Published private(set) var rows: [ProbeRow] = []
    /// Exclusions and execution order, kept in this app's own `UserDefaults.standard`.
    @Published private(set) var runPlan = CapabilityRunPlan.decode(
        UserDefaults.standard.data(forKey: CapabilityRunPlan.defaultsKey))
    static let judgeScope = "capabilities.live"

    /// Not-passed rows with a kept answer and no second opinion yet: what «Evaluar con Claude» sends.
    var judgeSubjects: [(key: String, subject: ClaudeJudgeSubject)] {
        guard !isRunning else { return [] }
        return executionOrder(Array(rows.indices)).compactMap { index in
            let row = rows[index]
            guard row.secondOpinion == nil, let subject = ClaudeJudgeSubject(probe: row.probe, result: row.result)
            else { return nil }
            return (row.judgeKey, subject)
        }
    }

    /// Kept only while the row still holds the attempt and answer that were judged; while the run is the saved one,
    /// the saved copy follows, like a mark.
    func recordSecondOpinion(_ judgment: ClaudeJudgment, key: String, judgedAnswer: String) {
        guard let index = rows.firstIndex(where: { $0.judgeKey == key }),
              rows[index].savedReply?.answer == judgedAnswer, rows[index].result.canBeValidatedByHand
        else { return }
        let probeID = rows[index].id
        rows[index].secondOpinion = judgment
        guard let savedRun, archive.report(modelKey: savedRun.modelKey, level: savedRun.level)?.date == savedRun.date
        else { return }
        archive.setSecondOpinion(judgment, probeID: probeID, modelKey: savedRun.modelKey, level: savedRun.level,
                                 savedOn: savedRun.date)
    }

    /// The level the rows belong to.
    @Published private(set) var level = CapabilityLevel.terminal
    /// The levels of the run on screen, in order; more than one only for "Todos".
    @Published private(set) var runLevels: [CapabilityLevel] = []
    @Published private(set) var levelPosition = 0
    @Published private(set) var phase: RunPhase = .idle
    /// The model the current rows belong to.
    @Published private(set) var runTitle: String?
    @Published private(set) var minutesLeft: Int?
    let archive = CapabilityResultStore()
    /// The archive entry this level's report was saved as; while it stands, marks follow it both ways.
    private var savedRun: (modelKey: String, level: CapabilityLevel, date: Date)?
    private var marksFromArchive: AnyCancellable?

    private let turnstile: GenerationTurnstile
    private let chat: TerminalChatViewModel
    private var work: Task<Void, Never>?
    private var activeEngine: (any ReplyEngine)?
    private var runChoice: ModelChoice?
    /// Read from the model sheet when a run starts; retries and the saved report use the same one.
    private var runReasoning = ReasoningSetting.medium
    private var runLength = ReplyLength.short
    /// A reply still streaming this many seconds after its first delta is cut off; set with the run's budgets.
    private var replySeconds = ReplyLength.probeTimeLimit(answerTokens: ReplyLength.short.tokens,
                                                          reasoningTokens: ReasoningSetting.medium.budget)
    private var pendingStop: StopCause?
    private var attemptStart: ContinuousClock.Instant?
    private var firstDeltaAt: ContinuousClock.Instant?
    private var attemptTimedOut = false
    private var attemptSkipped = false
    @Published private var currentAttempt: Task<Void, Error>?
    /// A cut-off producer keeps the turnstile until its decode stops, so the next probe's wait is ours.
    private var previousAttemptCutOff = false
    /// Seconds used for the estimate: from the first delta for the run's first probe, which includes the load.
    private var lastEstimateSample: Double?

    init(turnstile: GenerationTurnstile, chat: TerminalChatViewModel) {
        self.turnstile = turnstile
        self.chat = chat
        rows = freshRows(for: level)
        // A mark made or undone on the saved page has to show on this run's rows and summary too.
        marksFromArchive = archive.$reports.sink { [weak self] reports in
            self?.adoptMarks(from: reports)
        }
    }

    var isRunning: Bool { phase == .running }

    /// The rows as a report; unfinished rows are `notRun`.
    var currentReport: CapabilityReport? {
        guard let runChoice, phase != .idle else { return nil }
        return makeReport(for: runChoice)
    }

    /// Why Empezar is disabled right now; nil when a run can start.
    var startBlocker: String? {
        guard let choice = chat.selectedChoice else { return CapabilityText.noModel }
        if case .remote = choice.kind { return CapabilityText.remoteExcluded }
        if chat.isBusy { return CapabilityText.chatBusy }
        return nil
    }

    /// ``startBlocker``, or the note that every probe of `levels` is excluded.
    func startBlocker(for levels: [CapabilityLevel]) -> String? {
        if let startBlocker { return startBlocker }
        return levels.allSatisfy(runPlan.excludesEverything(in:)) ? CapabilityText.everythingExcluded : nil
    }

    /// Only for a busy-server row of the run on screen, while the chat still has that model selected.
    func canRetry(_ row: ProbeRow) -> Bool {
        guard row.phase == .finished(.error), !row.isExcluded, !isRunning, startBlocker == nil else { return false }
        return runChoice?.id == chat.selectedChoiceID
    }

    /// Drops the rows of another model's run so the page never shows them under the selected model's title.
    func selectionChanged() {
        guard !isRunning, let runChoice, runChoice.id != chat.selectedChoiceID else { return }
        self.runChoice = nil
        runTitle = nil
        rows = freshRows(for: level)
        runLevels = []
        levelPosition = 0
        phase = .idle
        minutesLeft = nil
        savedRun = nil
        ClaudeJudgeService.shared.clearNotes(scope: Self.judgeScope)
    }

    /// Before any run, the rows show the first level the picker would run.
    func preview(_ levels: [CapabilityLevel]) {
        guard phase == .idle, let first = levels.first, first != level else { return }
        level = first
        rows = freshRows(for: first)
        ClaudeJudgeService.shared.clearNotes(scope: Self.judgeScope)
    }

    /// "Nivel 2 de 3" while "Todos" runs; nil for a single level.
    var levelProgress: String? {
        guard runLevels.count > 1 else { return nil }
        return CapabilityText.levelProgress(current: levelPosition + 1, total: runLevels.count)
    }

    /// Marks or unmarks a finished, not-passed row. While its report is the saved one, the saved copy follows.
    func setValidation(_ validated: Bool, probeID: String) {
        guard let index = rows.firstIndex(where: { $0.id == probeID }), rows[index].result.canBeValidatedByHand
        else { return }
        rows[index].validatedOn = validated ? .now : nil
        guard let savedRun, archive.report(modelKey: savedRun.modelKey, level: savedRun.level)?.date == savedRun.date
        else { return }
        archive.setValidation(validated, probeID: probeID, modelKey: savedRun.modelKey, level: savedRun.level)
    }

    private func adoptMarks(from reports: [String: CapabilityReportArchive.Levels]) {
        guard let savedRun,
              let marks = CapabilityReportArchive.marks(modelKey: savedRun.modelKey, level: savedRun.level,
                                                        savedOn: savedRun.date, in: reports),
              let opinions = CapabilityReportArchive.secondOpinions(
                modelKey: savedRun.modelKey, level: savedRun.level, savedOn: savedRun.date, in: reports)
        else { return }
        let updated = rows.map { row in
            // The saved copy leaves excluded rows out, so it cannot carry their marks: keep them for an include.
            guard !row.isExcluded else { return row }
            var copy = row
            copy.validatedOn = marks[row.id]
            copy.secondOpinion = opinions[row.id]
            return copy
        }
        if updated != rows { rows = updated }
    }

    // MARK: Running

    /// Runs `levels` in order. A level that ends savable is saved and the next one starts with fresh rows; busy-server
    /// rows, a stop or an error end the sequence on that level.
    func start(levels requested: [CapabilityLevel]) {
        // A level with every probe excluded has nothing to run or save; «Todos» goes on without it.
        let levels = requested.filter { !runPlan.excludesEverything(in: $0) }
        guard !isRunning, startBlocker == nil, let choice = chat.selectedChoice, let first = levels.first else {
            return
        }
        let engine: any ReplyEngine
        runReasoning = ReplyEngines.reasoningSetting
        runLength = ReplyEngines.replyLength
        replySeconds = ReplyLength.probeTimeLimit(answerTokens: runLength.tokens, reasoningTokens: runReasoning.budget)
        do {
            engine = try ReplyEngines.make(for: choice, turnstile: turnstile, reasoning: runReasoning,
                                           length: runLength)
        } catch {
            runChoice = choice
            runTitle = choice.title
            setLevels(levels, current: first)
            savedRun = nil
            phase = .loadFailed(TerminalChatViewModel.describe(error))
            return
        }
        guard chat.beginCapabilityRun() else { return }
        runChoice = choice
        runTitle = choice.title
        setLevels(levels, current: first)
        minutesLeft = nil
        launch(engine: engine, indices: executionOrder(Array(rows.indices)), continuesToNextLevel: true)
    }

    private func setLevels(_ levels: [CapabilityLevel], current: CapabilityLevel) {
        runLevels = levels
        levelPosition = 0
        level = current
        rows = freshRows(for: current)
    }

    func retry(_ probeID: String) {
        guard let index = rows.firstIndex(where: { $0.id == probeID }), canRetry(rows[index]),
              let choice = runChoice else { return }
        guard let engine = try? ReplyEngines.make(for: choice, turnstile: turnstile, reasoning: runReasoning,
                                                  length: runLength),
              chat.beginCapabilityRun() else { return }
        resetRow(at: index)
        // The owner starts the next level separately after the retries, so «Nivel 1 de 3» no longer applies.
        runLevels = [level]
        levelPosition = 0
        launch(engine: engine, indices: [index], continuesToNextLevel: false)
    }

    /// Graded rows that did not pass, plus timeouts, in execution order: what «Repetir fallidas» runs again.
    var failedIndices: [Int] {
        executionOrder(rows.indices.filter {
            [.finished(.failed), .finished(.unrecognised), .finished(.timedOut)].contains(rows[$0].phase)
        })
    }

    /// Off for Gemini: its SDK preset never sends a temperature (Google deprecated it), so the retry would change nothing.
    var canRetryFailed: Bool {
        !isRunning && startBlocker == nil && runChoice?.id == chat.selectedChoiceID && !failedIndices.isEmpty
            && runChoice?.kind != .remote(.preset(.gemini))
    }

    /// Temperature of the last «Repetir fallidas» run, shown on the page; the saved report keeps the run's own.
    @Published private(set) var retryTemperature: Float?

    /// Repeats the failed probes at `temperature`. Local models fix the temperature at load, so the loaded copy is
    /// evicted first and again afterwards, to never hold two copies of the weights.
    func retryFailed(temperature: Float) {
        guard canRetryFailed, let choice = runChoice else { return }
        ReplyEngines.temperatureOverride = temperature
        ModelManager.shared.evictAll()
        guard let engine = try? ReplyEngines.make(for: choice, turnstile: turnstile, reasoning: runReasoning,
                                                  length: runLength),
              chat.beginCapabilityRun() else {
            ReplyEngines.temperatureOverride = nil
            return
        }
        let indices = failedIndices
        for index in indices { resetRow(at: index) }
        retryTemperature = temperature
        runLevels = [level]
        levelPosition = 0
        launch(engine: engine, indices: indices, continuesToNextLevel: false)
    }

    /// Rows that never got an outcome (not run, error). Timed-out rows stay out: re-running the slow probe first
    /// would stall the rest again; «Repetir fallidas» covers them.
    var pendingIndices: [Int] {
        executionOrder(rows.indices.filter { [.finished(.notRun), .finished(.error)].contains(rows[$0].phase) })
    }

    var canSkipCurrentProbe: Bool { isRunning && currentAttempt != nil }

    /// Cuts the probe in progress the way the time limit does, and the run goes on with the next one.
    func skipCurrentProbe() {
        guard let currentAttempt else { return }
        attemptSkipped = true
        attemptTimedOut = true
        activeEngine?.cancelLoad()
        currentAttempt.cancel()
    }

    var canRunPending: Bool {
        !isRunning && startBlocker == nil && runChoice?.id == chat.selectedChoiceID && !pendingIndices.isEmpty
    }

    /// Runs only the ungraded probes of the current level, keeping the graded ones, so the level can still be saved.
    func runPending() {
        guard canRunPending, let choice = runChoice else { return }
        guard let engine = try? ReplyEngines.make(for: choice, turnstile: turnstile, reasoning: runReasoning,
                                                  length: runLength),
              chat.beginCapabilityRun() else { return }
        let indices = pendingIndices
        for index in indices { resetRow(at: index) }
        runLevels = [level]
        levelPosition = 0
        launch(engine: engine, indices: indices, continuesToNextLevel: false)
    }

    /// Unfinished probes become `notRun` and nothing is saved. Leaving the page does not call this.
    func cancel(_ cause: StopCause) {
        guard isRunning else { return }
        pendingStop = cause
        activeEngine?.cancelLoad()
        work?.cancel()
    }

    private func launch(engine: any ReplyEngine, indices: [Int], continuesToNextLevel: Bool) {
        phase = .running
        savedRun = nil
        ClaudeJudgeService.shared.clearNotes(scope: Self.judgeScope)
        pendingStop = nil
        previousAttemptCutOff = false
        activeEngine = engine
        work = Task {
            await self.run(indices, engine: engine, continuesToNextLevel: continuesToNextLevel)
        }
    }

    private func run(_ indices: [Int], engine: any ReplyEngine, continuesToNextLevel: Bool) async {
        defer {
            if ReplyEngines.temperatureOverride != nil {
                ReplyEngines.temperatureOverride = nil
                ModelManager.shared.evictAll()
            }
            chat.endCapabilityRun()
            activeEngine = nil
            work = nil
        }
        var pending = indices
        while true {
            let failure = await runRows(pending, engine: engine)
            finish(failure: failure)
            guard continuesToNextLevel, let next = nextLevel() else { return }
            pending = advance(to: next)
        }
    }

    /// The level after the current one, only when the current one ended savable and nobody stopped the run.
    private func nextLevel() -> CapabilityLevel? {
        guard phase == .finished, pendingStop == nil, !Task.isCancelled, levelPosition + 1 < runLevels.count,
              let runChoice, makeReport(for: runChoice).isSavable else { return nil }
        return runLevels[levelPosition + 1]
    }

    /// Fresh rows for `next`; returns their indices.
    private func advance(to next: CapabilityLevel) -> [Int] {
        levelPosition += 1
        level = next
        rows = freshRows(for: next)
        savedRun = nil
        minutesLeft = nil
        phase = .running
        return executionOrder(Array(rows.indices))
    }

    /// Nil when the rows ran or were stopped; the reason when the engine failed.
    private func runRows(_ indices: [Int], engine: any ReplyEngine) async -> String? {
        var failure: String?
        var elapsed: [Double] = []
        var repeated = RepeatedProbeErrors()
        for (position, index) in indices.enumerated() {
            if Task.isCancelled { break }
            let outcome = await runProbe(at: index, engine: engine)
            if case .stop(let reason) = outcome {
                failure = reason
                break
            }
            if case .cancelled = outcome { break }
            if repeated.record(outcome.unclassifiedDescription) {
                failure = outcome.unclassifiedDescription
                break
            }
            if let sample = lastEstimateSample { elapsed.append(sample) }
            updateEstimate(elapsed: elapsed, remaining: indices.count - position - 1)
            announce(index)
        }
        return failure
    }

    private func finish(failure: String?) {
        minutesLeft = nil
        for index in rows.indices where !Self.isFinished(rows[index]) {
            rows[index].phase = .finished(.notRun)
            rows[index].progress = ""
        }
        if let failure {
            let anyFinished = rows.contains(where: \.hasRun)
            phase = anyFinished ? .stopped(failure) : .loadFailed(failure)
            return
        }
        guard let runChoice, makeReport(for: runChoice).isComplete else {
            phase = .incomplete
            return
        }
        phase = .finished
        // Echo has no key: its runs are never saved. The archive also refuses runs with busy-server rows.
        if let key = CapabilityResultStore.modelKey(for: runChoice) {
            let report = makeReport(for: runChoice)
            archive.save(report)
            if archive.report(modelKey: key, level: level) == report { savedRun = (key, level, report.date) }
        }
    }

    private enum AttemptOutcome {
        case done
        /// Nil for the shared turnstile's busy server; else the engine's words.
        case serverBusy(String?)
        case cancelled
        case stop(String)
        /// The row finished as `error` with an error no rule classifies; ``runRows`` watches for it repeating.
        case unclassifiedError(String)

        var unclassifiedDescription: String? {
            if case .unclassifiedError(let description) = self { return description }
            return nil
        }
    }

    private func runProbe(at index: Int, engine: any ReplyEngine) async -> AttemptOutcome {
        var busyReason: String?
        for attempt in 0...Self.busyRetries {
            let outcome = await attemptProbe(at: index, engine: engine)
            guard case .serverBusy(let reason) = outcome else { return outcome }
            busyReason = reason
            if attempt < Self.busyRetries {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return .cancelled }
            }
        }
        rows[index].phase = .finished(.error)
        rows[index].reason = busyReason ?? CapabilityText.serverBusyReason
        rows[index].progress = ""
        lastEstimateSample = nil
        return .done
    }

    private func attemptProbe(at index: Int, engine: any ReplyEngine) async -> AttemptOutcome {
        let probe = rows[index].probe
        rows[index].phase = .generating
        rows[index].reply = ""
        rows[index].savedReply = nil
        rows[index].secondOpinion = nil
        rows[index].attemptID = UUID()
        rows[index].progress = ""
        await debugPacing()
        let clock = ContinuousClock()
        let started = clock.now
        attemptStart = started
        firstDeltaAt = nil
        attemptTimedOut = false
        attemptSkipped = false
        let turn = ReplyTurn(prompt: probe.turnPrompt, pastedOutputBytes: probe.pastedOutputBytes)
        let consumer = makeConsumer(index: index, turn: turn, engine: engine)
        currentAttempt = consumer
        let watchdog = makeWatchdog(consumer: consumer, engine: engine)
        let result = await withTaskCancellationHandler {
            await consumer.result
        } onCancel: {
            consumer.cancel()
        }
        watchdog.cancel()
        currentAttempt = nil
        let ended = clock.now
        let seconds = Self.seconds(ended - started)
        let isFirstOfRun = !rows.contains { $0.id != probe.id && $0.hasRun }
        lastEstimateSample = isFirstOfRun ? firstDeltaAt.map { Self.seconds(ended - $0) } : seconds
        rows[index].progress = ""
        if attemptTimedOut {
            previousAttemptCutOff = true
            rows[index].finish(.timedOut)
            if attemptSkipped {
                rows[index].reason = "Saltada a mano a los \(Int(seconds)) s."
            } else {
                rows[index].reason = firstDeltaAt == nil ? "" : ReplyLength.timeoutReason(
                    seconds: replySeconds, tokens: runLength.tokens + (runReasoning.budget ?? 0))
            }
            rows[index].seconds = seconds
            return .done
        }
        if Task.isCancelled || pendingStop != nil { return .cancelled }
        switch result {
        case .success:
            let verdict = CapabilityGrader.grade(probe.id, reply: rows[index].reply)
            rows[index].finish(ProbeRunState(verdict.outcome))
            rows[index].reason = Self.reason(verdict.reason, engine: engine)
            rows[index].notes = verdict.notes
            rows[index].seconds = seconds
            return .done
        case .failure(LocalTurnError.serverBusy):
            return .serverBusy(nil)
        case .failure(is CancellationError), .failure(is GenerationInterrupted):
            return .cancelled
        case .failure(let error):
            return finishFailed(at: index, error: error, engine: engine, seconds: seconds)
        }
    }

    private func finishFailed(at index: Int, error: any Error, engine: any ReplyEngine, seconds: Double)
        -> AttemptOutcome {
        let description = TerminalChatViewModel.describe(error)
        let errorClass = ProbeErrorClass(Self.errorKind(error), partialReply: rows[index].reply)
        guard let finished = errorClass.finishedRow(probeID: rows[index].probe.id, reply: rows[index].reply,
                                                    errorReason: Self.probeFailureReason(error, engine: engine)) else {
            return errorClass == .busy ? .serverBusy(description) : .stop(description)
        }
        rows[index].finish(finished.state)
        rows[index].blockedBeforeReply = finished.blockedBeforeReply
        rows[index].reason = finished.reason
        rows[index].notes = finished.notes
        rows[index].seconds = seconds
        return errorClass == .unclassified ? .unclassifiedError(description) : .done
    }

    private static func errorKind(_ error: any Error) -> ProbeErrorKind {
        switch error {
        case is ReplyBudgetRefusal:
            return .prompt
        case let remote as RemoteReplyError:
            return remoteKind(remote)
        case is ModelLoadFailure, is CatalogError, is ModelConfigurationError:
            return .stopsRun
        case TonamoxError.modelNotLoaded, TonamoxError.modelTooLarge:
            return .stopsRun
        default:
            guard #available(iOS 27, *), let session = error as? AISessionError else { return .other }
            return sessionKind(session)
        }
    }

    /// Every case named, so a new case has to be classified here.
    private static func remoteKind(_ error: RemoteReplyError) -> ProbeErrorKind {
        switch error {
        case .refused, .declined, .missingKey, .modelNotChosen, .serverNotConfigured:
            return .stopsRun
        case .busy:
            return .busy
        case .serverStatus(let status):
            return ProbeErrorKind(serverStatus: status)
        case .inconsistentStream:
            return .other
        }
    }

    @available(iOS 27, macOS 27, visionOS 27, *)
    private static func sessionKind(_ error: AISessionError) -> ProbeErrorKind {
        switch error {
        case .modelUnavailable, .assetsUnavailable:
            return .stopsRun
        case .rateLimited, .timeout, .concurrentRequest:
            return .busy
        case .guardrailViolation, .refusal, .contextWindowExceeded, .unsupportedLanguage:
            return .prompt
        case .generationFailed:
            return .other
        }
    }

    private static func probeFailureReason(_ error: any Error, engine: any ReplyEngine) -> String {
        if error is ReplyBudgetRefusal, case .noRoom(let window)? = engine.lastReplyLimit {
            return CapabilityText.noRoomReason(window: window)
        }
        return CapabilityText.probeErrorReason(TerminalChatViewModel.describe(error))
    }

    private func makeConsumer(index: Int, turn: ReplyTurn, engine: any ReplyEngine) -> Task<Void, Error> {
        Task {
            let stream = try await engine.reply(to: turn) { message in
                let ownWait = self.previousAttemptCutOff && message == TonamoxReplyEngine.waitingText
                self.rows[index].progress = ownWait ? CapabilityText.waitingForPrevious : message
            }
            for try await chunk in stream {
                if firstDeltaAt == nil {
                    firstDeltaAt = ContinuousClock.now
                    previousAttemptCutOff = false
                }
                rows[index].progress = ""
                rows[index].reply += chunk
            }
            try Task.checkCancellation()
        }
    }

    /// Checks both time limits once a second and cuts the attempt off when one is exceeded.
    private func makeWatchdog(consumer: Task<Void, Error>, engine: any ReplyEngine) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if self.isPastLimit(now: .now) {
                    self.attemptTimedOut = true
                    engine.cancelLoad()
                    consumer.cancel()
                    return
                }
            }
        }
    }

    private func isPastLimit(now: ContinuousClock.Instant) -> Bool {
        if let firstDeltaAt { return now - firstDeltaAt > .seconds(replySeconds) }
        guard let attemptStart else { return false }
        return now - attemptStart > Self.firstDeltaLimit
    }

    /// The grade's reason plus what the context window did to the reply, so the saved report keeps it.
    private static func reason(_ graded: String, engine: any ReplyEngine) -> String {
        let window = engine.lastReplyFilledWindow.map(ReplyBudget.windowFilledNote)
        return ([graded, engine.lastReplyLimit?.note, window].compactMap { $0 }.filter { !$0.isEmpty })
            .joined(separator: " ")
    }

    /// Echo answers at once; the pause keeps Cancelar reachable for the simulator check.
    private func debugPacing() async {
        #if DEBUG
        if case .echo = runChoice?.kind { try? await Task.sleep(for: .milliseconds(600)) }
        #endif
    }

    // MARK: Report

    private func makeReport(for choice: ModelChoice, date: Date = .now) -> CapabilityReport {
        // Only GGUF backends apply the setting; MLX ignores it.
        let reasoning: String? = if case .onDisk(let weights) = choice.kind, weights.format == .gguf {
            runReasoning.reportLabel
        } else {
            nil
        }
        return CapabilityReport(
            modelKey: CapabilityResultStore.modelKey(for: choice) ?? choice.id,
            modelTitle: choice.title,
            level: level,
            temperature: (Double(ReplyEngines.defaultTemperature) * 100).rounded() / 100,
            reasoning: reasoning,
            answerLength: runLength.tokens,
            date: date,
            results: rows.filter { !$0.isExcluded }.map(\.result),
            excludedProbeIDs: rows.filter(\.isExcluded).map(\.id),
            safetyFiltersRemoved: choice.safetyFiltersRemoved
        )
    }

    private func updateEstimate(elapsed: [Double], remaining: Int) {
        guard !elapsed.isEmpty, remaining > 0 else {
            minutesLeft = nil
            return
        }
        let average = elapsed.reduce(0, +) / Double(elapsed.count)
        minutesLeft = CapabilityBattery.estimatedMinutesLeft(
            averageSecondsPerProbe: average, remainingProbes: remaining)
    }

    private func announce(_ index: Int) {
        let row = rows[index]
        let text = CapabilityText.rowAccessibility(
            number: index + 1, title: row.probe.title, state: row.stateLabel, reason: row.reason)
        AccessibilityNotification.Announcement(text).post()
    }

    private static func isFinished(_ row: ProbeRow) -> Bool {
        if case .finished = row.phase { return true }
        return false
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private func freshRows(for level: CapabilityLevel) -> [ProbeRow] {
        level.probes.map { probe in
            var row = ProbeRow(probe: probe)
            row.isExcluded = runPlan.isExcluded(probe.id)
            return row
        }
    }

    /// An emptied row for a new attempt; only rows that are not excluded are run again.
    private func resetRow(at index: Int) {
        rows[index] = ProbeRow(probe: rows[index].probe)
    }

    /// `indices` in the level's execution order, excluded rows removed.
    private func executionOrder(_ indices: [Int]) -> [Int] {
        let byID = Dictionary(indices.map { (rows[$0].id, $0) }) { first, _ in first }
        return runPlan.executionOrder(of: indices.map { rows[$0].id }, in: level).compactMap { byID[$0] }
    }

    // MARK: Exclusions and order

    var canEditRunPlan: Bool { !isRunning }

    func setExcluded(_ excluded: Bool, probeID: String) {
        guard canEditRunPlan else { return }
        var plan = runPlan
        plan.setExcluded(excluded, probeID: probeID)
        store(plan)
        // The order sheet lists other levels too; their toggles leave the run on screen alone.
        guard rows.contains(where: { $0.id == probeID }) else { return }
        for index in rows.indices { rows[index].isExcluded = plan.isExcluded(rows[index].id) }
        exclusionsChanged()
    }

    func moveProbes(in level: CapabilityLevel, fromOffsets source: IndexSet, toOffset destination: Int) {
        guard canEditRunPlan else { return }
        var plan = runPlan
        plan.move(level, fromOffsets: source, toOffset: destination)
        store(plan)
    }

    func resetOrder(of level: CapabilityLevel) {
        guard canEditRunPlan else { return }
        var plan = runPlan
        plan.resetOrder(level)
        store(plan)
    }

    private func store(_ plan: CapabilityRunPlan) {
        guard plan != runPlan else { return }
        runPlan = plan
        UserDefaults.standard.set(plan.encoded(), forKey: CapabilityRunPlan.defaultsKey)
    }

    /// A stopped or incomplete run whose remaining probes were all excluded is now complete: finish it, which saves
    /// it. A finished run is saved again only over its own archive entry, with its own date; one that lost
    /// completeness is incomplete. With every probe excluded there is nothing to report, so nothing changes.
    private func exclusionsChanged() {
        guard !isRunning, let runChoice, runChoice.id == chat.selectedChoiceID,
              !runPlan.excludesEverything(in: level) else { return }
        let isComplete = makeReport(for: runChoice).isComplete
        switch phase {
        case .finished where !isComplete:
            phase = .incomplete
            savedRun = nil
        case .finished:
            resaveFinishedRun(runChoice)
        case .incomplete, .stopped:
            if isComplete { finish(failure: nil) }
        case .idle, .running, .loadFailed:
            break
        }
    }

    /// Nothing when the owner cleared the archive or another run replaced the entry since.
    private func resaveFinishedRun(_ choice: ModelChoice) {
        guard let savedRun,
              archive.report(modelKey: savedRun.modelKey, level: savedRun.level)?.date == savedRun.date else { return }
        let report = makeReport(for: choice, date: savedRun.date)
        archive.save(report)
        if archive.report(modelKey: savedRun.modelKey, level: level) != report { self.savedRun = nil }
    }
}
