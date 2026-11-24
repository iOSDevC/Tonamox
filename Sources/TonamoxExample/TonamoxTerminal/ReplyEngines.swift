import Foundation
import TerminalBridgeKit
import TonamoxAppleIntelligence
import TonamoxCore
import TonamoxServer
#if canImport(FoundationModels)
import FoundationModels
#endif

/// One turn as an engine receives it.
struct ReplyTurn {
    /// The exact text sent to the model; for a "Pegar salida" turn, the delimited prompt.
    let prompt: String
    /// Size of the pasted terminal output inside `prompt`, nil when the turn has none.
    let pastedOutputBytes: Int?
    /// The paste turn names the last captured command.
    var includesCapturedCommand = false
}

/// The last measured decode speed per model choice, for the cost line in the model sheet. Kept in UserDefaults.
@MainActor
enum MeasuredDecodeStore {
    /// Shorter replies time mostly the first tokens and the forced close, not the steady decode speed.
    static let minimumTokens = 16

    static func record(_ stats: GenerationStats?, for choiceID: String, reasoningCounts: Bool) {
        guard let stats, stats.generatedTokens >= minimumTokens, let speed = stats.decodeTokensPerSecond else { return }
        let defaults = UserDefaults.standard
        var entries = MeasuredDecodeArchive.decode(defaults.data(forKey: MeasuredDecodeArchive.defaultsKey))
        entries[choiceID] = MeasuredDecode(tokensPerSecond: speed, reasoningCounts: reasoningCounts)
        defaults.set(MeasuredDecodeArchive.encode(entries), forKey: MeasuredDecodeArchive.defaultsKey)
    }
}

/// Produces one reply for one prompt. v1 is single-turn: no engine receives history.
protocol ReplyEngine: AnyObject {
    /// Loads whatever the engine needs, then returns the reply stream of deltas. Cancel the consuming task to
    /// stop it.
    func reply(to turn: ReplyTurn, progress: @escaping @MainActor (String) -> Void) async throws
        -> AsyncThrowingStream<String, Error>
    /// Cancels a load still in progress.
    func cancelLoad()
    /// The last reply's reasoning was closed by the reasoning budget; read once its stream ended.
    var lastReplyReasoningCut: Bool { get }
    /// What the context window took off the last reply's budgets; read once its stream ended.
    var lastReplyLimit: ReplyBudget.Clamp? { get }
    /// The window the last reply may have filled before it ended (``ReplyBudget/mayHaveFilledWindow``); read once its
    /// stream ended.
    var lastReplyFilledWindow: Int? { get }
}

extension ReplyEngine {
    var lastReplyReasoningCut: Bool { false }
    var lastReplyLimit: ReplyBudget.Clamp? { nil }
    var lastReplyFilledWindow: Int? { nil }
}

enum ReplyEngines {
    static let defaultTemperature: Float = 0.2
    /// Set only while the battery repeats failed probes at another temperature.
    static var temperatureOverride: Float?
    static var temperature: Float { temperatureOverride ?? defaultTemperature }

    /// The model sheet's choices, read when an engine is made, so a capability run keeps one setting throughout.
    static var reasoningSetting: ReasoningSetting {
        ReasoningSetting.stored(UserDefaults.standard.string(forKey: ReasoningSetting.defaultsKey))
    }

    static var replyLength: ReplyLength {
        ReplyLength.stored(UserDefaults.standard.string(forKey: ReplyLength.defaultsKey))
    }

    /// `turnstile` is the one the web server shares, so the chat and a served request never decode at once.
    /// `reasoning` applies to on-disk models only; `length` to every engine.
    static func make(for choice: ModelChoice, turnstile: GenerationTurnstile,
                     reasoning: ReasoningSetting = reasoningSetting,
                     length: ReplyLength = replyLength) throws -> any ReplyEngine {
        switch choice.kind {
        case .onDisk:
            return TonamoxReplyEngine(choiceID: choice.id, turnstile: turnstile, reasoning: reasoning,
                                      answerTokens: length.tokens)
        case .appleIntelligence:
            guard #available(iOS 27, *) else { throw CatalogError.appleNeedsNewerSystem }
            return AppleReplyEngine(turnstile: turnstile, answerTokens: length.tokens)
        case .remote(let kind):
            return RemoteReplyEngine(kind: kind, answerTokens: length.tokens)
        #if DEBUG
        case .echo:
            return EchoReplyEngine()
        #endif
        }
    }
}

