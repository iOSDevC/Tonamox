import Foundation
import Synchronization
import XCTest
@testable import TonamoxCore

/// `RemoteTarget.gemini(apiKey:model:)` against a stub `URLProtocol`: request shape, the streamed-usage rule and its
/// unpriced cost. No network and no real key.
@MainActor
final class GeminiTargetTests: XCTestCase {
    private static let fakeKey = "test-not-a-real-key"

    private func stubbedGemini() throws -> RemoteTarget {
        let preset = RemoteTarget.gemini(apiKey: Self.fakeKey, model: RemoteTarget.defaultGeminiModel)
        var provider = try XCTUnwrap(preset.provider as? OpenAICompatibleProvider)
        provider.makeSession = { GeminiStreamStub.session() }
        return RemoteTarget(provider: provider, modelID: preset.modelID, contextLength: preset.contextLength,
                            origin: preset.origin)
    }

    func testPresetShape() throws {
        let target = RemoteTarget.gemini(apiKey: Self.fakeKey, model: "gemini-3.8-flash")
        XCTAssertEqual(RemoteTarget.defaultGeminiModel, "gemini-3.5-flash-lite")
        XCTAssertEqual(target.modelID, "gemini-3.8-flash")
        XCTAssertEqual(target.origin, .cloud)
        XCTAssertNil(target.contextLength)
        XCTAssertEqual(target.provider.id, "cloud.gemini")
        XCTAssertEqual(target.provider.cacheIdentity,
                       "cloud.gemini@https://generativelanguage.googleapis.com:443/v1beta/openai")
        let note = target.provider.retentionNote
        XCTAssertTrue(note.contains("free-tier"), note)
        XCTAssertTrue(note.contains("EEA, the UK or Switzerland"), note)
    }

    func testRequestOmitsTemperatureAndSendsBearer() throws {
        let provider = try XCTUnwrap(
            RemoteTarget.gemini(apiKey: Self.fakeKey, model: "m").provider as? OpenAICompatibleProvider)
        let request = try provider.makeRequest(
            RemoteRequest(model: "m", messages: [["role": "user", "content": "hola"]], maxTokens: 300, temperature: 0.2))

        XCTAssertEqual(request.url?.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.fakeKey)")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertNil(body["temperature"])
        XCTAssertEqual(body["model"] as? String, "m")
        XCTAssertEqual(body["max_tokens"] as? Int, 300)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual((body["stream_options"] as? [String: Bool])?["include_usage"], true)
    }

