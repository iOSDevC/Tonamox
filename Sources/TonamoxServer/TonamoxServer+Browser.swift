import CryptoKit
import Foundation
import TonamoxHTTP

extension TonamoxServer {

    // MARK: - Pairing control (host app)

    /// Accepts one browser pairing during the next ``ServerLimits/pairingWindow`` (120 s by default). Outside an
    /// armed window `POST /pair` answers 403 `pairing_closed` and nothing reaches the ``PairingPresenter``.
    public func openPairingWindow() {
        guard pairing != nil, configuration.features.contains(.browserPage) else {
            log.record("pairing window not opened: no presenter or browser page off")
            return
        }
        pairingWindowUntil = clock.monotonic() + configuration.limits.pairingWindow
        log.record("pairing window opened")
    }

    /// Ends the pending pairing and closes the window: the person saw a request they did not expect.
    public func denyPairing(_ id: PairingRequest.ID) {
        guard pairingState?.request.id == id else { return }
        pairingWindowUntil = nil
        endPairing(succeeded: false)
        log.record("pairing denied")
    }

    /// Ends every paired browser's session; API keys are untouched.
    public func disconnectAllSessions() {
        let ended = pairedTokens.map(\.id)
        guard !ended.isEmpty else { return }
        pairedTokens = []
        ended.forEach { emit(.browserSessionEnded($0)) }
        log.record("browser sessions ended")
    }

    func closePairing() {
        pairingWindowUntil = nil
        endPairing(succeeded: false)
    }

    func endPairing(succeeded: Bool) {
        guard let pending = pairingState else { return }
        pairingState = nil
        pendingPairing = nil
        pairing?.dismiss(pending.request.id)
        if !succeeded { emit(.pairingEnded(pending.request.id)) }
    }

    func endBrowserSession(_ id: UUID) {
        guard pairedTokens.contains(where: { $0.id == id }) else { return }
        pairedTokens.removeAll { $0.id == id }
        emit(.browserSessionEnded(id))
    }

    // MARK: - Page

    func servePage(_ head: HTTPRequestHead, _ asset: PageAsset, _ context: ExchangeContext) async {
        if let refusal = originRefusal(head.fields) { return await reply(refusal, context) }
        guard head.contentLength == 0 else { return await reply(.tooLarge, context) }
        var extra: [HTTPField] = []
        if asset == .html {
            extra = [HTTPField(name: "Content-Security-Policy", value: PageAsset.contentSecurityPolicy),
                     HTTPField(name: "X-Frame-Options", value: "DENY"),
                     HTTPField(name: "Cross-Origin-Opener-Policy", value: "same-origin")]
        }
        await send(status: 200, body: asset.bytes, contentType: asset.contentType, context, extra: extra)
    }

    // MARK: - POST /pair

    /// Origin = self → armed window → JSON → size → rate → one pending → body → present the code on the device.
    /// The response carries only the request id; the code is never sent to the browser.
    func requestPairing(_ head: HTTPRequestHead, _ context: ExchangeContext) async {
        let peer = context.connection.peer
        let limits = configuration.limits
        if let refusal = pairingOriginRefusal(head.fields) { return await reply(refusal, context) }
        guard canPair else { return await reply(.pairingClosed, context) }
        guard Self.isJSON(head.fields["content-type"]) else { return await reply(.mediaType, context) }
        guard head.contentLength <= limits.pairingBodyBytes else { return await reply(.tooLarge, context) }
        let now = clock.monotonic()
        expirePairingIfDue(now: now)
        guard pairingRate.take(peer.host, now: now), pairingGlobalRate.take(now: now) else {
            return await reply(.rateLimited, context)
        }
        guard pairingState == nil else { return await reply(.pairingBusy, context) }
        guard let body = await readSmallBody(head, context) else { return }
        guard let fields = Self.smallJSONObject(body) else { return await reply(.invalidJSON(), context) }
        // The body read awaited: another request may have taken the slot or the window may have closed.
        guard canPair else { return await reply(.pairingClosed, context) }
        guard pairingState == nil else { return await reply(.pairingBusy, context) }
        let idText = SecretToken.random(bits: 128).text
        let code = CrockfordCode.random(length: 8)
        let request = PairingRequest(id: UUID(), peer: peer.host,
                                     untrustedLabel: Self.browserLabel(fields["name"] as? String), code: code,
                                     expiresAt: clock.wall().addingTimeInterval(limits.pairingRequestTTL.seconds))
        pairingState = PairingSlot(request: request, idHash: Self.digest(idText), codeHash: Self.digest(code),
                                      peer: peer.host, expiresAt: clock.monotonic() + limits.pairingRequestTTL,
                                      attemptsLeft: limits.pairingCodeAttempts)
        pendingPairing = request
        emit(.pairingRequested(request.id))
        log.record("pairing requested", peer: peer)
        schedulePairingExpiry(request.id, after: limits.pairingRequestTTL)
        if let pairing {
            Task { await pairing.present(request) }
        }
        await replyJSON(WireJSON.data(["request": idText, "expiresAt": Int(request.expiresAt.timeIntervalSince1970),
                                       "attempts": limits.pairingCodeAttempts]), context)
    }

