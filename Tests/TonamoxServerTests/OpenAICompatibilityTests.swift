import Foundation
import Testing
import TonamoxCore
import TonamoxHTTP
@testable import TonamoxServer

func decode(_ body: String, limits: ServerLimits = ServerLimits()) -> Result<ChatCompletionRequest, APIError> {
    Result { () throws(APIError) -> ChatCompletionRequest in
        try ChatCompletionDecoder.decode(Data(body.utf8), limits: limits)
    }
}

func rejectedParam(_ body: String) -> String? {
    guard case .failure(let error) = decode(body), error.code == "unsupported_parameter" else { return nil }
    return error.param
}

@Suite("OpenAI compatibility", .serialized)
@MainActor
struct OpenAICompatibilityTests {
    @Test func decodesStringContent() throws {
        let request = try decode(Bodies.chat("Hello")).get()
        #expect(request.messages == [ServedMessage(role: .user, content: "Hello")])
        #expect(request.model == "scripted")
        #expect(!request.stream)
        #expect(request.maxTokens == 1024)
    }

    @Test func decodesTextPartsArray() throws {
        let body = #"{"model":"m","messages":[{"role":"system","content":"S"},{"role":"user","content":[{"type":"text","text":"a"},{"type":"text","text":"b"}]},{"role":"assistant","content":null},{"role":"user","content":"c"}]}"#
        let request = try decode(body).get()
        #expect(request.messages.map(\.content) == ["S", "ab", "", "c"])
        #expect(request.messages.map(\.role) == [.system, .user, .assistant, .user])
    }

    @Test func rejectsImageParts() {
        let body = #"{"model":"m","messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"x"}}]}]}"#
        #expect(rejectedParam(body) == "messages.content.image_url")
    }

    @Test func rejectsTools() {
        #expect(rejectedParam(Bodies.chat(extra: #""tools":[{"type":"function"}]"#)) == "tools")
        #expect(rejectedParam(Bodies.chat(extra: #""tool_choice":"auto""#)) == "tool_choice")
        #expect(rejectedParam(Bodies.chat(extra: #""tools":null"#)) == nil)
        #expect(rejectedParam(Bodies.chat(extra: #""response_format":{"type":"json_object"}"#)) == "response_format")
        #expect(rejectedParam(Bodies.chat(extra: #""response_format":{"type":"text"}"#)) == nil)
    }

    @Test func rejectsNGreaterThanOne() {
        #expect(rejectedParam(Bodies.chat(extra: #""n":2"#)) == "n")
        #expect(rejectedParam(Bodies.chat(extra: #""n":1"#)) == nil)
    }

    @Test func rejectsStop() {
        #expect(rejectedParam(Bodies.chat(extra: #""stop":"\n""#)) == "stop")
        #expect(rejectedParam(Bodies.chat(extra: #""stop":["x"]"#)) == "stop")
        #expect(rejectedParam(Bodies.chat(extra: #""stop":[]"#)) == nil)
    }

    @Test func rejectsToolRole() {
        let tool = #"{"model":"m","messages":[{"role":"user","content":"a"},{"role":"tool","content":"b"}]}"#
        #expect(rejectedParam(tool) == "messages.role")
        let developer = #"{"model":"m","messages":[{"role":"developer","content":"a"},{"role":"user","content":"b"}]}"#
        #expect(rejectedParam(developer) == "messages.role")
    }

