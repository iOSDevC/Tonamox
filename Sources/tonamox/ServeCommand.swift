import Darwin
import Foundation
import TonamoxCore
import TonamoxServer

extension TonamoxCLI {
    static let serveUsage = """
        usage: tonamox serve --model <id|path.gguf> [--port N] [--browser]
               tonamox serve --scripted [--port N] [--browser]

          Serves one on-disk model through an OpenAI-compatible API on 127.0.0.1 until Ctrl-C. Never downloads.
          The API key goes to a 0600 header file for `curl -H @<file>`; it is never printed.
          --scripted serves a fixed reply (model id "scripted") for offline smoke runs, and a reply that opens
                     with a <think> block (model id "scripted-reasoning").
          --browser also serves the chat page at / ; pairing codes are printed here, and Enter opens a new
                    120 s pairing window (one browser per window).

        """

    static func runServe(_ args: [String]) async throws {
        var modelArgument: String?
        var port: UInt16 = 47830
        var scripted = false
        var browser = false
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--help", "-h":
                print(serveUsage, terminator: "")
                exit(0)
            case "--scripted":
                scripted = true
            case "--browser":
                browser = true
            case "--model":
                index += 1
                guard index < args.count else { serveUsageError("--model needs a value") }
                modelArgument = args[index]
            case "--port":
                index += 1
                port = parsePort(index < args.count ? args[index] : "")
            default:
                serveUsageError("unexpected argument \(args[index])")
            }
            index += 1
        }
        guard scripted != (modelArgument != nil) else { serveUsageError("pass exactly one of --model or --scripted") }

        let served = try await servedModels(modelArgument)
        var configuration = ServerConfiguration(serverName: "tonamox serve")
        configuration.port = .fixed(port)
        configuration.hostedBy = .commandLine
        if browser { configuration.features.insert(.browserPage) }
        let presenter = browser ? TerminalPairingPresenter() : nil
        let server = TonamoxServer(configuration: configuration, models: served, pairing: presenter)
        let endpoint = try await server.start()
        let key = try server.issueAPIKey(label: "tonamox serve")
        let keyFile = try ServeKeyFile.write(key.headerLine)
        let base = endpoint.baseURL.absoluteString
        print("Listening on \(base) (127.0.0.1 only). Model: \(served.map(\.info.id).joined(separator: ", "))")
        print("API key header file (0600): \(keyFile.path(percentEncoded: false))")
        print("Try: curl -sS -H @\"\(keyFile.path(percentEncoded: false))\" \(base)/v1/models")
        print("Ctrl-C stops the server; the key is valid only while it runs.")
        if browser {
            server.openPairingWindow()
            print("Chat page: \(base)/  (pairing window open for 120 s; press Enter to open another)")
            presenter?.watchStdin(server)
        }
        fflush(stdout)
        await waitForInterrupt()
        await server.stop()
    }

    static func servedModels(_ argument: String?) async throws -> [ServedModel] {
        guard let argument else {
            let pieces = ["This ", "is ", "a ", "scripted ", "reply."]
            let reasoned = ScriptedChatModel(id: "scripted-reasoning",
                                             pieces: ["<th", "ink>\nThe user ", "wants a ", "scripted reply.\n</th",
                                                      "ink>\n", "This ", "is ", "the ", "answer."],
                                             delay: .milliseconds(150), usage: nil)
            reasoned.splitsReasoning = true
            return [ScriptedChatModel(id: "scripted", pieces: pieces, usage: nil).served, reasoned.served]
        }
        let model = try ReceiptReader.model(for: argument)
        guard model.isDownloaded else {
            err("\(model.displayName) is not on disk; tonamox serve never downloads a model.\n")
            exit(1)
        }
        // A plain load: the served instance never has tools.
        let llm = try await ModelManager.shared.load(model)
        return [try LocalServedModel(llm, id: model.id, displayName: model.displayName,
                                     turnstile: GenerationTurnstile()).served]
    }

    static func parsePort(_ text: String) -> UInt16 {
        guard let value = UInt16(text), value > 0 else { serveUsageError("--port needs a number from 1 to 65535") }
        return value
    }

    static func waitForInterrupt() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)
            let sources = [SIGINT, SIGTERM].map { DispatchSource.makeSignalSource(signal: $0, queue: .main) }
            let resumed = ResumeOnce(continuation)
            sources.forEach { source in
                source.setEventHandler { resumed.resume() }
                source.resume()
            }
            ResumeOnce.retained = sources
        }
    }

    static func serveUsageError(_ message: String) -> Never {
        err("tonamox serve: \(message)\n" + serveUsage)
        exit(2)
    }
}

/// Resumes a continuation once, from whichever signal arrives first.
private final class ResumeOnce: @unchecked Sendable {
    nonisolated(unsafe) static var retained: [any DispatchSourceSignal] = []
    private var continuation: CheckedContinuation<Void, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}

/// `~/Library/Application Support/tonamox/server-key.header`: directory 0700, file 0600, written to a fresh
/// `O_EXCL|O_NOFOLLOW` file and renamed into place. A key in curl's argv would be visible to every user via `ps`.
enum ServeKeyFile {
    static func write(_ headerLine: String) throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let directory = support.appending(path: "tonamox", directoryHint: .isDirectory)
        let directoryPath = directory.path(percentEncoded: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard chmod(directoryPath, 0o700) == 0 else { throw POSIXError(.EPERM) }
        let final = directory.appending(path: "server-key.header")
        let temporary = directory.appending(path: ".server-key-\(UUID().uuidString)")
        let descriptor = open(temporary.path(percentEncoded: false), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let bytes = Array((headerLine + "\n").utf8)
        let written = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        fsync(descriptor)
        close(descriptor)
        guard written == bytes.count,
              rename(temporary.path(percentEncoded: false), final.path(percentEncoded: false)) == 0 else {
            unlink(temporary.path(percentEncoded: false))
            throw POSIXError(.EIO)
        }
        return final
    }
}

/// The terminal is the trusted screen here: the code is printed for the person to type into the page.
@MainActor
final class TerminalPairingPresenter: PairingPresenter {
    private var reader: Thread?

    func present(_ request: PairingRequest) async {
        print("Pairing request from \(request.peer) (name, untrusted: \(request.untrustedLabel)). "
              + "Code: \(request.displayCode)")
        fflush(stdout)
    }

    func dismiss(_ id: PairingRequest.ID) {
        print("Pairing request closed.")
        fflush(stdout)
    }

    /// Each Enter on stdin opens a new pairing window.
    func watchStdin(_ server: TonamoxServer) {
        let thread = Thread {
            while readLine() != nil {
                Self.reopenWindow(server)
            }
        }
        reader = thread
        thread.start()
    }

    private nonisolated static func reopenWindow(_ server: TonamoxServer) {
        Task { @MainActor in
            server.openPairingWindow()
            print("Pairing window open for 120 s.")
            fflush(stdout)
        }
    }
}
