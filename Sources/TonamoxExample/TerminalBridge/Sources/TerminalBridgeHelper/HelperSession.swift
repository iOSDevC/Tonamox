#if os(macOS)
import Foundation
import TerminalBridgeKit

/// Timestamped lines on stdout. Command text is never logged, only sizes and ids.
public final class HelperConsole: Sendable {
    static let clockStyle = Date.ISO8601FormatStyle(timeZone: .current).time(includingFractionalSeconds: false)

    public static let standardOutput: @Sendable (String) -> Void = { line in
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    public let verbose: Bool
    private let sink: @Sendable (String) -> Void

    public init(verbose: Bool = false, sink: @escaping @Sendable (String) -> Void = HelperConsole.standardOutput) {
        self.verbose = verbose
        self.sink = sink
    }

    public func info(_ message: String) {
        sink("\(Date().formatted(Self.clockStyle)) \(Self.printable(message))")
    }

    /// Peer-supplied strings reach this console: controls (C0, DEL, C1) and bidi or line-separator
    /// formats become "?" so they cannot drive the terminal or forge lines.
    static func printable(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.map { isDisplaySafe($0) ? $0 : "?" })
        return String(scalars)
    }

    static func isDisplaySafe(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F, 0x061C, 0x200E, 0x200F, 0x2028...0x202E, 0x2066...0x2069: false
        default: true
        }
    }

    public func debug(_ message: String) {
        guard verbose else { return }
        info(message)
    }
}

/// Journals every write attempt and prints one line about it.
public struct ReportingRecorder: WriteRecorder {
    public let journal: WriteJournal?
    public let console: HelperConsole
    public let targetLabel: String

    public init(journal: WriteJournal?, console: HelperConsole, targetLabel: String) {
        self.journal = journal
        self.console = console
        self.targetLabel = targetLabel
    }

    public func record(_ write: WriteRecord) async {
        await journal?.record(write)
        console.info(Self.describe(write, target: targetLabel))
    }

    static func describe(_ write: WriteRecord, target: String) -> String {
        let id = String(write.id.uuidString.prefix(8))
        switch write.outcome {
        case .typed where write.verified:
            return "escrito \(write.bytes) B (id \(id)) → \(target), verificado. Revisa la línea y pulsa Enter tú."
        case .typed:
            return "escrito \(write.bytes) B (id \(id)) → \(target), NO verificado: revisa la terminal (¿modo copia?)."
        case .alreadyTyped:
            return "id \(id) ya estaba escrito; no se vuelve a teclear."
        case .refused(let code):
            return "rechazado (\(HelperSession.displayCode(code))), id \(id), \(write.bytes) B; no se tecleó nada."
        }
    }
}

/// Retry delays: 0.5, 1, 2, 4 s, then the cap (5 s).
public struct BackoffPolicy: Sendable {
    public var steps: [Duration]
    public var cap: Duration

    public init(
        steps: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4)],
        cap: Duration = .seconds(5)
    ) {
        self.steps = steps
        self.cap = cap
    }

    public func delay(afterFailures failures: Int) -> Duration {
        guard failures >= 0, failures < steps.count else { return cap }
        return min(steps[failures], cap)
    }
}

