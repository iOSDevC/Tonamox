import Foundation
import Testing
import TonamoxHTTP
@testable import TonamoxServer

@Suite("Browser pairing and sessions", .serialized)
@MainActor
struct BrowserPairingTests {
    @Test func pairRefusedWhenWindowNotArmed() async throws {
        let presenter = FakePairingPresenter()
        let harness = try await ServerHarness.browser(presenter, armed: false)
        let response = try await harness.post("/pair", #"{"name":"x"}"#)
        #expect(response.status == 403)
        #expect(errorCode(response) == "pairing_closed")
        #expect(harness.server.pendingPairing == nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(presenter.presented.isEmpty)
        await harness.server.stop()
    }

    @Test func windowNeedsPresenterAndBrowserFeature() async throws {
        let withoutPresenter = try await ServerHarness.started { $0.features = ServerHarness.browserFeatures }
        withoutPresenter.server.openPairingWindow()
        #expect(!withoutPresenter.server.isPairingWindowOpen)
        await withoutPresenter.server.stop()
        let pageOff = try await ServerHarness.browser(FakePairingPresenter(), features: [.openAIAPI])
        #expect(!pageOff.server.isPairingWindowOpen)
        #expect(try await pageOff.post("/pair", "{}").status == 404)
        await pageOff.server.stop()
    }

    @Test func armedWindowAllowsOnePairing() async throws {
        let harness = try await ServerHarness.browser(FakePairingPresenter())
        #expect(harness.server.isPairingWindowOpen)
        _ = try await harness.pairBrowser()
        #expect(!harness.server.isPairingWindowOpen)
        let second = try await harness.post("/pair", "{}")
        #expect(errorCode(second) == "pairing_closed")
        harness.server.openPairingWindow()
        #expect(try await harness.post("/pair", "{}").status == 200)
        await harness.server.stop()
    }

    @Test func pairingSucceedsWithTypedCode() async throws {
        let presenter = FakePairingPresenter()
        let harness = try await ServerHarness.browser(presenter)
        let (id, code) = try await harness.requestPairing(name: #"Portátil\u0007 de Ana\u200B"#)
        let pending = try #require(harness.server.pendingPairing)
        #expect(pending.peer == "127.0.0.1")
        #expect(pending.untrustedLabel == "Portátil de Ana")
        #expect(pending.code.count == 8)
        #expect(pending.displayCode.count == 9)
        #expect(await eventually { presenter.presented.map(\.id) == [pending.id] })
        let typed = pending.displayCode.lowercased()
        let response = try await harness.claim(id, code: typed)
        #expect(response.status == 200)
        #expect(response.header("Set-Cookie") == nil)
        let body = json(response.body)
        let token = try #require(body["token"] as? String)
        #expect(TonamoxServer.isWellFormed(token))
        let session = try #require(body["session"] as? [String: Any])
        #expect(session["scopes"] as? [String] == ["chat", "models", "session"])
        #expect(session["idleSeconds"] as? Int == 1800)
        #expect(presenter.dismissed == [pending.id])
        #expect(harness.server.pendingPairing == nil)
        #expect(harness.server.pairedBrowsers.map(\.label) == ["Portátil de Ana"])
        #expect(!harness.logs.all.contains { $0.message.contains(token) || $0.message.contains(code) })
        await harness.server.stop()
    }

    @Test func browserTokenUsesTheOpenAIRoutes() async throws {
        let harness = try await ServerHarness.browser(FakePairingPresenter())
        let token = try await harness.pairBrowser()
        #expect(try await harness.get("/v1/models", key: token).status == 200)
        let stream = try await harness.chat(Bodies.stream(), key: token)
        #expect(stream.status == 200)
        #expect(stream.text.contains("data: [DONE]"))
        await harness.server.stop()
    }

    @Test func pairingCodeNeverInAnyResponse() async throws {
        let harness = try await ServerHarness.browser(FakePairingPresenter())
        var responses: [RawResponse] = []
        responses.append(try await harness.post("/pair", #"{"name":"a"}"#))
        let id = try #require(json(responses[0].body)["request"] as? String)
        let code = try #require(harness.server.pendingPairing?.code)
        let display = try #require(harness.server.pendingPairing?.displayCode)
        responses.append(try await harness.post("/pair", "{}"))
        responses.append(try await harness.claim(id, code: "00000000"))
        responses.append(try await harness.claim(id, code: code))
        let token = try #require(json(responses.last?.body ?? Data())["token"] as? String)
        responses.append(try await harness.session(token))
        for path in ["/", "/app.js", "/app.css"] {
            responses.append(try await harness.get(path, key: ""))
        }
        for response in responses {
            let text = response.text.uppercased()
            #expect(!text.contains(code))
            #expect(!text.contains(display))
            #expect(!response.headers.contains { $0.value.uppercased().contains(code) })
        }
        await harness.server.stop()
    }

    @Test func pairingFailsAfterThreeWrongCodes() async throws {
        let presenter = FakePairingPresenter()
        let harness = try await ServerHarness.browser(presenter)
        let (id, code) = try await harness.requestPairing()
        let wrong = code == "00000000" ? "11111111" : "00000000"
        for _ in 0..<3 {
            let response = try await harness.claim(id, code: wrong)
            #expect(response.status == 403)
            #expect(errorCode(response) == "invalid_pairing_code")
        }
        #expect(harness.server.pendingPairing == nil)
        #expect(presenter.dismissed.count == 1)
        #expect(try await harness.claim(id, code: code).status == 404)
        #expect(harness.server.pairedBrowsers.isEmpty)
        await harness.server.stop()
    }

    @Test func malformedCodeCountsAsAttempt() async throws {
        let harness = try await ServerHarness.browser(FakePairingPresenter())
        let (id, code) = try await harness.requestPairing()
        #expect(try await harness.post("/pair/\(id)", #"{"code":"!!"}"#).status == 403)
        #expect(try await harness.post("/pair/\(id)", #"{"other":1}"#).status == 403)
        #expect(try await harness.claim(id, code: code).status == 200)
        await harness.server.stop()
    }

    @Test func pairingExpiresAfterTTL() async throws {
        let presenter = FakePairingPresenter()
        let harness = try await ServerHarness.browser(presenter)
        let (id, code) = try await harness.requestPairing()
        harness.shiftClock(by: .seconds(121))
        let response = try await harness.claim(id, code: code)
        #expect(response.status == 410)
        #expect(errorCode(response) == "pairing_expired")
        #expect(harness.server.pendingPairing == nil)
        #expect(presenter.dismissed.count == 1)
        await harness.server.stop()
    }

    @Test func pendingPairingExpiresOnItsOwn() async throws {
        let presenter = FakePairingPresenter()
        let harness = try await ServerHarness.browser(presenter) { $0.limits.pairingRequestTTL = .milliseconds(200) }
        _ = try await harness.requestPairing()
        #expect(await eventually { harness.server.pendingPairing == nil })
        #expect(presenter.dismissed.count == 1)
        await harness.server.stop()
    }

    @Test func secondPendingPairingIs409() async throws {
        let harness = try await ServerHarness.browser(FakePairingPresenter())
        _ = try await harness.requestPairing()
        let second = try await harness.post("/pair", "{}")
        #expect(second.status == 409)
        #expect(errorCode(second) == "pairing_busy")
        await harness.server.stop()
    }

    @Test func pairingRateIsLimitedPerPeer() async throws {
        let harness = try await ServerHarness.browser(FakePairingPresenter())
        var statuses: [Int] = []
        for _ in 0..<4 {
            statuses.append(try await harness.post("/pair", "{}").status)
            if let id = harness.server.pendingPairing?.id { harness.server.denyPairing(id) }
            harness.server.openPairingWindow()
        }
        #expect(statuses == [200, 200, 200, 429])
        await harness.server.stop()
    }

    @Test func deniedPairingEndsRequest() async throws {
        let presenter = FakePairingPresenter()
        let harness = try await ServerHarness.browser(presenter)
        let (id, code) = try await harness.requestPairing()
        let pending = try #require(harness.server.pendingPairing)
        harness.server.denyPairing(pending.id)
        #expect(harness.server.pendingPairing == nil)
        #expect(presenter.dismissed == [pending.id])
        #expect(try await harness.claim(id, code: code).status == 404)
        #expect(errorCode(try await harness.post("/pair", "{}")) == "pairing_closed")
        await harness.server.stop()
    }

    @Test func claimRequiresSamePeer() async throws {
        let harness = try await ServerHarness.browser(FakePairingPresenter())
        let (id, code) = try await harness.requestPairing()
        let foreign = try await harness.exchange(from: "10.0.0.9", harness.postRequest("/pair/\(id)", #"{"code":"\#(code)"}"#))
        #expect(foreign.status == 403)
        #expect(json(foreign.body)["token"] == nil)
        #expect(harness.server.pendingPairing == nil)
        #expect(try await harness.claim(id, code: code).status == 404)
        await harness.server.stop()
    }

    @Test func browserTokenRejectedFromOtherIPAndRevoked() async throws {
        let harness = try await ServerHarness.browser(FakePairingPresenter())
        let token = try await harness.pairBrowser()
        let request = "GET /api/session HTTP/1.1\r\nHost: \(harness.host)\r\nAuthorization: Bearer \(token)\r\n\r\n"
        let foreign = try await harness.exchange(from: "10.0.0.9", request)
        #expect(foreign.status == 401)
        #expect(harness.server.pairedBrowsers.isEmpty)
        #expect(try await harness.session(token).status == 401)
        await harness.server.stop()
    }

    @Test func browserTokenIdleAndAbsoluteExpiry() async throws {
        let idle = try await ServerHarness.browser(FakePairingPresenter())
        let idleToken = try await idle.pairBrowser()
        idle.shiftClock(by: .seconds(29 * 60))
        #expect(try await idle.session(idleToken).status == 200)
        idle.shiftClock(by: .seconds(29 * 60 + 31 * 60))
        let expired = try await idle.session(idleToken)
        #expect(expired.status == 401)
        #expect(errorCode(expired) == "expired_api_key")
        #expect(idle.server.pairedBrowsers.isEmpty)
        await idle.server.stop()

        let absolute = try await ServerHarness.browser(FakePairingPresenter()) {
            $0.limits.browserSessionLifetime = .seconds(3600)
        }
        let token = try await absolute.pairBrowser()
        var statuses: [Int] = []
        for step in 1...4 {
            absolute.shiftClock(by: .seconds(19 * 60 * step))
            statuses.append(try await absolute.session(token).status)
        }
        #expect(statuses == [200, 200, 200, 401])
        await absolute.server.stop()
    }

    @Test func helloOnlyAfterPairing() async throws {
        let harness = try await ServerHarness.browser(FakePairingPresenter()) {
            $0.features = [.openAIAPI, .browserPage, .ingest, .scripts]
        }
        for path in ["/", "/app.js", "/app.css"] {
            let text = try await harness.get(path, key: "").text
            #expect(!text.contains("Mesa de pruebas"))
            #expect(!text.contains("scripted"))
        }
        #expect(try await harness.session(nil).status == 401)
        let apiKey = try await harness.session(harness.secret)
        #expect(apiKey.status == 403)
        #expect(errorCode(apiKey) == "insufficient_scope")
        let (id, code) = try await harness.requestPairing()
        let claimed = json(try await harness.claim(id, code: code).body)
        let hello = try #require(claimed["hello"] as? [String: Any])
        #expect(hello["serverName"] as? String == "Mesa de pruebas")
        #expect(hello["protocol"] as? Int == 1)
        let token = try #require(claimed["token"] as? String)
        let session = json(try await harness.session(token).body)
        #expect((session["hello"] as? [String: Any])?["serverName"] as? String == "Mesa de pruebas")
        await harness.server.stop()
    }

    @Test func helloListsOnlyWhatThisServerOffers() async throws {
        let plain = try await ServerHarness.browser(FakePairingPresenter())
        let plainHello = plain.server.hello()
        #expect(plainHello["features"] as? [String] == ["openai_api", "browser_page"])
        #expect(plainHello["ingest"] == nil)
        #expect(plainHello["scripts"] == nil)
        #expect(plainHello["exposure"] as? String == "loopback")
        #expect(plainHello["observable"] as? Bool == false)
        #expect(plainHello["port"] as? Int == Int(plain.port))
        let models = try #require(plainHello["models"] as? [[String: Any]])
        #expect(models.map { $0["id"] as? String } == ["scripted"])
        #expect((models.first?["egress"] as? [String: Any])?["class"] as? String == "on_device")
        let limits = try #require(plainHello["limits"] as? [String: Any])
        #expect(limits["maxTokensCap"] as? Int == 4096)
        #expect(limits["browserIdleMinutes"] as? Int == 30)
        #expect(limits["browserLifetimeHours"] as? Int == 8)
        await plain.server.stop()

        let full = try await ServerHarness.browser(FakePairingPresenter()) {
            $0.features = [.openAIAPI, .browserPage, .ingest, .scripts]
        }
        let fullHello = full.server.hello()
        #expect(fullHello["features"] as? [String] == ["openai_api", "browser_page", "ingest", "scripts"])
        #expect((fullHello["ingest"] as? [String: Any])?["maxBytes"] as? Int == 16 << 20)
        let scripts = try #require(fullHello["scripts"] as? [[String: Any]])
        #expect(scripts.first?["sha256"] as? String == HelperScript.tnxRunSHA256)
        #expect(scripts.first?["path"] as? String == "/s/tnx-run.sh")
        await full.server.stop()
    }

    @Test func everyHelloFieldThePageReadsIsSent() async throws {
        let app = try await ServerHarness.onInterface(features: [.openAIAPI, .browserPage, .ingest, .scripts])
        let cli = try await ServerHarness.browser(FakePairingPresenter()) { $0.hostedBy = .commandLine }
        let hellos = [app.server.hello(), cli.server.hello()]
        await app.server.stop()
        await cli.server.stop()
        func objects(_ path: [String]) -> [[String: Any]] {
            hellos.flatMap { hello -> [[String: Any]] in
                var current: [Any] = [hello]
                for key in path {
                    current = current.flatMap { value -> [Any] in
                        let found = (value as? [String: Any])?[key]
                        return (found as? [Any]) ?? found.map { [$0] } ?? []
                    }
                }
                return current.compactMap { $0 as? [String: Any] }
            }
        }
        let readers: [(variable: String, path: [String])] = [
            ("hello", []), ("hello\\.ingest", ["ingest"]), ("limits", ["limits"]), ("network", ["interface"]),
            ("keys", ["apiKeys"]), ("script", ["scripts"]), ("model", ["models"]), ("egress", ["models", "egress"]),
        ]
        // The test servers serve on-device models only; the other egress classes come from the same encoder.
        let otherEgress = [ServedModelInfo(id: "l", ownedBy: "x", contextLength: nil, egress: .localNetwork(host: "h")),
                           ServedModelInfo(id: "c", ownedBy: "x", contextLength: nil,
                                           egress: .cloud(providerName: "p", retentionNote: "r"))]
            .compactMap { TonamoxServer.modelEntry($0)["egress"] as? [String: Any] }
        var checked = 0
        for reader in readers {
            let pattern = #"(?<![\w.])"# + reader.variable + #"\.([A-Za-z_][A-Za-z0-9_]*)"#
            let sent = objects(reader.path) + (reader.variable == "egress" ? otherEgress : [])
            for read in try distinctCaptures(pattern, in: PageSource.script) {
                checked += 1
                #expect(sent.contains { $0[read] != nil }, "app.js reads \(reader.variable).\(read), which no hello sends")
            }
        }
        #expect(checked >= 35)
    }

    @Test func cliHelloSaysKeysAreInAHeaderFile() async throws {
        let cli = try await ServerHarness.browser(FakePairingPresenter()) { $0.hostedBy = .commandLine }
        let hello = cli.server.hello()
        #expect(hello["host"] as? String == "cli")
        #expect(hello["foreground"] as? Bool == false)
        let keys = try #require(hello["apiKeys"] as? [String: Any])
        #expect(keys["issuedOn"] as? String == "cli")
        #expect(keys["keyDelivery"] as? String == "header_file")
        await cli.server.stop()
        let app = try await ServerHarness.browser(FakePairingPresenter())
        #expect(app.server.hello()["host"] as? String == "app")
        #expect(app.server.hello()["foreground"] as? Bool == true)
        #expect((app.server.hello()["apiKeys"] as? [String: Any])?["keyDelivery"] as? String == "shown_once")
        await app.server.stop()
        let script = PageSource.script
        #expect(script.contains("hello.host === 'cli'"))
        #expect(script.contains("keys.keyDelivery === 'header_file'"))
        #expect(script.contains("hello.foreground === true"))
    }

    @Test func helloDescribesEgressClasses() {
        let local = ServedModelInfo(id: "lan", ownedBy: "x", contextLength: 8192, egress: .localNetwork(host: "10.0.0.2"))
        let cloud = ServedModelInfo(id: "c", ownedBy: "x", contextLength: nil,
                                    egress: .cloud(providerName: "Proveedor", retentionNote: "Retiene 30 días."))
        let models = [local, cloud].map(TonamoxServer.modelEntry)
        let egress = models.compactMap { $0["egress"] as? [String: String] }
        #expect(egress == [["class": "local_network", "host": "10.0.0.2"],
                           ["class": "cloud", "provider": "Proveedor", "retention": "Retiene 30 días."]])
        #expect(models.first?["contextLength"] as? Int == 8192)
    }

    @Test func pairWithoutJSONIs415() async throws {
        let harness = try await ServerHarness.browser(FakePairingPresenter())
        let response = try await harness.post("/pair", "name=x", contentType: "application/x-www-form-urlencoded")
        #expect(response.status == 415)
        #expect(harness.server.pendingPairing == nil)
        let (id, code) = try await harness.requestPairing()
        #expect(try await harness.post("/pair/\(id)", "code=\(code)", contentType: "text/plain").status == 415)
        await harness.server.stop()
    }

    @Test func pairNeedsOwnOrigin() async throws {
        let harness = try await ServerHarness.browser(FakePairingPresenter())
        let missing = try await harness.post("/pair", "{}", headers: [])
        #expect(missing.status == 403)
        #expect(errorCode(missing) == "origin_not_allowed")
        let foreign = try await harness.post("/pair", "{}", headers: ["Origin: http://evil.example"])
        #expect(foreign.status == 403)
        let crossSite = try await harness.post("/pair", "{}", headers: [harness.originHeader, "Sec-Fetch-Site: cross-site"])
        #expect(errorCode(crossSite) == "cross_site")
        #expect(harness.server.pendingPairing == nil)
        await harness.server.stop()
    }

    @Test func oversizedPairBodyIs413() async throws {
        let harness = try await ServerHarness.browser(FakePairingPresenter())
        let body = #"{"name":""# + String(repeating: "a", count: 1100) + #""}"#
        #expect(try await harness.post("/pair", body).status == 413)
        await harness.server.stop()
    }

    @Test func logoutRevokesOwnToken() async throws {
        let harness = try await ServerHarness.browser(FakePairingPresenter())
        let token = try await harness.pairBrowser()
        let other = try harness.server.issueAPIKey(label: "other")
        let request = "POST /api/session/logout HTTP/1.1\r\nHost: \(harness.host)\r\nAuthorization: Bearer \(token)\r\n"
            + "Content-Length: 0\r\n\r\n"
        let response = try await harness.raw(request)
        #expect(response.status == 200)
        #expect(try await harness.session(token).status == 401)
        #expect(try await harness.get("/v1/models", key: other.secret).status == 200)
        await harness.server.stop()
    }

    @Test func stopEndsBrowserSessionsAndPendingPairing() async throws {
        let presenter = FakePairingPresenter()
        let harness = try await ServerHarness.browser(presenter)
        _ = try await harness.pairBrowser()
        harness.server.openPairingWindow()
        _ = try await harness.requestPairing()
        await harness.server.stop()
        #expect(harness.server.pairedBrowsers.isEmpty)
        #expect(harness.server.pendingPairing == nil)
        #expect(!harness.server.isPairingWindowOpen)
        #expect(presenter.dismissed.count == 2)
    }

    @Test func disconnectAllSessionsKeepsAPIKeys() async throws {
        let harness = try await ServerHarness.browser(FakePairingPresenter())
        let token = try await harness.pairBrowser()
        harness.server.disconnectAllSessions()
        #expect(try await harness.session(token).status == 401)
        #expect(try await harness.get("/v1/models").status == 200)
        await harness.server.stop()
    }
}

@Suite("Browser page assets", .serialized)
@MainActor
struct BrowserPageAssetTests {
    @Test func pageIs404WhenFeatureOff() async throws {
        let harness = try await ServerHarness.started()
        for path in ["/", "/app.js", "/app.css", "/api/session"] {
            #expect(try await harness.get(path).status == 404)
        }
        await harness.server.stop()
    }

    @Test func htmlCarriesCSPAndFrameDeny() async throws {
        let harness = try await ServerHarness.browser(FakePairingPresenter())
        let page = try await harness.get("/", key: "")
        #expect(page.status == 200)
        #expect(page.header("Content-Type") == "text/html; charset=utf-8")
        #expect(page.header("Content-Security-Policy") == "default-src 'none'; script-src 'self'; style-src 'self'; "
                + "connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
        #expect(page.header("X-Frame-Options") == "DENY")
        #expect(page.header("Cross-Origin-Opener-Policy") == "same-origin")
        #expect(page.header("Cache-Control") == "no-store")
        #expect(page.header("X-Content-Type-Options") == "nosniff")
        #expect(!page.headers.contains { $0.name.lowercased().hasPrefix("access-control-") })
        let crossSite = try await harness.get("/", key: "", headers: ["Sec-Fetch-Site: cross-site"])
        #expect(crossSite.status == 403)
        #expect(try await harness.get("/", key: "", headers: ["Sec-Fetch-Site: none"]).status == 200)
        await harness.server.stop()
    }

    @Test func routesServeExactBytes() async throws {
        let harness = try await ServerHarness.browser(FakePairingPresenter())
        let expected: [(String, String, String)] = [
            ("/", "index.html", "text/html; charset=utf-8"),
            ("/app.js", "app.js", "text/javascript; charset=utf-8"),
            ("/app.css", "app.css", "text/css; charset=utf-8"),
        ]
        for (path, file, type) in expected {
            let response = try await harness.get(path, key: "")
            let source = try PageSource.bytes(file)
            #expect(response.status == 200)
            #expect(response.body == source)
            #expect(response.header("Content-Length") == "\(source.count)")
            #expect(response.header("Content-Type") == type)
        }
        #expect(try await harness.get("/app.js", key: "", method: "DELETE").status == 405)
        #expect(try await harness.get("/index.html", key: "").status == 404)
        await harness.server.stop()
    }

    @Test func pageHasNoInlineScriptOrHandlers() throws {
        let html = PageSource.html
        #expect(!html.isEmpty)
        let scripts = try matches(#"<script\b[^>]*>([\s\S]*?)</script>"#, in: html)
        #expect(scripts.count == 1)
        for script in scripts {
            #expect(script.tag.contains(#"src="/app.js""#))
            #expect(script.inner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        #expect(try matches(#"\son[a-zA-Z]+\s*="#, in: html).isEmpty)
        #expect(try matches(#"\sstyle\s*="#, in: html).isEmpty)
        #expect(!html.lowercased().contains("<style"))
        #expect(!html.lowercased().contains("javascript:"))
        #expect(!html.lowercased().contains("<form"))
        #expect(!html.lowercased().contains("<iframe"))
    }

    @Test func jsNeverUsesInnerHTMLEvalOrFunction() throws {
        let script = PageSource.script
        #expect(!script.isEmpty)
        let forbidden = ["innerHTML", "outerHTML", "insertAdjacentHTML", "eval(", "Function(", "document.write",
                         "setTimeout('", "setTimeout(\"", "setTimeout(`", "setInterval", "javascript:",
                         "createContextualFragment", "DOMParser", "srcdoc", "importScripts", "import(",
                         ".setAttribute('on", ".setAttribute(\"on"]
        for word in forbidden {
            #expect(!script.contains(word), "app.js contains \(word)")
        }
        #expect(script.contains(".textContent"))
    }

    @Test func assetsReferenceNoExternalURL() throws {
        let assets = ["index.html": PageSource.html, "app.js": PageSource.script, "app.css": PageSource.stylesheet]
        for (name, text) in assets {
            #expect(!text.isEmpty)
            for word in ["http://", "https://", "'//", "\"//", "url(", "@import", "ws://", "wss://"] {
                #expect(!text.lowercased().contains(word), "\(name) contains \(word)")
            }
        }
        for reference in try matches(#"(?:src|href)="([^"]*)""#, in: PageSource.html) {
            #expect(reference.inner.hasPrefix("/") && !reference.inner.hasPrefix("//"))
        }
    }

    @Test func tokenNeverPlacedInURLOrCookie() throws {
        let script = PageSource.script
        for word in ["document.cookie", "localStorage", "location.search", "location.hash =", "location.href =",
                     "history.pushState", "indexedDB", "?token", "&token", "location.assign", "location.replace"] {
            #expect(!script.contains(word), "app.js contains \(word)")
        }
        // The guide deep link is the only URL access: one read compared with constants, one write of the bare path.
        #expect(script.components(separatedBy: "location.hash").count == 2)
        #expect(script.contains("return GUIDE_HASHES.indexOf(location.hash) >= 0;"))
        #expect(script.components(separatedBy: "replaceState").count == 2)
        #expect(script.contains("history.replaceState(null, '', location.pathname);"))
        #expect(script.contains("sessionStorage"))
        #expect(script.contains("credentials: 'omit'"))
        #expect(script.contains("headers.Authorization = 'Bearer ' + token()"))
    }

    @Test func pageTextIsSpanishAndEnglish() throws {
        #expect(PageSource.html.contains(#"<html lang="en">"#))
        let pairs = [("Emparejar este navegador", "Pair this browser"), ("Guía de este servidor", "Guide to this server"),
                     ("Conexión sin cifrar.", "Unencrypted connection."), ("Detener", "Stop")]
        for (spanish, english) in pairs {
            #expect(PageSource.script.contains("es: '\(spanish)',\n      en: '\(english)',"))
        }
        #expect(PageSource.stylesheet.contains("prefers-color-scheme: dark"))
    }
}

@Suite("Browser page layout")
struct BrowserPageLayoutTests {
    private func region(_ html: String, from start: String, to end: String) throws -> String {
        let lower = try #require(html.range(of: start), "no \(start)")
        let upper = try #require(html.range(of: end, range: lower.upperBound..<html.endIndex), "no \(end) after \(start)")
        return String(html[lower.lowerBound..<upper.upperBound])
    }

    /// Declarations of the first rule whose selector list is exactly `selector`.
    private func rule(_ selector: String) throws -> String {
        let escaped = NSRegularExpression.escapedPattern(for: selector)
        let found = try matches(#"(?:^|\n)"# + escaped + #" \{([^}]*)\}"#, in: PageSource.stylesheet)
        return try #require(found.first?.inner, "app.css has no rule \(selector)")
    }

    @Test func guideLivesInAModalDialog() throws {
        let html = PageSource.html
        let dialog = try region(html, from: "<dialog", to: "</dialog>")
        #expect(dialog.hasPrefix(#"<dialog id="guide-dialog" class="guide-dialog" aria-labelledby="guide-title">"#))
        for id in ["guide-title", "guide-close", "guide", "guide-intro", "guide-body"] {
            #expect(dialog.contains(#"id="\#(id)""#), "\(id) is not inside the dialog")
        }
        #expect(dialog.contains(#"<button id="guide-close" type="button" class="secondary" data-i18n="guide.close">"#))
        #expect(html.components(separatedBy: #"id="guide-body""#).count == 2)
        let workspace = try region(html, from: #"<div id="workspace""#, to: "</main>")
        #expect(!workspace.contains(#"id="guide"#))
        #expect(try matches(#"\son[a-zA-Z]+\s*=|\sstyle\s*="#, in: dialog).isEmpty)
        let script = PageSource.script
        #expect(script.contains("dialog.showModal();"))
        #expect(!script.contains("dialog.show()"))
        #expect(script.contains("if (dialog.open) dialog.close();"))
        #expect(script.contains("dialog.addEventListener('close', guideClosed);"))
        #expect(script.contains("pressOnBackdrop = event.target === dialog;"))
        #expect(script.contains("if (pressOnBackdrop && event.target === dialog) closeGuide();"))
        #expect(!script.contains("if (event.target === dialog) closeGuide();"), "a drag ending on the backdrop closes it")
        #expect(script.contains("if (!byId('open-guide').hidden) byId('open-guide').focus();"))
        #expect(try rule(".guide-dialog").contains("padding: 0;"), "backdrop detection needs an unpadded dialog")
        #expect(try rule(".guide-dialog .guide").contains("overflow-y: auto;"))
        #expect(try rule("body:has(dialog[open])").contains("overflow: hidden;"))
    }

    @Test func topBarHasALocalizedGuideButton() throws {
        let header = try region(PageSource.html, from: "<header", to: "</header>")
        #expect(header.contains(#"<button id="open-guide" type="button" class="secondary" data-i18n="top.guide" "#
                                + #"aria-haspopup="dialog""#))
        #expect(header.contains(#"aria-controls="guide-dialog" hidden></button>"#))
        #expect(header.contains(#"<span id="current-model" class="current-model small" hidden></span>"#))
        #expect(header.contains(#"id="language""#))
        let script = PageSource.script
        for (key, spanish, english) in [("top.guide", "Guía", "Guide"), ("guide.close", "Cerrar", "Close"),
                                        ("top.model", "Modelo: {model}", "Model: {model}")] {
            #expect(script.contains("'\(key)': {\n      es: '\(spanish)',\n      en: '\(english)',\n    },"))
        }
        #expect(script.contains("'chat.guideHint': {\n      es: 'Abre la Guía, arriba,"))
        #expect(PageSource.html.contains(#"<p class="small" data-i18n="chat.guideHint"></p>"#))
        #expect(script.contains("node.title = name ? t('top.model', { model: name }) : '';"))
        #expect(try rule("#server-name, .current-model").contains("text-overflow: ellipsis;"))
    }

    @Test func transcriptIsTheOnlyScrollingRegion() throws {
        #expect(PageSource.html.contains("viewport-fit=cover"))
        let body = try rule("body.in-chat")
        #expect(body.contains("height: 100dvh;"))
        #expect(body.contains("overflow: hidden;"))
        let main = try rule("body.in-chat main")
        #expect(main.contains("display: flex;") && main.contains("min-height: 0;"))
        #expect(main.contains("env(safe-area-inset-bottom)"))
        #expect(try rule("body.in-chat .workspace").contains("flex: 1;"))
        let chat = try rule(".chat")
        #expect(chat.contains("flex: 1;") && chat.contains("min-height: 0;"))
        let messages = try rule(".messages")
        for declaration in ["flex: 1;", "min-height: 0;", "overflow-y: auto;"] {
            #expect(messages.contains(declaration), ".messages lacks \(declaration)")
        }
        #expect(!messages.contains("max-height"))
        #expect(try rule(".top").contains("env(safe-area-inset-top)"))
        #expect(PageSource.script.contains("document.body.classList.toggle('in-chat', on);"))
    }

    @Test func composerStaysReachableOnShortViewports() throws {
        #expect(try rule("body.in-chat main").contains("overflow-y: auto;"), "main is the fallback scroller")
        #expect(try rule("body.in-chat .workspace").contains("min-height: 16rem;"))
        #expect(try rule("body.in-chat .messages").contains("min-height: 3rem;"))
    }

    @Test func pairingScreenAndBannersRespectSideInsets() throws {
        let main = try rule("main")
        #expect(main.contains("env(safe-area-inset-left)") && main.contains("env(safe-area-inset-right)"))
        let banner = try rule(".banner")
        #expect(banner.contains("env(safe-area-inset-left)") && banner.contains("env(safe-area-inset-right)"))
        #expect(try rule("footer").contains("env(safe-area-inset-bottom)"))
    }

    @Test func openGuideCarriesTheLanguageSwitch() {
        let script = PageSource.script
        #expect(script.contains("const guideLanguage = byId('language').cloneNode(true);"))
        #expect(script.contains("guideLanguage.removeAttribute('id');"))
        #expect(script.contains("byId('guide-close').before(guideLanguage);"))
        #expect(!script.contains("'#language button'"), "the copy in the guide must be bound and updated too")
        #expect(script.components(separatedBy: "document.querySelectorAll('.language button')").count == 3)
    }

    @Test func guideHashesOpenTheDialog() {
        let script = PageSource.script
        #expect(script.contains("const GUIDE_HASHES = ['#guia', '#guide'];"))
        #expect(script.contains(
            "window.addEventListener('hashchange', function () {\n      if (guideRequested()) openGuide();\n      else closeGuide();"))
        #expect(script.contains("    if (guideRequested()) openGuide();\n  }\n\n  function observableWhere"))
        #expect(script.contains("if (guideRequested()) history.replaceState(null, '', location.pathname);"))
    }
}

private func distinctCaptures(_ pattern: String, in text: String) throws -> [String] {
    Array(Set(try matches(pattern, in: text).map(\.inner))).sorted()
}

private func matches(_ pattern: String, in text: String) throws -> [(tag: String, inner: String)] {
    let regex = try #require(try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))
    let range = NSRange(text.startIndex..., in: text)
    return regex.matches(in: text, range: range).map { match in
        let whole = Range(match.range, in: text).map { String(text[$0]) } ?? ""
        let inner = match.numberOfRanges > 1 ? Range(match.range(at: 1), in: text).map { String(text[$0]) } : nil
        return (whole, inner ?? "")
    }
}
