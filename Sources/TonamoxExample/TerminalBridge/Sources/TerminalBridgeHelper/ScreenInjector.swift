#if os(macOS)
import Darwin
import Foundation
import TerminalBridgeKit

public struct ScreenInjectorSettings: Sendable {
    public var session: String
    /// Always "0" in the CLI (one dedicated window); tests use other numbers.
    public var window: String
    public var idlePrompt: IdlePromptPattern
    /// Private 0700 directory for hardcopies; each probe uses a fresh 0600 file, deleted after reading.
    public var scratchDirectory: URL
    public var screenPath: String
    public var psPath: String
    public var userID: UInt32
    public var verificationAttempts: Int
    public var verificationInterval: Duration
    public var emptyHardcopyRereads: Int
    public var emptyHardcopyRereadInterval: Duration

    public init(
        session: String,
        window: String = BridgeConstants.defaultWindow,
        idlePrompt: IdlePromptPattern,
        scratchDirectory: URL,
        screenPath: String = ScreenVersionCheck.defaultScreenPath,
        psPath: String = ProcessTable.psPath,
        userID: UInt32 = getuid(),
        verificationAttempts: Int = 10,
        verificationInterval: Duration = .milliseconds(100),
        emptyHardcopyRereads: Int = 2,
        emptyHardcopyRereadInterval: Duration = .milliseconds(50)
    ) {
        self.session = session
        self.window = window
        self.idlePrompt = idlePrompt
        self.scratchDirectory = scratchDirectory
        self.screenPath = screenPath
        self.psPath = psPath
        self.userID = userID
        self.verificationAttempts = verificationAttempts
        self.verificationInterval = verificationInterval
        self.emptyHardcopyRereads = emptyHardcopyRereads
        self.emptyHardcopyRereadInterval = emptyHardcopyRereadInterval
    }
}

/// Everything `doctor` prints and `status` reports about the target window.
public struct ScreenInspection: Equatable, Sendable {
    public var state: TargetState
    public var detail: String
    /// The resolved `pid.name`, when exactly one live session has the configured name.
    public var socketName: String?
    public var candidates: [ScreenSessionEntry]
    public var windowCount: Int?
    public var foreground: String?
    public var lastLine: String?
    public var promptMatches: Bool?

    public init(
        state: TargetState,
        detail: String,
        socketName: String? = nil,
        candidates: [ScreenSessionEntry] = [],
        windowCount: Int? = nil,
        foreground: String? = nil,
        lastLine: String? = nil,
        promptMatches: Bool? = nil
    ) {
        self.state = state
        self.detail = detail
        self.socketName = socketName
        self.candidates = candidates
        self.windowCount = windowCount
        self.foreground = foreground
        self.lastLine = lastLine
        self.promptMatches = promptMatches
    }

    func refusing(_ newState: TargetState, _ reason: String) -> ScreenInspection {
        var copy = self
        copy.state = newState
        copy.detail = reason
        return copy
    }
}

/// How much an inspection proves.
public enum InspectionDepth: Sendable {
    /// Status polls: the process tree plus one hardcopy of the target window.
    case status
    /// Before a stuff, in doctor and status: also proves no other window number exists (~0.9 s).
    case beforeWrite
}

enum HardcopyCapture: Equatable, Sendable {
    case text(String)
    /// 0 bytes: screen writes nothing for a window that does not exist.
    case empty
    case failed(String)
}

