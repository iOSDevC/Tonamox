#if os(macOS)
import Darwin
import Foundation
import TerminalBridgeKit

/// Exit codes of `tonamox-bridge` (sysexits where one fits).
public enum HelperExitCode {
    public static let success: Int32 = 0
    /// Runtime failure; also `doctor` when the target is not ready.
    public static let failure: Int32 = 1
    public static let usage: Int32 = 64
    /// Missing pairing, unreadable or insecure config/journal, bad pairing code.
    public static let configuration: Int32 = 65
    /// /usr/bin/screen missing or not 4.00.03.
    public static let screenUnavailable: Int32 = 69
    /// Refuses to run as root. A rejection by the phone never exits.
    public static let runningAsRoot: Int32 = 77
}

/// Why a one-off inspection (status, doctor) could not run, and the exit code it maps to.
enum InspectionFailure: Error, Equatable {
    case screenUnavailable
    /// The saved prompt regex is invalid; a bad --prompt-regex argument fails at parse time (64).
    case configuration
    case scratchDirectory

    var exitCode: Int32 {
        switch self {
        case .screenUnavailable: HelperExitCode.screenUnavailable
        case .configuration: HelperExitCode.configuration
        case .scratchDirectory: HelperExitCode.failure
        }
    }
}

/// Console I/O, injectable so the subcommands can be tested.
public struct HelperIO: Sendable {
    public var out: @Sendable (String) -> Void
    public var err: @Sendable (String) -> Void
    /// Reads one line; `hideInput` turns terminal echo off while typing a secret.
    public var readLine: @Sendable (_ hideInput: Bool) -> String?

    public init(
        out: @escaping @Sendable (String) -> Void,
        err: @escaping @Sendable (String) -> Void,
        readLine: @escaping @Sendable (_ hideInput: Bool) -> String?
    ) {
        self.out = out
        self.err = err
        self.readLine = readLine
    }

    public static let standard = HelperIO(
        out: HelperConsole.standardOutput,
        err: { line in FileHandle.standardError.write(Data((line + "\n").utf8)) },
        readLine: TerminalInput.readLine(hideInput:)
    )
}

enum TerminalInput {
    static func readLine(hideInput: Bool) -> String? {
        guard hideInput, isatty(STDIN_FILENO) == 1 else { return Swift.readLine(strippingNewline: true) }
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return Swift.readLine(strippingNewline: true) }
        var silent = original
        silent.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &silent)
        defer {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
            FileHandle.standardError.write(Data("\n".utf8))
        }
        return Swift.readLine(strippingNewline: true)
    }
}

public enum HelperCLI {
    public static let version = "1.0.0"

    public static func main(_ arguments: [String], io streams: HelperIO = .standard) async -> Int32 {
        let command: HelperCommand
        do {
            command = try HelperOptions.parse(arguments)
        } catch {
            streams.err(error.message)
            streams.err(HelperOptions.usage)
            return HelperExitCode.usage
        }
        switch command {
        case .help:
            streams.out(HelperOptions.usage)
            return HelperExitCode.success
        case .version:
            streams.out("tonamox-bridge \(version) (protocolo \(BridgeConstants.protocolVersion))")
            return HelperExitCode.success
        case .pair(let source, let configURL):
            return pair(source, store: configStore(configURL), io: streams)
        case .unpair(let configURL):
            return unpair(store: configStore(configURL), io: streams)
        case .status(let options):
            return await status(options, io: streams)
        case .doctor(let options):
            return await doctor(options, io: streams)
        case .run(let options):
            return await run(options, io: streams)
        }
    }

    // MARK: pair / unpair

    static func pair(_ source: PairSource, store: HelperConfigStore, io streams: HelperIO) -> Int32 {
        let code: PairingCode
        switch source {
        case .generate:
            code = PairingCode.generate()
        case .code(let text):
            guard let parsed = parseCode(text, io: streams) else { return HelperExitCode.configuration }
            code = parsed
        case .standardInput:
            streams.err("Escribe el código que muestra Tonamox Terminal › Emparejar (no se mostrará):")
            guard let line = streams.readLine(true), let parsed = parseCode(line, io: streams) else {
                return HelperExitCode.configuration
            }
            code = parsed
        }
        do {
            var config = try store.loadIfPresent() ?? HelperConfig()
            config.pair(with: code)
            try store.save(config)
        } catch {
            streams.err(error.message)
            return HelperExitCode.configuration
        }
        if source == .generate {
            streams.out("Código de emparejamiento: \(code.formatted)")
            streams.out("Escríbelo en Tonamox Terminal › Emparejar (o pásalo al simulador en DEBUG).")
        }
        streams.out("Huella: \(code.fingerprint)")
        streams.out("Emparejado. Guardado en \(store.path) (0600).")
        streams.out("Comprueba que la huella coincide con la del teléfono.")
        return HelperExitCode.success
    }