    // MARK: - POST /pair/{id}

    /// Same peer, before expiry, at most ``ServerLimits/pairingCodeAttempts`` codes. Success returns the browser
    /// token and the capability hello, once.
    func claimPairing(_ head: HTTPRequestHead, id: String, _ context: ExchangeContext) async {
        let peer = context.connection.peer
        let limits = configuration.limits
        if let refusal = pairingOriginRefusal(head.fields) { return await reply(refusal, context) }
        guard Self.isJSON(head.fields["content-type"]) else { return await reply(.mediaType, context) }
        guard head.contentLength <= limits.pairingBodyBytes else { return await reply(.tooLarge, context) }
        guard let body = await readSmallBody(head, context) else { return }
        guard var pending = pairingState, SecretToken.constantTimeEqual(Self.digest(id), pending.idHash) else {
            return await reply(.notFound, context)
        }
        let now = clock.monotonic()
        guard now < pending.expiresAt else {
            endPairing(succeeded: false)
            return await reply(.pairingExpired, context)
        }
        guard pending.peer == peer.host else {
            log.record("pairing claimed from another address; request ended", peer: peer)
            endPairing(succeeded: false)
            return await reply(.wrongPairingCode, context)
        }
        let typed = (Self.smallJSONObject(body)?["code"] as? String).flatMap(CrockfordCode.normalize) ?? ""
        guard typed.count == 8, SecretToken.constantTimeEqual(Self.digest(typed), pending.codeHash) else {
            pending.attemptsLeft -= 1
            if pending.attemptsLeft <= 0 {
                log.record("pairing ended after wrong codes", peer: peer)
                endPairing(succeeded: false)
            } else {
                pairingState = pending
            }
            return await reply(.wrongPairingCode, context)
        }
        guard admitAuthenticated(peer) else {
            endPairing(succeeded: false)
            return context.connection.close()
        }
        let label = pending.request.untrustedLabel
        endPairing(succeeded: true)
        pairingWindowUntil = nil
        let secret = SecretToken.random(bits: 256, prefix: Self.keyPrefix)
        let paired = clock.wall()
        let token = BrowserToken(id: UUID(), label: label, tokenHash: Array(secret.storedHash), peer: peer.host,
                                 scopes: [.chat, .models, .session], createdAt: now, lastUsed: now, pairedAt: paired,
                                 expiresAt: paired.addingTimeInterval(limits.browserSessionLifetime.seconds))
        pairedTokens.append(token)
        noteActivity()
        emit(.browserPaired(token.id))
        log.record("browser paired \(token.id.uuidString)", peer: peer)
        var context = context
        context.clientLabel = label
        await replyJSON(WireJSON.data(["token": secret.text, "session": sessionObject(for: token),
                                       "hello": hello()]), context)
    }

    // MARK: - GET /api/session

    func sessionDocument(for client: AuthenticatedClient) -> Data {
        if let token = pairedTokens.first(where: { $0.id == client.id }) {
            return WireJSON.data(["session": sessionObject(for: token), "hello": hello()])
        }
        let expiry = keys.first { $0.id == client.id }?.expiresAt
        let session: [String: Any] = ["kind": "api_key", "label": client.label, "scopes": Self.scopeNames(client.scopes),
                                      "expiresAt": expiry.map { Int($0.timeIntervalSince1970) } ?? NSNull()]
        return WireJSON.data(["session": session, "hello": hello()])
    }

    private func sessionObject(for token: BrowserToken) -> [String: Any] {
        ["kind": "browser", "label": token.label, "scopes": Self.scopeNames(token.scopes),
         "expiresAt": Int(token.expiresAt.timeIntervalSince1970),
         "idleSeconds": Int(configuration.limits.browserSessionIdle.seconds)]
    }

