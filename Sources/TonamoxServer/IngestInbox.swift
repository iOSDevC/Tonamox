import CryptoKit
import Foundation
import TonamoxHTTP

/// One-time tickets for `POST /i/{ticket}` and the outputs posted with them. Only the app makes tickets; a ticket
/// is reserved when a post's head is accepted (a concurrent post gets 409 `ticket_in_use`), consumed when the whole
/// body arrived (a later post gets 409 `ticket_used`) and released when the body does not complete, so the same
/// curl line can be run again. Nothing is persisted.
public actor IngestInbox {
    /// Delivered outputs, oldest first. One stored stream with one consumer (the app); the newest 64 are buffered.
    public nonisolated let outputs: AsyncStream<IngestedOutput>
    /// Posts refused because their ticket was in use or already used, oldest first; the newest 64 are buffered.
    /// A post nobody but the app should have made means another program or computer saw the ticket's URL.
    public nonisolated let refusals: AsyncStream<IngestRefusal>

    private struct Entry {
        let ticket: IngestTicket
        let ticketHash: [UInt8]
        var phase: Phase
    }

    private enum Phase { case open, reserved, used }

    private let limits: ServerLimits
    private let clock: ServerClock
    private let delivery: AsyncStream<IngestedOutput>.Continuation
    private let refusalDelivery: AsyncStream<IngestRefusal>.Continuation
    private var entries: [Entry] = []

    static let bufferedOutputs = 64
    /// Used and expired tickets kept to answer 409 or 410 instead of 404.
    static let rememberedTickets = 256

    package init(limits: ServerLimits, clock: ServerClock) {
        self.limits = limits
        self.clock = clock
        (outputs, delivery) = AsyncStream.makeStream(of: IngestedOutput.self,
                                                         bufferingPolicy: .bufferingNewest(Self.bufferedOutputs))
        (refusals, refusalDelivery) = AsyncStream.makeStream(of: IngestRefusal.self,
                                                             bufferingPolicy: .bufferingNewest(Self.bufferedOutputs))
    }

    /// A new ticket. `label` is shown on the phone and echoed to the computer, filtered to `[A-Za-z0-9 ._-]`, at
    /// most 40 characters. `maxBytes` defaults to 1 MiB and is capped at 16 MiB, or at the in-flight body budget when
    /// that is smaller (8 MiB on iOS), since a larger post could never be read; at most 32 tickets are live.
    public func makeTicket(label: String, maxBytes: Int? = nil, ttl: Duration = .seconds(600)) throws -> IngestTicket {
        let size = maxBytes ?? limits.ingestDefaultBytes
        let cap = min(limits.ingestMaxBytes, limits.inflightBodyBytes)
        guard size >= 0, size <= cap else { throw IngestError.invalidMaxBytes(limit: cap) }
        guard ttl > .zero else { throw IngestError.invalidLifetime }
        prune()
        let now = clock.wall()
        let live = entries.filter { $0.phase != .used && $0.ticket.expiresAt > now }.count
        guard live < limits.maxLiveTickets else { throw IngestError.tooManyTickets(limit: limits.maxLiveTickets) }
        let token = SecretToken.random(bits: 256)
        let ticket = IngestTicket(id: UUID(), label: IngestTicket.sanitizedLabel(label),
                                  expiresAt: now.addingTimeInterval(ttl.seconds), maxBytes: size, secret: token.text)
        entries.append(Entry(ticket: ticket, ticketHash: Array(token.storedHash), phase: .open))
        return ticket
    }

    /// Ends a ticket; a later post with it gets 404.
    public func cancel(_ id: IngestTicket.ID) {
        entries.removeAll { $0.ticket.id == id }
    }

    /// Ends every ticket (``TonamoxServer/stop()``, or a resume that could not get its port back).
    func cancelAll() {
        entries.removeAll()
    }

    // MARK: - Server side

    /// Constant-time lookup, then the checks in pipeline order: used, expired, size, in use.
    func reserve(_ presented: String, contentLength: Int) -> IngestReservation {
        let candidate = Array(SHA256.hash(data: Data(presented.utf8)))
        guard let index = entries.firstIndex(where: { SecretToken.constantTimeEqual(candidate, $0.ticketHash) }) else {
            return .unknown
        }
        let entry = entries[index]
        if entry.phase == .used {
            refusalDelivery.yield(IngestRefusal(ticketID: entry.ticket.id, reason: .used))
            return .used
        }
        if entry.ticket.expiresAt <= clock.wall() { return .expired }
        if contentLength > entry.ticket.maxBytes { return .tooLarge }
        if entry.phase == .reserved {
            refusalDelivery.yield(IngestRefusal(ticketID: entry.ticket.id, reason: .inUse))
            return .inUse
        }
        entries[index].phase = .reserved
        return .granted(entry.ticket)
    }

    /// The body did not complete: the ticket can be posted again.
    func release(_ id: IngestTicket.ID) {
        guard let index = entries.firstIndex(where: { $0.ticket.id == id }), entries[index].phase == .reserved else {
            return
        }
        entries[index].phase = .open
    }

    /// Marks the ticket used and delivers the output; `false` when the app cancelled it meanwhile.
    func complete(_ id: IngestTicket.ID, with output: IngestedOutput) -> Bool {
        guard let index = entries.firstIndex(where: { $0.ticket.id == id }), entries[index].phase == .reserved else {
            return false
        }
        entries[index].phase = .used
        delivery.yield(output)
        return true
    }

    /// Drops the oldest finished tickets beyond the remembered count.
    private func prune() {
        let now = clock.wall()
        let finished = entries.filter { $0.phase == .used || $0.ticket.expiresAt <= now }
        guard finished.count > Self.rememberedTickets else { return }
        let dropped = Set(finished.prefix(finished.count - Self.rememberedTickets).map(\.ticket.id))
        entries.removeAll { dropped.contains($0.ticket.id) }
    }
}