    static func parseCode(_ text: String, io streams: HelperIO) -> PairingCode? {
        do {
            return try PairingCode(parsing: text)
        } catch {
            streams.err(pairingMessage(error))
            return nil
        }
    }

    static func pairingMessage(_ error: PairingCodeError) -> String {
        switch error {
        case .checksumMismatch:
            "Código mal copiado: el control no coincide. Vuelve a escribirlo."
        case .wrongLength(let count):
            "El código tiene \(count) caracteres; deben ser 36 (los guiones no cuentan)."
        case .invalidCharacter(let character):
            "Carácter no válido en el código: '\(character)'."
        case .invalidSecretLength(let count):
            "Secreto de \(count) bytes; deben ser \(BridgeConstants.secretByteCount)."
        }
    }

    static func unpair(store: HelperConfigStore, io streams: HelperIO) -> Int32 {
        do {
            guard var config = try store.loadIfPresent(), config.isPaired else {
                streams.out("No había emparejamiento en \(store.path).")
                return HelperExitCode.success
            }
            config.unpair()
            try store.save(config)
        } catch {
            streams.err(error.message)
            return HelperExitCode.configuration
        }
        streams.out("Emparejamiento borrado de \(store.path). Empareja de nuevo con: tonamox-bridge pair")
        return HelperExitCode.success
    }

    // MARK: status / doctor

    static func status(_ options: StatusOptions, io streams: HelperIO) async -> Int32 {
        streams.out("tonamox-bridge \(version) (protocolo \(BridgeConstants.protocolVersion))")
        var code = HelperExitCode.success
        let store = HelperConfigStore(fileURL: options.configURL ?? HelperConfigStore.defaultURL)
        var savedRegex: String?
        do {
            let config = try store.loadIfPresent()
            savedRegex = config?.promptRegex
            streams.out("Config: \(store.path): \(pairingSummary(config))")
        } catch {
            streams.out("Config: \(error.message)")
            code = HelperExitCode.configuration
        }
        if !printJournalSummary(options.journalURL, io: streams) { code = HelperExitCode.configuration }
        var target = options.target
        target.promptRegex = target.promptRegex ?? savedRegex
        switch await inspectTarget(target, io: streams) {
        case .success(let inspection):
            let state = inspection.state.wireValue
            streams.out("Destino \(target.session):\(target.window): \(state) — \(inspection.detail)")
        case .failure(let failure):
            if code == HelperExitCode.success { code = failure.exitCode }
        }
        if options.listUSBDevices {
            await listUSB(io: streams)
        }
        return code
    }

    /// Read-only; returns false when the journal exists but cannot be read safely.
    static func printJournalSummary(_ journalURL: URL?, io streams: HelperIO) -> Bool {
        let url = journalURL ?? WriteJournal.defaultURL
        do {
            let summary = try WriteJournal.summary(at: url)
            let typed = summary.counts["typed", default: 0]
            let refused = summary.counts["refused", default: 0]
            let scope = summary.isPartial ? " (en el último MiB)" : ""
            streams.out("Journal: \(PrivateFiles.path(url)): \(typed) escritas, \(refused) rechazadas\(scope)")
            return true
        } catch {
            streams.out("Journal: \(error.message)")
            return false
        }
    }

    static func pairingSummary(_ config: HelperConfig?) -> String {
        guard let config, config.isPaired else { return "sin emparejar" }
        let since = config.pairedAt.map { " desde \($0.formatted(WriteJournal.timestampStyle))" } ?? ""
        return "emparejado, huella \(config.fingerprint ?? "?")\(since)"
    }

    static func listUSB(io streams: HelperIO) async {
        do {
            let devices = try await USBMuxClient().listDevices()
            let usb = devices.filter(\.isUSB)
            streams.out("usbmuxd: \(usb.count) por USB, \(devices.count - usb.count) por red")
            usb.forEach { streams.out("  USB \($0.serialNumber) (DeviceID \($0.deviceID))") }
        } catch let error as USBMuxError {
            streams.out("usbmuxd: \(error.message)")
        } catch {
            streams.out("usbmuxd: \(error)")
        }
    }

    static let doctorAdvice = """
    Modo vi: el modo comando no se ve en el hardcopy y cada letra sería una orden del editor. Muestra
      el modo en PROMPT (zsh: zle-keymap-select) y usa un --prompt-regex que solo acepte el de inserción.
    No dejes abierto un aviso de screen (C-a k, C-a :) ni el modo copia: recibirían lo que se teclee.
    """

