import Foundation
import Synchronization
import XCTest
@testable import TonamoxCore

final class LocalProviderDetectionTests: XCTestCase {

    func testDefaultEndpoints() {
        XCTAssertEqual(LocalProviderEndpoint.ollamaDefault.baseURL.absoluteString, "http://localhost:11434")
        XCTAssertEqual(LocalProviderEndpoint.llamaDefault.baseURL.absoluteString, "http://127.0.0.1:8080/v1")
        XCTAssertEqual(LocalProviderEndpoint.magnitudeDefault.baseURL.absoluteString, "http://127.0.0.1:10100/inference/v1")
        XCTAssertEqual(LocalProviderEndpoint.defaults, [.ollamaDefault, .llamaDefault, .magnitudeDefault])
        XCTAssertEqual(LocalProviderEndpoint.ollamaDefault.kind, .ollama)
        XCTAssertEqual(LocalProviderEndpoint.llamaDefault.kind, .llamaServer)
        XCTAssertEqual(LocalProviderEndpoint.magnitudeDefault.kind, .magnitude)
    }

    func testDefaultEndpointsStayOnThisMachine() {
        XCTAssertEqual(Set(LocalProviderEndpoint.defaults.compactMap { $0.baseURL.host() }), ["localhost", "127.0.0.1"])
    }

    func testKindRawValuesAndDisplayNames() throws {
        XCTAssertEqual(LocalProviderKind(rawValue: "magnitude"), .magnitude)
        XCTAssertEqual(LocalProviderKind.ollama.displayName, "Ollama")
        XCTAssertEqual(LocalProviderKind.llamaServer.displayName, "llama-server")
        XCTAssertEqual(LocalProviderKind.magnitude.displayName, "Magnitude")
        let encoded = try JSONEncoder().encode([LocalProviderKind.magnitude])
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #"["magnitude"]"#)
        XCTAssertEqual(try JSONDecoder().decode([LocalProviderKind].self, from: encoded), [.magnitude])
    }

    func testIsAvailableFlag() {
        let url = URL(string: "http://localhost:11434")!
        let withModel = LocalProviderStatus(
            kind: .ollama, baseURL: url, reachable: true,
            version: "1.0", models: [LocalProviderModel(name: "llama3:latest")])
        XCTAssertTrue(withModel.isAvailable)

        let upNoModels = LocalProviderStatus(
            kind: .ollama, baseURL: url, reachable: true, version: "1.0", models: [])
        XCTAssertFalse(upNoModels.isAvailable)

        let down = LocalProviderStatus(
            kind: .ollama, baseURL: url, reachable: false, version: nil, models: [])
        XCTAssertFalse(down.isAvailable)
    }

    @MainActor
    func testDetectDeadPortIsGraceful() async {
        // Port 1 is closed → connection refused → graceful reachable:false, no throw.
        let dead = LocalProviderEndpoint(kind: .llamaServer, baseURL: URL(string: "http://127.0.0.1:1/v1")!)
        let status = await LocalProviderDetector.detect(dead, timeout: 0.5)
        XCTAssertFalse(status.reachable)
        XCTAssertTrue(status.models.isEmpty)
        XCTAssertNil(status.version)
        XCTAssertEqual(status.kind, .llamaServer)
    }

    @MainActor
    func testDetectAllPreservesOrderAndNeverThrows() async {
        let a = LocalProviderEndpoint(kind: .ollama, baseURL: URL(string: "http://127.0.0.1:1")!)
        let b = LocalProviderEndpoint(kind: .llamaServer, baseURL: URL(string: "http://127.0.0.1:2/v1")!)
        let statuses = await LocalProviderDetector.detectAll(endpoints: [a, b], timeout: 0.5)
        XCTAssertEqual(statuses.count, 2)
        XCTAssertEqual(statuses[0].kind, .ollama)   // input order preserved
        XCTAssertEqual(statuses[1].kind, .llamaServer)
        XCTAssertTrue(statuses.allSatisfy { !$0.reachable })
    }

    @MainActor
    func testFacadeAvailableFiltersUnreachable() async {
        let dead = [
            LocalProviderEndpoint(kind: .ollama, baseURL: URL(string: "http://127.0.0.1:1")!),
            LocalProviderEndpoint(kind: .llamaServer, baseURL: URL(string: "http://127.0.0.1:2/v1")!),
        ]
        let available = await Tonamox.availableLocalProviders(endpoints: dead, timeout: 0.5)
        XCTAssertTrue(available.isEmpty)
    }

    // MARK: - OpenAI-compatible probes (stubbed)

    @MainActor
    func testMagnitudeProbeReadsTopLevelContextLength() async throws {
        let endpoint = LocalProviderEndpoint.magnitudeDefault
        ProviderStubProtocol.serve(Self.magnitudeModels, at: endpoint.baseURL.appending(path: "models"))
        let status = await LocalProviderDetector.detect(endpoint, session: ProviderStubProtocol.session())
        XCTAssertTrue(status.reachable)
        XCTAssertTrue(status.isAvailable)
        XCTAssertEqual(status.kind, .magnitude)
        XCTAssertEqual(status.baseURL, endpoint.baseURL)
        XCTAssertNil(status.version)
        XCTAssertEqual(status.models.map(\.name), ["qwen3.5:4b", Self.magnitudeHuggingFaceID])
        XCTAssertEqual(status.models.map(\.contextLength), [40_960, 8_192])
        XCTAssertEqual(status.models.map(\.sizeBytes), [nil, nil])
        XCTAssertTrue(status.models.allSatisfy(\.runsLocally))
    }

