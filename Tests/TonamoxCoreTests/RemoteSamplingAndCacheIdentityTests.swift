import Foundation
import Synchronization
import XCTest
@testable import TonamoxCore

/// The escalation path's sampling temperature, the cache's endpoint identity and the estimate a stopped stream leaves.
@MainActor
final class RemoteSamplingAndCacheIdentityTests: XCTestCase {

    func testTemperatureReachesTheProviderRequest() async throws {
        let provider = CapturingProvider()
        let target = RemoteTarget(provider: provider, modelID: "m", contextLength: 8192, origin: .cloud)
        let escalator = HybridEscalator(ledger: CostLedger())

        _ = try await escalator.escalate(
            escalator.preparePayload(for: target, context: "", question: "q \(UUID().uuidString)"),
            to: target, temperature: 0.2)
        _ = try await escalator.escalate(
            escalator.preparePayload(for: target, context: "", question: "q \(UUID().uuidString)"), to: target)

        XCTAssertEqual(provider.temperatures(), [0.2, 0.7], "nil keeps the previous default")
    }

    func testRouteAndEscalatePassesTheTemperature() async throws {
        let provider = CapturingProvider()
        let target = RemoteTarget(provider: provider, modelID: "m", contextLength: 8192, origin: .localNetwork(.llamaServer))
        let result = try await HybridEscalator(ledger: CostLedger()).routeAndEscalate(
            policy: EscalationPolicy(mode: .askEachTime), context: "short", question: "q \(UUID().uuidString)",
            localAnswer: "I'm not sure, I cannot help with that.", consent: ApprovingGate(),
            targets: [target], temperature: 0.3)

        XCTAssertNotNil(result)
        XCTAssertEqual(provider.temperatures(), [0.3])
    }

    func testOpenAICompatibleBodyCarriesTheTemperature() throws {
        let provider = OpenAICompatibleProvider(
            id: "test.body", displayName: "Body", baseURL: URL(string: "http://127.0.0.1:9/v1")!)
        let request = try provider.makeRequest(
            RemoteRequest(model: "m", messages: [["role": "user", "content": "hi"]], temperature: 0.2))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        let sent = try XCTUnwrap(body["temperature"] as? Double)
        XCTAssertEqual(sent, 0.2, accuracy: 1e-6)
    }

    func testTemperatureIsPartOfTheCacheKey() async throws {
        let provider = CapturingProvider()
        let target = RemoteTarget(provider: provider, modelID: "m", contextLength: 8192, origin: .cloud)
        let escalator = HybridEscalator(ledger: CostLedger())
        let payload = escalator.preparePayload(for: target, context: "", question: "q \(UUID().uuidString)")

        let cold = try await escalator.escalate(payload, to: target, temperature: 0.2)
        let warm = try await escalator.escalate(payload, to: target, temperature: 0.2)
        let otherTemperature = try await escalator.escalate(payload, to: target)
        let explicitDefault = try await escalator.escalate(payload, to: target, temperature: 0.7)

        XCTAssertFalse(cold.fromCache)
        XCTAssertTrue(warm.fromCache)
        XCTAssertFalse(otherTemperature.fromCache)
        XCTAssertTrue(explicitDefault.fromCache, "0.7 keys like nil")
        XCTAssertEqual(provider.temperatures(), [0.2, 0.7])
    }

    func testSameProviderIDAtAnotherAddressIsNotAnsweredFromTheCache() async throws {
        let escalator = HybridEscalator(ledger: CostLedger())
        let question = "q \(UUID().uuidString)"
        let first = cachedServerTarget(baseURL: "http://192.168.1.10:8080/v1", answer: "first server")
        _ = try await escalator.escalate(to: first, context: "", question: question)

        let moved = cachedServerTarget(baseURL: "http://192.168.1.11:8080/v1", answer: "second server")
        let result = try await escalator.escalate(to: moved, context: "", question: question)

        XCTAssertFalse(result.fromCache)
        XCTAssertEqual(result.answer, "second server")
        let again = try await escalator.escalate(to: moved, context: "", question: question)
        XCTAssertTrue(again.fromCache)
    }

    func testCacheIdentityHoldsTheEndpointButNoSecret() {
        let provider = OpenAICompatibleProvider(
            id: "terminal.compatible-server", displayName: "S",
            baseURL: URL(string: "HTTPS://user:hunter2@Example.TEST/v1/?token=abc#frag")!, apiKey: "sk-secret")
        XCTAssertEqual(provider.cacheIdentity, "terminal.compatible-server@https://example.test:443/v1")

        let anthropic = AnthropicProvider(apiKey: "sk-ant-secret")
        XCTAssertEqual(anthropic.cacheIdentity, "cloud.anthropic@https://api.anthropic.com:443")
        XCTAssertEqual(CapturingProvider().cacheIdentity, "test.capturing", "the default is the id")
    }

