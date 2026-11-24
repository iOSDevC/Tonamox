import Foundation

/// The HID over GATT keyboard the phone presents. Bytes are the ones the 2026-11-18 hardware spike paired and
/// typed with; changing them invalidates that evidence.
public enum HIDKeyboardDescriptor {
    public static let reportID: UInt8 = 1

    /// Boot-compatible keyboard: modifiers, reserved, 6 keys in; 5 LED bits out. Report ID 1 inside one collection.
    /// The key array keeps the full 0x00-0x65 range; the allow-list is enforced in code, not here.
    public static let reportMap: [UInt8] = [
        0x05, 0x01, 0x09, 0x06, 0xA1, 0x01,
        0x85, 0x01,
        0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
        0x95, 0x01, 0x75, 0x08, 0x81, 0x01,
        0x95, 0x05, 0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02,
        0x95, 0x01, 0x75, 0x03, 0x91, 0x01,
        0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
        0xC0,
    ]

    /// bcdHID 1.11 little endian, country 0, flags: normally connectable.
    public static let hidInformation: [UInt8] = [0x11, 0x01, 0x00, 0x02]
    /// Vendor ID source USB, pid.codes test VID 0x1209 / PID 0x0001, version 1.0.
    public static let pnpID: [UInt8] = [0x02, 0x09, 0x12, 0x01, 0x00, 0x00, 0x01]
    public static let deviceName = "Tonamox Keyboard"
    public static let manufacturerName = "Tonamox"
    public static let inputReportLength = 8
    /// Report Reference descriptor values (report ID, report type).
    public static let reportTypeInput: UInt8 = 1
    public static let reportTypeOutput: UInt8 = 2
    /// The pace the spike typed with on hardware.
    public static let reportInterval: Duration = .milliseconds(12)
    /// Longest a key may stay down before the job aborts (host auto-repeat starts at ~225-250 ms). Unverified.
    public static let maxKeyHold: Duration = .milliseconds(150)
}

/// 16-bit Bluetooth SIG assigned numbers of the GATT database.
public enum HIDGATTIdentifier {
    public static let hidService: UInt16 = 0x1812
    public static let batteryService: UInt16 = 0x180F
    public static let deviceInformationService: UInt16 = 0x180A

    public static let batteryLevel: UInt16 = 0x2A19
    public static let manufacturerNameString: UInt16 = 0x2A29
    public static let pnpIDCharacteristic: UInt16 = 0x2A50
    public static let hidInformationCharacteristic: UInt16 = 0x2A4A
    public static let reportMapCharacteristic: UInt16 = 0x2A4B
    public static let hidControlPoint: UInt16 = 0x2A4C
    public static let protocolMode: UInt16 = 0x2A4E
    public static let report: UInt16 = 0x2A4D
    public static let bootKeyboardInput: UInt16 = 0x2A22
    public static let bootKeyboardOutput: UInt16 = 0x2A32
    public static let reportReference: UInt16 = 0x2908

    /// "0000XXXX-0000-1000-8000-00805F9B34FB"
    public static func fullUUIDString(_ short: UInt16) -> String {
        "0000" + shortUUIDString(short) + "-0000-1000-8000-00805F9B34FB"
    }

    /// "XXXX"
    public static func shortUUIDString(_ short: UInt16) -> String {
        let hex = String(short, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, 4 - hex.count)) + hex
    }
}