    @MainActor
    func testLlamaServerProbeStillReadsMeta() async throws {
        let endpoint = LocalProviderEndpoint(kind: .llamaServer, baseURL: URL(string: "http://127.0.0.1:18080/v1")!)
        ProviderStubProtocol.serve(Self.llamaModels, at: endpoint.baseURL.appending(path: "models"))
        let status = await LocalProviderDetector.detect(endpoint, session: ProviderStubProtocol.session())
        XCTAssertTrue(status.reachable)
        XCTAssertEqual(status.kind, .llamaServer)
        let model = try XCTUnwrap(status.models.first)
        XCTAssertEqual(model.name, "qwen3-32b")
        XCTAssertEqual(model.contextLength, 32_768)
        XCTAssertEqual(model.sizeBytes, 19_000_000_000)
    }

    @MainActor
    func testMagnitudeProbeOnServerErrorIsUnreachable() async {
        let endpoint = LocalProviderEndpoint(kind: .magnitude, baseURL: URL(string: "http://127.0.0.1:10101/inference/v1")!)
        ProviderStubProtocol.serve(Data(#"{"error":"catalog models are not configured"}"#.utf8),
                                   status: 500, at: endpoint.baseURL.appending(path: "models"))
        let status = await LocalProviderDetector.detect(endpoint, session: ProviderStubProtocol.session())
        XCTAssertFalse(status.reachable)
        XCTAssertTrue(status.models.isEmpty)
        XCTAssertEqual(status.kind, .magnitude)
    }

    @MainActor
    func testMagnitudeDeadPortIsGraceful() async {
        let dead = LocalProviderEndpoint(kind: .magnitude, baseURL: URL(string: "http://127.0.0.1:1/inference/v1")!)
        let status = await LocalProviderDetector.detect(dead, timeout: 0.5)
        XCTAssertFalse(status.reachable)
        XCTAssertFalse(status.isAvailable)
        XCTAssertNil(status.version)
        XCTAssertEqual(status.kind, .magnitude)
    }

    func testProviderFromMagnitudeKeepsTheBaseURL() throws {
        let status = LocalProviderStatus(
            kind: .magnitude, baseURL: LocalProviderEndpoint.magnitudeDefault.baseURL,
            reachable: true, version: nil, models: [LocalProviderModel(name: "qwen3.5:4b", contextLength: 40_960)])
        let provider = OpenAICompatibleProvider.from(status)
        XCTAssertEqual(provider.id, "local.magnitude")
        XCTAssertEqual(provider.displayName, "Magnitude (local)")
        let request = try provider.makeRequest(RemoteRequest(model: "qwen3.5:4b", messages: [["role": "user", "content": "hi"]]))
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:10100/inference/v1/chat/completions")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    private static let magnitudeHuggingFaceID = "hf:unsloth/Qwen3.6-35B-A3B-GGUF/Qwen3.6-35B-A3B-Q8_0.gguf"

    /// Shape of Magnitude's `GET /inference/v1/models` (one catalog model, one custom model).
    private static let magnitudeModels = Data("""
        {"object":"list","data":[
          {"id":"qwen3.5:4b","object":"model","created":0,"owned_by":"magnitude","name":"Qwen3.5 4B",
           "description":"","context_length":40960,
           "architecture":{"input_modalities":["text"],"output_modalities":["text"]},
           "supported_parameters":["tools"],"top_provider":{"context_length":40960,"max_completion_tokens":8192}},
          {"id":"\(magnitudeHuggingFaceID)","object":"model","created":0,"owned_by":"huggingface",
           "name":"Qwen3.6-35B-A3B Q8_0",
           "description":"","context_length":8192,
           "architecture":{"input_modalities":["text"],"output_modalities":["text"]},
           "supported_parameters":[],"top_provider":{"context_length":8192,"max_completion_tokens":8192}}
        ]}
        """.utf8)

    private static let llamaModels = Data("""
        {"object":"list","data":[{"id":"qwen3-32b","object":"model","owned_by":"llamacpp",
          "meta":{"n_ctx_train":32768,"size":19000000000,"n_params":32000000000}}]}
        """.utf8)

    /// Live check against the real machine — opt-in via AURA_LIVE_PROVIDER_TESTS=1.
    @MainActor
    func testLiveOllamaDetection() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AURA_LIVE_PROVIDER_TESTS"] == "1",
                          "Set AURA_LIVE_PROVIDER_TESTS=1 to run against a live Ollama server.")
        let status = await LocalProviderDetector.detect(.ollamaDefault, timeout: 3.0)
        XCTAssertTrue(status.reachable)
        XCTAssertNotNil(status.version)
    }

    /// Live check against a running llama.cpp `llama-server` — opt-in via AURA_LIVE_PROVIDER_TESTS=1.
    @MainActor
    func testLiveLlamaServerDetection() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AURA_LIVE_PROVIDER_TESTS"] == "1",
                          "Set AURA_LIVE_PROVIDER_TESTS=1 to run against a live llama-server.")
        let status = await LocalProviderDetector.detect(.llamaDefault, timeout: 3.0)
        XCTAssertTrue(status.reachable)
        XCTAssertFalse(status.models.isEmpty)
        XCTAssertNil(status.version)   // llama-server exposes no version
    }
}

/// Answers each registered URL with a canned status and body; unknown URLs get a 404.
private final class ProviderStubProtocol: URLProtocol, @unchecked Sendable {
    private struct Reply: Sendable {
        let status: Int
        let body: Data
    }

    private static let replies = Mutex<[String: Reply]>([:])

    static func serve(_ body: Data, status: Int = 200, at url: URL) {
        let reply = Reply(status: status, body: body)
        replies.withLock { $0[url.absoluteString] = reply }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        let reply = Self.replies.withLock { $0[url.absoluteString] } ?? Reply(status: 404, body: Data())
        if let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                          headerFields: ["Content-Type": "application/json"]) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
