#if os(macOS)
import Foundation
import Synchronization

/// Output of one child process. `launchError` is set when it could not start at all.
public struct ProcessResult: Equatable, Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data
    public var launchError: String?
    public var timedOut: Bool

    public init(
        status: Int32,
        stdout: Data = Data(),
        stderr: Data = Data(),
        launchError: String? = nil,
        timedOut: Bool = false
    ) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.launchError = launchError
        self.timedOut = timedOut
    }

    public var stdoutText: String {
        String(decoding: stdout, as: UTF8.self)
    }

    public var stderrText: String {
        String(decoding: stderr, as: UTF8.self)
    }

    public var didLaunch: Bool {
        launchError == nil
    }
}

/// Runs an executable by absolute path with an argv array. Never goes through a shell, so
/// arguments reach the child byte for byte with no quoting.
public protocol ProcessRunner: Sendable {
    func run(_ executable: String, _ arguments: [String]) async -> ProcessResult
}

public struct SystemProcessRunner: ProcessRunner {
    /// Added to (and overriding) the helper's own environment, e.g. SCREENDIR in tests.
    public var extraEnvironment: [String: String]
    public var timeout: Duration

    public init(extraEnvironment: [String: String] = [:], timeout: Duration = .seconds(5)) {
        self.extraEnvironment = extraEnvironment
        self.timeout = timeout
    }

    public func run(_ executable: String, _ arguments: [String]) async -> ProcessResult {
        let environment = extraEnvironment
        let limit = timeout
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.runBlocking(executable, arguments, environment, limit))
            }
        }
    }

    private static func runBlocking(
        _ executable: String,
        _ arguments: [String],
        _ environment: [String: String],
        _ limit: Duration
    ) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable, isDirectory: false)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in override }
        }
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return ProcessResult(status: -1, launchError: String(describing: error))
        }
        let errorBytes = Mutex(Data())
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            errorBytes.withLock { $0 = data }
            readers.leave()
        }
        let expired = Mutex(false)
        let watchdog = DispatchWorkItem { [process] in
            guard process.isRunning else { return }
            expired.withLock { $0 = true }
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds(limit), execute: watchdog)
        let outputBytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        readers.wait()
        return ProcessResult(
            status: process.terminationStatus,
            stdout: outputBytes,
            stderr: errorBytes.withLock { $0 },
            timedOut: expired.withLock { $0 }
        )
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
#endif
