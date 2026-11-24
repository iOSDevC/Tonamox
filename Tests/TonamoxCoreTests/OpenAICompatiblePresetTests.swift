import Foundation
import Synchronization
import XCTest
@testable import TonamoxCore

/// A generic `OpenAICompatibleProvider` (TonamoxTerminal's OpenRouter preset, any server with a trailing-slash base);
/// these pin the URL such a base produces, the Bearer header, and that an unpriced cloud id never projects a cost.
/// The SDK's own Gemini preset is covered in `GeminiTargetTests`.
final class OpenAICompatiblePresetTests: XCTestCase {
    private static let geminiBase = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/")!
    private static let fakeKey = "test-not-a-real-key"

    private func gemini() -> OpenAICompatibleProvider {
        var provider = OpenAICompatibleProvider(
            id: "cloud.gemini", displayName: "Gemini (Google)", baseURL: Self.geminiBase, apiKey: Self.fakeKey)
        provider.makeSession = { RequestCaptureProtocol.session() }
        return provider
    }

    func testTrailingSlashBaseKeepsTheOpenAIPath() throws {
        let request = try gemini().makeRequest(RemoteRequest(model: "gemini-3.5-flash-lite",
                                                             messages: [["role": "user", "content": "hola"]]))
        XCTAssertEqual(request.url?.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.fakeKey)")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
    }

    func testBaseWithoutVersionPathAppendsDirectly() throws {
        let provider = OpenAICompatibleProvider(
            id: "custom.server", displayName: "x", baseURL: URL(string: "https://api.example.com")!)
        let request = try provider.makeRequest(RemoteRequest(model: "m", messages: []))
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/chat/completions")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testStubbedStreamSendsToTheGeminiPathWithBearer() async throws {
        RequestCaptureProtocol.reset()
        let request = RemoteRequest(model: "gemini-3.5-flash-lite", messages: [["role": "user", "content": "hola"]],
                                    maxTokens: 400, temperature: 0.2)
        var answer = ""
        var usage: TokenUsage?
        for try await event in gemini().stream(request) {
            switch event {
            case .token(let text): answer += text
            case .usage(let reported): usage = reported
            case .reasoning: break
            }
        }
        XCTAssertEqual(answer, "ok")
        XCTAssertEqual(usage?.inputTokens, 7)
        let sent = try XCTUnwrap(RequestCaptureProtocol.captured())
        XCTAssertEqual(sent.url, "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        XCTAssertEqual(sent.authorization, "Bearer \(Self.fakeKey)")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "gemini-3.5-flash-lite")
        XCTAssertEqual(json["max_tokens"] as? Int, 400)
        XCTAssertEqual((json["temperature"] as? NSNumber)?.doubleValue ?? 0, 0.2, accuracy: 0.0001)
    }

    @MainActor
    func testUnpricedCloudIDsProjectNoCost() {
        let ledger = CostLedger()
        for id in ["cloud.gemini", "cloud.openrouter", "custom.server"] {
            for model in ["gemini-3.5-flash-lite", RemoteTarget.defaultOpenAIModel] {
                let target = Self.cloudTarget(providerID: id, modelID: model)
                XCTAssertNil(ledger.projectedCost(target: target, inputTokens: 1000, maxOutput: 400), "\(id) \(model)")
            }
        }
        let openAI = OpenAICompatibleProvider(id: "cloud.openai", displayName: "OpenAI",
                                              baseURL: URL(string: "https://api.openai.com/v1")!)
        let priced = RemoteTarget(provider: openAI, modelID: RemoteTarget.defaultOpenAIModel, contextLength: nil,
                                  origin: .cloud)
        XCTAssertNotNil(ledger.projectedCost(target: priced, inputTokens: 1000, maxOutput: 400))
    }

    private static func cloudTarget(providerID: String, modelID: String) -> RemoteTarget {
        let provider = OpenAICompatibleProvider(id: providerID, displayName: providerID, baseURL: geminiBase)
        return RemoteTarget(provider: provider, modelID: modelID, contextLength: nil, origin: .cloud)
    }
}

private final class RequestCaptureProtocol: URLProtocol, @unchecked Sendable {
    struct Sent: Sendable {
        let url: String
        let authorization: String?
        let body: Data
    }

    private static let last = Mutex<Sent?>(nil)

    private static let stream = """
        data: {"choices":[{"delta":{"content":"ok"}}]}

        data: {"choices":[],"usage":{"prompt_tokens":7,"completion_tokens":1}}

        data: [DONE]


        """

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestCaptureProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func reset() { last.withLock { $0 = nil } }
    static func captured() -> Sent? { last.withLock { $0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        let sent = Sent(url: url.absoluteString, authorization: request.value(forHTTPHeaderField: "Authorization"),
                        body: body)
        Self.last.withLock { $0 = sent }
        if let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                          headerFields: ["Content-Type": "text/event-stream"]) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: Data(Self.stream.utf8))
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
