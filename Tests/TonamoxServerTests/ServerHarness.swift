import Foundation
import Synchronization
import Testing
@testable import TonamoxCore
@testable import TonamoxServer

final class LogCollector: Sendable {
    private let entries = Mutex<[ServerLogEntry]>([])

    var log: ServerLog { ServerLog { [self] entry in entries.withLock { $0.append(entry) } } }
    var all: [ServerLogEntry] { entries.withLock { $0 } }
}

/// Listener ports below the ephemeral range (49152-65535), handed out once per process from a pid-derived start.
/// macOS allocates ephemeral TCP ports sequentially, so a suspended server's ephemeral port soon becomes some test
/// client's source port and the resume rebind fails with `portInUse`; the kernel never assigns these automatically.
enum TestListenerPorts {
    static let range: Range<UInt16> = 30_000..<45_000
    private static let cursor = Mutex(Int(getpid()) % 1_500 * 10)

    static func take() -> UInt16 {
        let offset = cursor.withLock { cursor in
            defer { cursor = (cursor + 1) % range.count }
            return cursor
        }
        return range.lowerBound + UInt16(offset)
    }
}

/// A running server on 127.0.0.1 with a scripted model, a private lifecycle and one API key. The port is preferred
/// from ``TestListenerPorts`` and falls back to an ephemeral one when another process holds it.
@MainActor
final class ServerHarness {
    static let background = Notification.Name("tonamox.test.background")
    static let foreground = Notification.Name("tonamox.test.foreground")

    let server: TonamoxServer
    let model: ScriptedChatModel
    let notifications: NotificationCenter
    let logs: LogCollector
    let credentials: InMemoryServerCredentials
    private(set) var port: UInt16 = 0
    private(set) var key: IssuedAPIKey?

    /// The address clients put in `Host`; interface tests set the injected interface's address.
    var hostAddress = "127.0.0.1"

    init(model: ScriptedChatModel = ScriptedChatModel(), extraModels: [ServedModel] = [],
         pairing: (any PairingPresenter)? = nil, network: ServerNetwork = .live,
         configure: (inout ServerConfiguration) -> Void = { _ in }) {
        var configuration = ServerConfiguration(serverName: "test")
        configuration.port = .preferred(TestListenerPorts.take())
        configure(&configuration)
        let notifications = NotificationCenter()
        let lifecycle = BackgroundLifecycle(notificationCenter: notifications, didEnterBackground: Self.background,
                                            willEnterForeground: Self.foreground)
        let logs = LogCollector()
        let credentials = InMemoryServerCredentials()
        self.model = model
        self.notifications = notifications
        self.logs = logs
        self.credentials = credentials
        self.server = TonamoxServer(configuration: configuration, models: [model.served] + extraModels,
                                    credentials: credentials, lifecycle: lifecycle, clock: .live, log: logs.log,
                                    pairing: pairing, network: network)
    }

    // A test that throws before its own `stop()` would otherwise keep its listener open for the rest of the run.
    // Not `isolated deinit`: that needs Swift 6.2 and the package supports 6.1.
    deinit {
        Task { [server] in await server.stop() }
    }

    static func started(model: ScriptedChatModel = ScriptedChatModel(), extraModels: [ServedModel] = [],
                        pairing: (any PairingPresenter)? = nil,
                        configure: (inout ServerConfiguration) -> Void = { _ in }) async throws -> ServerHarness {
        let harness = ServerHarness(model: model, extraModels: extraModels, pairing: pairing, configure: configure)
        try await harness.start()
        return harness
    }

    func start() async throws {
        port = try await server.start().port
        if key == nil { key = try server.issueAPIKey(label: "test") }
    }

    var secret: String { key?.secret ?? "" }
    var host: String { "\(hostAddress):\(port)" }

    func raw(_ request: String) async throws -> RawResponse {
        let client = try await RawHTTPClient.connected(port: port)
        defer { client.close() }
        try await client.send(request)
        return try #require(RawResponse(try await client.receiveResponse()))
    }

    func get(_ path: String, key: String? = nil, host: String? = nil, headers: [String] = [],
             method: String = "GET") async throws -> RawResponse {
        var lines = ["\(method) \(path) HTTP/1.1", "Host: \(host ?? self.host)"]
        if let key = key ?? self.key?.secret { lines.append("Authorization: Bearer \(key)") }
        lines += headers
        return try await raw(lines.joined(separator: "\r\n") + "\r\n\r\n")
    }

    func chatRequest(_ body: String, key: String? = nil, headers: [String] = [],
                     contentType: String = "application/json") -> String {
        var lines = ["POST /v1/chat/completions HTTP/1.1", "Host: \(host)",
                     "Authorization: Bearer \(key ?? secret)", "Content-Type: \(contentType)",
                     "Content-Length: \(body.utf8.count)"]
        lines += headers
        return lines.joined(separator: "\r\n") + "\r\n\r\n" + body
    }

