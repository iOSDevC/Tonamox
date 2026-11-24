import Foundation

// MARK: - Line with the ingest suffix

/// A command with the web server's ingest suffix appended, so the computer posts its output to this iPhone.
/// Pure text: the app passes the suffix (`IngestTicket.curlSuffix(on:)`); this package never sees the server.
public struct NetworkOutputLine: Hashable, Sendable {
    public let ticketID: UUID
    public let host: HostOS
    public let original: String
    public let suffix: String
    /// `original + suffix`: the single line any channel sends instead of `original`.
    public let line: String

    /// What every suffix starts with; anything else is not a suffix this app made.
    static let suffixPrefix = " 2>&1 | curl "

    /// Checked before a ticket exists: Windows, then the capture's refusal rules, since appending `| curl` puts the
    /// command in a pipeline exactly like the capture wrapper does (cd, export and assignments would be lost, a
    /// comment or an open quote would swallow the suffix, an endless program would never post).
    public static func refusal(for original: String, host: HostOS) -> NetworkOutputRefusal? {
        // PowerShell's `curl` is Invoke-WebRequest in 5.1 and `2>&1 |` differs; only POSIX shells are supported.
        if host == .windows { return .windows }
        return CaptureRefusalRules.refusal(for: original, host: host).map(NetworkOutputRefusal.rule)
    }

    public static func make(
        original: String,
        suffix: String,
        host: HostOS,
        ticketID: UUID
    ) -> Result<NetworkOutputLine, NetworkOutputRefusal> {
        if let refusal = refusal(for: original, host: host) { return .failure(refusal) }
        guard suffix.hasPrefix(suffixPrefix), !suffix.contains(where: \.isNewline) else {
            return .failure(.invalidSuffix)
        }
        let line = original + suffix
        let bytes = line.utf8.count
        if bytes > CommandTextPolicy.maxBytes { return .failure(.tooLong(bytes: bytes, suffixBytes: suffix.utf8.count)) }
        guard CommandTextPolicy.validate(line).isEmpty else { return .failure(.invalidSuffix) }
        return .success(NetworkOutputLine(ticketID: ticketID, host: host, original: original, suffix: suffix, line: line))
    }

    /// `<position> <program>`, for example "3.1 git"; the server filters it to `[A-Za-z0-9 ._-]` and 40 characters.
    public static func ticketLabel(position: String, original: String) -> String {
        let words = ShellCommandParser.commands(in: ShellLexer.tokenize(original)).first?.words ?? []
        let program = ShellCommandParser.resolve(words[...]).names.last ?? "orden"
        let kept = (position + " " + program).filter { $0.isASCII && ($0.isLetter || $0.isNumber || " ._-".contains($0)) }
        return String(kept.prefix(40))
    }

    /// A loopback server is reachable from the computer only through a USB forward of the same port; without it
    /// curl posts to the computer's own 127.0.0.1.
    public static func loopbackForwardHint(port: UInt16) -> (command: String, explanation: String) {
        ("iproxy -s 127.0.0.1 \(port):\(port)",
         "El servidor escucha solo en 127.0.0.1: antes de ejecutar la orden, deja corriendo en el ordenador este "
            + "reenvío por cable USB. Sin él, curl envía la salida al propio ordenador y no llega al iPhone.")
    }
}

public enum NetworkOutputRefusal: Error, Hashable, Sendable {
    /// One of the capture's refusal rules.
    case rule(CaptureRefusal)
    case windows
    /// The whole line exceeds `CommandTextPolicy.maxBytes`.
    case tooLong(bytes: Int, suffixBytes: Int)
    /// The suffix is not a single printable-ASCII line starting with ` 2>&1 | curl `.
    case invalidSuffix

    static let sendWithout = " Se puede enviar sin el envío por red."

    /// Spanish; says how to go on where there is a way.
    public var message: String {
        switch self {
        case .rule(let refusal):
            "Sin envío por red (mismas reglas que «Capturar salida»): "
                + refusal.message.replacingOccurrences(of: CaptureRefusal.sendWithoutCapture, with: Self.sendWithout)
        case .windows:
            "El envío por red usa curl y una tubería de shell POSIX; en Windows (PowerShell) no funciona. Elige macOS "
                + "o Linux como sistema del ordenador si es el caso."
        case .tooLong(let bytes, let suffixBytes):
            "Con el envío por red la línea ocuparía \(bytes) bytes; el máximo es \(CommandTextPolicy.maxBytes) y el "
                + "final con el enlace ocupa \(suffixBytes)." + Self.sendWithout
        case .invalidSuffix:
            "El enlace del servidor no tiene la forma esperada; no se ha añadido nada."
        }
    }
}