/// A model from disk through ModelManager. GGUF is a `.localFile` model: a missing file fails, never downloads.
/// The instance is ModelManager's cached one, which the web server serves too; every turn waits in the shared
/// turnstile.
final class TonamoxReplyEngine: ReplyEngine {
    private let choiceID: String
    private let turnstile: GenerationTurnstile
    private let reasoning: ReasoningSetting
    private let answerTokens: Int
    private var loading: Model?
    private(set) var lastReplyReasoningCut = false
    private(set) var lastReplyLimit: ReplyBudget.Clamp?
    private(set) var lastReplyFilledWindow: Int?

    init(choiceID: String, turnstile: GenerationTurnstile, reasoning: ReasoningSetting, answerTokens: Int) {
        self.choiceID = choiceID
        self.turnstile = turnstile
        self.reasoning = reasoning
        self.answerTokens = answerTokens
    }

    /// The setting's budgets, bounded by the loaded model's window (``ReplyBudget/planned``).
    static func budget(for llm: Tonamox, prompt: String, reasoning: ReasoningSetting,
                       answerTokens: Int) -> (budget: ReplyBudget, options: ReasoningOptions) {
        let plan = ReplyBudget.planned(
            answer: answerTokens, reasoning: reasoning, enforcesBudget: llm.reasoningSupport.enforcesBudget,
            window: llm.contextWindow,
            promptTokens: ReplyBudget.estimatedPromptTokens(systemPrompt: TerminalSystemPrompt.text, prompt: prompt))
        return (plan.budget, plan.reasoningRequest.map(ReasoningOptions.budgeted) ?? .disabled)
    }

    /// The window a finished reply may have filled. Only llama.cpp's measured stream counts one piece per token and
    /// stops at a full window; MLX's rotating cache drops old context instead.
    static func filledWindow(of llm: Tonamox, prompt: String, answerLimit: Int) -> Int? {
        guard let window = llm.contextWindow, let stats = llm.lastGenerationStats, stats.source == .measured else {
            return nil
        }
        let maximum = ReplyBudget.maximumPromptTokens(systemPrompt: TerminalSystemPrompt.text, prompt: prompt)
        let answered = llm.lastReasoningTurn?.answerTokens ?? stats.generatedTokens
        let filled = ReplyBudget.mayHaveFilledWindow(window: window, maximumPromptTokens: maximum,
                                                     decoded: stats.generatedTokens, answered: answered,
                                                     answerLimit: answerLimit)
        return filled ? window : nil
    }

    static let waitingText = "Esperando: el servidor web está usando el modelo…"