    func chat(_ body: String, key: String? = nil, headers: [String] = []) async throws -> RawResponse {
        try await raw(chatRequest(body, key: key, headers: headers))
    }

    /// Opens a streamed chat and returns the client after the response head arrived.
    func openStream(_ body: String) async throws -> (RawHTTPClient, Data) {
        let client = try await RawHTTPClient.connected(port: port)
        try await client.send(chatRequest(body))
        let head = try await client.receive(until: "\r\n\r\n")
        return (client, head)
    }

    func post(background: Bool) {
        notifications.post(name: background ? Self.background : Self.foreground, object: nil)
    }
}

enum Bodies {
    static func chat(_ content: String = "Hi", model: String = "scripted", extra: String = "") -> String {
        let suffix = extra.isEmpty ? "" : ", " + extra
        return #"{"model":"\#(model)","messages":[{"role":"user","content":"\#(content)"}]\#(suffix)}"#
    }

    static func stream(_ content: String = "Hi", includeUsage: Bool = false, extra: String = "") -> String {
        var options = #""stream":true"#
        if includeUsage { options += #","stream_options":{"include_usage":true}"# }
        return chat(content, extra: extra.isEmpty ? options : options + ", " + extra)
    }
}

func json(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

func errorCode(_ response: RawResponse) -> String? {
    (json(response.body)["error"] as? [String: Any])?["code"] as? String
}

/// SSE `data:` payloads in order.
func events(_ text: String) -> [String] {
    text.components(separatedBy: "\n\n").compactMap { frame in
        frame.hasPrefix("data: ") ? String(frame.dropFirst(6)) : nil
    }
}

/// Ids and timestamps are random or time-based; goldens hold fixed values.
func normalized(_ text: String) -> String {
    text.replacingOccurrences(of: #""id":"chatcmpl-[0-9a-f]+""#, with: #""id":"chatcmpl-ID""#, options: .regularExpression)
        .replacingOccurrences(of: #""created":[0-9]+"#, with: #""created":0"#, options: .regularExpression)
}

func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/openai"))
    return try String(contentsOf: url, encoding: .utf8)
}

@MainActor
func eventually(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Emits cumulative partials of `pieces` for any generate call; records the messages it was given.
@MainActor
final class MessagesFakeBackend: InferenceBackend {
    var pieces = ["A", "B", "C"]
    var stats: GenerationStats?
    var failure: Error?
    var delay: Duration = .zero
    private(set) var isLoaded = true
    private(set) var receivedMessages: [[String: String]] = []
    private(set) var isGenerating = false
    private(set) var emitted = 0
    private(set) var lastGenerationStats: GenerationStats?

    func load(onProgress: @escaping @MainActor (String) -> Void) async throws {}

    func generate(prompt: String, systemPrompt: String?, maxTokens: Int,
                  onToken: @escaping @MainActor (String) -> Void) async throws -> String {
        try await emit(onToken)
    }

    func generate(prompt: String, systemPrompt: String?, maxTokens: Int, constraint: GenerationConstraint,
                  onToken: @escaping @MainActor (String) -> Void) async throws -> String {
        try await emit(onToken)
    }

    func generate(prompt: String, image: PlatformImage?, maxTokens: Int,
                  onToken: @escaping @MainActor (String) -> Void) async throws -> String {
        try await emit(onToken)
    }

    func generate(messages: [[String: String]], maxTokens: Int,
                  onToken: @escaping @MainActor (String) -> Void) async throws -> String {
        receivedMessages = messages
        return try await emit(onToken)
    }

    private func emit(_ onToken: @escaping @MainActor (String) -> Void) async throws -> String {
        isGenerating = true
        defer { isGenerating = false }
        var text = ""
        for piece in pieces {
            if delay > .zero { try await Task.sleep(for: delay) }
            text += piece
            emitted += 1
            onToken(text)
        }
        if let failure { throw failure }
        lastGenerationStats = stats
        return text
    }

    func unload() { isLoaded = false }
}

@MainActor
func localModel(_ backend: MessagesFakeBackend, toolsEnabled: Bool = false) -> Tonamox {
    let notifications = NotificationCenter()
    let lifecycle = BackgroundLifecycle(notificationCenter: notifications, didEnterBackground: nil,
                                        willEnterForeground: nil)
    let engine = TonamoxEngine(model: .dolphin3_qwen25_1_5b_gguf, backend: backend, lifecycle: lifecycle,
                               toolsEnabled: toolsEnabled)
    return Tonamox(engine: engine)
}
