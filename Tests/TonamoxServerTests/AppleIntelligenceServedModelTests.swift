import Foundation
import Testing
@testable import TonamoxCore
@testable import TonamoxServer
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Replays cumulative snapshots like `LanguageModelSession.streamResponse`.
@MainActor
private final class FakeAppleDriver: AppleModelDriver {
    let contextSize: Int
    var snapshots: [String]
    var delay: Duration = .zero
    var usage: ServedUsage?
    /// Thrown after this many snapshots, when set.
    var failure: (afterSnapshots: Int, error: any Error)?
    /// Time a cancelled generation keeps running before it ends.
    var unwindDelay: Duration = .zero
    /// Thrown instead of `CancellationError` once a cancelled generation unwound, when set.
    var unwindFailure: (any Error)?
    private(set) var plans: [AppleChatPlan] = []
    private(set) var emitted = 0
    private(set) var isGenerating = false

    init(snapshots: [String] = ["Hel", "Hello", "Hello, wor", "Hello, world"], contextSize: Int = 4096) {
        self.snapshots = snapshots
        self.contextSize = contextSize
    }

    func generate(_ plan: AppleChatPlan, snapshot: (String) -> Void) async throws -> ServedUsage? {
        plans.append(plan)
        isGenerating = true
        defer { isGenerating = false }
        do {
            for (index, text) in snapshots.enumerated() {
                if let failure, failure.afterSnapshots == index { throw failure.error }
                if delay > .zero { try await Task.sleep(for: delay) }
                try Task.checkCancellation()
                snapshot(text)
                emitted += 1
            }
            if let failure, failure.afterSnapshots >= snapshots.count { throw failure.error }
        } catch is CancellationError {
            if unwindDelay > .zero {
                let unwind = unwindDelay
                await Task.detached { try? await Task.sleep(for: unwind) }.value
            }
            throw unwindFailure ?? CancellationError()
        }
        return usage
    }
}

private let testClient = ClientIdentity(clientID: nil, label: "t", peer: "127.0.0.1")

private func request(_ messages: [ServedMessage], maxTokens: Int = 256, stream: Bool = true,
                     reasoning: ReasoningOptions = .automatic) -> ServedChatRequest {
    ServedChatRequest(messages: messages, maxTokens: maxTokens, client: testClient, stream: stream,
                      reasoning: reasoning)
}

@MainActor
private func appleModel(_ driver: FakeAppleDriver,
                        turnstile: GenerationTurnstile? = GenerationTurnstile()) -> AppleIntelligenceServedModel {
    AppleIntelligenceServedModel(driver: driver, id: AppleIntelligenceServedModel.defaultID,
                                 displayName: AppleIntelligenceServedModel.defaultDisplayName, turnstile: turnstile)
}

@MainActor
private func collect(_ response: ServedResponse) async throws -> [ServedChatEvent] {
    var events: [ServedChatEvent] = []
    for try await event in response.events { events.append(event) }
    return events
}

private let question = [ServedMessage(role: .user, content: "Hi")]

@MainActor
@Suite struct AppleIntelligenceServedModelTests {
    @Test func infoIsOnDeviceWithTheDriversWindow() {
        let model = appleModel(FakeAppleDriver(contextSize: 4096))
        #expect(model.info.id == "apple-intelligence")
        #expect(model.info.ownedBy == "apple")
        #expect(model.info.contextLength == 4096)
        #expect(model.info.egress == .onDevice)
        #expect(model.displayName == "Apple Intelligence")
    }

    @Test func streamSendsDeltasOfCumulativeSnapshots() async throws {
        let events = try await collect(appleModel(FakeAppleDriver()).respond(to: request(question)))
        #expect(events == [.text("Hel"), .text("lo"), .text(", wor"), .text("ld"), .finished(.stop, nil)])
    }

    @Test func combiningMarkAppendedToTheLastCharacterIsSentAsItsOwnDelta() async throws {
        let driver = FakeAppleDriver(snapshots: ["cafe", "cafe\u{301}", "cafe\u{301}!"])
        let events = try await collect(appleModel(driver).respond(to: request(question)))
        #expect(events == [.text("cafe"), .text("\u{301}"), .text("!"), .finished(.stop, nil)])
    }

    @Test func snapshotThatDoesNotExtendTheSentTextIsSkipped() async throws {
        let driver = FakeAppleDriver(snapshots: ["Hello", "Hello", "Help", "Hello there"])
        let events = try await collect(appleModel(driver).respond(to: request(question)))
        #expect(events == [.text("Hello"), .text(" there"), .finished(.stop, nil)])
    }

