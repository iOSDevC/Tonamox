import Darwin
import Foundation
import LocalLLMClient
import Testing
@testable import TonamoxCore
import TonamoxHTTP
@testable import TonamoxServer

/// Occupies 127.0.0.1:`port` with a plain BSD listener.
final class PortSquatter {
    let descriptor: Int32

    init?(port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            Darwin.close(fd)
            return nil
        }
        descriptor = fd
    }

    deinit { Darwin.close(descriptor) }
}

@Suite("Server lifecycle", .serialized)
@MainActor
struct ServerLifecycleTests {
    @Test func backgroundStopsListenerAndReportsSuspended() async throws {
        let harness = try await ServerHarness.started()
        harness.post(background: true)
        #expect(await eventually { harness.server.state == .suspended(.appBackgrounded) })
        await #expect(throws: RawHTTPClient.Refused.self) {
            _ = try await RawHTTPClient.connected(port: harness.port)
        }
        await harness.server.stop()
    }

    @Test func inflightStreamGetsAppBackgroundedError() async throws {
        let model = ScriptedChatModel(pieces: Array(repeating: "tick ", count: 200), delay: .milliseconds(20))
        let harness = try await ServerHarness.started(model: model)
        let (client, _) = try await harness.openStream(Bodies.stream(extra: #""max_tokens":500"#))
        _ = try await client.receive(until: "tick")
        harness.post(background: true)
        let rest = String(decoding: try await client.receiveAll(), as: UTF8.self)
        #expect(events(rest).last?.contains(#""code":"app_backgrounded""#) == true)
        #expect(!rest.contains("[DONE]"))
        #expect(await eventually { model.running == 0 })
        client.close()
        await harness.server.stop()
    }

    @Test func foregroundRebindsSamePort() async throws {
        let harness = try await ServerHarness.started()
        let port = harness.port
        #expect(try await harness.get("/v1/models").status == 200)
        harness.post(background: true)
        #expect(await eventually { harness.server.state == .suspended(.appBackgrounded) })
        harness.post(background: false)
        let listening = ServerState.listening(ServerEndpoint(host: "127.0.0.1", port: port, exposure: .loopback))
        #expect(await eventually { harness.server.state == listening }, "state: \(harness.server.state)")
        #expect(try await harness.get("/v1/models").status == 200, "the key survives the suspension")
        await harness.server.stop()
    }

    @Test func resumeAfterStreamsRebindsSamePort() async throws {
        let model = ScriptedChatModel(pieces: Array(repeating: "tick ", count: 200), delay: .milliseconds(20))
        let harness = try await ServerHarness.started(model: model)
        let port = harness.port
        model.pieces = ["a", "b"]
        #expect(try await harness.chat(Bodies.stream()).status == 200)
        model.pieces = Array(repeating: "tick ", count: 200)
        let (client, _) = try await harness.openStream(Bodies.stream(extra: #""max_tokens":500"#))
        _ = try await client.receive(until: "tick")
        await harness.server.suspend(.appBackgrounded)
        _ = try await client.receiveAll()
        client.close()
        try await harness.server.resume()
        let listening = ServerState.listening(ServerEndpoint(host: "127.0.0.1", port: port, exposure: .loopback))
        #expect(harness.server.state == listening)
        #expect(try await harness.get("/v1/models").status == 200)
        await harness.server.stop()
    }

    @Test func requestArrivingDuringSuspendDrainIsNotServed() async throws {
        let harness = try await ServerHarness.started()
        let idle = try await RawHTTPClient.connected(port: harness.port)
        #expect(await eventually { harness.server.transport?.openCount == 1 })
        let suspension = Task { await harness.server.suspend(.appBackgrounded) }
        #expect(await eventually { harness.server.closingReason != nil })
        var answer: RawResponse?
        if let late = try? await RawHTTPClient.connected(port: harness.port) {
            try? await late.send(harness.chatRequest(Bodies.chat()))
            answer = (try? await late.receiveResponse()).flatMap(RawResponse.init)
            late.close()
        }
        #expect(answer?.status != 200, "served during the drain: \(String(describing: answer?.status))")
        await suspension.value
        idle.close()
        #expect(harness.server.state == .suspended(.appBackgrounded))
        await harness.server.stop()
    }

    @Test func stopWhileStartingEndsStopped() async throws {
        let harness = ServerHarness()
        let starting = Task { try await harness.server.start() }
        while harness.server.state != .starting { await Task.yield() }
        await harness.server.stop()
        _ = try? await starting.value
        #expect(harness.server.state == .stopped)
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.server.state == .stopped)
    }

    @Test func resumeDuringSuspendDrainWaitsForTheClose() async throws {
        let harness = try await ServerHarness.started()
        let port = harness.port
        let idle = try await RawHTTPClient.connected(port: port)
        #expect(await eventually { harness.server.transport?.openCount == 1 })
        let suspension = Task { await harness.server.suspend(.appBackgrounded) }
        #expect(await eventually { harness.server.state == .suspended(.appBackgrounded) })
        try await harness.server.resume()
        await suspension.value
        idle.close()
        let listening = ServerState.listening(ServerEndpoint(host: "127.0.0.1", port: port, exposure: .loopback))
        #expect(harness.server.state == listening)
        #expect(try await harness.get("/v1/models").status == 200)
        await harness.server.stop()
    }

    @Test func portTakenOnResumeReportsPortInUse() async throws {
        let harness = try await ServerHarness.started()
        let port = harness.port
        harness.post(background: true)
        #expect(await eventually { harness.server.state == .suspended(.appBackgrounded) })
        let squatter = try #require(PortSquatter(port: port))
        harness.post(background: false)
        #expect(await eventually { harness.server.state == .failed(.portInUse(port)) })
        withExtendedLifetime(squatter) {}
        await harness.server.stop()
    }

    @Test func stopEndsStreamsAndClosesPort() async throws {
        let model = ScriptedChatModel(pieces: Array(repeating: "tick ", count: 200), delay: .milliseconds(20))
        let harness = try await ServerHarness.started(model: model)
        let (client, _) = try await harness.openStream(Bodies.stream(extra: #""max_tokens":500"#))
        _ = try await client.receive(until: "tick")
        await harness.server.stop()
        let rest = String(decoding: try await client.receiveAll(), as: UTF8.self)
        #expect(!rest.contains("[DONE]"))
        #expect(client.sawEnd)
        #expect(harness.server.state == .stopped)
        #expect(await eventually { model.running == 0 })
        await #expect(throws: RawHTTPClient.Refused.self) {
            _ = try await RawHTTPClient.connected(port: harness.port)
        }
    }

    @Test func noTokenOrKeyInLogMessages() async throws {
        let harness = try await ServerHarness.started()
        let other = try harness.server.issueAPIKey(label: "second")
        _ = try await harness.get("/v1/models")
        _ = try await harness.get("/v1/models", key: other.secret)
        _ = try await harness.get("/v1/models", key: "tnx_" + String(repeating: "Q", count: 43))
        _ = try await harness.chat(Bodies.chat())
        _ = try await harness.raw("GET /v1/models?key=tnx_x HTTP/1.1\r\nHost: \(harness.host)\r\n\r\n")
        harness.server.revoke(other.client.id)
        await harness.server.stop()
        let lines = harness.logs.all
        #expect(!lines.isEmpty)
        let secrets = [harness.secret, other.secret, "tnx_"]
        #expect(!lines.contains { line in
            secrets.contains { line.message.contains($0) || (line.peer ?? "").contains($0) }
        })
    }
}

@Suite("LocalServedModel", .serialized)
@MainActor
struct LocalServedModelTests {
    @Test func streamsDeltasFromMessages() async throws {
        let backend = MessagesFakeBackend()
        let served = try LocalServedModel(localModel(backend), id: "local", displayName: "Local",
                                          turnstile: GenerationTurnstile())
        let request = ServedChatRequest(messages: [ServedMessage(role: .system, content: "S"),
                                                   ServedMessage(role: .user, content: "U")],
                                        maxTokens: 64, client: ClientIdentity(clientID: nil, label: "t", peer: "127.0.0.1"))
        var received: [ServedChatEvent] = []
        for try await event in served.respond(to: request).events {
            received.append(event)
        }
        #expect(Array(received.prefix(3)) == [.text("A"), .text("B"), .text("C")])
        #expect(backend.receivedMessages == [["role": "system", "content": "S"], ["role": "user", "content": "U"]])
        #expect(served.info.egress == .onDevice)
    }

    @Test func settledReturnsOnlyAfterTheCancelledDecodeStopped() async throws {
        let backend = MessagesFakeBackend()
        backend.pieces = Array(repeating: "x", count: 200)
        backend.delay = .milliseconds(20)
        let served = try LocalServedModel(localModel(backend), id: "local", displayName: "Local",
                                          turnstile: GenerationTurnstile())
        let client = ClientIdentity(clientID: nil, label: "t", peer: "127.0.0.1")
        let response = served.respond(to: ServedChatRequest(messages: [ServedMessage(role: .user, content: "U")],
                                                            maxTokens: 500, client: client))
        let consumer = Task { for try await _ in response.events {} }
        #expect(await eventually { backend.emitted >= 1 })
        consumer.cancel()
        _ = await consumer.result
        await response.settled()
        #expect(!backend.isGenerating)
        #expect(backend.emitted < 200)
    }

    @Test func usageFromGenerationStats() async throws {
        let backend = MessagesFakeBackend()
        backend.stats = GenerationStats(backend: .llamaCpp, source: .measured, promptTokens: 7, generatedTokens: 3,
                                        promptTime: 0, timeToFirstToken: 0, decodeTime: 0)
        let served = try LocalServedModel(localModel(backend), id: "local", displayName: "Local",
                                          turnstile: GenerationTurnstile())
        let client = ClientIdentity(clientID: nil, label: "t", peer: "127.0.0.1")
        var last: ServedChatEvent?
        for try await event in served.respond(to: ServedChatRequest(messages: [ServedMessage(role: .user, content: "U")],
                                                                     maxTokens: 64, client: client)).events {
            last = event
        }
        #expect(last == .finished(.stop, ServedUsage(promptTokens: 7, completionTokens: 3)))
        #expect(LocalServedModel.summary(backend.stats, maxTokens: 3).0 == .length)
        let unknown = LocalServedModel.summary(nil, maxTokens: 3)
        #expect(unknown.0 == .stop)
        #expect(unknown.1 == nil)
    }

    @Test func generationInterruptedMapsTo503() async throws {
        let backend = MessagesFakeBackend()
        backend.failure = GenerationInterrupted(reason: .appBackgrounded, partialText: "AB")
        let served = try LocalServedModel(localModel(backend), id: "local", displayName: "Local",
                                          turnstile: GenerationTurnstile())
        let harness = try await ServerHarness.started(extraModels: [served.served])
        let response = try await harness.chat(Bodies.chat(model: "local"))
        #expect(response.status == 503)
        #expect(errorCode(response) == "model_unavailable")
        await harness.server.stop()
    }

    @Test func llamaDecodeFailureMapsToModelUnavailable() async throws {
        let backend = MessagesFakeBackend()
        backend.pieces = []
        backend.failure = LLMError.failedToDecode(reason: "batch decode failed")
        let served = try LocalServedModel(localModel(backend), id: "local", displayName: "Local",
                                          turnstile: GenerationTurnstile())
        let harness = try await ServerHarness.started(extraModels: [served.served])
        let streamed = try await harness.chat(Bodies.chat(model: "local", extra: #""stream":true"#))
        #expect(streamed.status == 200)
        #expect(events(streamed.text).last?.contains(#""code":"model_unavailable""#) == true)
        #expect(!streamed.text.contains("[DONE]"))
        let plain = try await harness.chat(Bodies.chat(model: "local"))
        #expect(plain.status == 503)
        #expect(errorCode(plain) == "model_unavailable")
        await harness.server.stop()
        #expect(harness.logs.all.contains {
            $0.message == "stream ended with model_unavailable (LocalLLMClientCore.LLMError.failedToDecode)"
        })
        #expect(harness.logs.all.contains {
            $0.message == "chat ended with model_unavailable (LocalLLMClientCore.LLMError.failedToDecode)"
        })
    }

    @Test func llamaDecodeFailureExcludesFullWindowAndOtherErrors() {
        #expect(LlamaDecodeFailure.matches(LLMError.failedToDecode(reason: "batch decode failed")))
        #expect(!LlamaDecodeFailure.matches(LLMError.failedToDecode(reason: "context size exceeded[4096 < 4100]")))
        #expect(!LlamaDecodeFailure.matches(LLMError.invalidParameter(reason: "x")))
    }

    @Test func unrecognisedFailureLogsItsKindWithoutPayload() async throws {
        enum UnexpectedFailure: Error { case leaked(String) }
        let canary = "canary-7f3a-prompt-text"
        let backend = MessagesFakeBackend()
        backend.failure = UnexpectedFailure.leaked(canary)
        let served = try LocalServedModel(localModel(backend), id: "local", displayName: "Local",
                                          turnstile: GenerationTurnstile())
        let harness = try await ServerHarness.started(extraModels: [served.served])
        let streamed = try await harness.chat(Bodies.chat(model: "local", extra: #""stream":true"#))
        #expect(events(streamed.text).last?.contains(#""code":"internal""#) == true)
        let plain = try await harness.chat(Bodies.chat(model: "local"))
        #expect(plain.status == 500)
        await harness.server.stop()
        let lines = harness.logs.all.map(\.message)
        #expect(lines.contains { $0.hasPrefix("stream ended with internal (") && $0.hasSuffix("UnexpectedFailure.leaked)") })
        #expect(lines.contains { $0.hasPrefix("chat ended with internal (") && $0.hasSuffix("UnexpectedFailure.leaked)") })
        #expect(!lines.contains { $0.contains(canary) })
    }

    @Test func toolEnabledInstanceIsRefused() throws {
        #expect(throws: ServedModelError.toolsNotAllowed) {
            _ = try LocalServedModel(localModel(MessagesFakeBackend(), toolsEnabled: true), id: "x", displayName: "X",
                                     turnstile: GenerationTurnstile())
        }
    }
}
