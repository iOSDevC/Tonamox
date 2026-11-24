import Foundation

// Derivation and per-cell sources: docs/exec-plans/active/2026-11-18-bluetooth-keyboard-mode.md
// ("Layout tables to ship"). Letters, digits and space are shared; only the symbol rows differ.
extension HostKeyboardLayout {
    static let macUS = HostKeyboardLayout(
        id: .macUS,
        host: .macOS,
        title: "EE. UU.",
        hostInputSource: "U.S. («EE. UU.») o «ABC»",
        permittedModifiers: .leftShift,
        verification: macUSVerification,
        probeLine: probeUS,
        sources: [usbSource, appleSource],
        entries: table(usSymbols)
    )

    static let macSpanishISO = HostKeyboardLayout(
        id: .macSpanishISO,
        host: .macOS,
        title: "Español - ISO",
        hostInputSource: "Español - ISO",
        permittedModifiers: [.leftShift, .leftAlt],
        verification: macSpanishISOVerification,
        probeLine: probeSpanish,
        sources: [usbSource, appleSource],
        entries: table(macSpanishSymbols)
    )

    static let windowsUS = HostKeyboardLayout(
        id: .windowsUS,
        host: .windows,
        title: "EE. UU.",
        hostInputSource: "EE. UU. (00000409)",
        permittedModifiers: .leftShift,
        verification: .unverified,
        probeLine: probeUS,
        sources: [usbSource, microsoftSource],
        entries: table(usSymbols)
    )

    static let windowsSpanish = HostKeyboardLayout(
        id: .windowsSpanish,
        host: .windows,
        title: "Español (España)",
        hostInputSource: "Español (0000040A)",
        permittedModifiers: [.leftShift, .rightAlt],
        verification: .unverified,
        probeLine: probeSpanish,
        sources: [usbSource, microsoftSource, microsoftSpanishKLC],
        entries: table(windowsSpanishSymbols)
    )

    static let windowsLatinAmerican = HostKeyboardLayout(
        id: .windowsLatinAmerican,
        host: .windows,
        title: "Español (Latinoamérica)",
        hostInputSource: "Latinoamericano (0000080A)",
        permittedModifiers: [.leftShift, .rightAlt],
        verification: .unverified,
        probeLine: probeLatinAmerican,
        sources: [usbSource, microsoftSource, microsoftLatinAmericanKLC],
        entries: table(latinAmericanSymbols)
    )

    static let linuxUS = HostKeyboardLayout(
        id: .linuxUS,
        host: .linux,
        title: "EE. UU.",
        hostInputSource: "xkb us",
        permittedModifiers: .leftShift,
        verification: .unverified,
        probeLine: probeUS,
        sources: [usbSource, xkbSource],
        entries: table(usSymbols)
    )

    static let linuxSpanish = HostKeyboardLayout(
        id: .linuxSpanish,
        host: .linux,
        title: "Español (España)",
        hostInputSource: "xkb es",
        permittedModifiers: [.leftShift, .rightAlt],
        verification: .unverified,
        probeLine: probeSpanish,
        sources: [usbSource, xkbSource],
        entries: table(linuxSpanishSymbols)
    )

    static let linuxLatinAmerican = HostKeyboardLayout(
        id: .linuxLatinAmerican,
        host: .linux,
        title: "Español (Latinoamérica)",
        hostInputSource: "xkb latam",
        permittedModifiers: [.leftShift, .rightAlt],
        verification: .unverified,
        probeLine: probeLatinAmerican,
        sources: [usbSource, xkbSource],
        entries: table(latinAmericanSymbols)
    )

    // MARK: - Probe lines

    // Every symbol except `'` sits inside single quotes after the null command, so a stray Enter only runs `:`.
    static let probeUS = #": 'tnx Az09 ~!@#$%^&*()_+{}|:"<>?`-=[]\;,./'"#
    static let probeSpanish = #": 'tnx Az09 <>\|@#~^`[]{}"&/=?*+-_;:!$%(),.'"#
    static let probeLatinAmerican = #": 'tnx Az09 |\<>@#~^`[]{}"&/=?*+-_;:!$%(),.'"#

    // MARK: - Verification

    static let macUSVerification = LayoutVerification(
        verifiedCharacters: spikeVerifiedCharacters,
        evidence: "2026-11-18: iPhone con iOS 27 emparejado con una Mac con macOS 27.2.1; llegó bien "
            + "«tonamox ble hid ok 123». No se registró la fuente de entrada activa en la Mac.",
        scope: "lo que tecleó la prueba del 2026-11-18 (17 caracteres: «tonamox ble hid ok 123»)"
    )