    func testStopAfterOutputIsEstimatedAndNotCached() async throws {
        let ledger = CostLedger()
        ledger.setPrice(TokenPrice(inputUSDPerMillion: 1, outputUSDPerMillion: 1), provider: "test.open-ended")
        let target = RemoteTarget(provider: OpenEndedProvider(), modelID: "m", contextLength: 8192, origin: .cloud)
        let escalator = HybridEscalator(ledger: ledger)
        let payload = escalator.preparePayload(for: target, context: "", question: "q \(UUID().uuidString)")

        let task = Task { @MainActor in
            try await escalator.escalate(payload, to: target) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do {
            _ = try await task.value
            XCTFail("a stopped stream must not return as a finished answer")
        } catch is CancellationError {}

        let entry = try XCTUnwrap(ledger.records.last)
        XCTAssertTrue(entry.isEstimated)
        XCTAssertNotNil(entry.costUSD)
        XCTAssertEqual(ledger.unpricedRecordCount, 0)
        XCTAssertNil(ResponseCache.shared.lookup(
            provider: target.provider.cacheIdentity, model: "m", payload: payload), "a partial answer is not cached")
    }

    func testEstimateCountsTowardTheCostCap() {
        let ledger = CostLedger()
        ledger.setPrice(TokenPrice(inputUSDPerMillion: 1_000_000, outputUSDPerMillion: 1_000_000), provider: "p")
        ledger.record(provider: "p", usage: nil, estimatedUsage: TokenUsage(inputTokens: 1, outputTokens: 1),
                      origin: .cloud, compressionRatio: nil)
        var policy = EscalationPolicy(mode: .askEachTime, allowCloud: true)
        policy.costCapUSDPerSession = 1
        let input = RoutingInput(
            policy: policy, hasCandidateTarget: true, candidateIsCloud: true, online: true,
            projectedCostUSD: Decimal(string: "0.01"), sessionSpentUSD: ledger.sessionCostUSD, unpricedRecordCount: ledger.unpricedRecordCount)

        XCTAssertEqual(ledger.sessionCostUSD, 2)
        XCTAssertEqual(EscalationRouter.decideUserRequested(input), .refuse(.overCostCap))
    }

    func testAnEstimatedRecordStillAsksWithCostUnknownBeforeTheNextCloudSend() {
        let ledger = CostLedger()
        ledger.setPrice(TokenPrice(inputUSDPerMillion: 1, outputUSDPerMillion: 1), provider: "test.capturing")
        ledger.record(provider: "test.capturing", usage: nil, estimatedUsage: TokenUsage(inputTokens: 1, outputTokens: 1),
                      origin: .cloud, compressionRatio: nil)
        let target = RemoteTarget(provider: CapturingProvider(), modelID: "m", contextLength: 8192, origin: .cloud)
        var policy = EscalationPolicy(mode: .autoWithConsentMemory, allowCloud: true)
        policy.costCapUSDPerSession = 100
        var input = HybridEscalator(ledger: ledger).routingInput(
            policy: policy, target: target, promptTokens: 10, maxTokens: 10, localContextWindow: 4096,
            localAnswer: nil, domain: nil)
        input.online = true

        XCTAssertEqual(ledger.unpricedRecordCount, 0)
        XCTAssertEqual(input.unpricedRecordCount, 1)
        XCTAssertEqual(EscalationRouter.decideUserRequested(input), .ask(reason: .costUnknown))
    }

    func testReportedUsageWinsOverAnEstimate() {
        let ledger = CostLedger()
        ledger.setPrice(TokenPrice(inputUSDPerMillion: 1_000_000, outputUSDPerMillion: 0), provider: "p")
        ledger.record(provider: "p", usage: TokenUsage(inputTokens: 3, outputTokens: 0),
                      estimatedUsage: TokenUsage(inputTokens: 100, outputTokens: 100), origin: .cloud, compressionRatio: nil)

        let entry = ledger.records[0]
        XCTAssertFalse(entry.isEstimated)
        XCTAssertNil(entry.estimatedUsage)
        XCTAssertEqual(entry.costUSD, 3)
    }

    private func cachedServerTarget(baseURL: String, answer: String) -> RemoteTarget {
        var provider = OpenAICompatibleProvider(
            id: "terminal.compatible-server", displayName: "Server", baseURL: URL(string: baseURL)!)
        provider.makeSession = { CannedCompletionProtocol.session(answer: answer) }
        return RemoteTarget(provider: provider, modelID: "same-model", contextLength: 8192, origin: .localNetwork(.llamaServer))
    }
}

private struct ApprovingGate: ConsentGate {
    func requestConsent(target: RemoteTarget, preview: CompressionResult, projectedCostUSD: Decimal?) async -> Bool { true }
}

/// Keeps every request's temperature and answers "ok" with usage.
private final class CapturingProvider: RemoteLLMProvider, Sendable {
    let id = "test.capturing"
    let displayName = "Capturing"
    let retentionNote = "test"
    private let seen = Mutex<[Float]>([])

    func temperatures() -> [Float] { seen.withLock { $0 } }

    func stream(_ request: RemoteRequest) -> AsyncThrowingStream<RemoteEvent, Error> {
        seen.withLock { $0.append(request.temperature) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.token("ok"))
            continuation.yield(.usage(TokenUsage(inputTokens: 1, outputTokens: 1)))
            continuation.finish()
        }
    }
}

/// Streams one token and then never finishes, like a server still generating when the user stops.
private struct OpenEndedProvider: RemoteLLMProvider {
    let id = "test.open-ended"
    let displayName = "Open ended"
    let retentionNote = "test"

    func stream(_ request: RemoteRequest) -> AsyncThrowingStream<RemoteEvent, Error> {
        AsyncThrowingStream { $0.yield(.token("partial")) }
    }
}

/// Answers every request with one SSE token (the session's answer) and usage; no network.
private final class CannedCompletionProtocol: URLProtocol, @unchecked Sendable {
    private static let answer = Mutex("")

    static func session(answer text: String) -> URLSession {
        answer.withLock { $0 = text }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CannedCompletionProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        let text = Self.answer.withLock { $0 }
        let chunk = #"{"choices":[{"delta":{"content":"\#(text)"}}]}"#
        let usage = #"{"choices":[],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#
        let body = "data: \(chunk)\n\ndata: \(usage)\n\ndata: [DONE]\n\n"
        let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                 headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: ok, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
