import Foundation

/// Modifier bits of the boot keyboard report (HID Usage Tables page 0x07, E0-E7). Only the three a printable
/// character can need are declared; Control and GUI (Cmd/Win) have no constant on purpose.
public struct HIDModifierSet: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let leftShift = HIDModifierSet(rawValue: 0x02)
    /// Option on macOS.
    public static let leftAlt = HIDModifierSet(rawValue: 0x04)
    /// AltGr on Windows and Linux.
    public static let rightAlt = HIDModifierSet(rawValue: 0x40)

    /// The only modifier bytes a report may carry: 0x00, 0x02, 0x04, 0x40. Never Ctrl, GUI or combinations.
    public static let permittedBytes: Set<UInt8> = [0x00, 0x02, 0x04, 0x40]
}

/// A key usage from page 0x07 that is allowed to be pressed.
public struct HIDUsage: Hashable, Sendable, RawRepresentable {
    public let rawValue: UInt8

    /// Nil outside `permitted`.
    public init?(rawValue: UInt8) {
        guard Self.permitted.contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    private init(unchecked rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// 0x04...0x27 (letters, digits), 0x2C...0x38 except 0x32, and 0x64 (ISO key next to left shift).
    /// Excludes Enter 0x28, Escape 0x29, Backspace 0x2A, Tab 0x2B, Caps Lock 0x39 and everything above.
    public static let permitted: Set<UInt8> = {
        var usages = Set<UInt8>(0x04...0x27)
        usages.formUnion(0x2C...0x38)
        usages.remove(0x32)
        usages.insert(0x64)
        return usages
    }()

    public static let space = HIDUsage(unchecked: 0x2C)
}

/// One character-producing key press: the modifiers held and the key.
public struct HIDKeystroke: Hashable, Sendable {
    public let modifiers: HIDModifierSet
    public let usage: HIDUsage

    /// Nil when the modifier byte or the usage is not permitted.
    public init?(modifiers: HIDModifierSet, usage: UInt8) {
        guard HIDModifierSet.permittedBytes.contains(modifiers.rawValue),
              let permittedUsage = HIDUsage(rawValue: usage)
        else { return nil }
        self.modifiers = modifiers
        self.usage = permittedUsage
    }
}

/// The 8-byte boot-compatible input report. The report ID travels in the Report Reference descriptor.
public struct HIDKeyboardReport: Hashable, Sendable {
    public let modifierByte: UInt8
    /// 0 means no key.
    public let keyUsage: UInt8

    init(modifierByte: UInt8, keyUsage: UInt8) {
        self.modifierByte = modifierByte
        self.keyUsage = keyUsage
    }

    public static let released = HIDKeyboardReport(modifierByte: 0, keyUsage: 0)

    /// [modifierByte, 0, keyUsage, 0, 0, 0, 0, 0]
    public var bytes: [UInt8] {
        [modifierByte, 0, keyUsage, 0, 0, 0, 0, 0]
    }

    /// modifierByte in `HIDModifierSet.permittedBytes` and keyUsage == 0 or in `HIDUsage.permitted`.
    public var isPermitted: Bool {
        HIDModifierSet.permittedBytes.contains(modifierByte)
            && (keyUsage == 0 || HIDUsage.permitted.contains(keyUsage))
    }

    /// `isPermitted` and every modifier bit inside `modifiers` (the layout's own set).
    public func isPermitted(within modifiers: HIDModifierSet) -> Bool {
        isPermitted && modifierByte & ~modifiers.rawValue == 0
    }
}

/// Host LED output report (one byte, written by the host to Output Report 2A4D or Boot Output 2A32).
public struct HIDKeyboardLEDs: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let numLock = HIDKeyboardLEDs(rawValue: 0x01)
    public static let capsLock = HIDKeyboardLEDs(rawValue: 0x02)

    /// First byte of the write; an empty write gives nil (state stays unknown).
    public static func parse(_ value: [UInt8]) -> HIDKeyboardLEDs? {
        value.first.map { HIDKeyboardLEDs(rawValue: $0) }
    }
}
