import Foundation

/// The computer's operating system family; symbol positions differ between them for the same layout name.
public enum HostOS: String, CaseIterable, Codable, Sendable {
    case macOS
    case windows
    case linux

    public var title: String {
        switch self {
        case .macOS: "macOS"
        case .windows: "Windows"
        case .linux: "Linux"
        }
    }
}

/// Stable ids, persisted in UserDefaults.
public enum HostKeyboardLayoutID: String, CaseIterable, Codable, Sendable {
    case macUS = "mac.us"
    case macSpanishISO = "mac.es-iso"
    case windowsUS = "win.us"
    case windowsSpanish = "win.es"
    case windowsLatinAmerican = "win.latam"
    case linuxUS = "linux.us"
    case linuxSpanish = "linux.es"
    case linuxLatinAmerican = "linux.latam"
}

/// What of a table was seen arriving correctly on real hardware.
public struct LayoutVerification: Hashable, Sendable {
    /// Characters seen arriving correctly on real hardware; empty for every table except the two macOS ones.
    public let verifiedCharacters: Set<Character>
    /// Date, devices, the line typed.
    public let evidence: String?
    /// Spanish: what was typed, as the badge names it ("lo que tecleó…"). Nil falls back to a count.
    public let scope: String?

    init(verifiedCharacters: Set<Character>, evidence: String?, scope: String? = nil) {
        self.verifiedCharacters = verifiedCharacters
        self.evidence = evidence
        self.scope = scope
    }

    static let unverified = LayoutVerification(verifiedCharacters: [], evidence: nil)

    /// All of 0x20...0x7E verified.
    public var isFullyVerified: Bool {
        HostKeyboardLayout.printableASCII.allSatisfy { verifiedCharacters.contains($0) }
    }

    /// Spanish badge text.
    public var summary: String {
        if isFullyVerified { return "Verificada en hardware." }
        if verifiedCharacters.isEmpty { return "No verificada en hardware." }
        if let scope { return "Verificado en hardware solo \(scope). El resto, no." }
        let total = HostKeyboardLayout.printableASCII.count
        return "Verificados en hardware \(verifiedCharacters.count) de \(total) caracteres. El resto, no."
    }

    /// Distinct characters of `text` outside verifiedCharacters, in order of first appearance.
    public func unverifiedCharacters(in text: String) -> [Character] {
        var seen = Set<Character>()
        return text.filter { !verifiedCharacters.contains($0) && seen.insert($0).inserted }.map { $0 }
    }
}

/// One host OS + layout pair: how each printable ASCII character is typed there.
public struct HostKeyboardLayout: Identifiable, Sendable {
    public let id: HostKeyboardLayoutID
    /// Not `hostOS`: `HostOS` is declared in the same file.
    public let host: HostOS
    /// Spanish UI title, e.g. "Español - ISO".
    public let title: String
    /// What the user selects as input source on the computer.
    public let hostInputSource: String
    public let permittedModifiers: HIDModifierSet
    public let verification: LayoutVerification
    public let probeLine: String
    public let sources: [String]
    let entries: [Unicode.Scalar: [HIDKeystroke]]

    init(
        id: HostKeyboardLayoutID,
        host: HostOS,
        title: String,
        hostInputSource: String,
        permittedModifiers: HIDModifierSet,
        verification: LayoutVerification,
        probeLine: String,
        sources: [String],
        entries: [Unicode.Scalar: [HIDKeystroke]]
    ) {
        self.id = id
        self.host = host
        self.title = title
        self.hostInputSource = hostInputSource
        self.permittedModifiers = permittedModifiers
        self.verification = verification
        self.probeLine = probeLine
        self.sources = sources
        self.entries = entries
    }

    /// Nil when the layout cannot type `scalar`. Callers must also treat an empty result as unmappable.
    public func keystrokes(for scalar: Unicode.Scalar) -> [HIDKeystroke]? {
        entries[scalar]
    }

    public static let all: [HostKeyboardLayout] = HostKeyboardLayoutID.allCases.map(layout)

    public static func layout(_ id: HostKeyboardLayoutID) -> HostKeyboardLayout {
        switch id {
        case .macUS: macUS
        case .macSpanishISO: macSpanishISO
        case .windowsUS: windowsUS
        case .windowsSpanish: windowsSpanish
        case .windowsLatinAmerican: windowsLatinAmerican
        case .linuxUS: linuxUS
        case .linuxSpanish: linuxSpanish
        case .linuxLatinAmerican: linuxLatinAmerican
        }
    }

    public static func layouts(for hostOS: HostOS) -> [HostKeyboardLayout] {
        all.filter { $0.host == hostOS }
    }

    /// The Spanish table of that OS.
    public static func defaultLayout(for hostOS: HostOS) -> HostKeyboardLayout {
        switch hostOS {
        case .macOS: macSpanishISO
        case .windows: windowsSpanish
        case .linux: linuxSpanish
        }
    }

    /// UserDefaults fallback: an unknown or mismatched raw value gives the default of `hostOS`.
    public static func resolve(rawID: String?, hostOS: HostOS) -> HostKeyboardLayout {
        guard let rawID, let id = HostKeyboardLayoutID(rawValue: rawID) else { return defaultLayout(for: hostOS) }
        let stored = layout(id)
        return stored.host == hostOS ? stored : defaultLayout(for: hostOS)
    }

    /// 0x20...0x7E in order.
    static let printableASCII: [Character] = (UInt8(0x20)...UInt8(0x7E)).map(character)

    /// The 17 distinct characters of the spike line "tonamox ble hid ok 123" (input source not recorded); what
    /// `macUS` counts as verified.
    static let spikeVerifiedCharacters = Set<Character>("tonamox ble hid ok 123")

    private static func character(_ value: UInt8) -> Character {
        Character(Unicode.Scalar(value))
    }
}
