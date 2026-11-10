#if os(macOS)
import Foundation

/// A device as usbmuxd reports it. The same UDID can appear twice: once over USB, once over Network.
public struct USBMuxDevice: Equatable, Sendable {
    public let deviceID: Int
    public let serialNumber: String
    public let connectionType: String

    public init(deviceID: Int, serialNumber: String, connectionType: String) {
        self.deviceID = deviceID
        self.serialNumber = serialNumber
        self.connectionType = connectionType
    }

    public var isUSB: Bool {
        connectionType == "USB"
    }

    /// UDIDs compared without case or dashes: usbmuxd builds differ in how they print them.
    public static func normalizedUDID(_ udid: String) -> String {
        udid.uppercased().filter { $0 != "-" }
    }
}

public enum USBMuxReply: Equatable, Sendable {
    case result(Int)
    case attached(USBMuxDevice)
    case detached(deviceID: Int)
    case deviceList([USBMuxDevice])
    case other(String)
}

public enum USBMuxCodecError: Error, Equatable, Sendable {
    case shortHeader
    case badLength(UInt32)
    case unsupportedVersion(UInt32)
    case unsupportedMessage(UInt32)
    case malformedBody(String)
}

/// usbmuxd plist protocol v1: a 16-byte little-endian header (total length, version 1,
/// message 8 = plist, tag) followed by an XML plist dictionary.
public enum USBMuxCodec {
    public static let headerByteCount = 16
    public static let plistVersion: UInt32 = 1
    public static let plistMessage: UInt32 = 8
    public static let maxBodyBytes = 1 << 20
    public static let programName = "tonamox-bridge"
    public static let clientVersion = "tonamox-bridge 1"
    public static let libUSBMuxVersion = 3

    public struct Header: Equatable, Sendable {
        public let length: UInt32
        public let version: UInt32
        public let message: UInt32
        public let tag: UInt32

        public var bodyLength: Int {
            Int(length) - USBMuxCodec.headerByteCount
        }
    }

    // MARK: Requests

    public static func listen(tag: UInt32) throws -> Data {
        try packet(["MessageType": "Listen"], tag: tag)
    }

    public static func listDevices(tag: UInt32) throws -> Data {
        try packet(["MessageType": "ListDevices"], tag: tag)
    }

    /// `PortNumber` is the port in network byte order stored as a plain integer (htons),
    /// exactly as libusbmuxd sends it: 47821 travels as 52666.
    public static func connect(deviceID: Int, port: UInt16, tag: UInt32) throws -> Data {
        try packet(["MessageType": "Connect", "DeviceID": deviceID, "PortNumber": Int(port.bigEndian)], tag: tag)
    }

    static func packet(_ fields: [String: Any], tag: UInt32) throws -> Data {
        var body: [String: Any] = [
            "ClientVersionString": clientVersion,
            "ProgName": programName,
            "kLibUSBMuxVersion": libUSBMuxVersion
        ]
        body.merge(fields) { _, request in request }
        let encoded = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
        let header = encodeHeader(
            Header(
                length: UInt32(headerByteCount + encoded.count),
                version: plistVersion,
                message: plistMessage,
                tag: tag
            )
        )
        return header + encoded
    }

    public static func encodeHeader(_ header: Header) -> Data {
        var data = Data(capacity: headerByteCount)
        appendLittleEndian(header.length, to: &data)
        appendLittleEndian(header.version, to: &data)
        appendLittleEndian(header.message, to: &data)
        appendLittleEndian(header.tag, to: &data)
        return data
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    // MARK: Replies

    public static func decodeHeader(_ bytes: Data) throws(USBMuxCodecError) -> Header {
        guard bytes.count >= headerByteCount else { throw .shortHeader }
        let start = bytes.startIndex
        let header = Header(
            length: readLittleEndian(bytes, at: start),
            version: readLittleEndian(bytes, at: start + 4),
            message: readLittleEndian(bytes, at: start + 8),
            tag: readLittleEndian(bytes, at: start + 12)
        )
        guard header.version == plistVersion else { throw .unsupportedVersion(header.version) }
        guard header.message == plistMessage else { throw .unsupportedMessage(header.message) }
        guard header.bodyLength >= 0, header.bodyLength <= maxBodyBytes else { throw .badLength(header.length) }
        return header
    }

    private static func readLittleEndian(_ bytes: Data, at index: Data.Index) -> UInt32 {
        bytes[index..<index + 4].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    public static func decodeBody(_ body: Data) throws(USBMuxCodecError) -> USBMuxReply {
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: body, format: nil)
        } catch {
            throw .malformedBody(error.localizedDescription)
        }
        guard let dictionary = object as? [String: Any] else { throw .malformedBody("no es un diccionario") }
        return reply(from: dictionary)
    }

    static func reply(from dictionary: [String: Any]) -> USBMuxReply {
        if let list = dictionary["DeviceList"] as? [[String: Any]] {
            return .deviceList(list.compactMap(device(from:)))
        }
        let type = dictionary["MessageType"] as? String ?? ""
        switch type {
        case "Result":
            return .result(integer(dictionary["Number"]) ?? -1)
        case "Attached":
            return device(from: dictionary).map(USBMuxReply.attached) ?? .other(type)
        case "Detached":
            return integer(dictionary["DeviceID"]).map { .detached(deviceID: $0) } ?? .other(type)
        default:
            return .other(type)
        }
    }

    static func device(from dictionary: [String: Any]) -> USBMuxDevice? {
        let properties = dictionary["Properties"] as? [String: Any] ?? [:]
        guard let deviceID = integer(dictionary["DeviceID"]) ?? integer(properties["DeviceID"]) else { return nil }
        return USBMuxDevice(
            deviceID: deviceID,
            serialNumber: properties["SerialNumber"] as? String ?? "",
            connectionType: properties["ConnectionType"] as? String ?? ""
        )
    }

    static func integer(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }
}
#endif
