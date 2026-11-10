import Foundation

/// Wire-level constants shared by the phone app and the Mac helper.
public enum BridgeConstants {
    public static let protocolVersion = 1
    public static let supportedProtocols = [1]

    public static let defaultPort: UInt16 = 47821
    public static let defaultSessionName = "tonamox"
    public static let defaultWindow = "0"

    public static let maxFrameBytes = 16_384
    // screen 4.00.03 silently drops a stuff of 1016+ bytes with rc 0; 512 keeps a wide margin.
    public static let maxTextBytes = 512

    public static let tagByteCount = 32
    public static let nonceByteCount = 32
    public static let secretByteCount = 20

    public static let handshakeTimeout: Duration = .seconds(5)
    public static let heartbeatInterval: Duration = .seconds(10)
    public static let heartbeatTimeout: Duration = .seconds(25)
    public static let statusPollInterval: Duration = .seconds(3)
    public static let writeTimeout: Duration = .seconds(10)
    public static let minimumWriteInterval: Duration = .milliseconds(300)

    public static let maxUnauthenticatedConnections = 2
    public static let recentWriteCapacity = 256

    public static let writeTextCapability = "write.text"
    public static let helperNamePrefix = "tonamox-bridge 1"
    public static let defaultPhoneName = "Tonamox Terminal"

    static let authSalt = "tonamox-bridge/1/auth"
    static let helperProofLabel = "tonamox-bridge/1/helper"
    static let phoneProofLabel = "tonamox-bridge/1/phone"
    static let helperToPhoneInfo = "h2p"
    static let phoneToHelperInfo = "p2h"
    static let pairingChecksumLabel = "tonamox-pair/1"
    static let fingerprintLabel = "tonamox-fp/1"
}
