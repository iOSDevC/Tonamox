#if os(macOS)
import Darwin
import Foundation
import TerminalBridgeKit

/// SIGINT/SIGTERM handling for `run`: stop the loop, then exit cleanly.
final class SignalTrap: Sendable {
    private let sources: [any DispatchSourceSignal]
    private let trapped: [Int32]

    init(_ signals: [Int32], handler: @escaping @Sendable () -> Void) {
        trapped = signals
        sources = signals.map { Self.makeSource($0, handler: handler) }
    }

    private static func makeSource(
        _ number: Int32,
        handler: @escaping @Sendable () -> Void
    ) -> any DispatchSourceSignal {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler(handler: handler)
        source.resume()
        return source
    }

    func cancel() {
        sources.forEach { $0.cancel() }
        trapped.forEach { signal($0, SIG_DFL) }
    }
}

/// Everything `run` needs once the checks passed.
struct RunContext {
    let config: HelperConfig
    let secret: Data
    let idlePrompt: IdlePromptPattern
    let dialer: any ChannelDialer
    let journal: WriteJournal
    let journalURL: URL
    let seed: [UUID]
    let scratch: URL
}

/// A failed precondition of `run`, carrying its exit code.
struct ExitStatus: Error {
    let code: Int32
}

extension HelperCLI {
    static func run(_ options: RunOptions, io streams: HelperIO) async -> Int32 {
        let context: RunContext
        do {
            context = try await prepareRun(options, streams: streams)
        } catch {
            return error.code
        }
        defer { rmdir(PrivateFiles.path(context.scratch)) }
        let console = HelperConsole(verbose: options.verbose, sink: streams.out)
        let label = "\(options.target.session):\(options.target.window)"
        let injector = ScreenInjector(
            settings: ScreenInjectorSettings(
                session: options.target.session,
                window: options.target.window,
                idlePrompt: context.idlePrompt,
                scratchDirectory: context.scratch
            ),
            onStateChange: { inspection in console.info("screen \(label): \(inspection.detail)") }
        )
        let session = makeSession(context, injector: injector, console: console, label: label)
        console.info(
            "tonamox-bridge \(version) · huella \(context.config.fingerprint ?? "?") · screen \(label) · "
                + context.dialer.displayName
        )
        console.info("Nunca pulso Enter: revisa cada línea en tu terminal y pulsa Enter tú.")
        let journalPath = PrivateFiles.path(context.journalURL)
        console.debug("prompt inactivo: \(context.idlePrompt.pattern); journal: \(journalPath)")
        context.journal.note(.started, detail: context.dialer.deviceLabel)
        _ = await injector.inspect()
        await serveUntilSignalled(session)
        if let usb = context.dialer as? USBDialer { await usb.stop() }
        context.journal.note(.stopped)
        context.journal.close()
        console.info("Detenido.")
        return HelperExitCode.success
    }

    /// Root check, pairing, screen version, prompt regex, journal (seeding the replay ids) and scratch dir.
    static func prepareRun(_ options: RunOptions, streams: HelperIO) async throws(ExitStatus) -> RunContext {
        guard geteuid() != 0 else {
            streams.err("No ejecutes tonamox-bridge como root: teclearía en tu shell con privilegios de root.")
            throw ExitStatus(code: HelperExitCode.runningAsRoot)
        }
        let store = HelperConfigStore(fileURL: options.configURL ?? HelperConfigStore.defaultURL)
        let config: HelperConfig
        do {
            config = try store.loadPaired()
        } catch {
            streams.err(error.message)
            throw ExitStatus(code: HelperExitCode.configuration)
        }
        guard let secret = config.secret else { throw ExitStatus(code: HelperExitCode.configuration) }
        guard await checkScreen(runner: SystemProcessRunner(), io: streams) else {
            throw ExitStatus(code: HelperExitCode.screenUnavailable)
        }
        let idlePrompt: IdlePromptPattern
        do {
            idlePrompt = try IdlePromptPattern(
                options.target.promptRegex ?? config.promptRegex ?? IdlePromptPattern.defaultPattern
            )
        } catch {
            streams.err(error.message)
            // A bad --prompt-regex argument already failed at parse time, so this one came from the config.
            throw ExitStatus(code: HelperExitCode.configuration)
        }
        let dialer = makeDialer(options)
        let journalURL = options.journalURL ?? WriteJournal.defaultURL
        do {
            let seed = try WriteJournal.typedWriteIDs(at: journalURL)
            let journal = try WriteJournal(
                fileURL: journalURL,
                key: config.journalSymmetricKey,
                session: options.target.session,
                window: options.target.window,
                device: dialer.deviceLabel
            )
            return RunContext(
                config: config,
                secret: secret,
                idlePrompt: idlePrompt,
                dialer: dialer,
                journal: journal,
                journalURL: journalURL,
                seed: seed,
                scratch: try makeScratchDirectory()
            )
        } catch {
            streams.err(error.message)
            throw ExitStatus(code: HelperExitCode.configuration)
        }
    }

    static func makeSession(
        _ context: RunContext,
        injector: ScreenInjector,
        console: HelperConsole,
        label: String
    ) -> HelperSession {
        let journal = context.journal
        let dialer = context.dialer
        let engine = HelperBridgeSession(
            secret: context.secret,
            helperID: context.config.helperID,
            helperName: helperName(),
            injector: injector,
            recentWrites: RecentWriteIDs(seed: context.seed),
            recorder: ReportingRecorder(journal: journal, console: console, targetLabel: label),
            onAuthenticated: { phoneName, _ in
                console.info("Conectado a \(phoneName) por \(dialer.displayName).")
                journal.note(.connected, detail: phoneName)
            }
        )
        return HelperSession(engine: engine, dialer: dialer, console: console, journal: journal)
    }

    static func serveUntilSignalled(_ session: HelperSession) async {
        let loop = Task { await session.run() }
        let trap = SignalTrap([SIGINT, SIGTERM]) {
            loop.cancel()
            Task { await session.stop() }
        }
        await loop.value
        trap.cancel()
    }

    static func makeDialer(_ options: RunOptions) -> any ChannelDialer {
        switch options.mode {
        case .simulator:
            SimulatorDialer(port: options.port)
        case .device(let udid):
            USBDialer(udid: udid, port: options.port)
        }
    }

    /// Shown on the phone. gethostname avoids the DNS lookup ProcessInfo.hostName can do.
    static func helperName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return BridgeConstants.helperNamePrefix }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let host = String(decoding: bytes, as: UTF8.self).split(separator: ".").first.map(String.init) ?? ""
        return host.isEmpty ? BridgeConstants.helperNamePrefix : "\(BridgeConstants.helperNamePrefix) · \(host)"
    }
}
#endif
