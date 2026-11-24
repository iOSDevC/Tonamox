import Foundation
import TonamoxHTTP

extension TonamoxServer {

    // MARK: - Ingest

    /// No `Origin`/`Sec-Fetch-*` → rate → exit-status header → ticket (used, expired, size, in use) → body budget →
    /// 100-continue → body → consume. Every refusal before the body leaves the ticket as it was.
    func receiveOutput(_ head: HTTPRequestHead, ticket presented: String, _ context: ExchangeContext) async {
        let connection = context.connection
        if head.fields["origin"] != nil { return await reply(.originNotAllowed, context) }
        if head.fields.entries.contains(where: { $0.name.lowercased().hasPrefix("sec-fetch-") }) {
            return await reply(.crossSite, context)
        }
        guard ingestRate.take(connection.peer.host, now: clock.monotonic()) else {
            return await reply(.rateLimited, context)
        }
        guard let exitStatus = Self.exitStatus(head.fields) else { return await reply(.invalidExitStatus, context) }
        let ticket: IngestTicket
        switch await ingest.reserve(presented, contentLength: head.contentLength) {
        case .granted(let granted): ticket = granted
        case .unknown: return await replyNotFound(context)
        case .used: return await reply(.ticketUsed, context)
        case .expired: return await reply(.ticketExpired, context)
        case .tooLarge: return await reply(.ingestTooLarge, context)
        case .inUse:
            log.record("ingest ticket raced by a second post", peer: connection.peer)
            return await reply(.ticketInUse, context)
        }
        var context = context
        context.clientLabel = ticket.label
        let limits = configuration.limits
        guard inflightBody + head.contentLength <= limits.inflightBodyBytes else {
            await ingest.release(ticket.id)
            return await reply(.bodyBudget, context)
        }
        inflightBody += head.contentLength
        defer { inflightBody -= head.contentLength }
        let body: Data
        do {
            if head.expectsContinue { try await connection.sendContinue() }
            body = try await connection.readBody(length: head.contentLength,
                                                 deadline: ContinuousClock.now + limits.ingestBodyTimeout(for: head.contentLength))
        } catch {
            await ingest.release(ticket.id)
            log.record("ingest body not received; ticket released", peer: connection.peer)
            connection.close()
            return
        }
        let output = IngestedOutput(ticketID: ticket.id, label: ticket.label, peer: connection.peer.host,
                                    receivedAt: clock.wall(), rawBytes: body, exitStatus: exitStatus,
                                    peerMatchesLock: peerMatchesLock(connection.peer))
        guard await ingest.complete(ticket.id, with: output) else { return await replyNotFound(context) }
        noteActivity()
        log.record("ingest received \(body.count) bytes", peer: connection.peer)
        let answer = Data("tonamox: received \(body.count) bytes for \(ticket.label)\n".utf8)
        await send(status: 200, body: answer, contentType: Self.plainTextType, context, extra: [])
    }

    /// The same JSON 404 as an unknown path, so a probe cannot tell an unknown ticket from a disabled route.
    private func replyNotFound(_ context: ExchangeContext) async {
        var context = context
        context.plainText = false
        await reply(.notFound, context)
    }

    /// `nil` when the header is malformed or repeated; `.some(nil)` when absent.
    static func exitStatus(_ fields: HTTPFields) -> Int32?? {
        let name = "x-tonamox-exit-status"
        switch fields.occurrences(of: name) {
        case 0: return .some(nil)
        case 1: break
        default: return nil
        }
        guard let text = fields[name] else { return nil }
        let digits = text.hasPrefix("-") ? text.dropFirst() : Substring(text)
        guard (1...10).contains(digits.count), digits.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              let value = Int32(text) else { return nil }
        return .some(value)
    }

    // MARK: - Scripts

    func serveScript(_ head: HTTPRequestHead, _ script: HelperScript, _ context: ExchangeContext) async {
        if let refusal = originRefusal(head.fields) { return await reply(refusal, context) }
        guard scriptRate.take(context.connection.peer.host, now: clock.monotonic()) else {
            return await reply(.rateLimited, context)
        }
        guard head.contentLength == 0 else { return await reply(.tooLarge, context) }
        await send(status: 200, body: script.bytes, contentType: Self.plainTextType, context,
                   extra: [HTTPField(name: "ETag", value: "\"\(script.servedHash)\"")])
    }
}