/// Residual risks: a shell `read -q`, vi command mode and any screen overlay (C-a k's [y/n], C-a :, copy
/// mode) take printable keys while the hardcopy still shows an idle prompt. See the CLI's "Límites".
public actor ScreenInjector: TerminalTextInjector {
    /// screen 4.00.03 numbers windows 0...39 (measured: `screen 40` falls back to a free number).
    static let windowNumbers: [String] = (0...39).map { String($0) }

    private let settings: ScreenInjectorSettings
    private let runner: any ProcessRunner
    private let clock: any BridgeClock
    private let onStateChange: (@Sendable (ScreenInspection) -> Void)?
    private var lastState: TargetState?

    /// `onStateChange` sees each inspection whose state differs from the previous one.
    public init(
        settings: ScreenInjectorSettings,
        runner: any ProcessRunner = SystemProcessRunner(),
        clock: any BridgeClock = SystemBridgeClock(),
        onStateChange: (@Sendable (ScreenInspection) -> Void)? = nil
    ) {
        self.settings = settings
        self.runner = runner
        self.clock = clock
        self.onStateChange = onStateChange
    }

    public func currentTarget() async -> TargetStatus {
        let inspection = await inspect(.status)
        return TargetStatus(
            session: settings.session,
            window: settings.window,
            state: inspection.state,
            foreground: inspection.foreground
        )
    }

    public func type(_ text: String) async -> InjectionOutcome {
        guard Self.isTypeable(text) else { return Self.policyRefusal }
        let inspection = await inspect(.beforeWrite)
        guard inspection.state == .ready, let socketName = inspection.socketName else {
            return .refused(inspection.state.refusalCode ?? .screenUnavailable, detail: inspection.detail)
        }
        return await deliver(text, to: socketName)
    }

    // MARK: Inspection

    public func inspect(_ depth: InspectionDepth = .beforeWrite) async -> ScreenInspection {
        let inspection = await inspectTarget(depth)
        if inspection.state != lastState {
            lastState = inspection.state
            onStateChange?(inspection)
        }
        return inspection
    }

    private func inspectTarget(_ depth: InspectionDepth) async -> ScreenInspection {
        let session = settings.session
        let listing = await runner.run(settings.screenPath, ["-ls"])
        guard listing.didLaunch, !listing.timedOut else {
            let reason = "No se pudo ejecutar \(settings.screenPath) -ls."
            return ScreenInspection(state: .screenUnavailable, detail: reason)
        }
        let entries = ScreenListParser.parse(listing.stdoutText)
        let report = ScreenInspection(state: .ready, detail: "", candidates: entries.filter { $0.name == session })
        let entry: ScreenSessionEntry
        switch ScreenListParser.match(session, in: entries) {
        case .missing:
            return report.refusing(
                .sessionMissing, "No hay sesión screen '\(session)'. Ábrela en Terminal con: screen -S \(session)"
            )
        case .ambiguous(let matches):
            let names = matches.map(\.socketName).joined(separator: ", ")
            return report.refusing(
                .ambiguousSession, "Hay \(matches.count) sesiones '\(session)' (\(names)); cierra las que sobren."
            )
        case .found(let match):
            entry = match
        }
        var resolved = report
        resolved.socketName = entry.socketName
        // Before the process-tree and prompt checks, so the slow probe does not widen the gap to the stuff.
        if depth == .beforeWrite, let refusal = await otherWindowRefusal(entry.socketName, from: resolved) {
            return refusal
        }
        return await inspectWindow(of: entry, from: resolved)
    }

    /// A window with no process of its own (zombie, telnet, serial) is invisible in the process tree,
    /// but its hardcopy is not empty; a missing window number hardcopies 0 bytes.
    private func otherWindowRefusal(_ socketName: String, from report: ScreenInspection) async -> ScreenInspection? {
        for number in Self.windowNumbers where number != settings.window {
            switch await hardcopy(socketName, window: number, rereadsWhenEmpty: false) {
            case .empty:
                continue
            case .text:
                return report.refusing(
                    .multipleWindows,
                    "La sesión '\(settings.session)' tiene también la ventana \(number) (quizá sin proceso: zombie, "
                        + "telnet o serie); usa una sesión dedicada de una sola ventana."
                )
            case .failed(let reason):
                return report.refusing(.screenUnavailable, reason)
            }
        }
        return nil
    }

    private func inspectWindow(of entry: ScreenSessionEntry, from report: ScreenInspection) async -> ScreenInspection {
        guard let table = await processTable() else {
            return report.refusing(.screenUnavailable, "No se pudo leer la tabla de procesos con \(settings.psPath).")
        }
        let processes = WindowProcessReport.analyze(table, screenPID: entry.pid, userID: settings.userID)
        var inspected = report
        inspected.windowCount = processes.windowCount
        inspected.foreground = processes.foreground
        switch processes.verdict {
        case .noWindow:
            return inspected.refusing(.windowMissing, "La sesión '\(settings.session)' no tiene ventanas.")
        case .multipleWindows(let count):
            return inspected.refusing(
                .multipleWindows,
                "La sesión '\(settings.session)' tiene \(count) ventanas; usa una sesión dedicada de una sola ventana."
            )
        case .notShell(let name):
            return inspected.refusing(
                .foregroundNotShell,
                "En primer plano está '\(name)', no el shell de la ventana. Sal de él antes de escribir."
            )
        case .shellInForeground:
            break
        }
        return await inspectPrompt(entry.socketName, from: inspected)
    }

    private func inspectPrompt(_ socketName: String, from report: ScreenInspection) async -> ScreenInspection {
        let screenText: String
        switch await hardcopy(socketName) {
        case .text(let text):
            screenText = text
        case .empty:
            return report.refusing(.windowMissing, "No existe la ventana \(settings.window) en '\(settings.session)'.")
        case .failed(let reason):
            return report.refusing(.screenUnavailable, reason)
        }
        var inspected = report
        let line = IdlePromptPattern.lastNonEmptyLine(of: screenText)
        let idle = line.map(settings.idlePrompt.matches) ?? false
        inspected.lastLine = line
        inspected.promptMatches = idle
        guard idle else {
            return inspected.refusing(
                .promptNotIdle, "La terminal no está en un prompt vacío (regex \(settings.idlePrompt.pattern))."
            )
        }
        inspected.detail = "Listo: \(settings.session):\(settings.window)"
        return inspected
    }

    private func processTable() async -> ProcessTable? {
        let result = await runner.run(settings.psPath, ProcessTable.psArguments)
        guard result.didLaunch, !result.timedOut, result.status == 0 else { return nil }
        return ProcessTable(parsing: result.stdoutText)
    }

    func hardcopy(
        _ socketName: String,
        window: String? = nil,
        rereadsWhenEmpty: Bool = true
    ) async -> HardcopyCapture {
        let target = settings.scratchDirectory
            .appending(path: "hc-\(UUID().uuidString).txt", directoryHint: .notDirectory)
        do {
            try PrivateFiles.createEmpty(target)
        } catch {
            return .failed(error.message)
        }
        let path = PrivateFiles.path(target)
        defer { unlink(path) }
        let result = await runner.run(
            settings.screenPath, ["-S", socketName, "-p", window ?? settings.window, "-X", "hardcopy", path]
        )
        guard result.didLaunch, !result.timedOut else {
            return .failed("screen hardcopy no terminó: \(result.launchError ?? "timeout")")
        }
        guard result.status == 0 else {
            return .failed("screen hardcopy rc \(result.status): \(Self.firstLine(result.stderrText))")
        }
        return await readHardcopy(path, rereads: rereadsWhenEmpty ? settings.emptyHardcopyRereads : 0)
    }

    /// screen has written the file by the time `-X` returns (measured), but rereads cover a slow server.
    private func readHardcopy(_ path: String, rereads allowed: Int) async -> HardcopyCapture {
        var contents = FileManager.default.contents(atPath: path) ?? Data()
        var rereads = 0
        while contents.isEmpty, rereads < allowed {
            rereads += 1
            try? await clock.sleep(for: settings.emptyHardcopyRereadInterval)
            contents = FileManager.default.contents(atPath: path) ?? contents
        }
        guard !contents.isEmpty else { return .empty }
        return .text(String(decoding: contents, as: UTF8.self))
    }

    // MARK: Typing

    /// Last stop before screen: re-checks the bytes on its own, then stuffs and verifies.
    func deliver(_ text: String, to socketName: String) async -> InjectionOutcome {
        guard Self.isTypeable(text) else { return Self.policyRefusal }
        let arguments = Self.stuffArguments(socketName: socketName, window: settings.window, text: text)
        let result = await runner.run(settings.screenPath, arguments)
        guard result.didLaunch else {
            return .refused(.screenUnavailable, detail: result.launchError ?? settings.screenPath)
        }
        guard result.status == 0, !result.timedOut else {
            let reason = result.timedOut ? "timeout" : "rc \(result.status): \(Self.firstLine(result.stderrText))"
            return .refused(.screenFailed, detail: "screen stuff falló (\(reason)).")
        }
        return .typed(verified: await verify(text, socketName: socketName))
    }

    /// Best effort: rc 0 proves nothing (screen drops some stuffs silently), so look for the text.
    private func verify(_ text: String, socketName: String) async -> Bool {
        let expected = Self.compacted(text)
        var attempts = 0
        while attempts < settings.verificationAttempts {
            attempts += 1
            try? await clock.sleep(for: settings.verificationInterval)
            if case .text(let screenText) = await hardcopy(socketName), Self.screen(screenText, endsWith: expected) {
                return true
            }
        }
        return false
    }

    public static func stuffArguments(socketName: String, window: String, text: String) -> [String] {
        ["-S", socketName, "-p", window, "-X", "stuff", text]
    }

    /// Printable ASCII only, 1...512 bytes, no blank at either end: checked again here so a
    /// control byte never reaches screen even if the Kit policy were bypassed or changed.
    static func isTypeable(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count <= BridgeConstants.maxTextBytes else { return false }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else { return false }
        return CommandTextPolicy.isValid(bytes: bytes)
    }

    static let policyRefusal = InjectionOutcome.refused(
        .policy, detail: "Solo se escribe una línea de ASCII imprimible (1-512 bytes)."
    )

    /// Wrapped lines are joined and blanks dropped: hardcopy trims the blank at a wrap point.
    static func screen(_ screenText: String, endsWith expected: String) -> Bool {
        let joined = screenText.split(whereSeparator: \.isNewline).joined()
        return compacted(joined).hasSuffix(expected)
    }

    static func compacted(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }

    static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }
}
#endif