    @Test func withoutStreamingTheLastSnapshotIsSentOnce() async throws {
        let events = try await collect(appleModel(FakeAppleDriver()).respond(to: request(question, stream: false)))
        #expect(events == [.text("Hello, world"), .finished(.stop, nil)])
    }

    @Test func reasoningOptionsAreIgnoredAndNoReasoningIsServed() async throws {
        let driver = FakeAppleDriver(snapshots: ["<think>", "<think>x</think>ok"])
        let events = try await collect(appleModel(driver).respond(to: request(question, reasoning: .budgeted(64))))
        #expect(!events.contains { if case .reasoning = $0 { true } else { false } })
        #expect(!events.contains { if case .reasoningCut = $0 { true } else { false } })
        #expect(driver.plans.first?.maxTokens == 256)
    }

    @Test func historyMapsToInstructionsTranscriptAndPrompt() async throws {
        let driver = FakeAppleDriver()
        let messages = [ServedMessage(role: .system, content: "Be brief."),
                        ServedMessage(role: .user, content: "First?"),
                        ServedMessage(role: .assistant, content: "<think>hidden</think>\nAnswer one."),
                        ServedMessage(role: .system, content: "Use Spanish."),
                        ServedMessage(role: .user, content: "Second?")]
        _ = try await collect(appleModel(driver).respond(to: request(messages, maxTokens: 99)))
        let plan = try #require(driver.plans.first)
        #expect(plan == AppleChatPlan(instructions: "Be brief.\n\nUse Spanish.",
                                      history: [ServedMessage(role: .user, content: "First?"),
                                                ServedMessage(role: .assistant, content: "Answer one.")],
                                      prompt: "Second?", maxTokens: 99))
    }

    @Test func withoutSystemMessagesThereAreNoInstructions() throws {
        let plan = try AppleIntelligenceServedModel.plan(for: request(question))
        #expect(plan.instructions == nil)
        #expect(plan.history.isEmpty)
        #expect(plan.prompt == "Hi")
    }

    @Test func assistantTurnWithoutReasoningIsKeptAsIs() {
        let turn = ServedMessage(role: .assistant, content: "Plain <b>answer</b>")
        #expect(AppleIntelligenceServedModel.withoutReasoning(turn) == turn)
    }

    @Test func conversationEndingWithAnAssistantTurnIsRefusedBeforeGenerating() async throws {
        let driver = FakeAppleDriver()
        let messages = question + [ServedMessage(role: .assistant, content: "Prefill")]
        await #expect(throws: ServedModelError.unsupported("messages")) {
            _ = try await collect(appleModel(driver).respond(to: request(messages)))
        }
        #expect(driver.plans.isEmpty)
    }

    @Test func usageIsForwardedAndAFullAnswerEndsWithLength() async throws {
        let driver = FakeAppleDriver()
        driver.usage = ServedUsage(promptTokens: 12, completionTokens: 4)
        let cut = try await collect(appleModel(driver).respond(to: request(question, maxTokens: 4)))
        #expect(cut.last == .finished(.length, ServedUsage(promptTokens: 12, completionTokens: 4)))
        let whole = try await collect(appleModel(driver).respond(to: request(question, maxTokens: 5)))
        #expect(whole.last == .finished(.stop, ServedUsage(promptTokens: 12, completionTokens: 4)))
    }

    @Test(arguments: [ServedModelError.unsupportedLanguage, .busy, .notLoaded, .contextLengthExceeded(limit: 4096)])
    func driverFailureEndsTheStream(_ failure: ServedModelError) async throws {
        let driver = FakeAppleDriver()
        driver.failure = (afterSnapshots: 2, error: failure)
        var received: [ServedChatEvent] = []
        await #expect(throws: failure) {
            for try await event in appleModel(driver).respond(to: request(question)).events { received.append(event) }
        }
        #expect(received == [.text("Hel"), .text("lo")])
    }

    @Test func contentFilterEndsTheStreamKeepingTheTextSoFar() async throws {
        let driver = FakeAppleDriver()
        let usage = ServedUsage(promptTokens: 9, completionTokens: 2)
        driver.failure = (afterSnapshots: 2, error: AppleContentFiltered(usage: usage))
        let streamed = try await collect(appleModel(driver).respond(to: request(question)))
        #expect(streamed == [.text("Hel"), .text("lo"), .finished(.contentFilter, usage)])
        let whole = try await collect(appleModel(driver).respond(to: request(question, stream: false)))
        #expect(whole == [.text("Hello"), .finished(.contentFilter, usage)])
    }

    @Test func contentFilterBeforeAnyTextEndsWithNoText() async throws {
        let driver = FakeAppleDriver()
        driver.failure = (afterSnapshots: 0, error: AppleContentFiltered())
        #expect(try await collect(appleModel(driver).respond(to: request(question))) == [.finished(.contentFilter, nil)])
        let whole = try await collect(appleModel(driver).respond(to: request(question, stream: false)))
        #expect(whole == [.finished(.contentFilter, nil)])
    }

    @Test func cancellationStopsTheGenerationAndSettledAwaitsIt() async throws {
        let driver = FakeAppleDriver(snapshots: (1...200).map { String(repeating: "x", count: $0) })
        driver.delay = .milliseconds(20)
        driver.unwindDelay = .milliseconds(200)
        let response = appleModel(driver).respond(to: request(question))
        let consumer = Task { for try await _ in response.events {} }
        #expect(await eventually { driver.emitted >= 1 })
        consumer.cancel()
        _ = await consumer.result
        await response.settled()
        #expect(!driver.isGenerating)
        #expect(driver.emitted < 200)
    }

    @Test func cancelledGenerationEndingWithItsOwnErrorStillSettlesAfterTheUnwind() async throws {
        let driver = FakeAppleDriver(snapshots: (1...200).map { String(repeating: "x", count: $0) })
        driver.delay = .milliseconds(20)
        driver.unwindDelay = .milliseconds(200)
        driver.unwindFailure = ServedModelError.busy
        let response = appleModel(driver).respond(to: request(question))
        let consumer = Task { for try await _ in response.events {} }
        #expect(await eventually { driver.emitted >= 1 })
        consumer.cancel()
        let ended = await consumer.result
        #expect(throws: Never.self) { try ended.get() }
        await response.settled()
        #expect(!driver.isGenerating)
        #expect(driver.emitted < 200)
    }

    @Test func answersThroughTheServer() async throws {
        let driver = FakeAppleDriver()
        let harness = try await ServerHarness.started(extraModels: [appleModel(driver).served])
        let response = try await harness.chat(Bodies.chat(model: "apple-intelligence"))
        #expect(response.status == 200)
        let choices = json(response.body)["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        #expect(message?["content"] as? String == "Hello, world")
        #expect(choices?.first?["finish_reason"] as? String == "stop")
        #expect(json(response.body)["usage"] == nil)
        await harness.server.stop()
    }

    @Test func contentFilterBeforeAnyTextIsServedAsAnEmptyAnswer() async throws {
        let driver = FakeAppleDriver()
        driver.failure = (afterSnapshots: 0, error: AppleContentFiltered())
        let harness = try await ServerHarness.started(extraModels: [appleModel(driver).served])
        let response = try await harness.chat(Bodies.chat(model: "apple-intelligence"))
        #expect(response.status == 200)
        let choices = json(response.body)["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        #expect(message?["content"] as? String == "")
        #expect(choices?.first?["finish_reason"] as? String == "content_filter")
        #expect(json(response.body)["error"] == nil)
        await harness.server.stop()
    }

    @Test func contentFilterKeepsThePartialAnswerWithoutStreaming() async throws {
        let driver = FakeAppleDriver()
        driver.failure = (afterSnapshots: 3, error: AppleContentFiltered(usage: ServedUsage(promptTokens: 5,
                                                                                           completionTokens: 3)))
        let harness = try await ServerHarness.started(extraModels: [appleModel(driver).served])
        let response = try await harness.chat(Bodies.chat(model: "apple-intelligence"))
        #expect(response.status == 200)
        let body = json(response.body)
        let choices = body["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        #expect(message?["content"] as? String == "Hello, wor")
        #expect(choices?.first?["finish_reason"] as? String == "content_filter")
        #expect((body["usage"] as? [String: Any])?["completion_tokens"] as? Int == 3)
        await harness.server.stop()
    }

    @Test func contentFilterEndsAStreamWithItsFinishReasonThenDone() async throws {
        let driver = FakeAppleDriver()
        driver.failure = (afterSnapshots: 2, error: AppleContentFiltered())
        let harness = try await ServerHarness.started(extraModels: [appleModel(driver).served])
        let response = try await harness.chat(Bodies.chat(model: "apple-intelligence", extra: #""stream":true"#))
        #expect(response.status == 200)
        let frames = events(response.text)
        #expect(frames.last == "[DONE]")
        let chunks = frames.dropLast().map { json(Data($0.utf8)) }
        #expect(chunks.allSatisfy { $0["error"] == nil })
        let choices = chunks.compactMap { ($0["choices"] as? [[String: Any]])?.first }
        let text = choices.compactMap { ($0["delta"] as? [String: Any])?["content"] as? String }.joined()
        #expect(text == "Hello")
        #expect(choices.last?["finish_reason"] as? String == "content_filter")
        #expect(choices.dropLast().allSatisfy { $0["finish_reason"] is NSNull })
        await harness.server.stop()
    }

    @Test func contentFilterIsNoLongerAnErrorCode() {
        let language = APIError.from(ServedModelError.unsupportedLanguage, suspended: false)
        #expect(language.status == 400)
        #expect(language.code == "unsupported_language")
        #expect(FinishReason.contentFilter.rawValue == "content_filter")
    }
}

#if canImport(FoundationModels)
@MainActor
@Suite struct SystemModelDriverTests {
    @Test func currentModelErrorsMapToServedErrors() throws {
        guard #available(macOS 27, iOS 27, visionOS 27, *) else { return }
        let exceeded = LanguageModelError.ContextSizeExceeded(contextSize: 8192, tokenCount: 9000, debugDescription: "t")
        let cases: [(any Error, ServedModelError)] = [
            (LanguageModelError.contextSizeExceeded(exceeded), .contextLengthExceeded(limit: 8192)),
            (LanguageModelError.unsupportedLanguageOrLocale(.init(languageCode: .init("xx"), debugDescription: "t")),
             .unsupportedLanguage),
            (LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "t")), .busy),
            (LanguageModelError.timeout(.init(debugDescription: "t")), .busy),
            (SystemLanguageModel.Error.assetsUnavailable(.init(debugDescription: "t")), .notLoaded),
            (LanguageModelSession.Error.concurrentRequests, .busy)
        ]
        for (error, expected) in cases {
            #expect(SystemModelDriver.failure(from: error) as? ServedModelError == expected)
        }
        let filtered = AppleContentFiltered(usage: ServedUsage(promptTokens: 4, completionTokens: 2))
        let filters: [any Error] = [LanguageModelError.guardrailViolation(.init(debugDescription: "t")),
                                    LanguageModelError.refusal(.init(explanation: "no", debugDescription: "t"))]
        for error in filters {
            #expect(SystemModelDriver.failure(from: error, usage: filtered.usage) as? AppleContentFiltered == filtered)
            #expect(SystemModelDriver.mapped(error) == nil)
        }
        let unmapped = SystemModelDriver.failure(from: LanguageModelSession.Error.transcriptMutationWhileResponding)
        #expect(unmapped as? ServedModelError == nil)
    }

    @Test func cancellationPassesThroughUnmapped() {
        guard #available(macOS 27, iOS 27, visionOS 27, *) else { return }
        #expect(SystemModelDriver.failure(from: CancellationError()) is CancellationError)
    }

    @Test func planBecomesInstructionsThenAlternatingTurns() throws {
        guard #available(macOS 27, iOS 27, visionOS 27, *) else { return }
        let plan = AppleChatPlan(instructions: "Be brief.",
                                 history: [ServedMessage(role: .user, content: "First?"),
                                           ServedMessage(role: .assistant, content: "Answer one.")],
                                 prompt: "Second?", maxTokens: 50)
        let entries = Array(SystemModelDriver.transcript(for: plan))
        #expect(entries.count == 3)
        guard entries.count == 3 else { return }
        guard case .instructions(let instructions) = entries[0], case .prompt(let prompt) = entries[1],
              case .response(let response) = entries[2] else {
            Issue.record("unexpected entry kinds")
            return
        }
        #expect(texts(instructions.segments) == ["Be brief."])
        #expect(texts(prompt.segments) == ["First?"])
        #expect(texts(response.segments) == ["Answer one."])
        let bare = SystemModelDriver.transcript(for: AppleChatPlan(instructions: nil, history: [], prompt: "Q",
                                                                   maxTokens: 1))
        #expect(bare.isEmpty)
    }

    @available(macOS 27, iOS 27, visionOS 27, *)
    private func texts(_ segments: [Transcript.Segment]) -> [String] {
        segments.compactMap { segment in
            guard case .text(let text) = segment else { return nil }
            return text.content
        }
    }
}
#endif