// MARK: - Ticket state

public enum NetworkTicketPhase: Hashable, Sendable {
    case open(expiresAt: Date)
    /// `laterPostRefused`: the server refused another post with this ticket (raced or after use).
    case used(receivedAt: Date, laterPostRefused: Bool = false)
    case cancelledByServerStop

    public func isExpired(now: Date) -> Bool {
        guard case .open(let expiresAt) = self else { return false }
        return now >= expiresAt
    }

    /// The server run ended: an open ticket died with it; a used one keeps saying its output arrived.
    public func endedByServerStop() -> NetworkTicketPhase {
        guard case .open = self else { return self }
        return .cancelledByServerStop
    }

    /// The output arrived; `laterPostRefused` carries a refusal seen while the ticket was still open (a race).
    public func arrived(at date: Date, laterPostRefused: Bool) -> NetworkTicketPhase {
        guard case .open = self else { return self }
        return .used(receivedAt: date, laterPostRefused: laterPostRefused)
    }

    public func refusingLaterPost() -> NetworkTicketPhase {
        guard case .used(let receivedAt, _) = self else { return self }
        return .used(receivedAt: receivedAt, laterPostRefused: true)
    }

    /// Spanish status line under the command; `time` formats a date as hours and minutes.
    public func text(now: Date, time: (Date) -> String) -> String {
        switch self {
        case .open(let expiresAt) where now >= expiresAt:
            "Enlace caducado a las \(time(expiresAt)): el servidor ya no lo acepta. Desactiva y vuelve a activar "
                + "«Enviar salida al iPhone por red» para tener uno nuevo."
        case .open(let expiresAt):
            "Enlace de un solo uso, caduca a las \(time(expiresAt)). Cuando ejecutes la orden en el ordenador, la "
                + "salida llega a este iPhone y la revisas antes de enviarla al modelo. El enlace es secreto, pero "
                + "mientras la orden corre se ve en «ps» del ordenador, y si copias la línea viaja por el portapapeles "
                + "universal (2 minutos): si otro programa lo usa antes, verás un aviso."
        case .used(let receivedAt, false):
            "Enlace usado: la salida llegó a las \(time(receivedAt)). Otro envío con el mismo enlace se rechaza."
        case .used(let receivedAt, true):
            "Enlace usado: la salida llegó a las \(time(receivedAt)) y después se rechazó otro envío con el mismo "
                + "enlace. Otro programa o equipo pudo verlo: comprueba que la salida recibida es la tuya."
        case .cancelledByServerStop:
            "Enlace cancelado: el servidor web se detuvo. Si ya escribiste la línea, al ejecutarla curl fallará."
        }
    }
}

// MARK: - Received output into the paste preview

/// What the server reported about one received output, copied out of the SDK type by the app.
public struct IncomingOutputFacts: Hashable, Sendable {
    public let label: String
    public let peer: String
    /// Bytes received, before decoding and sanitising.
    public let receivedBytes: Int
    public let exitStatus: Int32?
    /// Invalid UTF-8 sequences the server replaced while decoding.
    public let invalidSequences: Int
    public let peerMatchesLock: Bool
    /// Another post arrived with this ticket after it was used.
    public let laterPostRefused: Bool

    public init(
        label: String,
        peer: String,
        receivedBytes: Int,
        exitStatus: Int32?,
        invalidSequences: Int,
        peerMatchesLock: Bool,
        laterPostRefused: Bool
    ) {
        self.label = label
        self.peer = peer
        self.receivedBytes = receivedBytes
        self.exitStatus = exitStatus
        self.invalidSequences = invalidSequences
        self.peerMatchesLock = peerMatchesLock
        self.laterPostRefused = laterPostRefused
    }

    public func markingLaterPostRefused() -> IncomingOutputFacts {
        IncomingOutputFacts(label: label, peer: peer, receivedBytes: receivedBytes, exitStatus: exitStatus,
                            invalidSequences: invalidSequences, peerMatchesLock: peerMatchesLock,
                            laterPostRefused: true)
    }
}

/// A received output prepared for the paste preview. The one mapping from the server's output to what the model
/// sees: the decoded text goes through `PastedOutput.sanitize` and later `PastedOutputPrompt.make`, the same cap,
/// sanitiser and nonce framing as a clipboard paste. The SDK's own `untrustedBlock` framing is not used, so the
/// model only ever sees one framing.
public struct NetworkPaste: Hashable, Sendable {
    public let output: PastedOutput
    public let facts: IncomingOutputFacts
    /// The command whose line carried the ticket, when the app made the ticket for a line.
    public let command: String?

