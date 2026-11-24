import Foundation
import Testing
@testable import TonamoxServer

extension ServerHarness {
    static func ingesting(configure: (inout ServerConfiguration) -> Void = { _ in }) async throws -> ServerHarness {
        try await started { configuration in
            configuration.features = [.openAIAPI, .ingest, .scripts]
            configure(&configuration)
        }
    }

    func ingestHead(_ ticket: IngestTicket, length: Int, headers: [String] = []) -> String {
        ingestHead(path: "/i/\(ticket.secret)", length: length, headers: headers)
    }

    func ingestHead(path: String, length: Int, headers: [String] = []) -> String {
        let lines = ["POST \(path) HTTP/1.1", "Host: \(host)", "Content-Type: application/octet-stream",
                     "Content-Length: \(length)"] + headers
        return lines.joined(separator: "\r\n") + "\r\n\r\n"
    }

    func postOutput(_ ticket: IngestTicket, _ body: String, headers: [String] = []) async throws -> RawResponse {
        try await raw(ingestHead(ticket, length: body.utf8.count, headers: headers) + body)
    }

    func nextOutput() async throws -> IngestedOutput {
        let inbox = server.ingest
        return try await withTimeout(.seconds(5)) {
            var iterator = inbox.outputs.makeAsyncIterator()
            guard let output = await iterator.next() else { throw RawHTTPClient.TimedOut() }
            return output
        }
    }

    func nextRefusal() async throws -> IngestRefusal {
        let inbox = server.ingest
        return try await withTimeout(.seconds(5)) {
            var iterator = inbox.refusals.makeAsyncIterator()
            guard let refusal = await iterator.next() else { throw RawHTTPClient.TimedOut() }
            return refusal
        }
    }
}

/// Mirrors TerminalBridgeKit's `CommandTextPolicy` (one printable-ASCII line, 1-512 bytes, no blank at either end),
/// which the SDK cannot import.
func fitsTypedLinePolicy(_ line: String) -> Bool {
    let bytes = Array(line.utf8)
    guard !bytes.isEmpty, bytes.count <= 512, bytes.first != 0x20, bytes.last != 0x20 else { return false }
    return bytes.allSatisfy { (0x20...0x7E).contains($0) }
}

func isPrintableASCIILine(_ data: Data) -> Bool {
    guard data.last == 0x0A else { return false }
    return data.dropLast().allSatisfy { (0x20...0x7E).contains($0) }
}

@Suite("Server ingest", .serialized)
@MainActor
struct IngestTests {
    @Test func ingestAndScriptsAreOffByDefault() async throws {
        let harness = try await ServerHarness.started()
        let ticket = try await harness.server.ingest.makeTicket(label: "x")
        let notFound = try await harness.get("/nope")
        let posted = try await harness.postOutput(ticket, "hi")
        let script = try await harness.get("/s/tnx-run.sh")
        #expect(posted.status == 404 && script.status == 404)
        #expect(posted.body == notFound.body && script.body == notFound.body)
        await harness.server.stop()
    }

    @Test func deliversBytesAndExitStatus() async throws {
        let harness = try await ServerHarness.ingesting()
        let ticket = try await harness.server.ingest.makeTicket(label: "build")
        let response = try await harness.postOutput(ticket, "hello\n", headers: ["X-Tonamox-Exit-Status: 3"])
        #expect(response.status == 200)
        #expect(response.text == "tonamox: received 6 bytes for build\n")
        #expect(response.header("Content-Type") == "text/plain; charset=us-ascii")
        let output = try await harness.nextOutput()
        #expect(output.ticketID == ticket.id)
        #expect(output.label == "build")
        #expect(output.rawBytes == Data("hello\n".utf8))
        #expect(output.text == "hello\n")
        #expect(output.exitStatus == 3)
        #expect(output.peer == "127.0.0.1")
        #expect(output.peerMatchesLock)
        await harness.server.stop()
    }

    @Test func emptyOutputIsDeliveredWithoutExitStatus() async throws {
        let harness = try await ServerHarness.ingesting()
        let ticket = try await harness.server.ingest.makeTicket(label: "quiet")
        #expect(try await harness.postOutput(ticket, "").status == 200)
        let output = try await harness.nextOutput()
        #expect(output.rawBytes.isEmpty)
        #expect(output.exitStatus == nil)
        await harness.server.stop()
    }

