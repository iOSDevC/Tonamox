import CryptoKit
import Foundation
import TonamoxCore
import TonamoxHTTP

enum ServerRoute: Equatable {
    case models
    case model(String)
    case chat
    case ingest(String)
    case script(HelperScript)
    case page(PageAsset)
    case pair
    case pairClaim(String)
    case session
    case logout

    init?(target: String) {
        if target == "/v1/models" {
            self = .models
        } else if target == "/v1/chat/completions" {
            self = .chat
        } else if let asset = PageAsset.at(target) {
            self = .page(asset)
        } else if target == "/pair" {
            self = .pair
        } else if target == "/api/session" {
            self = .session
        } else if target == "/api/session/logout" {
            self = .logout
        } else if target.hasPrefix(Self.modelPrefix), target.count > Self.modelPrefix.count {
            self = .model(String(target.dropFirst(Self.modelPrefix.count)))
        } else if target.hasPrefix(Self.ingestPrefix) {
            let ticket = String(target.dropFirst(Self.ingestPrefix.count))
            guard Self.isBase64URL(ticket, length: 43) else { return nil }
            self = .ingest(ticket)
        } else if target.hasPrefix(Self.pairPrefix) {
            let id = String(target.dropFirst(Self.pairPrefix.count))
            guard Self.isBase64URL(id, length: 22) else { return nil }
            self = .pairClaim(id)
        } else if target.hasPrefix(Self.scriptPrefix),
                  let script = HelperScript.named(String(target.dropFirst(Self.scriptPrefix.count))) {
            self = .script(script)
        } else {
            return nil
        }
    }

    static let modelPrefix = "/v1/models/"
    static let ingestPrefix = "/i/"
    static let scriptPrefix = "/s/"
    static let pairPrefix = "/pair/"

    /// Tickets are 43 base64url characters (256 bits), pairing ids 22 (128 bits); anything else gets the plain 404.
    static func isBase64URL(_ text: String, length: Int) -> Bool {
        text.utf8.count == length && text.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_")
        }
    }

    var feature: ServerFeatures {
        switch self {
        case .models, .model, .chat: .openAIAPI
        case .ingest: .ingest
        case .script: .scripts
        case .page, .pair, .pairClaim, .session, .logout: .browserPage
        }
    }

    var allowedMethod: HTTPMethod {
        switch self {
        case .chat, .ingest, .pair, .pairClaim, .logout: .post
        case .models, .model, .script, .page, .session: .get
        }
    }

    var scope: ClientScopes {
        switch self {
        case .chat: .chat
        case .session, .logout: .session
        default: .models
        }
    }

    var name: String {
        switch self {
        case .models: "/v1/models"
        case .model: "/v1/models/{id}"
        case .chat: "/v1/chat/completions"
        case .ingest: "/i/{ticket}"
        case .script(let script): "/s/" + script.name
        case .page(let asset): asset.path
        case .pair: "/pair"
        case .pairClaim: "/pair/{id}"
        case .session: "/api/session"
        case .logout: "/api/session/logout"
        }
    }

    func bodyLimit(_ limits: ServerLimits) -> Int { self == .chat ? limits.chatBodyBytes : 0 }
}

/// What one exchange answered, for the activity log.
struct ExchangeContext {
    let connection: any HTTPConnection
    let method: HTTPMethod?
    var route = "-"
    var clientLabel: String?
    var modelID: String?
    /// Errors as one ASCII line instead of JSON: curl prints them into the user's terminal.
    var plainText = false
}

/// Accumulates a non-streamed answer.
@MainActor
final class ChatAccumulator {
    var text = ""
    var reasoning = ""
    var finish = FinishReason.stop
    var usage: ServedUsage?
    /// Reasoning tokens before the budget closed the block.
    var reasoningCut: Int?
}

extension TonamoxServer {

    // MARK: - Pipeline

