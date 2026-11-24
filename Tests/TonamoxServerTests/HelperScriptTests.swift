import CryptoKit
import Foundation
import Testing
@testable import TonamoxServer

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private var scriptSourceURL: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/TonamoxServer/Embedded/tnx-run.sh")
}

/// Runs `/bin/sh -c line` with a private TMPDIR; returns the exit status and standard output.
private func runShell(_ line: String, tmp: URL) async throws -> (status: Int32, stdout: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", line]
    process.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": tmp.path(percentEncoded: false)]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    let status: Int32 = try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            continuation.resume(throwing: error)
        }
    }
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return (status, text)
}

@Suite("Helper scripts", .serialized)
@MainActor
struct HelperScriptTests {
    @Test func scriptHashMatchesPublishedConstant() {
        #expect(HelperScript.tnxRun.sha256 == HelperScript.tnxRunSHA256)
        #expect(sha256Hex(HelperScript.tnxRun.bytes) == HelperScript.tnxRunSHA256)
        #expect(HelperScript.tnxRun.servedHash == HelperScript.tnxRunSHA256)
    }

    @Test func embeddedBytesEqualSourceFile() throws {
        #expect(try Data(contentsOf: scriptSourceURL) == HelperScript.tnxRun.bytes)
    }

    @Test func scriptsAreASCIIWithLFOnly() {
        #expect(HelperScript.all.count <= 8)
        for script in HelperScript.all {
            #expect(script.bytes.count <= 64 * 1024)
            #expect(script.bytes.allSatisfy { $0 == 0x0A || (0x20...0x7E).contains($0) }, "\(script.name)")
            #expect(script.bytes.last == 0x0A)
            #expect(script.name.hasSuffix(".sh"))
        }
    }

    @Test func scriptServedByteExact() async throws {
        let harness = try await ServerHarness.ingesting()
        let response = try await harness.raw("GET /s/tnx-run.sh HTTP/1.1\r\nHost: \(harness.host)\r\n\r\n")
        #expect(response.status == 200)
        #expect(response.body == HelperScript.tnxRun.bytes)
        #expect(response.header("Content-Type") == "text/plain; charset=us-ascii")
        #expect(response.header("Cache-Control") == "no-store")
        await harness.server.stop()
    }

    @Test func scriptETagIsSHA256() async throws {
        let harness = try await ServerHarness.ingesting()
        let response = try await harness.get("/s/tnx-run.sh")
        #expect(response.header("ETag") == "\"\(sha256Hex(response.body))\"")
        #expect(response.header("ETag") == "\"\(HelperScript.tnxRunSHA256)\"")
        await harness.server.stop()
    }

    @Test func scriptNameValidation() async throws {
        let harness = try await ServerHarness.ingesting()
        let notFound = try await harness.get("/nope")
        for path in ["/s/tnx-run", "/s/TNX-RUN.sh", "/s/tnx-run.sh.bak", "/s/", "/s/tnx-run.shx", "/s/x/tnx-run.sh"] {
            let response = try await harness.get(path)
            #expect(response.status == 404, "\(path)")
            #expect(response.body == notFound.body, "\(path)")
        }
        #expect(try await harness.get("/s/../tnx-run.sh").status == 400)
        #expect(try await harness.get("/s/%74nx-run.sh").status == 400)
        #expect(try await harness.get("/s/tnx-run.sh", method: "POST").status == 411)
        #expect(HelperScript.named("tnx-run.sh") == .tnxRun)
        #expect(HelperScript.named("tnx-run") == nil)
        await harness.server.stop()
    }

    @Test func unknownScriptIs404() async throws {
        let harness = try await ServerHarness.ingesting()
        let unknown = try await harness.get("/s/other.sh")
        #expect(unknown.status == 404)
        #expect(unknown.body == (try await harness.get("/nope")).body)
        await harness.server.stop()
    }

    @Test func crossSiteScriptFetchIs403() async throws {
        let harness = try await ServerHarness.ingesting()
        #expect(try await harness.get("/s/tnx-run.sh", headers: ["Sec-Fetch-Site: cross-site"]).status == 403)
        #expect(try await harness.get("/s/tnx-run.sh", headers: ["Origin: http://evil.example"]).status == 403)
        await harness.server.stop()
    }