    public static let emptyMessage = "La salida recibida por red no tiene texto visible después de quitar códigos "
        + "de control. No se ha enviado nada al modelo."

    /// `text` is the server's lossy UTF-8 decoding (U+FFFD for invalid sequences, NUL removed); the sanitiser
    /// removes the replacement characters and counts them.
    public static func make(text: String, facts: IncomingOutputFacts, command: String?) -> NetworkPaste? {
        guard case .success(let output) = PastedOutput.sanitize(text) else { return nil }
        return NetworkPaste(output: output, facts: facts, command: command)
    }

    /// The same paste with the "posted again" warning, for a refusal reported after the preview opened.
    public func markingLaterPostRefused() -> NetworkPaste {
        NetworkPaste(output: output, facts: facts.markingLaterPostRefused(), command: command)
    }

    /// Spanish provenance lines for the preview, in a fixed order.
    public var provenanceLines: [String] {
        var lines = [
            "Enlace: «\(facts.label)»",
            "Enviada desde: \(facts.peer)",
            "Recibidos: \(facts.receivedBytes) bytes",
        ]
        if let status = facts.exitStatus { lines.append("Estado de salida: \(status)") }
        if facts.invalidSequences > 0 {
            lines.append("Secuencias UTF-8 no válidas sustituidas: \(facts.invalidSequences)")
        }
        lines.append(output.wasCut
            ? "Recortada: sí, al modelo solo llegan los últimos \(output.byteCount) bytes"
            : "Recortada: no")
        return lines
    }

    public var warnings: [String] {
        var warnings: [String] = []
        if !facts.peerMatchesLock {
            warnings.append("Llegó de un equipo que no es el permitido (o aún no había ninguno): puede no ser la "
                + "salida que esperas.")
        }
        if facts.laterPostRefused {
            warnings.append("Alguien volvió a enviar con este enlace, a la vez o después, y se rechazó: otro programa "
                + "o equipo pudo verlo (por ejemplo en «ps»). Esta salida puede no ser la de tu orden.")
        }
        return warnings
    }
}

// MARK: - Arrivals waiting for the preview

/// Received outputs waiting for the paste preview. An arrival opens the preview at once only when no sheet or
/// dialog is showing and nothing else waits; otherwise it waits behind a badge until the user taps it. Bounded:
/// past `capacity` the oldest is dropped and counted, so a flood cannot grow memory and nothing goes silently.
public struct IncomingOutputQueue<Item: Identifiable & Sendable>: Sendable where Item.ID: Sendable {
    public static var capacity: Int { 16 }

    public private(set) var waiting: [Item] = []
    /// Arrivals dropped for capacity this session.
    public private(set) var dropped = 0

    public init() {}

    public mutating func append(_ item: Item) {
        waiting.append(item)
        if waiting.count > Self.capacity {
            waiting.removeFirst(waiting.count - Self.capacity)
            dropped += 1
        }
    }

    /// The newest arrival when it alone waits and nothing is showing; removed from the queue.
    public mutating func takeForAutomaticOpen(isPresenting: Bool) -> Item? {
        guard !isPresenting, waiting.count == 1 else { return nil }
        return waiting.removeFirst()
    }

    /// The oldest waiting item, for a tap on the badge; nil while something is showing.
    public mutating func takeForTap(isPresenting: Bool) -> Item? {
        guard !isPresenting, !waiting.isEmpty else { return nil }
        return waiting.removeFirst()
    }

    /// A specific item, for "Revisar" on the server screen; nil while something is showing.
    public mutating func take(_ id: Item.ID, isPresenting: Bool) -> Item? {
        guard !isPresenting, let index = waiting.firstIndex(where: { $0.id == id }) else { return nil }
        return waiting.remove(at: index)
    }

    public mutating func remove(_ id: Item.ID) {
        waiting.removeAll { $0.id == id }
    }

    public mutating func removeAll() {
        waiting.removeAll()
    }

    /// Spanish badge text; nil when nothing waits.
    public var badgeText: String? {
        guard !waiting.isEmpty else { return nil }
        let count = waiting.count == 1 ? "1 salida recibida" : "\(waiting.count) salidas recibidas"
        let lost = dropped == 0 ? "" : dropped == 1 ? " (se descartó 1 antigua)" : " (se descartaron \(dropped) antiguas)"
        return count + lost
    }
}