    /// Host → route → Origin/Sec-Fetch → auth → scope → size and media type → budgets → 100-continue → body.
    func serve(_ connection: any HTTPConnection) async {
        let limits = configuration.limits
        guard admitsConnection(from: connection.peer) else {
            log.record("connection refused: off-link or outside the peer lock", peer: connection.peer)
            return connection.close()
        }
        var context = ExchangeContext(connection: connection, method: nil)
        let head: HTTPRequestHead
        do {
            head = try await connection.readHead(deadline: ContinuousClock.now + limits.headTimeout)
        } catch HTTPConnectionError.rejected(let rejection) {
            log.record("rejected head: \(rejection.status) \(rejection.reason)", peer: connection.peer)
            await reply(.http(rejection), context)
            return
        } catch {
            connection.close()
            return
        }
        context = ExchangeContext(connection: connection, method: head.method)
        guard isAllowedHost(head.fields["host"]) else { return await reply(.misdirected, context) }
        guard let route = ServerRoute(target: head.target), configuration.features.contains(route.feature) else {
            return await reply(.notFound, context)
        }
        context.route = route.name
        if case .ingest = route { context.plainText = true }
        guard head.method == route.allowedMethod else {
            return await reply(.methodNotAllowed(route.allowedMethod.rawValue), context)
        }
        switch route {
        case .ingest(let ticket): return await receiveOutput(head, ticket: ticket, context)
        case .script(let script): return await serveScript(head, script, context)
        case .page(let asset): return await servePage(head, asset, context)
        case .pair: return await requestPairing(head, context)
        case .pairClaim(let id): return await claimPairing(head, id: id, context)
        case .models, .model, .chat, .session, .logout: break
        }
        if let refusal = originRefusal(head.fields) { return await reply(refusal, context) }
        let key: AuthenticatedClient
        switch authenticate(head.fields["authorization"], peer: connection.peer) {
        case .success(let match): key = match
        case .failure(let error): return await reply(error, context)
        }
        guard admitAuthenticated(connection.peer) else { return connection.close() }
        noteActivity()
        context.clientLabel = key.label
        guard key.scopes.contains(route.scope) else { return await reply(.insufficientScope, context) }
        guard head.contentLength <= route.bodyLimit(limits) else { return await reply(.tooLarge, context) }
        if route == .chat, !Self.isJSON(head.fields["content-type"]) { return await reply(.mediaType, context) }
        if route == .chat, !chatRate.take(key.id, now: clock.monotonic()) { return await reply(.rateLimited, context) }
        guard inflightBody + head.contentLength <= limits.inflightBodyBytes else {
            return await reply(.bodyBudget, context)
        }
        inflightBody += head.contentLength
        defer { inflightBody -= head.contentLength }
        let body: Data
        do {
            if head.expectsContinue { try await connection.sendContinue() }
            body = try await connection.readBody(length: head.contentLength,
                                                 deadline: ContinuousClock.now + limits.bodyTimeout(for: head.contentLength))
        } catch {
            log.record("body not received", peer: connection.peer)
            connection.close()
            return
        }
        let client = ClientIdentity(clientID: key.id, label: key.label, peer: connection.peer.host)
        switch route {
        case .models:
            await replyJSON(ChatCompletionEncoder.models(models.map(\.info), created: createdAt), context)
        case .model(let id):
            guard let model = models.first(where: { $0.info.id == id }) else {
                return await reply(.modelNotFound(id), context)
            }
            await replyJSON(ChatCompletionEncoder.model(model.info, created: createdAt), context)
        case .chat:
            await chat(body, client: client, context)
        case .session:
            await replyJSON(sessionDocument(for: key), context)
        case .logout:
            revoke(key.id)
            await replyJSON(WireJSON.data(["revoked": true]), context)
        case .ingest, .script, .page, .pair, .pairClaim:
            await reply(.notFound, context)
        }
    }

    /// `127.0.0.1:<port>` and `localhost:<port>` on loopback; only `<interface IPv4>:<port>` on an interface.
    func isAllowedHost(_ host: String?) -> Bool {
        guard let host, let port = boundPortForHost else { return false }
        let own = isInterfaceExposure ? ["\(boundHost):\(port)"] : ["127.0.0.1:\(port)", "localhost:\(port)"]
        let allowed = Set(own + configuration.extraHostNames.map { $0.lowercased() })
        return allowed.contains(host.lowercased())
    }

