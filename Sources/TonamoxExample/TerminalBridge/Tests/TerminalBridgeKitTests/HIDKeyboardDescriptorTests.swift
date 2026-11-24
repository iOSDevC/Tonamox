import Testing
import TerminalBridgeKit

@Suite struct HIDKeyboardDescriptorTests {
    /// Short items of a report descriptor: prefix byte and data bytes.
    private struct Item {
        let prefix: UInt8
        let data: [UInt8]

        var value: Int {
            data.reversed().reduce(0) { $0 << 8 | Int($1) }
        }
    }

    private func items(_ bytes: [UInt8]) -> [Item] {
        var parsed: [Item] = []
        var index = 0
        while index < bytes.count {
            let prefix = bytes[index]
            let size = prefix & 0x03 == 3 ? 4 : Int(prefix & 0x03)
            parsed.append(item(in: bytes, at: index, size: size))
            index += 1 + size
        }
        return parsed
    }

    private func item(in bytes: [UInt8], at index: Int, size: Int) -> Item {
        Item(prefix: bytes[index], data: Array(bytes[(index + 1)..<min(bytes.count, index + 1 + size)]))
    }

    /// Bits per main item tag (0x81 Input, 0x91 Output), from the Report Size and Report Count globals.
    private func bits(of mainTag: UInt8) -> Int {
        var reportSize = 0
        var reportCount = 0
        var total = 0
        for item in items(HIDKeyboardDescriptor.reportMap) {
            switch item.prefix {
            case 0x75: reportSize = item.value
            case 0x95: reportCount = item.value
            case mainTag: total += reportSize * reportCount
            default: break
            }
        }
        return total
    }

    @Test func reportMapMatchesTheHardwareVerifiedBytes() {
        let spike: [UInt8] = [
            0x05, 0x01, 0x09, 0x06, 0xA1, 0x01,
            0x85, 0x01,
            0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
            0x95, 0x01, 0x75, 0x08, 0x81, 0x01,
            0x95, 0x05, 0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02,
            0x95, 0x01, 0x75, 0x03, 0x91, 0x01,
            0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
            0xC0,
        ]
        #expect(HIDKeyboardDescriptor.reportMap == spike)
        #expect(HIDKeyboardDescriptor.reportMap.count == 65)
    }

    @Test func reportMapHasOneApplicationCollectionWithReportIDOne() {
        let parsed = items(HIDKeyboardDescriptor.reportMap)
        let collections = parsed.filter { $0.prefix == 0xA1 }
        #expect(collections.count == 1)
        #expect(collections.first?.value == 0x01)
        #expect(parsed.filter { $0.prefix == 0xC0 }.count == 1)
        #expect(parsed.last?.prefix == 0xC0)
        let reportIDs = parsed.filter { $0.prefix == 0x85 }
        #expect(reportIDs.count == 1)
        #expect(reportIDs.first?.value == Int(HIDKeyboardDescriptor.reportID))
        #expect(HIDKeyboardDescriptor.reportID == 1)
        // Generic Desktop / Keyboard
        #expect(parsed.prefix(2).map(\.value) == [0x01, 0x06])
    }

    @Test func inputReportIsEightBytesAndOutputReportIsOneByte() {
        #expect(bits(of: 0x81) == 64)
        #expect(bits(of: 0x91) == 8)
        #expect(HIDKeyboardDescriptor.inputReportLength == 8)
        #expect(HIDKeyboardReport.released.bytes.count == HIDKeyboardDescriptor.inputReportLength)
        #expect(HIDKeyboardDescriptor.reportTypeInput == 1)
        #expect(HIDKeyboardDescriptor.reportTypeOutput == 2)
    }

    @Test func keyArrayLogicalMaximumIs0x65() {
        let parsed = items(HIDKeyboardDescriptor.reportMap)
        #expect(parsed.last { $0.prefix == 0x25 }?.value == 0x65)
        #expect(parsed.last { $0.prefix == 0x29 }?.value == 0x65)
    }

    @Test func hidInformationAndPnPIDAreTheVerifiedValues() {
        #expect(HIDKeyboardDescriptor.hidInformation == [0x11, 0x01, 0x00, 0x02])
        #expect(HIDKeyboardDescriptor.pnpID == [0x02, 0x09, 0x12, 0x01, 0x00, 0x00, 0x01])
        #expect(HIDKeyboardDescriptor.deviceName == "Tonamox Keyboard")
        #expect(HIDKeyboardDescriptor.manufacturerName == "Tonamox")
        #expect(HIDKeyboardDescriptor.reportInterval == .milliseconds(12))
        #expect(HIDKeyboardDescriptor.maxKeyHold == .milliseconds(150))
    }

    @Test func uuidStringsHaveTheBluetoothBaseForm() {
        #expect(HIDGATTIdentifier.fullUUIDString(HIDGATTIdentifier.hidService) == "00001812-0000-1000-8000-00805F9B34FB")
        #expect(HIDGATTIdentifier.shortUUIDString(HIDGATTIdentifier.reportReference) == "2908")
        #expect(HIDGATTIdentifier.shortUUIDString(0x000A) == "000A")
        #expect(HIDGATTIdentifier.fullUUIDString(0x2A4D).count == 36)
        let identifiers: [UInt16] = [
            HIDGATTIdentifier.hidService, HIDGATTIdentifier.batteryService, HIDGATTIdentifier.deviceInformationService,
            HIDGATTIdentifier.batteryLevel, HIDGATTIdentifier.manufacturerNameString,
            HIDGATTIdentifier.pnpIDCharacteristic, HIDGATTIdentifier.hidInformationCharacteristic,
            HIDGATTIdentifier.reportMapCharacteristic, HIDGATTIdentifier.hidControlPoint,
            HIDGATTIdentifier.protocolMode, HIDGATTIdentifier.report, HIDGATTIdentifier.bootKeyboardInput,
            HIDGATTIdentifier.bootKeyboardOutput, HIDGATTIdentifier.reportReference,
        ]
        #expect(identifiers == [
            0x1812, 0x180F, 0x180A, 0x2A19, 0x2A29, 0x2A50, 0x2A4A, 0x2A4B, 0x2A4C, 0x2A4E, 0x2A4D, 0x2A22, 0x2A32,
            0x2908,
        ])
    }
}
