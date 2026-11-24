import Testing
@testable import TerminalBridgeKit

@Suite struct HIDKeystrokeTests {
    /// Written independently of `HIDUsage.permitted`.
    private static func isPrintableKey(_ usage: UInt8) -> Bool {
        (0x04...0x27).contains(usage) || ((0x2C...0x38).contains(usage) && usage != 0x32) || usage == 0x64
    }

    @Test(arguments: UInt8.min...UInt8.max)
    func permitsOnlyPrintableKeyUsages(usage: UInt8) {
        #expect((HIDUsage(rawValue: usage) != nil) == Self.isPrintableKey(usage))
        #expect((HIDKeystroke(modifiers: [], usage: usage) != nil) == Self.isPrintableKey(usage))
        #expect(HIDKeyboardReport(modifierByte: 0, keyUsage: usage).isPermitted == (usage == 0 || Self.isPrintableKey(usage)))
    }

    /// Enter, Escape, Backspace, Tab, Non-US #, Caps Lock, F1-F12, PrintScreen...arrows, keypad Enter, the
    /// Application key, F13-F24 and the modifier usages themselves.
    @Test(arguments: [0x28, 0x29, 0x2A, 0x2B, 0x32, 0x39, 0x58, 0x65] + Array(0x3A...0x52) + Array(0x68...0x73)
        + Array(0xE0...0xE7))
    func neverPermitsEnterTabEscapeBackspaceCapsLockOrFunctionKeys(usage: Int) {
        let byte = UInt8(usage)
        #expect(HIDUsage(rawValue: byte) == nil)
        #expect(HIDKeystroke(modifiers: .leftShift, usage: byte) == nil)
        #expect(!HIDKeyboardReport(modifierByte: 0, keyUsage: byte).isPermitted)
    }

    @Test(arguments: UInt8.min...UInt8.max)
    func permitsOnlyShiftOptionAndAltGrModifierBytes(modifierByte: UInt8) {
        let allowed: Set<UInt8> = [0x00, 0x02, 0x04, 0x40]
        let modifiers = HIDModifierSet(rawValue: modifierByte)
        #expect((HIDKeystroke(modifiers: modifiers, usage: 0x04) != nil) == allowed.contains(modifierByte))
        #expect(HIDKeyboardReport(modifierByte: modifierByte, keyUsage: 0x04).isPermitted == allowed.contains(modifierByte))
        #expect(HIDModifierSet.permittedBytes == allowed)
    }

    @Test func reportBytesAreBootKeyboardLayout() {
        let report = HIDKeyboardReport(modifierByte: 0x40, keyUsage: 0x1F)
        #expect(report.bytes == [0x40, 0x00, 0x1F, 0x00, 0x00, 0x00, 0x00, 0x00])
    }

    @Test func releasedReportIsAllZero() {
        #expect(HIDKeyboardReport.released.bytes == [UInt8](repeating: 0, count: 8))
        #expect(HIDKeyboardReport.released.isPermitted)
        #expect(HIDKeyboardReport.released.isPermitted(within: []))
        #expect(HIDUsage.space.rawValue == 0x2C)
    }

    @Test func reportOutsideTheLayoutsModifiersIsNotPermitted() {
        let pcLayout: HIDModifierSet = [.leftShift, .rightAlt]
        let macLayout: HIDModifierSet = [.leftShift, .leftAlt]
        let option = HIDKeyboardReport(modifierByte: 0x04, keyUsage: 0x1F)
        let altGr = HIDKeyboardReport(modifierByte: 0x40, keyUsage: 0x1F)
        let shift = HIDKeyboardReport(modifierByte: 0x02, keyUsage: 0x1F)
        #expect(option.isPermitted)
        #expect(!option.isPermitted(within: pcLayout))
        #expect(!altGr.isPermitted(within: macLayout))
        #expect(altGr.isPermitted(within: pcLayout))
        #expect(option.isPermitted(within: macLayout))
        #expect(shift.isPermitted(within: .leftShift))
        #expect(!option.isPermitted(within: .leftShift))
        #expect(!HIDKeyboardReport(modifierByte: 0x01, keyUsage: 0x06).isPermitted(within: HIDModifierSet(rawValue: 0xFF)))
    }

    @Test func capsLockIsBitOneOfTheLEDReportAndEmptyWritesStayUnknown() {
        #expect(HIDKeyboardLEDs.capsLock.rawValue == 0x02)
        #expect(HIDKeyboardLEDs.numLock.rawValue == 0x01)
        #expect(HIDKeyboardLEDs.parse([]) == nil)
        #expect(HIDKeyboardLEDs.parse([0x02])?.contains(.capsLock) == true)
        #expect(HIDKeyboardLEDs.parse([0x03, 0x00])?.contains(.capsLock) == true)
        #expect(HIDKeyboardLEDs.parse([0x01])?.contains(.capsLock) == false)
        #expect(HIDKeyboardLEDs.parse([0x00]) == [])
    }
}