    func testUsageInEveryChunkKeepsTheLastReportNotASum() async throws {
        GeminiStreamStub.reset()
        let ledger = CostLedger()
        let escalator = HybridEscalator(ledger: ledger)
        let target = try stubbedGemini()

        let result = try await escalator.escalate(
            to: target, context: "", question: "q \(UUID().uuidString)", maxTokens: 64, temperature: 0.2)

        XCTAssertEqual(result.answer, "abc")
        XCTAssertEqual(result.usage, TokenUsage(inputTokens: 7, outputTokens: 4))
        XCTAssertEqual(ledger.records.last?.usage, TokenUsage(inputTokens: 7, outputTokens: 4))
        XCTAssertNil(ledger.records.last?.costUSD, "Gemini is unpriced")
        let sent = try XCTUnwrap(GeminiStreamStub.capturedBody())
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent) as? [String: Any])
        XCTAssertNil(body["temperature"], "an explicit temperature still is not sent to Gemini")
    }

    func testChunkWithAnIncompleteUsageReportsNone() {
        let line = #"data: {"choices":[],"usage":{"prompt_tokens":7}}"#
        XCTAssertTrue(OpenAICompatibleProvider.parse(line: line).isEmpty)
    }

    func testStreamedErrorAfterContentThrowsAndIsNotCached() async throws {
        GeminiStreamStub.reset(stream: GeminiStreamStub.errorStream)
        let ledger = CostLedger()
        let escalator = HybridEscalator(ledger: ledger)
        let target = try stubbedGemini()
        let question = "q \(UUID().uuidString)"

        for _ in 0..<2 {
            do {
                _ = try await escalator.escalate(to: target, context: "", question: question, maxTokens: 64)
                XCTFail("an error event must fail the escalation")
            } catch TonamoxError.remoteFailed(let code, let message) {
                XCTAssertEqual(code, 429)
                XCTAssertEqual(message, "Resource has been exhausted")
            }
        }

        XCTAssertEqual(GeminiStreamStub.requestCount(), 2, "the partial answer was not cached")
        XCTAssertEqual(ledger.records.count, 2)
        XCTAssertEqual(ledger.records.last?.isEstimated, true, "output arrived, so the call is billed as estimated")
    }

    func testStreamedErrorWithStringBodyThrows() async throws {
        GeminiStreamStub.reset(stream: "data: {\"error\":\"upstream closed\"}\n\n")
        let target = try stubbedGemini()
        do {
            _ = try await HybridEscalator(ledger: CostLedger()).escalate(
                to: target, context: "", question: "q \(UUID().uuidString)", maxTokens: 64)
            XCTFail("an error event must fail the escalation")
        } catch TonamoxError.remoteFailed(let code, let message) {
            XCTAssertEqual(code, -1)
            XCTAssertEqual(message, "upstream closed")
        }
    }

    func testTemperatureNeverSentDoesNotSplitTheCache() async throws {
        GeminiStreamStub.reset()
        let escalator = HybridEscalator(ledger: CostLedger())
        let target = try stubbedGemini()
        let question = "q \(UUID().uuidString)"

        let first = try await escalator.escalate(
            to: target, context: "", question: question, maxTokens: 64, temperature: 0.2)
        let second = try await escalator.escalate(
            to: target, context: "", question: question, maxTokens: 64, temperature: 0.5)

        XCTAssertFalse(first.fromCache)
        XCTAssertTrue(second.fromCache)
        XCTAssertEqual(GeminiStreamStub.requestCount(), 1)
    }

    func testRouteAndEscalateOffersGeminiAsCostUnknownAndDeclineSendsNothing() async throws {
        try XCTSkipUnless(NetworkMonitor.shared.isOnline, "cloud routing needs a network path (R3)")
        GeminiStreamStub.reset()
        let gate = DecliningOfferGate()

        do {
            _ = try await HybridEscalator(ledger: CostLedger()).routeAndEscalate(
                policy: EscalationPolicy(mode: .askEachTime, allowCloud: true),
                context: "short", question: "q \(UUID().uuidString)",
                localAnswer: "I'm not sure, I cannot help with that.",
                consent: gate, targets: [try stubbedGemini()])
            XCTFail("the gate declines, so routeAndEscalate must throw")
        } catch TonamoxError.escalationDeclined {}

        XCTAssertEqual(gate.offers.map(\.reason), [.costUnknown])
        XCTAssertNil(try XCTUnwrap(gate.offers.first).projectedCostUSD)
        XCTAssertEqual(GeminiStreamStub.requestCount(), 0)
    }

    func testUnpricedSoTheRouterOffersWithCostUnknown() {
        let ledger = CostLedger()
        let target = RemoteTarget.gemini(apiKey: Self.fakeKey, model: RemoteTarget.defaultGeminiModel)
        let projected = ledger.projectedCost(target: target, inputTokens: 1000, maxOutput: 400)
        XCTAssertNil(projected)

        let input = RoutingInput(
            policy: EscalationPolicy(mode: .autoWithConsentMemory, allowCloud: true),
            hasCandidateTarget: true, candidateIsCloud: !target.isLocalNetwork, online: true,
            localAnswer: "I'm not sure, I cannot help with that.", projectedCostUSD: projected)
        XCTAssertEqual(EscalationRouter.decide(input), .offer(reason: .costUnknown))
    }
}

/// Records each offer and declines it.
private final class DecliningOfferGate: ConsentGate {
    private(set) var offers: [EscalationOffer] = []

    func requestConsent(target: RemoteTarget, preview: CompressionResult, projectedCostUSD: Decimal?) async -> Bool {
        XCTFail("routeAndEscalate must call requestConsent(target:preview:offer:)")
        return false
    }

    func requestConsent(target: RemoteTarget, preview: CompressionResult, offer: EscalationOffer) async -> Bool {
        offers.append(offer)
        return false
    }
}

/// Streams Gemini-style chunks; by default each carries cumulative usage and the finishing chunk has no `delta`.
private final class GeminiStreamStub: URLProtocol, @unchecked Sendable {
    private struct Recorded {
        var body: Data?
        var requests = 0
        var stream = GeminiStreamStub.usageStream
    }
    private static let recorded = Mutex(Recorded())

    static let errorStream = """
        data: {"choices":[{"delta":{"content":"partial"}}]}

        data: {"error":{"code":429,"message":"Resource has been exhausted","status":"RESOURCE_EXHAUSTED"}}


        """

    static let usageStream = """
        data: {"choices":[{"delta":{"content":"a"}}],"usage":{"prompt_tokens":7,"completion_tokens":1}}

        data: {"choices":[{"delta":{"content":"b"}}],"usage":{"prompt_tokens":7,"completion_tokens":2}}

        data: {"choices":[{"delta":{"content":"c"}}],"usage":{"prompt_tokens":7,"completion_tokens":3}}

        data: {"choices":[{"index":0,"finish_reason":"stop"}],"usage":{"prompt_tokens":7,"completion_tokens":4}}

        data: {"choices":[],"usage":{"prompt_tokens":7}}

        data: [DONE]


        """

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiStreamStub.self]
        return URLSession(configuration: configuration)
    }

    static func reset(stream: String = usageStream) { recorded.withLock { $0 = Recorded(stream: stream) } }
    static func capturedBody() -> Data? { recorded.withLock { $0.body } }
    static func requestCount() -> Int { recorded.withLock { $0.requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        let stream = Self.recorded.withLock { state -> String in
            state.body = body
            state.requests += 1
            return state.stream
        }
        if let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                          headerFields: ["Content-Type": "text/event-stream"]) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: Data(stream.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
