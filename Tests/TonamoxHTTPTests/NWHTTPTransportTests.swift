import Darwin
import Foundation
import Network
import Testing
@testable import TonamoxHTTP

let lanAddress = InterfaceCatalog.current().first { !$0.ipv4.isLoopback && !$0.name.hasPrefix("utun") }

/// A plain BSD listener on 127.0.0.1, to occupy a port.
final class PortSquatter {
    let descriptor: Int32
    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        descriptor = fd
        port = UInt16(bigEndian: address.sin_port)
    }

    deinit { Darwin.close(descriptor) }
}

func startedTransport(_ admission: AdmissionPolicy = AdmissionPolicy(), port: UInt16 = 0)
    async throws -> (NWHTTPTransport, UInt16) {
    let transport = NWHTTPTransport(binding: .loopbackIPv4, port: port, admission: admission)
    let bound = try await transport.start()
    return (transport, bound)
}

func nextConnection(_ transport: NWHTTPTransport) async throws -> any HTTPConnection {
    try await withTimeout(.seconds(5)) {
        for await connection in transport.connections { return connection }
        throw RawHTTPClient.TimedOut()
    }
}

func eventually(_ timeout: Duration = .seconds(5), _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@Suite("NWHTTPTransport", .serialized)
struct NWHTTPTransportTests {
    @Test(.enabled(if: lanAddress != nil, "skipped: this machine has no non-loopback IPv4 address"))
    func bindsLoopbackOnly() async throws {
        let (transport, port) = try await startedTransport()
        defer { Task { await transport.stop() } }
        let address = try #require(lanAddress)
        await #expect(throws: RawHTTPClient.Refused.self) {
            _ = try await RawHTTPClient.connected(host: address.ipv4.description, port: port)
        }
        let local = try await RawHTTPClient.connected(port: port)
        local.close()
    }

    @Test func refusesNonLoopbackPeerInLoopbackMode() async throws {
        let (transport, _) = try await startedTransport()
        transport.accept(NWConnection(host: "192.0.2.10", port: 9, using: .tcp))
        #expect(transport.refusedCount == 1)
        #expect(transport.openCount == 0)
        await transport.stop()
    }

    @Test func capsConnectionsPerPeerAndTotal() async throws {
        let (perPeer, perPeerPort) = try await startedTransport(AdmissionPolicy(maxConnections: 8, maxPerPeer: 2))
        let first = try await RawHTTPClient.connected(port: perPeerPort)
        let second = try await RawHTTPClient.connected(port: perPeerPort)
        let third = try await RawHTTPClient.connected(port: perPeerPort)
        #expect(await eventually { perPeer.refusedCount == 1 })
        #expect(perPeer.openCount == 2)
        _ = try await third.receiveAll(timeout: .seconds(3))
        [first, second, third].forEach { $0.close() }
        await perPeer.stop()

        let (total, totalPort) = try await startedTransport(AdmissionPolicy(maxConnections: 2, maxPerPeer: nil))
        let clients = [try await RawHTTPClient.connected(port: totalPort), try await RawHTTPClient.connected(port: totalPort),
                       try await RawHTTPClient.connected(port: totalPort)]
        #expect(await eventually { total.refusedCount == 1 })
        #expect(total.openCount == 2)
        clients.forEach { $0.close() }
        await total.stop()
    }

    @Test func portInUseIsReported() async throws {
        let squatter = try PortSquatter()
        let transport = NWHTTPTransport(binding: .loopbackIPv4, port: squatter.port, admission: AdmissionPolicy())
        await #expect(throws: HTTPTransportError.portInUse(squatter.port)) {
            _ = try await transport.start()
        }
    }

    @Test func noEndpointReuse() async throws {
        let parameters = NWHTTPTransport(binding: .loopbackIPv4, port: 0, admission: AdmissionPolicy()).makeParameters()
        #expect(parameters.allowLocalEndpointReuse == false)
        #expect(parameters.includePeerToPeer == false)
        let (first, port) = try await startedTransport()
        let second = NWHTTPTransport(binding: .loopbackIPv4, port: port, admission: AdmissionPolicy())
        await #expect(throws: HTTPTransportError.portInUse(port)) {
            _ = try await second.start()
        }
        await first.stop()
    }

    @Test func slowHeadIsClosedAtDeadline() async throws {
        let (transport, port) = try await startedTransport()
        let client = try await RawHTTPClient.connected(port: port)
        try await client.send("GET /v1/models HTTP/1.1\r\nHost: 127.0.0.1\r\n")
        let connection = try await nextConnection(transport)
        await #expect(throws: HTTPConnectionError.deadlineExceeded) {
            _ = try await connection.readHead(deadline: .now + .milliseconds(300))
        }
        _ = try await client.receiveAll(timeout: .seconds(3))
        #expect(client.sawEnd)
        await transport.stop()
    }

    @Test func slowBodyIsClosedAtDeadline() async throws {
        let (transport, port) = try await startedTransport()
        let client = try await RawHTTPClient.connected(port: port)
        try await client.send("POST /x HTTP/1.1\r\nHost: a\r\nContent-Length: 10\r\n\r\nabc")
        let connection = try await nextConnection(transport)
        let parsed = try await connection.readHead(deadline: .now + .seconds(2))
        #expect(parsed.contentLength == 10)
        await #expect(throws: HTTPConnectionError.deadlineExceeded) {
            _ = try await connection.readBody(length: 10, deadline: .now + .milliseconds(300))
        }
        _ = try await client.receiveAll(timeout: .seconds(3))
        #expect(client.sawEnd)
        await transport.stop()
    }

    @Test func stalledReaderClosesStreamAfterStallTimeout() async throws {
        let (transport, port) = try await startedTransport()
        let client = try await RawHTTPClient.connected(port: port)
        try await client.send("GET /x HTTP/1.1\r\nHost: a\r\n\r\n")
        let connection = try await nextConnection(transport)
        _ = try await connection.readHead(deadline: .now + .seconds(2))
        let writer = try await connection.openEventStream(HTTPResponseHead(status: 200), stallTimeout: .milliseconds(500))
        let chunk = Data(repeating: 0x61, count: 256 * 1024)
        var written = 0
        let started = ContinuousClock.now
        await #expect(throws: HTTPConnectionError.stalled) {
            while written < 400 {
                try await writer.write(chunk)
                written += 1
            }
        }
        #expect(written < 400, "the client never reads, so a write must stall")
        #expect(ContinuousClock.now - started < .seconds(30))
        client.close()
        await transport.stop()
    }

    @Test func bytesAfterBodyAreNotParsed() async throws {
        let (transport, port) = try await startedTransport()
        let client = try await RawHTTPClient.connected(port: port)
        try await client.send("POST /x HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\n\r\nhelloGET /evil HTTP/1.1\r\nHost: a\r\n\r\n")
        let connection = try await nextConnection(transport)
        let parsed = try await connection.readHead(deadline: .now + .seconds(2))
        #expect(parsed.target == "/x")
        let body = try await connection.readBody(length: 5, deadline: .now + .seconds(2))
        #expect(body == Data("hello".utf8))
        await connection.send(HTTPResponseHead(status: 200, fields: [HTTPField(name: "Content-Length", value: "2")]),
                              body: Data("ok".utf8))
        let reply = String(decoding: try await client.receiveResponse(), as: UTF8.self)
        client.close()
        #expect(reply.components(separatedBy: "HTTP/1.1").count == 2)
        #expect(reply.hasSuffix("ok"))
        await transport.stop()
    }

    @Test func stopClosesOpenConnections() async throws {
        let (transport, port) = try await startedTransport()
        let client = try await RawHTTPClient.connected(port: port)
        _ = try await nextConnection(transport)
        await transport.stop()
        _ = try await client.receiveAll(timeout: .seconds(3))
        #expect(client.sawEnd)
        #expect(await eventually { transport.openCount == 0 })
    }

    @Test func startTwiceThrows() async throws {
        let (transport, _) = try await startedTransport()
        await #expect(throws: HTTPTransportError.alreadyStarted) {
            _ = try await transport.start()
        }
        await transport.stop()
    }
}
