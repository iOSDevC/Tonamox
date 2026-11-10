#if os(macOS)
import Foundation
import Network
import TerminalBridgeKit

/// Produces one started channel to the phone per call; the session loop retries on failure.
public protocol ChannelDialer: Sendable {
    /// Human description for logs, e.g. "127.0.0.1:47821".
    var displayName: String { get }
    /// Stored in the journal: "simulator" or the device UDID.
    var deviceLabel: String { get }
    func dial() async throws -> BridgeChannel
}

/// The simulator shares the Mac's network stack, so the app's 127.0.0.1 listener is local.
public struct SimulatorDialer: ChannelDialer {
    public let port: UInt16

    public init(port: UInt16 = BridgeConstants.defaultPort) {
        self.port = port
    }

    public var displayName: String {
        "127.0.0.1:\(port)"
    }

    public var deviceLabel: String {
        "simulator"
    }

    public func dial() async throws -> BridgeChannel {
        let channel = BridgeChannel.loopbackClient(port: port)
        try await channel.start()
        return channel
    }
}

/// A USB-attached iPhone through usbmuxd. Unverified on hardware: Blue has only shown up over Network.
public struct USBDialer: ChannelDialer {
    public let udid: String
    public let port: UInt16
    public let deviceWait: Duration
    private let client: USBMuxClient

    public init(
        udid: String,
        port: UInt16 = BridgeConstants.defaultPort,
        client: USBMuxClient = USBMuxClient(),
        deviceWait: Duration = .seconds(3)
    ) {
        self.udid = udid
        self.port = port
        self.client = client
        self.deviceWait = deviceWait
    }

    public var displayName: String {
        "USB \(udid):\(port)"
    }

    public var deviceLabel: String {
        udid
    }

    public func dial() async throws -> BridgeChannel {
        let deviceID = try await client.usbDeviceID(for: udid, timeout: deviceWait)
        let tunnel = try await client.connect(deviceID: deviceID, port: port)
        let channel = BridgeChannel(connection: tunnel)
        try await channel.start()
        return channel
    }

    public func stop() async {
        await client.stop()
    }
}
#endif
