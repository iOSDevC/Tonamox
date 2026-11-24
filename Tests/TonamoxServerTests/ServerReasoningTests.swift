import Foundation
import Testing
@testable import TonamoxCore
@testable import TonamoxServer

@MainActor
private func reasoningModel(_ pieces: [String]) -> ScriptedChatModel {
    let model = ScriptedChatModel(pieces: pieces)
    model.splitsReasoning = true
    return model
}

/// Deltas of every streamed chunk, in order.
private func deltas(_ response: RawResponse) -> [[String: Any]] {
    events(response.text).compactMap { payload in
        let choices = json(Data(payload.utf8))["choices"] as? [[String: Any]]
        return choices?.first?["delta"] as? [String: Any]
    }
}

private func message(_ response: RawResponse) -> [String: Any] {
    let choices = json(response.body)["choices"] as? [[String: Any]]
    return choices?.first?["message"] as? [String: Any] ?? [:]
}

private func finishReason(_ response: RawResponse) -> String? {
    (json(response.body)["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String
}

@MainActor
@Suite(.serialized)
struct ServerReasoningTests {
    static let splitTags = ["<th", "ink>", "Plan ", "it.", "</thi", "nk>\n", "Hel", "lo"]

    @Test func streamSendsReasoningAndAnswerInSeparateFields() async throws {
        let harness = try await ServerHarness.started(model: reasoningModel(Self.splitTags))
        let response = try await harness.chat(Bodies.stream())
        #expect(response.status == 200)
        let all = deltas(response)
        let reasoning = all.compactMap { $0["reasoning_content"] as? String }
        let content = all.compactMap { $0["content"] as? String }
        #expect(reasoning.joined() == "Plan it.")
        #expect(content.joined() == "Hello")
        #expect(!content.contains { $0.contains("<") || $0.contains("Plan") })
        let firstAnswer = try #require(all.firstIndex { ($0["content"] as? String)?.isEmpty == false })
        let lastReasoning = try #require(all.lastIndex { $0["reasoning_content"] != nil })
        #expect(lastReasoning < firstAnswer)
        #expect(all.allSatisfy { !($0["reasoning_content"] != nil && $0["content"] != nil) })
        await harness.server.stop()
    }

    @Test func nonStreamReturnsAnswerAsContentAndReasoningApart() async throws {
        let harness = try await ServerHarness.started(model: reasoningModel(Self.splitTags))
        let response = try await harness.chat(Bodies.chat())
        #expect(response.status == 200)
        #expect(message(response)["content"] as? String == "Hello")
        #expect(message(response)["reasoning_content"] as? String == "Plan it.")
        #expect(finishReason(response) == "stop")
        let usage = json(response.body)["usage"] as? [String: Any]
        #expect(usage?["completion_tokens"] as? Int == 3)
        #expect(usage?["prompt_tokens"] as? Int == 5)
        await harness.server.stop()
    }

    @Test func splittingWithoutReasoningKeepsTheGoldenBytes() async throws {
        let harness = try await ServerHarness.started(model: reasoningModel(["Hello", ",", " world"]))
        let plain = try await harness.chat(try fixture("req-basic.json"))
        #expect(normalized(plain.text) == (try fixture("resp-basic.json")))
        let streamed = try await harness.chat(try fixture("req-stream.json"))
        #expect(normalized(streamed.text) == (try fixture("resp-stream.sse")))
        await harness.server.stop()
    }

    @Test func unterminatedReasoningAtTheTokenLimitLeavesTheAnswerEmpty() async throws {
        let harness = try await ServerHarness.started(model: reasoningModel(["<think>", "still ", "going", "on"]))
        let plain = try await harness.chat(Bodies.chat(extra: #""max_tokens":3"#))
        #expect(plain.status == 200)
        #expect(message(plain)["content"] as? String == "")
        #expect(message(plain)["reasoning_content"] as? String == "still going")
        #expect(finishReason(plain) == "length")

        let streamed = try await harness.chat(Bodies.stream(extra: #""max_tokens":3"#))
        let all = deltas(streamed)
        #expect(all.compactMap { $0["content"] as? String }.joined() == "")
        #expect(all.compactMap { $0["reasoning_content"] as? String }.joined() == "still going")
        #expect(events(streamed.text).contains { $0.contains(#""finish_reason":"length""#) })
        await harness.server.stop()
    }

    @Test func nonStreamWithoutReasoningHasNoReasoningField() async throws {
        let harness = try await ServerHarness.started(model: reasoningModel(["\n Answer <think>x"]))
        let response = try await harness.chat(Bodies.chat())
        #expect(message(response)["content"] as? String == "\n Answer <think>x")
        #expect(message(response)["reasoning_content"] == nil)
        let streamed = try await harness.chat(Bodies.stream())
        #expect(deltas(streamed).compactMap { $0["content"] as? String }.joined() == "\n Answer <think>x")
        await harness.server.stop()
    }

    static let templateOpened = ["Let me check… ", "```bash\nrm -rf build\n```", "</th", "ink>\n\n", "Use ", "make clean."]

    @Test func nonStreamSplitsATemplateOpenedReplyOnTheWholeOutput() async throws {
        let harness = try await ServerHarness.started(model: reasoningModel(Self.templateOpened))
        let response = try await harness.chat(Bodies.chat())
        #expect(message(response)["content"] as? String == "Use make clean.")
        #expect(message(response)["reasoning_content"] as? String == "Let me check… ```bash\nrm -rf build\n```")
        await harness.server.stop()
    }

    /// Too late to retract: the raw bytes go out, closing tag included, so a client can split them itself.
    @Test func streamPassesATemplateOpenedReplyThroughRawAfterTheAnswerStarted() async throws {
        let harness = try await ServerHarness.started(model: reasoningModel(Self.templateOpened))
        let streamed = try await harness.chat(Bodies.stream())
        let all = deltas(streamed)
        #expect(all.compactMap { $0["content"] as? String }.joined() == Self.templateOpened.joined())
        #expect(all.allSatisfy { $0["reasoning_content"] == nil })
        let resplit = ReasoningSplitter.split(Self.templateOpened.joined())
        #expect(resplit.answer == "Use make clean.")
        await harness.server.stop()
    }
}

struct ReasoningRelayTests {
    private static func text(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    private static func halves(_ bytes: [UInt8], at cut: Int) -> [String] {
        [text(bytes[..<cut]), text(bytes[cut...])]
    }

    private static func relayed(_ chunks: [String]) -> (reasoning: String, answer: String) {
        var relay = ReasoningRelay()
        var reasoning = ""
        var answer = ""
        let events = chunks.flatMap { relay.consume($0) } + relay.finish()
        for event in events {
            switch event {
            case .reasoning(let text): reasoning += text
            case .text(let text): answer += text
            case .finished, .reasoningCut: break
            }
        }
        return (reasoning, answer)
    }

    @Test func everyTwoChunkSplitMatchesTheOneShotSplit() {
        let samples = ["<think>\nThe user asks.\n</think>\nlisto",
                       "<thought>\nOctal.\n</thought>\nThe response is \"29\".",
                       "  <THINK>a</THINK> <think>b</think>\n3, 7, 19, 42",
                       "<think>never closed",
                       "plain <think>later answer",
                       "\u{FEFF}<think>bom</think> answer",
                       "<think>a<think>b</think>c</think>ans"]
        for sample in samples {
            let whole = ReasoningSplitter.split(sample)
            let bytes = Array(sample.utf8)
            // Chunks are whole strings: no cut inside a multi-byte character.
            for cut in 0...bytes.count where Self.text(bytes[..<cut]).utf8.count == cut {
                let result = Self.relayed(Self.halves(bytes, at: cut))
                #expect(result.reasoning == whole.reasoning, "\(sample) cut at \(cut)")
                #expect(result.answer == whole.answer, "\(sample) cut at \(cut)")
            }
        }
    }

    @Test func loneClosingTagInOneChunkBecomesReasoning() {
        let result = Self.relayed(["Template opened it.</think>\nAnswer"])
        #expect(result.reasoning == "Template opened it.")
        #expect(result.answer == "Answer")
    }

    @Test func loneClosingTagAfterRelayedAnswerPassesTheRawOutputThrough() {
        let result = Self.relayed(["Template ", "opened it.</th", "ink>\n", "Answer"])
        #expect(result.reasoning == "")
        #expect(result.answer == "Template opened it.</think>\nAnswer")
    }

    /// Every cut either splits like the whole output or, once answer text went out, relays the raw bytes.
    @Test func loneClosingTagAtEveryCutGivesTheSplitOrTheRawText() {
        let sample = "  Template opened it.\n</THINK>\n\nAnswer"
        let whole = ReasoningSplitter.split(sample)
        let bytes = Array(sample.utf8)
        for cut in 0...bytes.count {
            let result = Self.relayed(Self.halves(bytes, at: cut))
            let isSplit = result.reasoning == whole.reasoning && result.answer == whole.answer
            let isRaw = result.reasoning.isEmpty && result.answer == sample
            #expect(isSplit || isRaw, "cut at \(cut)")
        }
    }

    @Test func whitespaceOnlyOutputKeepsItsBytes() {
        #expect(Self.relayed([" \n", "\n"]).answer == " \n\n")
        #expect(Self.relayed(["\n", "Hi"]).answer == "\nHi")
    }
}

@MainActor
struct LocalServedModelReasoningTests {
    @Test func localModelServesALeadingThoughtBlockAsReasoning() async throws {
        let backend = MessagesFakeBackend()
        backend.pieces = ["<thou", "ght>x", "</THOUGHT>", "\nAnswer"]
        let served = try LocalServedModel(localModel(backend), id: "local", displayName: "Local",
                                          turnstile: GenerationTurnstile())
        let request = ServedChatRequest(messages: [ServedMessage(role: .user, content: "U")], maxTokens: 64,
                                        client: ClientIdentity(clientID: nil, label: "t", peer: "127.0.0.1"))
        var received: [ServedChatEvent] = []
        for try await event in served.respond(to: request).events {
            received.append(event)
        }
        #expect(received.filter { if case .finished = $0 { false } else { true } } == [.reasoning("x"), .text("Answer")])
    }

    @Test func templateThatOpensTheBlockServesTheStartAsReasoningWhileStreaming() async throws {
        let backend = MessagesFakeBackend()
        backend.pieces = ["Check ", "```sh\nrm x\n```", "</think>", "\nAnswer"]
        MessagesFakeBackend.openedTags[ObjectIdentifier(backend)] = "<think>"
        defer { MessagesFakeBackend.openedTags[ObjectIdentifier(backend)] = nil }
        let llm = localModel(backend)
        #expect(llm.promptOpenedReasoningTag == "<think>")
        let served = try LocalServedModel(llm, id: "local", displayName: "Local", turnstile: GenerationTurnstile())
        let request = ServedChatRequest(messages: [ServedMessage(role: .user, content: "U")], maxTokens: 64,
                                        client: ClientIdentity(clientID: nil, label: "t", peer: "127.0.0.1"),
                                        stream: true)
        var reasoning = ""
        var text = ""
        for try await event in served.respond(to: request).events {
            switch event {
            case .reasoning(let piece): reasoning += piece
            case .text(let piece): text += piece
            case .finished, .reasoningCut: break
            }
        }
        #expect(reasoning == "Check ```sh\nrm x\n```")
        #expect(text == "Answer")
    }
}

@MainActor
struct LocalServedModelHistoryTests {
    @Test func reasoningInsideAnAssistantTurnIsNotSentToTheModelAgain() async throws {
        let backend = MessagesFakeBackend()
        let served = try LocalServedModel(localModel(backend), id: "local", displayName: "Local",
                                          turnstile: GenerationTurnstile())
        let request = ServedChatRequest(messages: [ServedMessage(role: .user, content: "Q1"),
                                                   ServedMessage(role: .assistant,
                                                                 content: "Plan ```sh\nrm x\n```</think>\nA1"),
                                                   ServedMessage(role: .user, content: "Q2 <think>kept</think>")],
                                        maxTokens: 64,
                                        client: ClientIdentity(clientID: nil, label: "t", peer: "127.0.0.1"))
        for try await _ in served.respond(to: request).events {}
        let contents = backend.receivedMessages.map { $0["content"] ?? "" }
        #expect(contents == ["Q1", "A1", "Q2 <think>kept</think>"])
        #expect(LocalServedModel.answer(of: "No reasoning here.") == "No reasoning here.")
    }
}

/// The fake reports a template-opened tag per instance, so suites running alongside never see one.
extension MessagesFakeBackend: PromptReasoningReporting {
    static var openedTags: [ObjectIdentifier: String] = [:]

    var promptOpenedReasoningTag: String? { Self.openedTags[ObjectIdentifier(self)] }
}