    // Exactly the probe line: the spike's input source was not recorded, so its characters are not carried over.
    static let macSpanishISOVerification = LayoutVerification(
        verifiedCharacters: Set(probeSpanish),
        evidence: "2026-11-18: iPhone con iOS 27 y Mac con macOS 27.2.1, fuente de entrada «Español - ISO»; "
            + "la línea de prueba llegó idéntica byte a byte.",
        scope: "la línea de prueba de Español - ISO del 2026-11-18 (40 caracteres, símbolos con Opción y "
            + "teclas muertas incluidos)"
    )

    // MARK: - Sources

    static let usbSource = "USB-IF, HID Usage Tables 1.5, Keyboard/Keypad Page (0x07): "
        + "https://usb.org/document-library/hid-usage-tables-15"
    static let appleSource = "UCKeyTranslate sobre com.apple.keylayout.US y com.apple.keylayout.Spanish-ISO "
        + "(macOS 27.2.1, 2026-11-18); códigos de tecla virtual de HIToolbox Events.h"
    static let microsoftSource = "Microsoft, Windows keyboard layouts: "
        + "https://learn.microsoft.com/globalization/windows-keyboard-layouts"
    static let microsoftSpanishKLC = "KLC de KBDSP: https://kbdlayout.info/kbdsp/download/klc"
    static let microsoftLatinAmericanKLC = "KLC de KBDLA: https://kbdlayout.info/kbdla/download/klc"
    static let xkbSource = "xkeyboard-config 2.42 symbols/us, es, latam, latin, pc: "
        + "https://sources.debian.org/data/main/x/xkeyboard-config/2.42-1/symbols/"

    // MARK: - Symbol rows

    static let usSymbols: [Unicode.Scalar: [HIDKeystroke]] = [
        "!": key(0x1E, .leftShift), "\"": key(0x34, .leftShift), "#": key(0x20, .leftShift),
        "$": key(0x21, .leftShift), "%": key(0x22, .leftShift), "&": key(0x24, .leftShift),
        "'": key(0x34), "(": key(0x26, .leftShift), ")": key(0x27, .leftShift),
        "*": key(0x25, .leftShift), "+": key(0x2E, .leftShift), ",": key(0x36),
        "-": key(0x2D), ".": key(0x37), "/": key(0x38),
        ":": key(0x33, .leftShift), ";": key(0x33), "<": key(0x36, .leftShift),
        "=": key(0x2E), ">": key(0x37, .leftShift), "?": key(0x38, .leftShift),
        "@": key(0x1F, .leftShift), "[": key(0x2F), "\\": key(0x31),
        "]": key(0x30), "^": key(0x23, .leftShift), "_": key(0x2D, .leftShift),
        "`": key(0x35), "{": key(0x2F, .leftShift), "|": key(0x31, .leftShift),
        "}": key(0x30, .leftShift), "~": key(0x35, .leftShift),
    ]

    /// Symbols on the unmodified and Shift levels, identical on macOS ISO, Windows and Linux Spanish.
    static let spanishShiftSymbols: [Unicode.Scalar: [HIDKeystroke]] = [
        "!": key(0x1E, .leftShift), "\"": key(0x1F, .leftShift), "$": key(0x21, .leftShift),
        "%": key(0x22, .leftShift), "&": key(0x23, .leftShift), "'": key(0x2D),
        "(": key(0x25, .leftShift), ")": key(0x26, .leftShift), "*": key(0x30, .leftShift),
        "+": key(0x30), ",": key(0x36), "-": key(0x38),
        ".": key(0x37), "/": key(0x24, .leftShift), ":": key(0x37, .leftShift),
        ";": key(0x36, .leftShift), "=": key(0x27, .leftShift), "?": key(0x2D, .leftShift),
        "^": dead(0x2F, .leftShift), "_": key(0x38, .leftShift), "`": dead(0x2F),
    ]

    /// Assumption A1: `<`/`>` on HID 0x35 and `\` on HID 0x64 (no ISO swap). Confirmed here by probe H4
    /// (2026-11-18); still open for `macUS`, whose `` ` ``/`~` on 0x35 would arrive as `§`/`±` on ISO (H3).
    static let macSpanishSymbols = spanishShiftSymbols.merging([
        "#": key(0x20, .leftAlt), "<": key(0x35), ">": key(0x35, .leftShift),
        "@": key(0x1F, .leftAlt), "[": key(0x2F, .leftAlt), "\\": key(0x64, .leftAlt),
        "]": key(0x30, .leftAlt), "{": key(0x34, .leftAlt), "|": key(0x1E, .leftAlt),
        "}": key(0x31, .leftAlt), "~": dead(0x33, .leftAlt),
    ], uniquingKeysWith: rejectDuplicate)