    /// What this server instance offers, sent only to an authenticated client: the page builds its guide from it.
    func hello() -> [String: Any] {
        let limits = configuration.limits
        let features = configuration.features
        var document: [String: Any] = [
            "protocol": 1,
            "serverName": configuration.serverName,
            "features": Self.featureNames(features),
            "exposure": isInterfaceExposure ? "interface" : "loopback",
            "observable": isInterfaceExposure,
            "host": configuration.hostedBy == .app ? "app" : "cli",
            "foreground": configuration.hostedBy == .app,
            "models": servedModels.map(Self.modelEntry),
            "limits": [
                "maxTokensDefault": limits.defaultMaxTokens,
                "maxTokensCap": limits.maxTokensCap,
                "chatRequestsPerMinute": limits.chatRequestsPerMinute,
                "chatBodyBytes": limits.chatBodyBytes,
                "maxMessages": limits.maxMessages,
                "maxCharactersPerMessage": limits.maxCharactersPerMessage,
                "generationsRunning": 1,
                "queueWaitSeconds": Int(limits.queueWait.seconds),
                "browserIdleMinutes": Int(limits.browserSessionIdle.seconds / 60),
                "browserLifetimeHours": Int(limits.browserSessionLifetime.seconds / 3600),
            ],
            "apiKeys": apiKeyGuide,
        ]
        if let port = boundPortForHost { document["port"] = Int(port) }
        if case .interface(let chosen) = configuration.exposure {
            document["interface"] = ["name": chosen.name, "kind": chosen.wireName, "address": boundHost,
                                     "peerLock": configuration.peerLockPolicy == .firstPairedPeer ? "first_paired_peer" : "none",
                                     "idleMinutes": configuration.idleShutdown.map { Int($0.seconds / 60) } ?? NSNull()]
        }
        if features.contains(.ingest) {
            document["ingest"] = ["defaultMaxBytes": limits.ingestDefaultBytes, "maxBytes": limits.ingestMaxBytes,
                                  "ticketMinutes": 10, "liveTickets": limits.maxLiveTickets,
                                  "postsPerMinute": limits.ingestPostsPerMinute]
        }
        if features.contains(.scripts) {
            document["scripts"] = HelperScript.all.map { script -> [String: Any] in
                ["name": script.name, "path": ServerRoute.scriptPrefix + script.name, "sha256": script.sha256]
            }
        }
        return document
    }

    private var apiKeyGuide: [String: Any] {
        switch configuration.hostedBy {
        case .app:
            ["issuedOn": "device", "keyDelivery": "shown_once", "defaultLifetimeDays": 7, "scopes": ["chat", "models"]]
        case .commandLine:
            ["issuedOn": "cli", "keyDelivery": "header_file", "scopes": ["chat", "models"]]
        }
    }

    static func modelEntry(_ info: ServedModelInfo) -> [String: Any] {
        var entry: [String: Any] = ["id": info.id, "ownedBy": info.ownedBy,
                                    "contextLength": info.contextLength ?? NSNull()]
        switch info.egress {
        case .onDevice:
            entry["egress"] = ["class": "on_device"]
        case .localNetwork(let host):
            entry["egress"] = ["class": "local_network", "host": host]
        case .cloud(let provider, let retention):
            entry["egress"] = ["class": "cloud", "provider": provider, "retention": retention]
        }
        return entry
    }

    static func featureNames(_ features: ServerFeatures) -> [String] {
        let names: [(ServerFeatures, String)] = [(.openAIAPI, "openai_api"), (.browserPage, "browser_page"),
                                                 (.ingest, "ingest"), (.scripts, "scripts")]
        return names.filter { features.contains($0.0) }.map(\.1)
    }

    static func scopeNames(_ scopes: ClientScopes) -> [String] {
        let names: [(ClientScopes, String)] = [(.chat, "chat"), (.models, "models"), (.session, "session")]
        return names.filter { scopes.contains($0.0) }.map(\.1)
    }

    // MARK: - Helpers

    private var canPair: Bool {
        pairing != nil && isPairingWindowOpen && !failures.isFlooded(now: clock.monotonic())
    }

    /// Pairing is only for this server's own page: a missing `Origin` is refused too.
    private func pairingOriginRefusal(_ fields: HTTPFields) -> APIError? {
        guard fields["origin"] != nil else { return .originRequired }
        return originRefusal(fields)
    }

    private func expirePairingIfDue(now: ContinuousClock.Instant) {
        if let pending = pairingState, now >= pending.expiresAt { endPairing(succeeded: false) }
    }

    private func schedulePairingExpiry(_ id: UUID, after ttl: Duration) {
        Task { [weak self] in
            try? await Task.sleep(for: ttl)
            guard let self, self.pairingState?.request.id == id else { return }
            self.endPairing(succeeded: false)
        }
    }

    /// Budget → 100-continue → body; `nil` when the exchange was already answered or closed.
    private func readSmallBody(_ head: HTTPRequestHead, _ context: ExchangeContext) async -> Data? {
        let limits = configuration.limits
        guard inflightBody + head.contentLength <= limits.inflightBodyBytes else {
            await reply(.bodyBudget, context)
            return nil
        }
        inflightBody += head.contentLength
        defer { inflightBody -= head.contentLength }
        do {
            if head.expectsContinue { try await context.connection.sendContinue() }
            return try await context.connection.readBody(length: head.contentLength,
                                                         deadline: ContinuousClock.now + limits.bodyTimeout(for: head.contentLength))
        } catch {
            log.record("body not received", peer: context.connection.peer)
            context.connection.close()
            return nil
        }
    }

    static func smallJSONObject(_ body: Data) -> [String: Any]? {
        guard !JSONDepth.exceeds(body, limit: 4) else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    static func digest(_ text: String) -> [UInt8] {
        Array(SHA256.hash(data: Data(text.utf8)))
    }

    /// Printable, at most 60 characters; shown on the device as untrusted.
    static func browserLabel(_ name: String?) -> String {
        let scalars = (name ?? "").unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && !CharacterSet.illegalCharacters.contains(scalar)
                && scalar.properties.generalCategory != .format
        }
        let label = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? "browser" : String(label.prefix(60))
    }
}
