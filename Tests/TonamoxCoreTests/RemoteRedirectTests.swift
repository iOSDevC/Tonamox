import Foundation
import Synchronization
import XCTest
@testable import TonamoxCore

/// A server that answers the prompt with a redirect must not get the body forwarded to another host.
final class RemoteRedirectTests: XCTestCase {

    func testOpenAICompatibleStreamRefusesRedirect() async throws {
        let origin = "redirect-\(UUID().uuidString.lowercased()).invalid"
        var provider = OpenAICompatibleProvider(
            id: "test.redirect", displayName: "Redirect", baseURL: URL(string: "https://\(origin)/v1")!,
            apiKey: "test-key")
        provider.makeSession = { RedirectStubProtocol.session() }
        try await assertRefused(provider, origin: origin)
    }

    func testOpenAICompatibleNonStreamingRefusesRedirect() async throws {
        let origin = "redirect-\(UUID().uuidString.lowercased()).invalid"
        var provider = OpenAICompatibleProvider(
            id: "test.redirect", displayName: "Redirect", baseURL: URL(string: "https://\(origin)/v1")!,
            apiKey: "test-key", streaming: false)
        provider.makeSession = { RedirectStubProtocol.session() }
        try await assertRefused(provider, origin: origin)
    }

    func testAnthropicStreamRefusesRedirect() async throws {
        let origin = "redirect-\(UUID().uuidString.lowercased()).invalid"
        var provider = AnthropicProvider(apiKey: "test-key", baseURL: URL(string: "https://\(origin)")!)
        provider.makeSession = { RedirectStubProtocol.session() }
        try await assertRefused(provider, origin: origin)
    }

    private func assertRefused(_ provider: any RemoteLLMProvider, origin: String) async throws {
        let request = RemoteRequest(model: "m", messages: [["role": "user", "content": "secret turn"]], maxTokens: 8)
        do {
            for try await _ in provider.stream(request) {}
            XCTFail("a redirect must fail the request")
        } catch TonamoxError.remoteFailed(let status, _) {
            XCTAssertEqual(status, 307)
        }
        XCTAssertEqual(RedirectStubProtocol.hosts(), [origin])
    }
}

/// Answers the first host with a 307 to `RedirectStubProtocol.elsewhere` and records every host it sees.
private final class RedirectStubProtocol: URLProtocol, @unchecked Sendable {
    static let elsewhere = "elsewhere.invalid"
    private static let seen = Mutex<[String]>([])

    static func session() -> URLSession {
        seen.withLock { $0 = [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func hosts() -> [String] { seen.withLock { $0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let host = url.host() else { return }
        Self.seen.withLock { $0.append(host) }
        if host == Self.elsewhere {
            let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: ok, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("data: [DONE]\n\n".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        var target = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        target.host = Self.elsewhere
        let redirect = HTTPURLResponse(
            url: url, statusCode: 307, httpVersion: "HTTP/1.1",
            headerFields: ["Location": target.url!.absoluteString])!
        var next = request
        next.url = target.url
        client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: redirect)
        client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
}