    /// Checked before auth, so a hostile page's requests never reach the credential check or the failure budget.
    func originRefusal(_ fields: HTTPFields) -> APIError? {
        if let origin = fields["origin"] {
            let host = origin.lowercased().hasPrefix("http://") ? String(origin.dropFirst(7)) : ""
            guard isAllowedHost(host) else { return .originNotAllowed }
        }
        if let site = fields["sec-fetch-site"]?.lowercased(), site != "same-origin", site != "none" {
            return .crossSite
        }
        return nil
    }

    static func isJSON(_ contentType: String?) -> Bool {
        guard let contentType else { return false }
        let media = contentType.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
        return media.trimmingCharacters(in: .whitespaces).lowercased() == "application/json"
    }

    // MARK: - Auth

    func authenticate(_ header: String?, peer: PeerAddress) -> Result<AuthenticatedClient, APIError> {
        let now = clock.monotonic()
        guard let header, let presented = Self.bearer(header), Self.isWellFormed(presented) else {
            return .failure(header == nil ? .missingKey : .invalidKey)
        }
        if failures.isBlocked(peer.host, now: now) { return .failure(.authFlood) }
        let candidate = Array(SHA256.hash(data: Data(presented.utf8)))
        if let index = keys.firstIndex(where: { SecretToken.constantTimeEqual(candidate, Array($0.keyHash)) }) {
            if let expiry = keys[index].expiresAt, expiry <= clock.wall() {
                return .failure(countFailure(peer: peer, now: now) ?? .expiredKey)
            }
            let usedAt = clock.wall()
            keys[index].lastUsed = usedAt
            keys[index].lastPeer = peer.host
            clients = keys.map(\.info)
            persistUsageIfDue(keys[index].id, now: usedAt)
            let key = keys[index]
            return .success(AuthenticatedClient(id: key.id, label: key.label, scopes: key.scopes, isBrowser: false))
        }
        if let index = pairedTokens.firstIndex(where: { SecretToken.constantTimeEqual(candidate, $0.tokenHash) }) {
            return authenticateBrowser(at: index, peer: peer, now: now)
        }
        return .failure(countFailure(peer: peer, now: now) ?? .invalidKey)
    }

    /// Saves "last used" at most once a minute per key, measured from the last write, so a store that persists
    /// keeps it to the minute without a write per request. A failed write only loses the use time.
    private func persistUsageIfDue(_ id: UUID, now: Date) {
        guard Self.usageIsDue(lastSaved: usageSavedAt[id], now: now) else { return }
        // Recorded before the write: a failing store is retried once a minute, not on every request.
        usageSavedAt[id] = now
        do {
            try credentials.save(keys)
        } catch {
            log.record("credential store could not be written")
        }
    }

    nonisolated package static func usageIsDue(lastSaved: Date?, now: Date) -> Bool {
        guard let lastSaved else { return true }
        return now.timeIntervalSince(lastSaved) >= usagePersistInterval
    }

    nonisolated static let usagePersistInterval: TimeInterval = 60

    /// A browser token presented from another address is revoked: it was copied off the wire or the machine.
    private func authenticateBrowser(at index: Int, peer: PeerAddress,
                                     now: ContinuousClock.Instant) -> Result<AuthenticatedClient, APIError> {
        let token = pairedTokens[index]
        let limits = configuration.limits
        guard token.peer == peer.host else {
            log.record("browser token presented from another address; revoked", peer: peer)
            endBrowserSession(token.id)
            return .failure(countFailure(peer: peer, now: now) ?? .invalidKey)
        }
        guard now - token.lastUsed <= limits.browserSessionIdle,
              now - token.createdAt <= limits.browserSessionLifetime else {
            endBrowserSession(token.id)
            return .failure(countFailure(peer: peer, now: now) ?? .expiredSession)
        }
        pairedTokens[index].lastUsed = now
        return .success(AuthenticatedClient(id: token.id, label: token.label, scopes: token.scopes, isBrowser: true))
    }