enum IngestReservation: Sendable, Equatable {
    case granted(IngestTicket)
    case unknown, used, expired, tooLarge, inUse
}

/// A post with a valid ticket that the server refused: another post held the ticket (409 `ticket_in_use`) or had
/// already used it (409 `ticket_used`). Carries no secret.
public struct IngestRefusal: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        case inUse
        case used
    }

    public let ticketID: UUID
    public let reason: Reason
}

public enum IngestError: Error, Sendable, Equatable {
    case tooManyTickets(limit: Int)
    case invalidMaxBytes(limit: Int)
    case invalidLifetime
}

/// A one-time ingest ticket. Its secret is only in ``url(on:)`` and ``curlSuffix(on:)``, never in `description`.
public struct IngestTicket: Sendable, Identifiable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: UUID
    public let label: String
    public let expiresAt: Date
    public let maxBytes: Int
    let secret: String

    init(id: UUID, label: String, expiresAt: Date, maxBytes: Int, secret: String) {
        self.id = id
        self.label = label
        self.expiresAt = expiresAt
        self.maxBytes = maxBytes
        self.secret = secret
    }

    public func url(on endpoint: ServerEndpoint) -> URL {
        endpoint.baseURL.appendingPathComponent("i").appendingPathComponent(secret)
    }

    /// ` 2>&1 | curl -sS --data-binary @- http://host:port/i/<ticket>`, to append to a command. `--data-binary`
    /// sends a `Content-Length`; `curl -T -` would send a chunked body, which the server refuses with 411.
    public func curlSuffix(on endpoint: ServerEndpoint) -> String {
        " 2>&1 | curl -sS --data-binary @- " + url(on: endpoint).absoluteString
    }

    public var description: String { "IngestTicket(\(id.uuidString), \(label))" }
    public var debugDescription: String { description }

    static let labelLimit = 40

    static func sanitizedLabel(_ text: String) -> String {
        let kept = text.unicodeScalars.filter(isLabelScalar).prefix(labelLimit)
        let label = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? "output" : label
    }

    private static func isLabelScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", " ", ".", "_", "-": true
        default: false
        }
    }
}

/// Output a computer posted with a ticket. Everything in it came from that computer: treat it as untrusted data.
public struct IngestedOutput: Sendable {
    public let ticketID: UUID
    public let label: String
    public let peer: String
    public let receivedAt: Date
    public let rawBytes: Data
    /// `rawBytes` decoded as UTF-8 with invalid sequences replaced (U+FFFD) and NUL removed.
    public let text: String
    /// Invalid UTF-8 sequences replaced while decoding.
    public let replacedSequences: Int
    /// From `X-Tonamox-Exit-Status`, when the sender included it (``HelperScript/tnxRun`` does).
    public let exitStatus: Int32?
    /// `true` when no peer lock applies (loopback, ``PeerLock/none``) or the peer is a locked computer; `false`
    /// on interface exposure while nobody is locked yet or for a computer let in by ``TonamoxServer/allowAnotherComputer()``
    /// that has not authenticated.
    public let peerMatchesLock: Bool

    init(ticketID: UUID, label: String, peer: String, receivedAt: Date, rawBytes: Data, exitStatus: Int32?,
         peerMatchesLock: Bool) {
        self.ticketID = ticketID
        self.label = label
        self.peer = peer
        self.receivedAt = receivedAt
        self.rawBytes = rawBytes
        let decoded = LossyUTF8.decode(rawBytes)
        self.text = decoded.text
        self.replacedSequences = decoded.replaced
        self.exitStatus = exitStatus
        self.peerMatchesLock = peerMatchesLock
    }

    /// The output sanitized and framed for a model prompt; see ``UntrustedText``.
    public func untrustedBlock(maxCharacters: Int = 16_000) -> UntrustedText {
        UntrustedText(output: self, maxCharacters: maxCharacters, boundaries: UntrustedText.randomBoundary)
    }
}

enum LossyUTF8 {
    /// Decodes with U+FFFD for each invalid sequence and drops NUL.
    static func decode(_ bytes: Data) -> (text: String, replaced: Int) {
        var scalars = String.UnicodeScalarView()
        var replaced = 0
        var decoder = UTF8()
        var iterator = bytes.makeIterator()
        decoding: while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar):
                if scalar != "\0" { scalars.append(scalar) }
            case .error:
                replaced += 1
                scalars.append(replacement)
            case .emptyInput:
                break decoding
            }
        }
        return (String(scalars), replaced)
    }

    static let replacement: Unicode.Scalar = "\u{FFFD}"
}