    /// AltGr level of KBDSP and xkb `es`, without `~` (dead on Windows, not on Linux).
    static let pcSpanishAltGrSymbols = spanishShiftSymbols.merging([
        "#": key(0x20, .rightAlt), "<": key(0x64), ">": key(0x64, .leftShift),
        "@": key(0x1F, .rightAlt), "[": key(0x2F, .rightAlt), "\\": key(0x35, .rightAlt),
        "]": key(0x30, .rightAlt), "{": key(0x34, .rightAlt), "|": key(0x1E, .rightAlt),
        "}": key(0x31, .rightAlt),
    ], uniquingKeysWith: rejectDuplicate)

    static let windowsSpanishSymbols = pcSpanishAltGrSymbols.merging(
        ["~": dead(0x21, .rightAlt)], uniquingKeysWith: rejectDuplicate
    )

    static let linuxSpanishSymbols = pcSpanishAltGrSymbols.merging(
        ["~": key(0x21, .rightAlt)], uniquingKeysWith: rejectDuplicate
    )

    /// KBDLA and xkb `latam` agree on every ASCII symbol.
    static let latinAmericanSymbols: [Unicode.Scalar: [HIDKeystroke]] = [
        "!": key(0x1E, .leftShift), "\"": key(0x1F, .leftShift), "#": key(0x20, .leftShift),
        "$": key(0x21, .leftShift), "%": key(0x22, .leftShift), "&": key(0x23, .leftShift),
        "'": key(0x2D), "(": key(0x25, .leftShift), ")": key(0x26, .leftShift),
        "*": key(0x30, .leftShift), "+": key(0x30), ",": key(0x36),
        "-": key(0x38), ".": key(0x37), "/": key(0x24, .leftShift),
        ":": key(0x37, .leftShift), ";": key(0x36, .leftShift), "<": key(0x64),
        "=": key(0x27, .leftShift), ">": key(0x64, .leftShift), "?": key(0x2D, .leftShift),
        "@": key(0x14, .rightAlt), "[": key(0x34, .leftShift), "\\": key(0x2D, .rightAlt),
        "]": key(0x31, .leftShift), "^": dead(0x34, .rightAlt), "_": key(0x38, .leftShift),
        "`": dead(0x31, .rightAlt), "{": key(0x34), "|": key(0x35),
        "}": key(0x31), "~": key(0x30, .rightAlt),
    ]

    // MARK: - Factories

    /// Letters a-z / A-Z, digits and space, the same usages in all eight tables.
    static let sharedEntries: [Unicode.Scalar: [HIDKeystroke]] = {
        var shared: [Unicode.Scalar: [HIDKeystroke]] = [" ": key(0x2C), "0": key(0x27)]
        for offset in UInt8(0)..<26 {
            shared[scalar(0x61 + offset)] = key(0x04 + offset)
            shared[scalar(0x41 + offset)] = key(0x04 + offset, .leftShift)
        }
        for offset in UInt8(0)..<9 {
            shared[scalar(0x31 + offset)] = key(0x1E + offset)
        }
        return shared
    }()

    static func table(_ symbols: [Unicode.Scalar: [HIDKeystroke]]) -> [Unicode.Scalar: [HIDKeystroke]] {
        sharedEntries.merging(symbols, uniquingKeysWith: rejectDuplicate)
    }

    /// One key press; an impermissible usage or modifier gives an empty entry, which the encoder refuses.
    static func key(_ usage: UInt8, _ modifiers: HIDModifierSet = []) -> [HIDKeystroke] {
        guard let keystroke = HIDKeystroke(modifiers: modifiers, usage: usage) else { return [] }
        return [keystroke]
    }

    /// A dead key followed by Space, which yields the spacing accent on all three host families.
    static func dead(_ usage: UInt8, _ modifiers: HIDModifierSet = []) -> [HIDKeystroke] {
        let accent = key(usage, modifiers)
        guard !accent.isEmpty, let space = HIDKeystroke(modifiers: [], usage: HIDUsage.space.rawValue) else {
            return []
        }
        return accent + [space]
    }

    /// A clash between shared and layout rows is a table bug; an empty entry makes the encoder refuse it.
    private static func rejectDuplicate(_ first: [HIDKeystroke], _ second: [HIDKeystroke]) -> [HIDKeystroke] {
        []
    }

    private static func scalar(_ value: UInt8) -> Unicode.Scalar {
        Unicode.Scalar(value)
    }
}