    static func doctor(_ options: StatusOptions, io streams: HelperIO) async -> Int32 {
        var resolved = options.target
        if resolved.promptRegex == nil {
            let store = HelperConfigStore(fileURL: options.configURL ?? HelperConfigStore.defaultURL)
            do {
                resolved.promptRegex = try store.loadIfPresent()?.promptRegex
            } catch {
                streams.err("Config: \(error.message)")
                return HelperExitCode.configuration
            }
        }
        let inspection: ScreenInspection
        switch await inspectTarget(resolved, io: streams) {
        case .success(let found):
            inspection = found
        case .failure(let failure):
            return failure.exitCode
        }
        streams.out("Sesión: '\(resolved.session)' → \(inspection.socketName ?? "sin resolver")")
        if inspection.candidates.count > 1 {
            streams.out("  Candidatas: \(inspection.candidates.map(\.socketName).joined(separator: ", "))")
        }
        let windows = inspection.windowCount.map { String($0) } ?? "—"
        streams.out("Ventanas con proceso: \(windows) (se exige 1 y ninguna otra de la 1 a la 39; siempre -p 0)")
        streams.out("Primer plano: \(inspection.foreground ?? "—")")
        streams.out("Última línea no vacía: \(inspection.lastLine.map { "\"\($0)\"" } ?? "—")")
        let pattern = resolved.promptRegex ?? IdlePromptPattern.defaultPattern
        streams.out("Regex de prompt inactivo: \(pattern) → \(matchSummary(inspection.promptMatches))")
        streams.out("Estado: \(inspection.state.wireValue) — \(inspection.detail)")
        _ = printJournalSummary(options.journalURL, io: streams)
        streams.out(doctorAdvice)
        streams.out("(doctor no teclea nada)")
        return inspection.state == .ready ? HelperExitCode.success : HelperExitCode.failure
    }

    static func matchSummary(_ matches: Bool?) -> String {
        switch matches {
        case true?: "coincide"
        case false?: "NO coincide"
        case nil: "sin comprobar"
        }
    }

    /// Checks the screen version, then inspects the target once, as thoroughly as before a write,
    /// without typing anything.
    static func inspectTarget(
        _ target: TargetOptions,
        io streams: HelperIO
    ) async -> Result<ScreenInspection, InspectionFailure> {
        let runner = SystemProcessRunner()
        guard await checkScreen(runner: runner, io: streams) else { return .failure(.screenUnavailable) }
        let pattern: IdlePromptPattern
        do {
            pattern = try IdlePromptPattern(target.promptRegex ?? IdlePromptPattern.defaultPattern)
        } catch {
            streams.err(error.message)
            return .failure(.configuration)
        }
        let scratch: URL
        do {
            scratch = try makeScratchDirectory()
        } catch {
            streams.err(error.message)
            return .failure(.scratchDirectory)
        }
        defer { rmdir(PrivateFiles.path(scratch)) }
        let settings = ScreenInjectorSettings(
            session: target.session,
            window: target.window,
            idlePrompt: pattern,
            scratchDirectory: scratch
        )
        return .success(await ScreenInjector(settings: settings, runner: runner).inspect(.beforeWrite))
    }

    static func checkScreen(runner: any ProcessRunner, io streams: HelperIO) async -> Bool {
        switch await ScreenVersionCheck.check(runner: runner) {
        case .supported(let found):
            streams.out("screen: \(ScreenVersionCheck.defaultScreenPath) \(found) ✓")
            return true
        case .unsupported(let found):
            let path = ScreenVersionCheck.defaultScreenPath
            let required = ScreenVersionCheck.requiredVersion
            streams.err("screen: se exige \(required) y \(path) dice '\(found)'. No continúo.")
            return false
        case .unavailable(let reason):
            streams.err("screen: \(reason)")
            return false
        }
    }

    static func configStore(_ configURL: URL?) -> HelperConfigStore {
        HelperConfigStore(fileURL: configURL ?? HelperConfigStore.defaultURL)
    }

    /// $TMPDIR when it is set: FileManager.temporaryDirectory ignores it (measured) and returns the per-user
    /// confstr folder, which is the fallback.
    static var temporaryParent: URL {
        if let value = ProcessInfo.processInfo.environment["TMPDIR"], value.hasPrefix("/") {
            return URL(filePath: value, directoryHint: .isDirectory)
        }
        return FileManager.default.temporaryDirectory
    }

    /// A fresh hardcopy folder in $TMPDIR, after sweeping the ones killed helpers left behind.
    static func makeScratchDirectory(in parent: URL = temporaryParent) throws(PrivateFileError) -> URL {
        ScratchDirectories.sweepStale(in: parent)
        return try ScratchDirectories.make(in: parent)
    }
}
#endif