    @Test func ticketSingleUseSecondPostIs409() async throws {
        let harness = try await ServerHarness.ingesting()
        let ticket = try await harness.server.ingest.makeTicket(label: "once")
        #expect(try await harness.postOutput(ticket, "first").status == 200)
        let second = try await harness.postOutput(ticket, "forged")
        #expect(second.status == 409)
        #expect(second.text.contains("[ticket_used]"))
        let output = try await harness.nextOutput()
        #expect(output.text == "first")
        #expect(try await harness.nextRefusal() == IngestRefusal(ticketID: ticket.id, reason: .used))
        await harness.server.stop()
    }

    @Test func concurrentPostIs409TicketInUse() async throws {
        let harness = try await ServerHarness.ingesting()
        let ticket = try await harness.server.ingest.makeTicket(label: "race")
        let holder = try await RawHTTPClient.connected(port: harness.port)
        defer { holder.close() }
        try await holder.send(harness.ingestHead(ticket, length: 10) + "12345")
        try await Task.sleep(for: .milliseconds(200))
        let racer = try await harness.postOutput(ticket, "racer")
        #expect(racer.status == 409)
        #expect(racer.text.contains("[ticket_in_use]"))
        #expect(try await harness.nextRefusal() == IngestRefusal(ticketID: ticket.id, reason: .inUse))
        try await holder.send("67890")
        let held = try #require(RawResponse(try await holder.receiveResponse()))
        #expect(held.status == 200)
        #expect(try await harness.nextOutput().text == "1234567890")
        await harness.server.stop()
    }

