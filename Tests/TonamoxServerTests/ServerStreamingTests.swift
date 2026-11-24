import Foundation
import Testing
import TonamoxCore
@testable import TonamoxServer

@Suite("Interop and streaming", .serialized)
@MainActor
struct ServerStreamingTests {
    func provider(_ harness: ServerHarness, streaming: Bool) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(id: "test.server", displayName: "Tonamox server",
                                 baseURL: URL(string: "http://127.0.0.1:\(harness.port)/v1")!,
                                 apiKey: harness.secret, streaming: streaming)
    }

    func collect(_ stream: AsyncThrowingStream<RemoteEvent, Error>) async throws -> (String, TokenUsage?) {
        var text = ""
        var usage: TokenUsage?
        for try await event in stream {
            switch event {
            case .token(let token): text += token
            case .usage(let reported): usage = reported
            case .reasoning: break
            }
        }
        return (text, usage)
    }

    @Test func openAICompatibleProviderStreamsFromServer() async throws {
        let harness = try await ServerHarness.started()
        let request = RemoteRequest(model: "scripted", messages: [["role": "user", "content": "Hi"]], maxTokens: 64)
        let (text, _) = try await collect(provider(harness, streaming: true).stream(request))
        #expect(text == "Hello, world")
        await harness.server.stop()
    }

    @Test func openAICompatibleProviderNonStreaming() async throws {
        let harness = try await ServerHarness.started()
        let request = RemoteRequest(model: "scripted", system: "Be brief.", messages: [["role": "user", "content": "Hi"]])
        let (text, usage) = try await collect(provider(harness, streaming: false).stream(request))
        #expect(text == "Hello, world")
        #expect(usage == TokenUsage(inputTokens: 5, outputTokens: 3))
        #expect(harness.model.requests.last?.messages.first?.role == .system)
        await harness.server.stop()
    }

    @Test func providerSeesUsage() async throws {
        let harness = try await ServerHarness.started()
        let request = RemoteRequest(model: "scripted", messages: [["role": "user", "content": "Hi"]])
        let (_, usage) = try await collect(provider(harness, streaming: true).stream(request))
        #expect(usage == TokenUsage(inputTokens: 5, outputTokens: 3))
        await harness.server.stop()
    }

    @Test func cancellingConsumerCancelsGeneration() async throws {
        let model = ScriptedChatModel(pieces: Array(repeating: "tick ", count: 200), delay: .milliseconds(20))
        let harness = try await ServerHarness.started(model: model)
        let request = RemoteRequest(model: "scripted", messages: [["role": "user", "content": "Hi"]], maxTokens: 500)
        var received = 0
        for try await event in provider(harness, streaming: true).stream(request) {
            if case .token = event { received += 1 }
            if received == 2 { break }
        }
        #expect(await eventually { model.cancelled == 1 })
        #expect(model.running == 0)
        await harness.server.stop()
    }

    @Test func clientDisconnectCancelsGeneration() async throws {
        let model = ScriptedChatModel(pieces: Array(repeating: "tick ", count: 200), delay: .milliseconds(20))
        let harness = try await ServerHarness.started(model: model)
        let (client, _) = try await harness.openStream(Bodies.stream(extra: #""max_tokens":500"#))
        _ = try await client.receive(until: "tick")
        client.close()
        #expect(await eventually { model.cancelled == 1 })
        #expect(await eventually { model.running == 0 })
        await harness.server.stop()
    }

    @Test func oneGenerationAtATime() async throws {
        let model = ScriptedChatModel(pieces: ["a", "b", "c", "d"], delay: .milliseconds(20))
        let harness = try await ServerHarness.started(model: model)
        async let first = harness.chat(Bodies.chat())
        async let second = harness.chat(Bodies.chat())
        let statuses = [try await first.status, try await second.status]
        #expect(statuses == [200, 200])
        #expect(model.started == 2)
        #expect(model.maxConcurrent == 1)
        await harness.server.stop()
    }

    @Test func queuedRequestWaitsForCancelledDecodeToUnwind() async throws {
        let model = ScriptedChatModel(pieces: Array(repeating: "tick ", count: 200), delay: .milliseconds(20))
        model.unwindDelay = .milliseconds(400)
        let harness = try await ServerHarness.started(model: model)
        let (first, _) = try await harness.openStream(Bodies.stream(extra: #""max_tokens":500"#))
        _ = try await first.receive(until: "tick")
        model.pieces = ["a"]
        async let queued = harness.chat(Bodies.chat())
        let turnstile = try #require(harness.server.turnstile(for: "scripted"))
        #expect(await eventually { turnstile.queuedCount == 1 })
        first.close()
        #expect(try await queued.status == 200)
        #expect(model.started == 2)
        #expect(model.maxConcurrent == 1)
        await harness.server.stop()
    }

    @Test func thirdQueuedRequestIs429WithRetryAfter() async throws {
        let model = ScriptedChatModel(pieces: Array(repeating: "tick ", count: 500), delay: .milliseconds(20))
        let harness = try await ServerHarness.started(model: model)
        let turnstile = try #require(harness.server.turnstile(for: "scripted"))
        let running = try await harness.openStream(Bodies.stream(extra: #""max_tokens":500"#))
        #expect(await eventually { model.running == 1 })
        let queued = [try await harness.openStream(Bodies.stream(extra: #""max_tokens":500"#)),
                      try await harness.openStream(Bodies.stream(extra: #""max_tokens":500"#))]
        #expect(await eventually { turnstile.queuedCount == 2 })
        let refused = try await harness.chat(Bodies.chat())
        #expect(refused.status == 429)
        #expect(errorCode(refused) == "server_busy")
        #expect(refused.header("Retry-After") == "5")
        ([running] + queued).forEach { $0.0.close() }
        await harness.server.stop()
    }

    @Test func appAndServerShareTurnstile() async throws {
        let model = ScriptedChatModel()
        let harness = try await ServerHarness.started(model: model)
        let turnstile = try #require(harness.server.turnstile(for: "scripted"))
        let appTurn = Task { @MainActor in
            try await turnstile.run { try await Task.sleep(for: .milliseconds(400)) }
        }
        #expect(await eventually { turnstile.isBusy })
        let started = ContinuousClock.now
        let response = try await harness.chat(Bodies.chat())
        #expect(response.status == 200)
        #expect(ContinuousClock.now - started >= .milliseconds(250), "the request waited for the app's turn")
        try await appTurn.value
        await harness.server.stop()
    }

    @Test func keepAliveSentWhileWaiting() async throws {
        let harness = try await ServerHarness.started { $0.limits.keepAliveInterval = .milliseconds(100) }
        let turnstile = try #require(harness.server.turnstile(for: "scripted"))
        let appTurn = Task { @MainActor in
            try await turnstile.run { try await Task.sleep(for: .milliseconds(600)) }
        }
        #expect(await eventually { turnstile.isBusy })
        let response = try await harness.chat(Bodies.stream())
        let text = response.text
        let keepAlive = try #require(text.range(of: ": keep-alive\n\n"))
        let firstContent = try #require(text.range(of: "\"content\":\"Hello\""))
        #expect(keepAlive.lowerBound < firstContent.lowerBound)
        #expect(text.hasSuffix("data: [DONE]\n\n"))
        try await appTurn.value
        await harness.server.stop()
    }

    @Test func setModelsEndsRunningStreamWithModelChanged() async throws {
        let model = ScriptedChatModel(pieces: Array(repeating: "tick ", count: 200), delay: .milliseconds(20))
        let harness = try await ServerHarness.started(model: model)
        let (client, _) = try await harness.openStream(Bodies.stream(extra: #""max_tokens":500"#))
        _ = try await client.receive(until: "tick")
        harness.server.setModels([])
        let rest = String(decoding: try await client.receiveAll(), as: UTF8.self)
        #expect(events(rest).last?.contains(#""code":"model_changed""#) == true)
        #expect(!rest.contains("[DONE]"))
        #expect(harness.server.servedModels.isEmpty)
        #expect(try await harness.get("/v1/models/scripted").status == 404)
        client.close()
        await harness.server.stop()
    }

    @Test func statesAndEventsFanOutToTwoConsumers() async throws {
        let harness = ServerHarness()
        let firstStates = harness.server.states()
        let secondStates = harness.server.states()
        let firstEvents = harness.server.events()
        let secondEvents = harness.server.events()
        try await harness.start()
        for stream in [firstStates, secondStates] {
            #expect(await Self.firstListening(stream) == harness.port)
        }
        for stream in [firstEvents, secondEvents] {
            #expect(await Self.firstKeyIssued(stream) == harness.key?.client.id)
        }
        await harness.server.stop()
    }

    static func firstListening(_ stream: AsyncStream<ServerState>) async -> UInt16? {
        for await state in stream {
            if case .listening(let endpoint) = state { return endpoint.port }
        }
        return nil
    }

    static func firstKeyIssued(_ stream: AsyncStream<ServerEvent>) async -> UUID? {
        for await event in stream {
            if case .keyIssued(let id) = event { return id }
        }
        return nil
    }
}