    func reply(to turn: ReplyTurn, progress: @escaping @MainActor (String) -> Void) async throws
        -> AsyncThrowingStream<String, Error> {
        let weights = try LocalModelCatalog.readyModel(for: choiceID)
        let turnstile = self.turnstile
        let prompt = turn.prompt
        let reasoning = self.reasoning
        let answerTokens = self.answerTokens
        let choiceID = self.choiceID
        lastReplyReasoningCut = false
        lastReplyLimit = nil
        lastReplyFilledWindow = nil
        return AsyncThrowingStream { continuation in
            let producer = Task { @MainActor [weak self] in
                do {
                    if turnstile.isBusy { progress(Self.waitingText) }
                    // The load waits in the turnstile too: loading while the server decodes on the previous model
                    // would hold both copies of the weights. `generate` returns only after the decode stopped, so a
                    // stopped turn frees the turnstile only when the context is free.
                    try await turnstile.run {
                        self?.loading = weights
                        defer { self?.loading = nil }
                        let llm: Tonamox
                        do {
                            llm = try await ModelManager.shared.load(
                                weights,
                                temperature: ReplyEngines.temperature,
                                onProgress: progress
                            )
                        } catch let error where ModelLoadFailure.wraps(error) {
                            throw ModelLoadFailure(message: TerminalChatViewModel.describe(error))
                        }
                        // A cancelled load can still return an instance; don't generate with it.
                        try Task.checkCancellation()
                        let (budget, options) = Self.budget(for: llm, prompt: prompt, reasoning: reasoning,
                                                            answerTokens: answerTokens)
                        self?.lastReplyLimit = budget.limit
                        if let refusal = budget.limit?.refusal { throw ReplyBudgetRefusal(message: refusal) }
                        // The template opened the block in the prompt: without the tag, reasoning cut off by the
                        // token limit would read as the answer and its fences as commands.
                        let opened = llm.promptOpenedReasoningTag(for: options) ?? ""
                        if !opened.isEmpty { continuation.yield(opened) }
                        do {
                            try await llm.generate(prompt, systemPrompt: TerminalSystemPrompt.text,
                                                   maxTokens: budget.answerTokens,
                                                   reasoning: options) { continuation.yield($0) }
                            self?.lastReplyReasoningCut = llm.lastReasoningTurn?.wasCut ?? false
                            self?.lastReplyFilledWindow = Self.filledWindow(of: llm, prompt: prompt,
                                                                            answerLimit: budget.answerTokens)
                            MeasuredDecodeStore.record(llm.lastGenerationStats, for: choiceID,
                                                       reasoningCounts: llm.reasoningSupport.enforcesBudget)
                        } catch let stop as GenerationInterrupted where !opened.isEmpty {
                            throw GenerationInterrupted(reason: stop.reason, partialText: opened + stop.partialText)
                        }
                    }
                    continuation.finish()
                } catch ServedModelError.busy {
                    continuation.finish(throwing: LocalTurnError.serverBusy)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    func cancelLoad() {
        guard let loading else { return }
        ModelManager.shared.cancelLoad(loading)
    }
}

/// The model could not be loaded, so every later turn would fail the same way: the battery stops on it, unlike on
/// an error of one turn. Its text is the load error's.
struct ModelLoadFailure: LocalizedError {
    let message: String

    var errorDescription: String? { message }

    /// Cancellation, a background stop and a busy server keep their own handling.
    static func wraps(_ error: any Error) -> Bool {
        !(error is CancellationError || error is GenerationInterrupted || error is ServedModelError)
    }
}

/// The prompt leaves no room for an answer in the model's window; nothing was decoded.
struct ReplyBudgetRefusal: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

enum LocalTurnError: LocalizedError {
    case serverBusy

    var errorDescription: String? {
        switch self {
        case .serverBusy:
            "El servidor web está usando el modelo y tiene peticiones en cola. Espera un momento y vuelve a enviar."
        }
    }
}

/// Waits in the shared turnstile like the on-disk engine, since the web server can serve Apple Intelligence too.
@available(iOS 27, *)
final class AppleReplyEngine: ReplyEngine {
    private let turnstile: GenerationTurnstile
    private let answerTokens: Int

    init(turnstile: GenerationTurnstile, answerTokens: Int) {
        self.turnstile = turnstile
        self.answerTokens = answerTokens
    }

    func reply(to turn: ReplyTurn, progress: @escaping @MainActor (String) -> Void) async throws
        -> AsyncThrowingStream<String, Error> {
        let session = try AISession(instructions: TerminalSystemPrompt.text)
        let prompt = turn.prompt
        // `streamDeltas` returns only once the model stopped, so a stopped turn frees the turnstile after its decode.
        #if canImport(FoundationModels)
        let options = GenerationOptions(
            temperature: Double(ReplyEngines.temperature),
            maximumResponseTokens: answerTokens
        )
        let generate: (@Sendable (String) -> Void) async throws -> Void = {
            try await session.streamDeltas(prompt, options: options, onDelta: $0)
        }
        #else
        let generate: (@Sendable (String) -> Void) async throws -> Void = {
            try await session.streamDeltas(prompt, onDelta: $0)
        }
        #endif
        let turnstile = self.turnstile
        return AsyncThrowingStream { continuation in
            let producer = Task { @MainActor in
                do {
                    if turnstile.isBusy { progress(TonamoxReplyEngine.waitingText) }
                    try await turnstile.run {
                        try await generate { _ = continuation.yield($0) }
                    }
                    continuation.finish()
                } catch ServedModelError.busy {
                    continuation.finish(throwing: LocalTurnError.serverBusy)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    func cancelLoad() {}
}

/// A remote model the user picked. Every turn goes through `RemoteEscalation` with `.always`: policy and cost cap
/// first, then the Spanish consent sheet with the exact payload. The answer only proposes commands, like any other.
final class RemoteReplyEngine: ReplyEngine {
    private let kind: RemoteEngineKind
    /// Also the output the consent sheet shows and the cost cap projects.
    private let answerTokens: Int

    init(kind: RemoteEngineKind, answerTokens: Int) {
        self.kind = kind
        self.answerTokens = answerTokens
    }

    func reply(to turn: ReplyTurn, progress: @escaping @MainActor (String) -> Void) async throws
        -> AsyncThrowingStream<String, Error> {
        let target = try RemoteTargets.target(for: kind)
        progress("Esperando tu confirmación…")
        let authorized: RemoteEscalation.Authorized
        do {
            authorized = try await RemoteEscalation.authorize(
                target: target,
                systemPrompt: TerminalSystemPrompt.text,
                question: turn.prompt,
                maxTokens: answerTokens,
                consentRule: .always,
                disclosures: RemoteTurnDisclosure.lines(
                    pastedOutputBytes: turn.pastedOutputBytes, isCloud: !target.isLocalNetwork,
                    includesCapturedCommand: turn.includesCapturedCommand),
                temperature: ReplyEngines.temperature
            )
        } catch let failure as RemoteEscalation.Failure {
            throw RemoteReplyError(failure)
        }
        return AsyncThrowingStream { continuation in
            let feed = DeltaFeed(continuation: continuation)
            let producer = Task { @MainActor in
                do {
                    let result = try await authorized.send { feed.take($0) }
                    // The cache path reports the answer once; for a streamed one this repeats the last update.
                    feed.take(result.answer)
                    feed.finish()
                } catch TonamoxError.remoteFailed(let status, _) {
                    // The body is server-controlled text; show only the status.
                    feed.finish(throwing: RemoteReplyError.serverStatus(status))
                } catch {
                    feed.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    func cancelLoad() {
        HybridSettings.shared.consent.declinePending()
    }
}

/// `RemoteBackend` reports the whole answer so far on each token; the chat appends, so it needs deltas.
private final class DeltaFeed {
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private var differ = CumulativeTextDiffer()
    private var isDone = false

    init(continuation: AsyncThrowingStream<String, Error>.Continuation) {
        self.continuation = continuation
    }

    func take(_ cumulative: String) {
        guard !isDone else { return }
        switch differ.next(cumulative) {
        case .append(let delta):
            if !delta.isEmpty { continuation.yield(delta) }
        case .diverged:
            finish(throwing: RemoteReplyError.inconsistentStream)
        }
    }

    func finish(throwing error: (any Error)? = nil) {
        guard !isDone else { return }
        isDone = true
        continuation.finish(throwing: error)
    }
}

enum RemoteReplyError: LocalizedError, Equatable {
    case refused(UserRequestRefusal)
    case declined
    case busy
    case serverStatus(Int)
    case missingKey(provider: String)
    case modelNotChosen(provider: String)
    case serverNotConfigured
    case inconsistentStream

    init(_ failure: RemoteEscalation.Failure) {
        switch failure {
        case .refused(let refusal): self = .refused(refusal)
        case .declined: self = .declined
        case .busy: self = .busy
        }
    }

    var errorDescription: String? {
        switch self {
        case .refused(.policyOff): "El envío remoto está desactivado en «Claves API y envío remoto»."
        case .refused(.cloudNotAllowed):
            "Activa «Allow cloud providers» en «Claves API y envío remoto» para usar este motor."
        case .refused(.offline): "Sin conexión: el motor en la nube no está disponible."
        case .refused(.overCostCap):
            "Superarías el límite de gasto de la sesión. Súbelo en «Claves API y envío remoto» o empieza una "
                + "sesión nueva."
        case .declined: "No se envió nada: rechazaste el envío."
        case .busy: "No se envió nada: ya hay otra petición de permiso abierta."
        case .serverStatus(let status) where (300..<400).contains(status):
            "El servidor intentó redirigir la petición a otra dirección (código \(status)); no se siguió."
        case .serverStatus(let status) where status < 0: "El servidor no devolvió una respuesta HTTP."
        case .serverStatus(let status): "El servidor respondió con un error (código \(status))."
        case .missingKey(let provider):
            "Falta la clave de \(provider). Añádela en «Claves API y envío remoto» › «Proveedores»."
        case .modelNotChosen(let provider):
            "Elige el modelo de \(provider) con el botón de información (i) de su fila en «Selecciona un modelo»."
        case .serverNotConfigured: "Configura el servidor compatible con OpenAI antes de usarlo."
        case .inconsistentStream: "La respuesta remota cambió a mitad de camino; se descartó el resto."
        }
    }
}

#if DEBUG
/// Deterministic engine for the end-to-end test: the prompt comes back as a one-line bash block.
final class EchoReplyEngine: ReplyEngine {
    static func echoReply(for prompt: String) -> String {
        "```bash\n" + prompt + "\n```"
    }

    func reply(to turn: ReplyTurn, progress: @escaping @MainActor (String) -> Void) async throws
        -> AsyncThrowingStream<String, Error> {
        if let chunks = Self.reasoningChunks(for: turn.prompt) {
            return AsyncThrowingStream { continuation in
                let producer = Task {
                    for chunk in chunks where !Task.isCancelled {
                        continuation.yield(chunk)
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in producer.cancel() }
            }
        }
        let text = Self.echoReply(for: turn.prompt)
        return AsyncThrowingStream { continuation in
            continuation.yield(text)
            continuation.finish()
        }
    }

    /// Exercises the reasoning view without a model: a prompt that starts with `<think>` comes back verbatim, the
    /// two characters `\n` as line breaks, in three-character chunks so tags arrive split.
    static func reasoningChunks(for prompt: String) -> [String]? {
        guard prompt.hasPrefix("<think>") else { return nil }
        let characters = Array(prompt.replacingOccurrences(of: "\\n", with: "\n"))
        return stride(from: 0, to: characters.count, by: 3).map { start in
            String(characters[start..<min(start + 3, characters.count)])
        }
    }

    func cancelLoad() {}
}
#endif
