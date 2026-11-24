import Foundation
import Testing
@testable import TonamoxServer

@Suite("Server policy", .serialized)
@MainActor
struct ServerPolicyTests {
    @Test func hostMismatchIs421() async throws {
        let harness = try await ServerHarness.started()
        let response = try await harness.get("/v1/models", host: "evil.example:\(harness.port)")
        #expect(response.status == 421)
        await harness.server.stop()
    }

    @Test func hostWithoutPortIs421() async throws {
        let harness = try await ServerHarness.started()
        #expect(try await harness.get("/v1/models", host: "127.0.0.1").status == 421)
        #expect(try await harness.get("/v1/models", host: "localhost").status == 421)
        await harness.server.stop()
    }

    @Test func localhostHostAllowedOnlyOnLoopback() async throws {
        let harness = try await ServerHarness.started()
        #expect(harness.server.configuration.exposure == .loopback)
        #expect(try await harness.get("/v1/models", host: "localhost:\(harness.port)").status == 200)
        #expect(try await harness.get("/v1/models", host: "LOCALHOST:\(harness.port)").status == 200)
        await harness.server.stop()
    }

    @Test func foreignOriginIs403() async throws {
        let harness = try await ServerHarness.started()
        let response = try await harness.get("/v1/models", headers: ["Origin: http://evil.example"])
        #expect(response.status == 403)
        #expect(errorCode(response) == "origin_not_allowed")
        let sameHost = try await harness.get("/v1/models", headers: ["Origin: http://\(harness.host)"])
        #expect(sameHost.status == 200)
        await harness.server.stop()
    }

    @Test func absentOriginAccepted() async throws {
        let harness = try await ServerHarness.started()
        #expect(try await harness.get("/v1/models").status == 200)
        await harness.server.stop()
    }

    @Test func optionsIs405WithoutCORS() async throws {
        let harness = try await ServerHarness.started()
        let response = try await harness.get("/v1/chat/completions", headers: [
            "Origin: http://evil.example", "Access-Control-Request-Method: POST",
        ], method: "OPTIONS")
        #expect(response.status == 405)
        #expect(response.header("Allow") == "POST")
        #expect(!response.headers.contains { $0.name.lowercased().hasPrefix("access-control-") })
        await harness.server.stop()
    }

    @Test func noResponseCarriesAccessControlHeaders() async throws {
        let harness = try await ServerHarness.started()
        let responses = [
            try await harness.get("/v1/models", headers: ["Origin: http://\(harness.host)"]),
            try await harness.get("/v1/models", headers: ["Origin: http://evil.example"]),
            try await harness.get("/nope"),
            try await harness.chat(Bodies.chat()),
            try await harness.get("/v1/models", key: "tnx_wrong"),
        ]
        for response in responses {
            #expect(!response.headers.contains { $0.name.lowercased().hasPrefix("access-control-") })
        }
        await harness.server.stop()
    }

    @Test func everyResponseIsNoStoreNosniff() async throws {
        let harness = try await ServerHarness.started()
        let responses = [
            try await harness.get("/v1/models"), try await harness.get("/nope"),
            try await harness.raw("GET / HTTP/1.0\r\nHost: x\r\n\r\n"), try await harness.chat(Bodies.chat()),
        ]
        for response in responses {
            #expect(response.header("Cache-Control") == "no-store")
            #expect(response.header("X-Content-Type-Options") == "nosniff")
            #expect(response.header("Referrer-Policy") == "no-referrer")
            #expect(response.header("Cross-Origin-Resource-Policy") == "same-origin")
            #expect(response.header("Connection") == "close")
            #expect(response.header("Date")?.hasSuffix(" GMT") == true)
        }
        await harness.server.stop()
    }

    @Test func noServerHeader() async throws {
        let harness = try await ServerHarness.started()
        #expect(try await harness.get("/v1/models").header("Server") == nil)
        #expect(try await harness.get("/nope").header("Server") == nil)
        await harness.server.stop()
    }

    @Test func wrongMethodIs405WithAllow() async throws {
        let harness = try await ServerHarness.started()
        let get = try await harness.get("/v1/chat/completions")
        #expect(get.status == 405)
        #expect(get.header("Allow") == "POST")
        let delete = try await harness.get("/v1/models", method: "DELETE")
        #expect(delete.status == 405)
        #expect(delete.header("Allow") == "GET")
        await harness.server.stop()
    }