/// Dial, serve, back off, repeat until `stop()`. A phone rejection is unauthenticated (anyone on
/// loopback can send it), so it is logged and retried, never a reason to exit or unpair.
public actor HelperSession {
    public static let defaultRejectionSummaryInterval: Duration = .seconds(60)

    public private(set) var dialAttempts = 0
    public private(set) var phoneRejections = 0
    public private(set) var lastEnd: HelperSessionEnd?

    /// Identical rejections in a row: the first is logged, then one line with a count per interval.
    private struct RejectionStreak {
        let detail: String
        var lastLoggedAt: Duration
        var unlogged = 0
    }

    private let engine: HelperBridgeSession
    private let dialer: any ChannelDialer
    private let console: HelperConsole
    private let journal: WriteJournal?
    private let clock: any BridgeClock
    private let backoff: BackoffPolicy
    private var activeChannel: BridgeChannel?
    private var isStopping = false
    private var lastWaitingNote: String?
    private let rejectionSummaryInterval: Duration
    private var streak: RejectionStreak?

    public init(
        engine: HelperBridgeSession,
        dialer: any ChannelDialer,
        console: HelperConsole,
        journal: WriteJournal? = nil,
        clock: any BridgeClock = SystemBridgeClock(),
        backoff: BackoffPolicy = BackoffPolicy(),
        rejectionSummaryInterval: Duration = HelperSession.defaultRejectionSummaryInterval
    ) {
        self.engine = engine
        self.dialer = dialer
        self.console = console
        self.journal = journal
        self.clock = clock
        self.backoff = backoff
        self.rejectionSummaryInterval = rejectionSummaryInterval
    }

    /// Runs until `stop()` or task cancellation.
    public func run() async {
        var failures = 0
        while !isStopping, !Task.isCancelled {
            failures = await serveOnce(consecutiveFailures: failures)
            guard !isStopping else { break }
            do {
                try await clock.sleep(for: backoff.delay(afterFailures: failures))
            } catch {
                break
            }
        }
        flushRejections()
        activeChannel?.close()
    }

    public func stop() {
        isStopping = true
        activeChannel?.close()
    }

    /// One dial and, if it connects, one served session. Returns the new failure streak.
    private func serveOnce(consecutiveFailures failures: Int) async -> Int {
        dialAttempts += 1
        let channel: BridgeChannel
        do {
            channel = try await dialer.dial()
        } catch {
            noteWaiting(Self.describe(error))
            return failures + 1
        }
        guard !isStopping else {
            channel.close()
            return failures
        }
        activeChannel = channel
        let end = await engine.run(on: channel)
        activeChannel = nil
        lastEnd = end
        lastWaitingNote = nil
        return report(end, failures: failures)
    }

    private func report(_ end: HelperSessionEnd, failures: Int) -> Int {
        switch end {
        case .rejectedByPhone, .phoneProofInvalid, .handshakeFailed:
            break
        case .closedByPeer, .heartbeatTimeout, .protocolError:
            flushRejections()
        }
        switch end {
        case .closedByPeer:
            console.info("Desconectado: la app cerró la conexión. Reintentando…")
            journal?.note(.disconnected, detail: "closedByPeer")
            return 0
        case .heartbeatTimeout:
            console.info("Sin respuesta del teléfono en 25 s; reconectando…")
            journal?.note(.disconnected, detail: "heartbeatTimeout")
            return 0
        case .rejectedByPhone(let code):
            phoneRejections += 1
            noteRejection(
                "rejectedByPhone:\(Self.journalCode(code))",
                message: "\(dialer.displayName) rechazó la prueba del helper (\(Self.displayCode(code))). Si "
                    + "regeneraste el código en la app, empareja otra vez (tonamox-bridge pair). Sigo reintentando."
            )
            return failures + 1
        case .phoneProofInvalid:
            noteRejection(
                "phoneProofInvalid",
                message: "Algo en \(dialer.displayName) no demostró el emparejamiento; no se tecleó nada."
            )
            return failures + 1
        case .handshakeFailed(let detail):
            console.info("Handshake fallido con \(dialer.displayName).")
            console.debug("handshake: \(detail)")
            return failures + 1
        case .protocolError(let detail):
            console.info("Error de protocolo; cierro la conexión.")
            console.debug("protocolo: \(detail)")
            journal?.note(.disconnected, detail: "protocolError")
            return failures + 1
        }
    }

    private func noteRejection(_ detail: String, message: String) {
        let now = clock.now()
        guard var current = streak, current.detail == detail else {
            flushRejections()
            console.info(message)
            journal?.note(.rejected, detail: detail, count: 1)
            streak = RejectionStreak(detail: detail, lastLoggedAt: now)
            return
        }
        current.unlogged += 1
        if now - current.lastLoggedAt >= rejectionSummaryInterval {
            logUnlogged(current)
            current.unlogged = 0
            current.lastLoggedAt = now
        }
        streak = current
    }

    /// Ends the streak, logging the count of rejections not logged one by one.
    private func flushRejections() {
        guard let current = streak else { return }
        streak = nil
        logUnlogged(current)
    }

    private func logUnlogged(_ current: RejectionStreak) {
        guard current.unlogged > 0 else { return }
        console.info("Siguen los rechazos (\(current.detail)): \(current.unlogged) más. Sigo reintentando.")
        journal?.note(.rejected, detail: current.detail, count: current.unlogged)
    }

    /// Error codes from an unauthenticated peer: an unknown one is reported only by its size.
    static func displayCode(_ code: BridgeErrorCode) -> String {
        guard case .unrecognized(let value) = code else { return code.wireValue }
        return "código desconocido, \(value.utf8.count) B"
    }

    static func journalCode(_ code: BridgeErrorCode) -> String {
        guard case .unrecognized(let value) = code else { return code.wireValue }
        return "unrecognized(\(value.utf8.count)B)"
    }

    private func noteWaiting(_ reason: String) {
        let note = "Esperando la app en \(dialer.displayName)… (\(reason))"
        guard note != lastWaitingNote else { return }
        lastWaitingNote = note
        console.info(note)
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as USBMuxError:
            error.message
        case BridgeChannelError.connectionFailed:
            "no hay nadie escuchando"
        default:
            String(describing: error)
        }
    }
}
#endif