    /// `nil` when the failure is just counted; the flood answer while a flood is on.
    private func countFailure(peer: PeerAddress, now: ContinuousClock.Instant) -> APIError? {
        if failures.isFlooded(now: now) { return .authFlood }
        log.record("authentication failed", peer: peer)
        guard failures.recordFailure(from: peer.host, now: now) else {
            // The failure that starts a per-IP block answers 429, like the one that starts a global flood.
            return failures.isBlocked(peer.host, now: now) ? .authFlood : nil
        }
        log.record("authentication flood: unknown credentials refused for a while")
        emit(.authFlood)
        return .authFlood
    }

    static func bearer(_ header: String) -> String? {
        let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return parts[1].trimmingCharacters(in: .whitespaces)
    }

    /// `tnx_` and 43 base64url characters.
    static func isWellFormed(_ key: String) -> Bool {
        guard key.hasPrefix(keyPrefix) else { return false }
        let body = key.utf8.dropFirst(keyPrefix.utf8.count)
        return body.count == 43 && body.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_")
        }
    }

    // MARK: - Chat

    func chat(_ body: Data, client: ClientIdentity, _ context: ExchangeContext) async {
        defer { noteActivity() }
        var context = context
        let request: ChatCompletionRequest
        do {
            request = try ChatCompletionDecoder.decode(body, limits: configuration.limits)
        } catch {
            return await reply(error, context)
        }
        guard let model = models.first(where: { $0.info.id == request.model }) else {
            return await reply(.modelNotFound(request.model), context)
        }
        context.modelID = model.info.id
        var reasoning = request.reasoning
        if let window = model.info.contextLength {
            let promptTokens = Self.estimatedTokens(request.messages)
            guard let fitted = Self.fittedReasoning(request.reasoning, promptTokens: promptTokens,
                                                    maxTokens: request.maxTokens, window: window) else {
                return await reply(.contextLengthExceeded(limit: window), context)
            }
            reasoning = fitted
        }
        let extra = request.ignored.isEmpty ? [] : [HTTPField(name: "X-Tonamox-Ignored-Params",
                                                             value: request.ignored.joined(separator: ", "))]
        let slot: TurnstileSlot?
        do {
            slot = try model.base.turnstile?.reserve()
        } catch {
            return await reply(.serverBusy, context, extra: extra)
        }
        let served = ServedChatRequest(messages: request.messages, maxTokens: request.maxTokens, client: client,
                                       stream: request.stream, reasoning: reasoning)
        let control = GenerationControl(modelID: model.info.id)
        let id = UUID()
        generations[id] = control
        defer { generations[id] = nil }
        if let closingReason { control.interrupt(closingReason) }
        let connection = context.connection
        let watcher = Task { [weak control] in
            await connection.waitForPeerClose()
            control?.peerClosed()
        }
        defer { watcher.cancel() }
        if request.stream {
            await streamChat(model, served, request, slot: slot, control: control, extra: extra, context)
        } else {
            await completeChat(model, served, slot: slot, control: control, extra: extra, context)
        }
        // Not a defer: the next queued request may start only after this decode has unwound.
        await control.settle()
        slot?.release()
    }

    /// Conservative: about 3 UTF-8 bytes per token plus a few per message for the template.
    static func estimatedTokens(_ messages: [ServedMessage]) -> Int {
        messages.reduce(0) { $0 + ($1.content.utf8.count + 2) / 3 + 4 }
    }

    /// The forced close of a reasoning block (the budget sentence and the tag, twice at most) on top of its budget.
    static let reasoningCloseAllowance = 48

    /// `reasoning` with its budget lowered so prompt, budget and `maxTokens` fit `window`; `nil` when the answer alone
    /// does not. A full window ends a GGUF reply as if the model had stopped, so the reasoning gives way first.
    static func fittedReasoning(_ reasoning: ReasoningOptions, promptTokens: Int, maxTokens: Int,
                                window: Int) -> ReasoningOptions? {
        let room = window - promptTokens - maxTokens
        guard room >= 0 else { return nil }
        guard let budget = reasoning.budget, budget + reasoningCloseAllowance > room else { return reasoning }
        var fitted = reasoning
        fitted.budget = max(0, room - reasoningCloseAllowance)
        return fitted
    }

    private func completeChat(_ model: ServedModel, _ served: ServedChatRequest, slot: TurnstileSlot?,
                              control: GenerationControl, extra: [HTTPField], _ context: ExchangeContext) async {
        let answer = ChatAccumulator()
        do {
            try await waitForTurn(slot, control: control, writer: nil)
            try await control.run {
                for try await event in control.track(model.base.respond(to: served)) {
                    Self.accumulate(event, into: answer)
                }
                // A cancelled consumer sees the stream end normally, not throw.
                try Task.checkCancellation()
            }
        } catch {
            if control.peerGone { return context.connection.close() }
            let interruption = control.interruption
            let failure = interruption ?? APIError.from(error, suspended: isSuspended)
            if interruption == nil, let cause = APIError.cause(of: error) {
                log.record("chat ended with \(failure.code) (\(cause))", peer: context.connection.peer)
            }
            return await reply(failure, context, extra: extra)
        }
        let json = ChatCompletionEncoder.completion(id: Self.completionID(), created: Int(clock.wall().timeIntervalSince1970),
                                                    model: model.info.id, text: answer.text,
                                                    reasoning: answer.reasoning, finish: answer.finish,
                                                    usage: answer.usage, reasoningCut: answer.reasoningCut)
        await replyJSON(json, context, extra: extra)
    }

    private static func accumulate(_ event: ServedChatEvent, into answer: ChatAccumulator) {
        switch event {
        case .text(let text): answer.text += text
        case .reasoning(let text): answer.reasoning += text
        case .reasoningCut(let tokens): answer.reasoningCut = tokens
        case .finished(let reason, let usage):
            answer.finish = reason
            answer.usage = usage
        }
    }

    private func streamChat(_ model: ServedModel, _ served: ServedChatRequest, _ request: ChatCompletionRequest,
                            slot: TurnstileSlot?, control: GenerationControl, extra: [HTTPField],
                            _ context: ExchangeContext) async {
        let head = responseHead(status: 200, contentType: "text/event-stream; charset=utf-8", length: nil,
                                extra: extra + [HTTPField(name: "X-Accel-Buffering", value: "no")])
        let writer: EventStreamWriter
        do {
            writer = try await context.connection.openEventStream(head, stallTimeout: configuration.limits.writeStall)
        } catch {
            return context.connection.close()
        }
        record(route: context.route, status: 200, client: context.clientLabel, modelID: context.modelID)
        let stamp = (id: Self.completionID(), created: Int(clock.wall().timeIntervalSince1970), model: model.info.id)
        let answer = ChatAccumulator()
        do {
            try await waitForTurn(slot, control: control, writer: writer)
            try await control.run {
                try await writer.write(ChatCompletionEncoder.chunk(id: stamp.id, created: stamp.created, model: stamp.model,
                                                                   delta: ["role": "assistant", "content": ""],
                                                                   finish: nil))
                for try await event in control.track(model.base.respond(to: served)) {
                    try await Self.forward(event, to: writer, stamp: stamp, answer: answer)
                }
                try Task.checkCancellation()
                try await writer.write(ChatCompletionEncoder.chunk(id: stamp.id, created: stamp.created, model: stamp.model,
                                                                   delta: [:], finish: answer.finish,
                                                                   reasoningCut: answer.reasoningCut))
                if request.includeUsage, let usage = answer.usage {
                    try await writer.write(ChatCompletionEncoder.usageChunk(id: stamp.id, created: stamp.created,
                                                                            model: stamp.model, usage: usage))
                }
                try await writer.write(ChatCompletionEncoder.done)
            }
        } catch {
            if control.peerGone || error is HTTPConnectionError { return context.connection.close() }
            let interruption = control.interruption
            let failure = interruption ?? APIError.from(error, suspended: isSuspended)
            let cause = interruption == nil ? APIError.cause(of: error).map { " (\($0))" } ?? "" : ""
            log.record("stream ended with \(failure.code)\(cause)", peer: context.connection.peer)
            try? await writer.write(ChatCompletionEncoder.errorEvent(failure))
        }
        await writer.finish()
    }

    private static func forward(_ event: ServedChatEvent, to writer: EventStreamWriter,
                                stamp: (id: String, created: Int, model: String), answer: ChatAccumulator) async throws {
        switch event {
        case .text(let text):
            guard !text.isEmpty else { return }
            try await writer.write(ChatCompletionEncoder.chunk(id: stamp.id, created: stamp.created, model: stamp.model,
                                                               delta: ["content": text], finish: nil))
        case .reasoning(let text):
            guard !text.isEmpty else { return }
            try await writer.write(ChatCompletionEncoder.chunk(id: stamp.id, created: stamp.created, model: stamp.model,
                                                               delta: ["reasoning_content": text], finish: nil))
        case .reasoningCut(let tokens):
            answer.reasoningCut = tokens
        case .finished(let reason, let usage):
            answer.finish = reason
            answer.usage = usage
        }
    }

    /// Waits for the model's turnstile, bounded by the queue wait; streams get keep-alive comments meanwhile.
    private func waitForTurn(_ slot: TurnstileSlot?, control: GenerationControl,
                             writer: EventStreamWriter?) async throws {
        guard let slot else { return }
        let limits = configuration.limits
        let deadline = ContinuousClock.now + limits.queueWait
        var lastPing = ContinuousClock.now
        let peerGone = CancellationError()
        while !slot.isGranted {
            if let interruption = control.interruption { throw interruption }
            if control.peerGone { throw peerGone }
            if ContinuousClock.now >= deadline { throw APIError.serverBusy }
            if let writer, ContinuousClock.now - lastPing >= limits.keepAliveInterval {
                try await writer.write(ChatCompletionEncoder.keepAlive)
                lastPing = ContinuousClock.now
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func completionID() -> String {
        "chatcmpl-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    // MARK: - Responses

    func responseHead(status: Int, contentType: String, length: Int?, extra: [HTTPField] = []) -> HTTPResponseHead {
        var fields = [
            HTTPField(name: "Content-Type", value: contentType),
            HTTPField(name: "Date", value: HTTPDate.string(for: clock.wall())),
            HTTPField(name: "Connection", value: "close"),
            HTTPField(name: "Cache-Control", value: "no-store"),
            HTTPField(name: "X-Content-Type-Options", value: "nosniff"),
            HTTPField(name: "Referrer-Policy", value: "no-referrer"),
            HTTPField(name: "Cross-Origin-Resource-Policy", value: "same-origin"),
        ]
        if let length { fields.append(HTTPField(name: "Content-Length", value: String(length))) }
        return HTTPResponseHead(status: status, fields: fields + extra)
    }

    func reply(_ error: APIError, _ context: ExchangeContext, extra: [HTTPField] = []) async {
        var fields = extra
        if let retry = error.retryAfter { fields.append(HTTPField(name: "Retry-After", value: String(retry))) }
        if let allow = error.allow { fields.append(HTTPField(name: "Allow", value: allow)) }
        if context.plainText {
            await send(status: error.status, body: error.textBody, contentType: Self.plainTextType, context, extra: fields)
        } else {
            await send(status: error.status, body: error.body, contentType: "application/json", context, extra: fields)
        }
    }

    func replyJSON(_ body: Data, _ context: ExchangeContext, extra: [HTTPField] = []) async {
        await send(status: 200, body: body, contentType: "application/json", context, extra: extra)
    }

    static let plainTextType = "text/plain; charset=us-ascii"

    func send(status: Int, body: Data, contentType: String, _ context: ExchangeContext, extra: [HTTPField]) async {
        let payload = context.method == .head ? Data() : body
        let head = responseHead(status: status, contentType: contentType, length: payload.count, extra: extra)
        record(route: context.route, status: status, client: context.clientLabel, modelID: context.modelID)
        log.record("answered \(context.route) \(status)", peer: context.connection.peer)
        await context.connection.send(head, body: payload)
    }
}