    @Test func incompleteBodyReleasesReservation() async throws {
        let harness = try await ServerHarness.ingesting()
        let ticket = try await harness.server.ingest.makeTicket(label: "retry")
        let dropped = try await RawHTTPClient.connected(port: harness.port)
        try await dropped.send(harness.ingestHead(ticket, length: 100) + "partial")
        try await Task.sleep(for: .milliseconds(100))
        dropped.close()
        var status = 0
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(100))
            status = try await harness.postOutput(ticket, "complete").status
            if status != 409 { break }
        }
        #expect(status == 200)
        #expect(try await harness.nextOutput().text == "complete")
        await harness.server.stop()
    }

    @Test func stalledIngestBodyReleasesWithinIngestDeadline() async throws {
        let harness = try await ServerHarness.ingesting { $0.limits.ingestBodyTimeoutBase = .milliseconds(500) }
        let ticket = try await harness.server.ingest.makeTicket(label: "stall")
        let staller = try await RawHTTPClient.connected(port: harness.port)
        defer { staller.close() }
        let started = ContinuousClock.now
        try await staller.send(harness.ingestHead(ticket, length: 100) + "x")
        _ = try await staller.receiveAll(timeout: .seconds(5))
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(staller.sawEnd)
        #expect(try await harness.postOutput(ticket, "real").status == 200)
        await harness.server.stop()
    }

    @Test func expiredTicketIs410() async throws {
        let harness = try await ServerHarness.ingesting()
        let ticket = try await harness.server.ingest.makeTicket(label: "late", ttl: .milliseconds(50))
        try await Task.sleep(for: .milliseconds(150))
        let response = try await harness.postOutput(ticket, "late")
        #expect(response.status == 410)
        #expect(response.text.contains("[ticket_expired]"))
        await harness.server.stop()
    }

    @Test func unknownAndCancelledTicketsAre404() async throws {
        let harness = try await ServerHarness.ingesting()
        let ticket = try await harness.server.ingest.makeTicket(label: "gone")
        await harness.server.ingest.cancel(ticket.id)
        let notFound = try await harness.get("/nope")
        let cancelled = try await harness.postOutput(ticket, "x")
        let unknown = try await harness.raw(harness.ingestHead(path: "/i/" + String(repeating: "A", count: 43), length: 1) + "x")
        let short = try await harness.raw(harness.ingestHead(path: "/i/abc", length: 1) + "x")
        let statuses: [Int] = [cancelled.status, unknown.status, short.status]
        #expect(statuses == [404, 404, 404])
        #expect(cancelled.body == notFound.body && unknown.body == notFound.body && short.body == notFound.body)
        await harness.server.stop()
    }

    @Test func overMaxBytesIs413AndKeepsTicket() async throws {
        let harness = try await ServerHarness.ingesting()
        let ticket = try await harness.server.ingest.makeTicket(label: "small", maxBytes: 8)
        let large = try await harness.postOutput(ticket, "0123456789")
        #expect(large.status == 413)
        #expect(try await harness.postOutput(ticket, "01234567").status == 200)
        await harness.server.stop()
    }

    @Test func ingestRejectsOriginHeader() async throws {
        let harness = try await ServerHarness.ingesting()
        let ticket = try await harness.server.ingest.makeTicket(label: "origin")
        let sameOrigin = try await harness.postOutput(ticket, "x", headers: ["Origin: http://\(harness.host)"])
        let foreign = try await harness.postOutput(ticket, "x", headers: ["Origin: http://evil.example"])
        #expect(sameOrigin.status == 403 && foreign.status == 403)
        #expect(try await harness.postOutput(ticket, "x").status == 200)
        await harness.server.stop()
    }

    @Test func ingestRejectsSecFetchHeaders() async throws {
        let harness = try await ServerHarness.ingesting()
        let ticket = try await harness.server.ingest.makeTicket(label: "fetch")
        for header in ["Sec-Fetch-Site: same-origin", "Sec-Fetch-Mode: no-cors", "sec-fetch-dest: empty"] {
            #expect(try await harness.postOutput(ticket, "x", headers: [header]).status == 403)
        }
        #expect(try await harness.postOutput(ticket, "x").status == 200)
        await harness.server.stop()
    }

    @Test func expectContinueOnlyAfterTicketCheck() async throws {
        let harness = try await ServerHarness.ingesting()
        let unknown = try await RawHTTPClient.connected(port: harness.port)
        defer { unknown.close() }
        try await unknown.send(harness.ingestHead(path: "/i/" + String(repeating: "B", count: 43), length: 4,
                                                  headers: ["Expect: 100-continue"]))
        let refused = String(decoding: try await unknown.receiveResponse(), as: UTF8.self)
        #expect(refused.hasPrefix("HTTP/1.1 404 "))
        #expect(!refused.contains("100 Continue"))

        let ticket = try await harness.server.ingest.makeTicket(label: "expect")
        let client = try await RawHTTPClient.connected(port: harness.port)
        defer { client.close() }
        try await client.send(harness.ingestHead(ticket, length: 4, headers: ["Expect: 100-continue"]))
        let interim = String(decoding: try await client.receive(until: "\r\n\r\n"), as: UTF8.self)
        #expect(interim.hasPrefix("HTTP/1.1 100 Continue\r\n"))
        try await client.send("data")
        let final = String(decoding: try await client.receiveAll(), as: UTF8.self)
        #expect(final.contains("HTTP/1.1 200 OK"))
        await harness.server.stop()
    }

    @Test func rejectsNonDecimalExitStatus() async throws {
        let harness = try await ServerHarness.ingesting()
        let ticket = try await harness.server.ingest.makeTicket(label: "status")
        let bad = [["X-Tonamox-Exit-Status: abc"], ["X-Tonamox-Exit-Status: +1"], ["X-Tonamox-Exit-Status: 1.0"],
                   ["X-Tonamox-Exit-Status: 99999999999"], ["X-Tonamox-Exit-Status: 0x1"],
                   ["X-Tonamox-Exit-Status: 1", "X-Tonamox-Exit-Status: 2"]]
        for headers in bad {
            let response = try await harness.postOutput(ticket, "x", headers: headers)
            #expect(response.status == 400, "\(headers)")
            #expect(response.text.contains("[invalid_header]"))
        }
        #expect(try await harness.postOutput(ticket, "x", headers: ["X-Tonamox-Exit-Status: -1"]).status == 200)
        #expect(try await harness.nextOutput().exitStatus == -1)
        await harness.server.stop()
    }

    @Test func responseIsPrintableASCII() async throws {
        let harness = try await ServerHarness.ingesting()
        let inbox = harness.server.ingest
        let used = try await inbox.makeTicket(label: "used")
        let small = try await inbox.makeTicket(label: "small", maxBytes: 1)
        let late = try await inbox.makeTicket(label: "late", ttl: .milliseconds(20))
        try await Task.sleep(for: .milliseconds(60))
        let responses = [
            try await harness.postOutput(used, "\u{1B}]0;pwned\u{07}ok"),
            try await harness.postOutput(used, "again"),
            try await harness.postOutput(small, "too large"),
            try await harness.postOutput(late, "x"),
            try await harness.postOutput(small, "x", headers: ["Origin: http://evil.example"]),
            try await harness.postOutput(small, "x", headers: ["X-Tonamox-Exit-Status: no"]),
            try await harness.get("/i/\(small.secret)"),
        ]
        #expect(responses.map(\.status) == [200, 409, 413, 410, 403, 400, 405])
        for response in responses {
            #expect(isPrintableASCIILine(response.body), "\(response.status): \(response.text)")
            #expect(response.header("Content-Type") == "text/plain; charset=us-ascii")
        }
        await harness.server.stop()
    }

    @Test func labelSanitized() async throws {
        let harness = ServerHarness()
        let inbox = harness.server.ingest
        let hostile = try await inbox.makeTicket(label: "\u{1B}[31mbuild; rm -rf /\u{202E}\u{FC}\n" + String(repeating: "a", count: 60))
        #expect(hostile.label.unicodeScalars.allSatisfy { scalar in
            scalar.properties.isAlphabetic && scalar.isASCII || "0123456789 ._-".unicodeScalars.contains(scalar)
        })
        #expect(hostile.label.count <= 40)
        #expect(hostile.label.hasPrefix("31mbuild rm -rf"))
        #expect(try await inbox.makeTicket(label: "\u{200B}\u{1B}").label == "output")
        #expect(!hostile.description.contains(hostile.secret))
        #expect(!"\(hostile)".contains(hostile.secret))
    }

    @Test func ticketLimitsAreEnforced() async throws {
        let harness = ServerHarness()
        let inbox = harness.server.ingest
        await #expect(throws: IngestError.invalidMaxBytes(limit: 16 << 20)) {
            try await inbox.makeTicket(label: "x", maxBytes: (16 << 20) + 1)
        }
        await #expect(throws: IngestError.invalidLifetime) { try await inbox.makeTicket(label: "x", ttl: .zero) }
        for _ in 0..<32 { _ = try await inbox.makeTicket(label: "x") }
        await #expect(throws: IngestError.tooManyTickets(limit: 32)) { try await inbox.makeTicket(label: "x") }
    }

    @Test func ticketSizeCappedByInflightBodyBudget() async throws {
        let harness = ServerHarness { $0.limits.inflightBodyBytes = 8 << 20 }
        let inbox = harness.server.ingest
        await #expect(throws: IngestError.invalidMaxBytes(limit: 8 << 20)) {
            try await inbox.makeTicket(label: "x", maxBytes: 12 << 20)
        }
        #expect(try await inbox.makeTicket(label: "x", maxBytes: 8 << 20).maxBytes == 8 << 20)
    }

    @Test func curlSuffixFitsCommandTextPolicyBudget() throws {
        let endpoint = ServerEndpoint(host: "255.255.255.255", port: 65_535, exposure: .loopback)
        let ticket = IngestTicket(id: UUID(), label: "x", expiresAt: Date(), maxBytes: 1,
                                  secret: String(repeating: "A", count: 43))
        let suffix = ticket.curlSuffix(on: endpoint)
        #expect(suffix == " 2>&1 | curl -sS --data-binary @- http://255.255.255.255:65535/i/" + ticket.secret)
        #expect(suffix.utf8.count <= 108)
        #expect(fitsTypedLinePolicy("ls -la" + suffix))
        #expect(fitsTypedLinePolicy("git status --short" + suffix))
        let run = HelperScript.tnxRun.runLine(on: endpoint, ticket: ticket, command: "make test")
        #expect(fitsTypedLinePolicy(run))
        #expect(fitsTypedLinePolicy(HelperScript.tnxRun.fetchAndVerifyLine(on: endpoint, verifier: .sha256sum)))
    }

    @Test func stopEndsTickets() async throws {
        let harness = try await ServerHarness.ingesting()
        let ticket = try await harness.server.ingest.makeTicket(label: "stop")
        await harness.server.stop()
        try await harness.start()
        #expect(try await harness.postOutput(ticket, "x").status == 404)
        await harness.server.stop()
    }

    @Test func noTicketInLogsOrActivity() async throws {
        let harness = try await ServerHarness.ingesting()
        let ticket = try await harness.server.ingest.makeTicket(label: "log")
        _ = try await harness.postOutput(ticket, "x")
        _ = try await harness.postOutput(ticket, "x")
        #expect(!harness.logs.all.contains { $0.message.contains(ticket.secret) })
        #expect(!harness.server.activity.contains { $0.route.contains(ticket.secret) })
        #expect(harness.server.activity.contains { $0.route == "/i/{ticket}" && $0.status == 200 })
        await harness.server.stop()
    }
}
