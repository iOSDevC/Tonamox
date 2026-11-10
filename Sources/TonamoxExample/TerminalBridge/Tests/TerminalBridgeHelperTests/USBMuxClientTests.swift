#if os(macOS)
import Darwin
import Foundation
import Network
import Synchronization
import Testing
@testable import TerminalBridgeHelper
import TerminalBridgeKit

/// One UDID attached over USB (id 5) and Network (id 6). Connect to `openPort` (network byte order)
/// answers Result 0 and echoes the tunnel; any other port gets Result 3.
final class FakeUSBMuxd: Sendable {
    static let udid = "00008150-001A2B3C4D5E6F7A"
    static let openPort: UInt16 = 47821

    let path: String
    private let listener: Int32
    private let connectPorts = Mutex<[Int]>([])
    private let clients = Mutex<[Int32]>([])

    init() throws {
        path = FileManager.default.temporaryDirectory.path(percentEncoded: false)
            + "tnx-mux-\(UUID().uuidString.prefix(6)).sock"
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        try #require(bytes.count < MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) }
        }
        try #require(bound == 0)
        try #require(Darwin.listen(listener, 8) == 0)
        let server = self
        Thread.detachNewThread { server.acceptLoop() }
    }

    var receivedConnectPorts: [Int] {
        connectPorts.withLock { $0 }
    }

    func stop() {
        Darwin.close(listener)
        clients.withLock { descriptors in
            descriptors.forEach { Darwin.close($0) }
            descriptors.removeAll()
        }
        unlink(path)
    }

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            clients.withLock { $0.append(client) }
            let server = self
            Thread.detachNewThread { server.serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        guard let request = readPacket(client) else { return }
        let tag = request.tag
        switch request.body["MessageType"] as? String {
        case "Listen":
            reply(client, ["MessageType": "Result", "Number": 0], tag: tag)
            reply(client, attached(id: 5, type: "USB"), tag: 0)
            reply(client, attached(id: 6, type: "Network"), tag: 0)
        case "ListDevices":
            reply(client, ["DeviceList": [attached(id: 5, type: "USB"), attached(id: 6, type: "Network")]], tag: tag)
        case "Connect":
            let port = (request.body["PortNumber"] as? NSNumber)?.intValue ?? -1
            connectPorts.withLock { $0.append(port) }
            guard port == Int(Self.openPort.bigEndian) else {
                reply(client, ["MessageType": "Result", "Number": 3], tag: tag)
                return
            }
            reply(client, ["MessageType": "Result", "Number": 0], tag: tag)
            echo(client)
        default:
            reply(client, ["MessageType": "Result", "Number": 1], tag: tag)
        }
    }

    private func attached(id: Int, type: String) -> [String: Any] {
        [
            "MessageType": "Attached",
            "DeviceID": id,
            "Properties": ["ConnectionType": type, "DeviceID": id, "SerialNumber": Self.udid],
        ]
    }

    private func readPacket(_ client: Int32) -> (tag: UInt32, body: [String: Any])? {
        guard let headerBytes = readExactly(client, USBMuxCodec.headerByteCount),
              let header = try? USBMuxCodec.decodeHeader(headerBytes),
              let body = readExactly(client, header.bodyLength),
              let plist = try? PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any]
        else { return nil }
        return (header.tag, plist)
    }

    private func readExactly(_ client: Int32, _ count: Int) -> Data? {
        var buffer = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let read = buffer.withUnsafeMutableBytes { Darwin.read(client, $0.baseAddress! + filled, count - filled) }
            guard read > 0 else { return nil }
            filled += read
        }
        return Data(buffer)
    }

    private func reply(_ client: Int32, _ body: [String: Any], tag: UInt32) {
        guard let packet = try? USBMuxCodec.packet(body, tag: tag) else { return }
        _ = PrivateFiles.writeAll(packet, to: client)
    }

    private func echo(_ client: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let read = buffer.withUnsafeMutableBytes { Darwin.read(client, $0.baseAddress!, 4096) }
            guard read > 0 else { return }
            _ = buffer.withUnsafeBytes { Darwin.write(client, $0.baseAddress!, read) }
        }
    }
}

@Suite(.serialized) struct USBMuxClientTests {
    @Test func listDevicesReturnsEveryConnectionType() async throws {
        let muxd = try FakeUSBMuxd()
        defer { muxd.stop() }
        let devices = try await USBMuxClient(socketPath: muxd.path).listDevices()
        #expect(devices.map(\.deviceID) == [5, 6])
        #expect(devices.filter(\.isUSB).map(\.deviceID) == [5])
    }

    @Test func listenKeepsOnlyTheUSBEntryForAUDID() async throws {
        let muxd = try FakeUSBMuxd()
        defer { muxd.stop() }
        let client = USBMuxClient(socketPath: muxd.path)
        let deviceID = try await client.usbDeviceID(for: "00008150001a2b3c4d5e6f7a", timeout: .seconds(3))
        #expect(deviceID == 5)
        #expect(await client.knownUSBDevices == [USBMuxDevice.normalizedUDID(FakeUSBMuxd.udid): 5])
        await #expect(throws: USBMuxError.deviceNotAttached("0000AAAA-0000BBBB0000CCCC")) {
            try await client.usbDeviceID(for: "0000AAAA-0000BBBB0000CCCC", timeout: .milliseconds(200))
        }
        await client.stop()
    }

    @Test func refusedConnectIsResultThreeAndUsesNetworkByteOrder() async throws {
        let muxd = try FakeUSBMuxd()
        defer { muxd.stop() }
        let client = USBMuxClient(socketPath: muxd.path)
        await #expect(throws: USBMuxError.result(3)) {
            try await client.connect(deviceID: 5, port: 47822)
        }
        #expect(muxd.receivedConnectPorts == [Int(UInt16(47822).bigEndian)])
    }

    @Test func usbDialerTunnelsBridgeFrames() async throws {
        let muxd = try FakeUSBMuxd()
        defer { muxd.stop() }
        let client = USBMuxClient(socketPath: muxd.path)
        let dialer = USBDialer(udid: FakeUSBMuxd.udid, port: FakeUSBMuxd.openPort, client: client)
        let channel = try await dialer.dial()
        defer { channel.close() }
        let payload = Data(#"{"type":"ping","n":1}"#.utf8)
        try await channel.sendFrame(payload)
        #expect(try await channel.receiveFrame() == payload)
        #expect(muxd.receivedConnectPorts == [52666])
        #expect(dialer.deviceLabel == FakeUSBMuxd.udid)
        await dialer.stop()
    }

    @Test func missingDaemonIsUnavailable() async {
        let client = USBMuxClient(socketPath: FileManager.default.temporaryDirectory.path(percentEncoded: false) + "tnx-none.sock")
        do {
            _ = try await client.listDevices()
            Issue.record("expected a failure")
        } catch let error as USBMuxError {
            guard case .unavailable = error else {
                Issue.record("expected unavailable, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}
#endif