    @Test func scriptFetchesAreRateLimited() async throws {
        let harness = try await ServerHarness.ingesting { $0.limits.scriptFetchesPerMinute = 3 }
        var statuses: [Int] = []
        for _ in 0..<4 {
            statuses.append(try await harness.get("/s/tnx-run.sh").status)
        }
        #expect(statuses == [200, 200, 200, 429])
        await harness.server.stop()
    }

    @Test func scriptParsesUnderPOSIXShell() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tnx-sh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("tnx-run.sh")
        try HelperScript.tnxRun.bytes.write(to: file)
        let result = try await runShell("sh -n '\(file.path(percentEncoded: false))'", tmp: tmp)
        #expect(result.status == 0, "\(result.stdout)")
        let usage = try await runShell("sh '\(file.path(percentEncoded: false))' http://x/i/y", tmp: tmp)
        #expect(usage.status == 2)
        let quoted = try await runShell("echo 'http://x/i/y\"' | sh '\(file.path(percentEncoded: false))' -- true",
                                        tmp: tmp)
        #expect(quoted.status == 2, "a URL that could escape the curl config is refused")
    }

    @Test func runLineKeepsTicketOutOfProcessArguments() throws {
        let endpoint = ServerEndpoint(host: "127.0.0.1", port: 47830, exposure: .loopback)
        let ticket = IngestTicket(id: UUID(), label: "x", expiresAt: Date(), maxBytes: 1,
                                  secret: String(repeating: "A", count: 43))
        let url = ticket.url(on: endpoint).absoluteString
        let line = HelperScript.tnxRun.runLine(on: endpoint, ticket: ticket, command: "make test")
        #expect(line.hasSuffix(" && echo '\(url)' | sh \"$f\" -- make test"))
        #expect(line.components(separatedBy: url).count == 2)
        let script = String(decoding: HelperScript.tnxRun.bytes, as: UTF8.self)
        #expect(script.contains(#"printf 'url = "%s"\n' "$url" | curl -sS -K - "#))
        #expect(!script.contains(#""$url" -"#) && !script.contains(#"-H "X-Tonamox-Exit-Status: $status" "$url""#))
    }

    /// End to end on 127.0.0.1 with the system curl and shasum: fetch, verify, run a harmless command, post.
    @Test func runLineFetchesVerifiesRunsAndPostsExitStatus() async throws {
        let harness = try await ServerHarness.ingesting()
        let endpoint = try #require({ if case .listening(let endpoint) = harness.server.state { endpoint } else { nil } }())
        let ticket = try await harness.server.ingest.makeTicket(label: "e2e")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tnx-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let line = HelperScript.tnxRun.runLine(on: endpoint, ticket: ticket, command: "sh -c 'printf hello; exit 3'")
        // macOS mktemp ignores TMPDIR without a template, so the shell removes the downloaded script itself.
        let result = try await runShell(line + "; s=$?; rm -f \"$f\"; exit $s", tmp: tmp)
        #expect(result.status == 3, "\(result.stdout)")
        #expect(result.stdout.contains("tonamox: received 5 bytes for e2e"), "\(result.stdout)")
        let output = try await harness.nextOutput()
        #expect(output.text == "hello")
        #expect(output.exitStatus == 3)
        await harness.server.stop()
    }

    @Test func tamperedHashFailsBeforeRunning() async throws {
        let harness = try await ServerHarness.ingesting()
        let endpoint = try #require({ if case .listening(let endpoint) = harness.server.state { endpoint } else { nil } }())
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tnx-bad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let wrong = HelperScript(name: "tnx-run.sh", sha256: String(repeating: "0", count: 64), bytes: Data())
        let marker = tmp.appendingPathComponent("ran").path(percentEncoded: false)
        let line = wrong.fetchAndVerifyLine(on: endpoint) + " && touch '\(marker)'; s=$?; rm -f \"$f\"; exit $s"
        let result = try await runShell(line, tmp: tmp)
        #expect(result.status != 0)
        #expect(!FileManager.default.fileExists(atPath: marker))
        await harness.server.stop()
    }
}
