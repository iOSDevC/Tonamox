#if os(macOS)
import Foundation
import Testing
@testable import TerminalBridgeHelper

@Suite struct USBMuxCodecTests {
    private func body(of packet: Data) throws -> [String: Any] {
        let plist = try PropertyListSerialization.propertyList(from: packet.dropFirst(16), format: nil)
        return try #require(plist as? [String: Any])
    }

    private func plist(_ dictionary: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    }

    @Test func headerIsFourLittleEndianWords() throws {
        let packet = try USBMuxCodec.listDevices(tag: 7)
        let header = Array(packet.prefix(16))
        let length = UInt32(packet.count)
        #expect(header[0..<4] == [UInt8(length & 0xFF), UInt8((length >> 8) & 0xFF), 0, 0])
        #expect(header[4..<8] == [1, 0, 0, 0])
        #expect(header[8..<12] == [8, 0, 0, 0])
        #expect(header[12..<16] == [7, 0, 0, 0])
        let decoded = try USBMuxCodec.decodeHeader(packet)
        #expect(decoded == USBMuxCodec.Header(length: length, version: 1, message: 8, tag: 7))
        #expect(decoded.bodyLength == packet.count - 16)
    }

    @Test func connectSendsThePortInNetworkByteOrder() throws {
        let fields = try body(of: USBMuxCodec.connect(deviceID: 5, port: 47821, tag: 3))
        #expect(fields["MessageType"] as? String == "Connect")
        #expect(fields["DeviceID"] as? Int == 5)
        #expect(fields["PortNumber"] as? Int == Int(UInt16(47821).byteSwapped))
        #expect(fields["PortNumber"] as? Int == 52666)
        #expect(fields["ProgName"] as? String == "tonamox-bridge")
        #expect(fields["kLibUSBMuxVersion"] as? Int == 3)
        let python = try body(of: USBMuxCodec.connect(deviceID: 999, port: 47123, tag: 1))
        #expect(python["PortNumber"] as? Int == 5048)
    }

    @Test func listenAndListDevicesCarryTheClientFields() throws {
        let listen = try body(of: USBMuxCodec.listen(tag: 1))
        #expect(listen["MessageType"] as? String == "Listen")
        #expect(listen["ClientVersionString"] as? String == "tonamox-bridge 1")
        #expect(try body(of: USBMuxCodec.listDevices(tag: 2))["MessageType"] as? String == "ListDevices")
    }

    @Test func decodesResultAttachedAndDetached() throws {
        #expect(try USBMuxCodec.decodeBody(plist(["MessageType": "Result", "Number": 3])) == .result(3))
        let attached = try USBMuxCodec.decodeBody(plist([
            "MessageType": "Attached",
            "DeviceID": 12,
            "Properties": ["ConnectionType": "USB", "DeviceID": 12, "SerialNumber": "00008150-001A2B3C4D5E6F7A"],
        ]))
        #expect(attached == .attached(USBMuxDevice(deviceID: 12, serialNumber: "00008150-001A2B3C4D5E6F7A", connectionType: "USB")))
        #expect(try USBMuxCodec.decodeBody(plist(["MessageType": "Detached", "DeviceID": 12])) == .detached(deviceID: 12))
        #expect(try USBMuxCodec.decodeBody(plist(["MessageType": "Paired", "DeviceID": 12])) == .other("Paired"))
    }

    /// Shape of the real ListDevices reply on this Mac today: Blue over Network only.
    @Test func decodesTheDeviceList() throws {
        let reply = try USBMuxCodec.decodeBody(plist([
            "DeviceList": [
                [
                    "DeviceID": 473,
                    "MessageType": "Attached",
                    "Properties": [
                        "ConnectionType": "Network",
                        "DeviceID": 473,
                        "InterfaceIndex": 16,
                        "SerialNumber": "00008150-001A2B3C4D5E6F7A",
                    ],
                ],
            ],
        ]))
        guard case .deviceList(let devices) = reply else {
            Issue.record("expected a device list, got \(reply)")
            return
        }
        #expect(devices == [USBMuxDevice(deviceID: 473, serialNumber: "00008150-001A2B3C4D5E6F7A", connectionType: "Network")])
        #expect(devices.filter(\.isUSB).isEmpty)
    }

    @Test func udidsCompareWithoutDashesOrCase() {
        #expect(USBMuxDevice.normalizedUDID("00008150-001a2b3c4d5e6f7a") == USBMuxDevice.normalizedUDID("00008150001A2B3C4D5E6F7A"))
    }

    @Test func rejectsBadHeaders() {
        #expect(throws: USBMuxCodecError.shortHeader) { try USBMuxCodec.decodeHeader(Data(count: 8)) }
        let wrongVersion = USBMuxCodec.encodeHeader(.init(length: 16, version: 0, message: 8, tag: 1))
        #expect(throws: USBMuxCodecError.unsupportedVersion(0)) { try USBMuxCodec.decodeHeader(wrongVersion) }
        let binary = USBMuxCodec.encodeHeader(.init(length: 16, version: 1, message: 3, tag: 1))
        #expect(throws: USBMuxCodecError.unsupportedMessage(3)) { try USBMuxCodec.decodeHeader(binary) }
        let short = USBMuxCodec.encodeHeader(.init(length: 4, version: 1, message: 8, tag: 1))
        #expect(throws: USBMuxCodecError.badLength(4)) { try USBMuxCodec.decodeHeader(short) }
        #expect(throws: USBMuxCodecError.self) { try USBMuxCodec.decodeBody(Data("not a plist".utf8)) }
    }
}
#endif