    @Test func ignoresTemperatureAndListsItInHeader() async throws {
        let harness = try await ServerHarness.started()
        let response = try await harness.chat(Bodies.chat(extra: #""temperature":0.1,"seed":3,"x_custom":true"#))
        #expect(response.status == 200)
        #expect(response.header("X-Tonamox-Ignored-Params") == "seed, temperature, x_custom")
        #expect(try await harness.chat(Bodies.chat()).header("X-Tonamox-Ignored-Params") == nil)
        await harness.server.stop()
    }

    @Test func ignoredParamsHeaderCannotBeSplitOrInflated() async throws {
        let harness = try await ServerHarness.started()
        let many = (0..<40).map { String(format: #""k%02d":0"#, $0) }.joined(separator: ",")
        let hostile = #""a\r\nX-Evil: 1":0,"é":0,"\#(String(repeating: "x", count: 65))":0,"#
        let response = try await harness.chat(Bodies.chat(extra: hostile + many))
        #expect(response.status == 200)
        #expect(response.header("X-Evil") == nil)
        let reported = try #require(response.header("X-Tonamox-Ignored-Params")).components(separatedBy: ", ")
        #expect(reported == (0..<32).map { String(format: "k%02d", $0) })
        await harness.server.stop()
    }

    @Test func responseHeadDropsFieldsThatWouldSplitIt() {
        let head = HTTPResponseHead(status: 200, fields: [HTTPField(name: "X-A", value: "1\r\nX-Evil: 1"),
                                                          HTTPField(name: "X B", value: "1"),
                                                          HTTPField(name: "X-C", value: "caf\u{e9}"),
                                                          HTTPField(name: "X-Ok", value: "fine\tvalue")])
        #expect(String(decoding: head.serialized, as: UTF8.self) == "HTTP/1.1 200 OK\r\nX-Ok: fine\tvalue\r\n\r\n")
    }

    @Test func clampsMaxTokens() throws {
        #expect(try decode(Bodies.chat(extra: #""max_tokens":999999"#)).get().maxTokens == 4096)
        #expect(try decode(Bodies.chat(extra: #""max_tokens":0"#)).get().maxTokens == 1)
        #expect(try decode(Bodies.chat(extra: #""max_tokens":-5"#)).get().maxTokens == 1)
        guard case .failure(let error) = decode(Bodies.chat(extra: #""max_tokens":"ten""#)) else {
            Issue.record("a string max_tokens must be refused")
            return
        }
        #expect(error.status == 400)
    }

    @Test func prefersMaxCompletionTokens() throws {
        let request = try decode(Bodies.chat(extra: #""max_tokens":10,"max_completion_tokens":20"#)).get()
        #expect(request.maxTokens == 20)
    }

    @Test func unknownModelIs404() async throws {
        let harness = try await ServerHarness.started()
        let response = try await harness.chat(Bodies.chat(model: "nope"))
        #expect(response.status == 404)
        #expect(errorCode(response) == "model_not_found")
        #expect(try await harness.get("/v1/models/nope").status == 404)
        #expect(try await harness.get("/v1/models/scripted").status == 200)
        await harness.server.stop()
    }

    @Test func emptyMessagesIs400() async throws {
        let harness = try await ServerHarness.started()
        let empty = try await harness.chat(#"{"model":"scripted","messages":[]}"#)
        #expect(empty.status == 400)
        #expect(errorCode(empty) == "invalid_messages")
        let noUser = try await harness.chat(#"{"model":"scripted","messages":[{"role":"system","content":"x"}]}"#)
        #expect(noUser.status == 400)
        #expect(try await harness.chat("not json").status == 400)
        await harness.server.stop()
    }

    @Test func nonStreamMatchesGolden() async throws {
        let harness = try await ServerHarness.started()
        let response = try await harness.chat(try fixture("req-basic.json"))
        #expect(response.status == 200)
        #expect(response.header("Content-Type") == "application/json")
        #expect(normalized(response.text) == (try fixture("resp-basic.json")))
        #expect(harness.model.requests.last?.messages.map(\.role) == [.system, .user])
        await harness.server.stop()
    }

    @Test func streamMatchesGolden() async throws {
        let harness = try await ServerHarness.started()
        let response = try await harness.chat(try fixture("req-stream.json"))
        #expect(response.status == 200)
        #expect(response.header("Content-Type") == "text/event-stream; charset=utf-8")
        #expect(response.header("X-Accel-Buffering") == "no")
        #expect(response.header("Content-Length") == nil)
        #expect(normalized(response.text) == (try fixture("resp-stream.sse")))
        await harness.server.stop()
    }

    @Test func usageChunkOnlyWithIncludeUsage() async throws {
        let harness = try await ServerHarness.started()
        let without = try await harness.chat(Bodies.stream())
        #expect(!without.text.contains("\"usage\""))
        #expect(without.text.hasSuffix("data: [DONE]\n\n"))
        let with = try await harness.chat(Bodies.stream(includeUsage: true))
        #expect(events(with.text).contains { $0.contains(#""choices":[]"#) && $0.contains("\"usage\"") })
        await harness.server.stop()
    }

    @Test func omitsUsageWhenUnknown() async throws {
        let model = ScriptedChatModel(usage: nil)
        let harness = try await ServerHarness.started(model: model)
        let plain = try await harness.chat(Bodies.chat())
        #expect(json(plain.body)["usage"] == nil)
        let streamed = try await harness.chat(Bodies.stream(includeUsage: true))
        #expect(!streamed.text.contains("\"usage\""))
        await harness.server.stop()
    }

    @Test func finishReasonLengthAtCap() async throws {
        let harness = try await ServerHarness.started()
        let response = try await harness.chat(Bodies.chat(extra: #""max_tokens":2"#))
        let choice = (json(response.body)["choices"] as? [[String: Any]])?.first
        #expect(choice?["finish_reason"] as? String == "length")
        #expect((choice?["message"] as? [String: Any])?["content"] as? String == "Hello,")
        #expect(harness.model.requests.last?.maxTokens == 2)
        await harness.server.stop()
    }

    @Test func midStreamErrorHasNoDONE() async throws {
        let model = ScriptedChatModel()
        model.failure = (afterPieces: 1, error: .notLoaded)
        let harness = try await ServerHarness.started(model: model)
        let response = try await harness.chat(Bodies.stream())
        #expect(response.status == 200)
        let frames = events(response.text)
        #expect(frames.contains { $0.contains(#""content":"Hello""#) })
        #expect(frames.last?.contains(#""code":"model_unavailable""#) == true)
        #expect(!response.text.contains("[DONE]"))
        await harness.server.stop()
    }

    @Test func errorObjectShapeForEveryCode() {
        let errors: [APIError] = [
            .unsupported("tools"), .invalidJSON(), .invalidMessages("x"), .missingKey, .invalidKey, .expiredKey,
            .insufficientScope, .originNotAllowed, .crossSite, .notFound, .modelNotFound("m"), .misdirected,
            .tooLarge, .mediaType, .rateLimited, .authFlood, .serverBusy, .bodyBudget, .appBackgrounded,
            .modelUnavailable, .modelChanged, .internalError, .contextLengthExceeded(limit: 8),
            .methodNotAllowed("GET"), .http(.init(status: 505, reason: "x")),
        ]
        for error in errors {
            let object = json(error.body)
            #expect(object.keys.sorted() == ["error"])
            let inner = object["error"] as? [String: Any] ?? [:]
            #expect(inner.keys.sorted() == ["code", "message", "param", "type"])
            #expect(inner["message"] is String && inner["type"] is String && inner["code"] is String)
            #expect(inner["param"] is String || inner["param"] is NSNull)
        }
    }

    @Test func modelsListMatchesGolden() async throws {
        let harness = try await ServerHarness.started()
        let response = try await harness.get("/v1/models")
        #expect(response.status == 200)
        #expect(normalized(response.text) == (try fixture("resp-models.json")))
        await harness.server.stop()
    }

    @Test func deeplyNestedJSONIs400() async throws {
        let harness = try await ServerHarness.started()
        let nested = String(repeating: "[", count: 20) + String(repeating: "]", count: 20)
        let response = try await harness.chat(Bodies.chat(extra: "\"metadata\":\(nested)"))
        #expect(response.status == 400)
        #expect(errorCode(response) == "invalid_json")
        await harness.server.stop()
    }

    @Test func promptOverContextIs400ContextLengthExceeded() async throws {
        let model = ScriptedChatModel(contextLength: 200)
        let harness = try await ServerHarness.started(model: model)
        let response = try await harness.chat(Bodies.chat(String(repeating: "x", count: 600), extra: #""max_tokens":10"#))
        #expect(response.status == 400)
        #expect(errorCode(response) == "context_length_exceeded")
        #expect(model.started == 0)
        #expect(try await harness.chat(Bodies.chat("short", extra: #""max_tokens":10"#)).status == 200)
        await harness.server.stop()
    }

    @Test func reasoningBudgetShrinksToFitTheContext() async throws {
        let model = ScriptedChatModel(contextLength: 8192)
        let harness = try await ServerHarness.started(model: model)
        let body = Bodies.chat("short", extra: #""max_tokens":4096,"reasoning_effort":"high""#)
        #expect(try await harness.chat(body).status == 200)
        let prompt = TonamoxServer.estimatedTokens([ServedMessage(role: .user, content: "short")])
        let budget = try #require(model.requests.last?.reasoning.budget)
        #expect(budget == 8192 - prompt - 4096 - TonamoxServer.reasoningCloseAllowance)
        await harness.server.stop()
    }

    @Test func fittedReasoningKeepsWhatFitsAndRefusesAnOverfullAnswer() {
        let high = ReasoningOptions.budgeted(4096)
        #expect(TonamoxServer.fittedReasoning(high, promptTokens: 10, maxTokens: 512, window: 8192) == high)
        let squeezed = TonamoxServer.fittedReasoning(high, promptTokens: 100, maxTokens: 4096, window: 8192)
        #expect(squeezed?.budget == 8192 - 100 - 4096 - TonamoxServer.reasoningCloseAllowance)
        #expect(squeezed?.thinking == .automatic)
        #expect(TonamoxServer.fittedReasoning(high, promptTokens: 4070, maxTokens: 4096, window: 8192)?.budget == 0)
        #expect(TonamoxServer.fittedReasoning(.disabled, promptTokens: 4000, maxTokens: 4096, window: 8192) == .disabled)
        #expect(TonamoxServer.fittedReasoning(high, promptTokens: 4097, maxTokens: 4096, window: 8192) == nil)
    }
}