    @Test func unknownPathIs404SameBody() async throws {
        let harness = try await ServerHarness.started()
        let first = try await harness.get("/nope")
        let second = try await harness.get("/v2/models", key: "tnx_x")
        let third = try await harness.get("/v1/modelsx")
        let statuses: [Int] = [first.status, second.status, third.status]
        #expect(statuses == [404, 404, 404])
        #expect(first.body == second.body && second.body == third.body)
        await harness.server.stop()
    }

    @Test func originCheckedBeforeAuth() async throws {
        let harness = try await ServerHarness.started()
        let response = try await harness.get("/v1/models", key: "tnx_" + String(repeating: "A", count: 43),
                                             headers: ["Origin: http://evil.example"])
        #expect(response.status == 403)
        #expect(!harness.logs.all.contains { $0.message.contains("authentication failed") })
        await harness.server.stop()
    }

    @Test func crossSiteSecFetchIs403() async throws {
        let harness = try await ServerHarness.started()
        let crossSite = try await harness.get("/v1/models", headers: ["Sec-Fetch-Site: cross-site"])
        #expect(crossSite.status == 403)
        #expect(errorCode(crossSite) == "cross_site")
        #expect(try await harness.get("/v1/models", headers: ["Sec-Fetch-Site: same-site"]).status == 403)
        #expect(try await harness.get("/v1/models", headers: ["Sec-Fetch-Site: none"]).status == 200)
        await harness.server.stop()
    }

    @Test func forwarderPortHostNeedsExtraHostName() async throws {
        let plain = try await ServerHarness.started()
        #expect(try await plain.get("/v1/models", host: "127.0.0.1:8000").status == 421)
        await plain.server.stop()
        let forwarded = try await ServerHarness.started { $0.extraHostNames = ["127.0.0.1:8000"] }
        #expect(try await forwarded.get("/v1/models", host: "127.0.0.1:8000").status == 200)
        #expect(try await forwarded.get("/v1/models", host: "localhost:8000").status == 421)
        await forwarded.server.stop()
    }

    @Test func zeroContentLengthAccepted() async throws {
        let harness = try await ServerHarness.started()
        let response = try await harness.get("/v1/models", headers: ["Content-Length: 0"])
        #expect(response.status == 200)
        await harness.server.stop()
    }

    @Test func leadingZeroContentLengthIs400() async throws {
        let harness = try await ServerHarness.started()
        let body = Bodies.chat()
        let request = "POST /v1/chat/completions HTTP/1.1\r\nHost: \(harness.host)\r\nAuthorization: Bearer \(harness.secret)\r\n"
            + "Content-Type: application/json\r\nContent-Length: 0\(body.utf8.count)\r\n\r\n\(body)"
        #expect(try await harness.raw(request).status == 400)
        await harness.server.stop()
    }

    @Test func earlyErrorIsReadableByCurlAfterLingeringClose() async throws {
        let harness = try await ServerHarness.started()
        let client = try await RawHTTPClient.connected(port: harness.port)
        defer { client.close() }
        let size = 2 << 20
        try await client.send("POST /v1/chat/completions HTTP/1.1\r\nHost: \(harness.host)\r\n"
                              + "Authorization: Bearer \(harness.secret)\r\nContent-Type: application/json\r\n"
                              + "Content-Length: \(size)\r\n\r\n")
        let filler = Data(repeating: 0x20, count: size)
        let writer = Task { try? await client.send(filler) }
        let received = try await client.receive(until: "\r\n\r\n")
        let response = try #require(RawResponse(received))
        #expect(response.status == 413)
        writer.cancel()
        await harness.server.stop()
    }

    @Test func inflightBodyBudgetIs503() async throws {
        let harness = try await ServerHarness.started { $0.limits.inflightBodyBytes = 64 }
        let response = try await harness.chat(Bodies.chat(String(repeating: "x", count: 200)))
        #expect(response.status == 503)
        #expect(errorCode(response) == "server_busy")
        #expect(response.header("Retry-After") != nil)
        await harness.server.stop()
    }

    @Test func wrongMediaTypeIs415() async throws {
        let harness = try await ServerHarness.started()
        let response = try await harness.raw(harness.chatRequest(Bodies.chat(), contentType: "text/plain"))
        #expect(response.status == 415)
        await harness.server.stop()
    }

    @Test func oversizedChatBodyIs413BeforeReading() async throws {
        let harness = try await ServerHarness.started { $0.limits.chatBodyBytes = 16 }
        #expect(try await harness.chat(Bodies.chat()).status == 413)
        await harness.server.stop()
    }
}
