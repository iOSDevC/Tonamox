import Foundation
import Testing
@testable import TerminalBridgeKit

@Suite struct HostKeyboardLayoutTests {
    // Transcribed from the plan's "Layout tables to ship" (cited sources there), independent of the kit tables.
    private static let usCells: [Character: String] = [
        "!": "S1E", "\"": "S34", "#": "S20", "$": "S21", "%": "S22", "&": "S24", "'": "34", "(": "S26",
        ")": "S27", "*": "S25", "+": "S2E", ",": "36", "-": "2D", ".": "37", "/": "38", ":": "S33",
        ";": "33", "<": "S36", "=": "2E", ">": "S37", "?": "S38", "@": "S1F", "[": "2F", "\\": "31",
        "]": "30", "^": "S23", "_": "S2D", "`": "35", "{": "S2F", "|": "S31", "}": "S30", "~": "S35",
    ]
    private static let macSpanishCells: [Character: String] = [
        "!": "S1E", "\"": "S1F", "#": "O20", "$": "S21", "%": "S22", "&": "S23", "'": "2D", "(": "S25",
        ")": "S26", "*": "S30", "+": "30", ",": "36", "-": "38", ".": "37", "/": "S24", ":": "S37",
        ";": "S36", "<": "35", "=": "S27", ">": "S35", "?": "S2D", "@": "O1F", "[": "O2F", "\\": "O64",
        "]": "O30", "^": "S2F dead", "_": "S38", "`": "2F dead", "{": "O34", "|": "O1E", "}": "O31",
        "~": "O33 dead",
    ]
    private static let windowsSpanishCells: [Character: String] = [
        "!": "S1E", "\"": "S1F", "#": "G20", "$": "S21", "%": "S22", "&": "S23", "'": "2D", "(": "S25",
        ")": "S26", "*": "S30", "+": "30", ",": "36", "-": "38", ".": "37", "/": "S24", ":": "S37",
        ";": "S36", "<": "64", "=": "S27", ">": "S64", "?": "S2D", "@": "G1F", "[": "G2F", "\\": "G35",
        "]": "G30", "^": "S2F dead", "_": "S38", "`": "2F dead", "{": "G34", "|": "G1E", "}": "G31",
        "~": "G21 dead",
    ]
    private static let linuxSpanishCells = windowsSpanishCells.merging(["~": "G21"]) { $1 }
    private static let latinAmericanCells: [Character: String] = [
        "!": "S1E", "\"": "S1F", "#": "S20", "$": "S21", "%": "S22", "&": "S23", "'": "2D", "(": "S25",
        ")": "S26", "*": "S30", "+": "30", ",": "36", "-": "38", ".": "37", "/": "S24", ":": "S37",
        ";": "S36", "<": "64", "=": "S27", ">": "S64", "?": "S2D", "@": "G14", "[": "S34", "\\": "G2D",
        "]": "S31", "^": "G34 dead", "_": "S38", "`": "G31 dead", "{": "34", "|": "35", "}": "31",
        "~": "G30",
    ]

    private static func cells(for id: HostKeyboardLayoutID) -> [Character: String] {
        switch id {
        case .macUS, .windowsUS, .linuxUS: usCells
        case .macSpanishISO: macSpanishCells
        case .windowsSpanish: windowsSpanishCells
        case .linuxSpanish: linuxSpanishCells
        case .windowsLatinAmerican, .linuxLatinAmerican: latinAmericanCells
        }
    }

    private static let usIDs: Set<HostKeyboardLayoutID> = [.macUS, .windowsUS, .linuxUS]

    private func entry(_ id: HostKeyboardLayoutID, _ character: Character) -> [HIDKeystroke]? {
        character.unicodeScalars.first.flatMap { HostKeyboardLayout.layout(id).keystrokes(for: $0) }
    }

    private func usedModifiers(_ layout: HostKeyboardLayout) -> HIDModifierSet {
        layout.entries.values.joined().reduce(into: []) { $0.formUnion($1.modifiers) }
    }

    @Test(arguments: HostKeyboardLayoutID.allCases)
    func everyLayoutTypesEveryPrintableASCIICharacter(id: HostKeyboardLayoutID) {
        let layout = HostKeyboardLayout.layout(id)
        let missing = HostKeyboardLayout.printableASCII.filter { entry(id, $0) == nil }
        #expect(missing.isEmpty)
        #expect(layout.entries.count == 95)
    }

    @Test(arguments: HostKeyboardLayoutID.allCases)
    func everyEntryUsesPermittedUsagesAndOnlyTheLayoutsModifiers(id: HostKeyboardLayoutID) {
        let layout = HostKeyboardLayout.layout(id)
        let pressed = layout.entries.values.flatMap { $0 }
        #expect(pressed.allSatisfy { HIDUsage.permitted.contains($0.usage.rawValue) })
        #expect(pressed.allSatisfy { layout.permittedModifiers.isSuperset(of: $0.modifiers) })
        #expect(pressed.allSatisfy { HIDModifierSet.permittedBytes.contains($0.modifiers.rawValue) })
    }

    @Test(arguments: HostKeyboardLayoutID.allCases)
    func everyTableEntryProducesAtLeastOneKeyPress(id: HostKeyboardLayoutID) {
        let layout = HostKeyboardLayout.layout(id)
        let empty = layout.entries.filter { $0.value.isEmpty }.keys
        #expect(empty.isEmpty)
        // A dead entry is exactly accent + Space; anything else is one key press.
        #expect(layout.entries.values.allSatisfy { $0.count == 1 || $0.count == 2 })
    }

    @Test(arguments: HostKeyboardLayoutID.allCases)
    func deadKeysAppearOnlyWhereTheSourcesSayDead(id: HostKeyboardLayoutID) {
        let expected: Set<Character> = switch id {
        case .macUS, .windowsUS, .linuxUS: []
        case .macSpanishISO, .windowsSpanish: ["^", "`", "~"]
        case .linuxSpanish, .windowsLatinAmerican, .linuxLatinAmerican: ["^", "`"]
        }
        #expect(HostKeyboardLayout.layout(id).deadCharacters == expected)
    }

    @Test func usLayoutsUseOnlyShift() {
        for id in Self.usIDs {
            let layout = HostKeyboardLayout.layout(id)
            #expect(layout.permittedModifiers == .leftShift)
            #expect(layout.entries.values.joined().allSatisfy { $0.modifiers.isSubset(of: .leftShift) })
        }
    }

    @Test func macLayoutsNeverUseAltGrAndPCLayoutsNeverUseOption() {
        for layout in HostKeyboardLayout.all {
            let used = usedModifiers(layout)
            if layout.host == .macOS {
                #expect(!used.contains(.rightAlt))
                #expect(!layout.permittedModifiers.contains(.rightAlt))
            } else {
                #expect(!used.contains(.leftAlt))
                #expect(!layout.permittedModifiers.contains(.leftAlt))
            }
        }
    }

    @Test(arguments: HostKeyboardLayoutID.allCases)
    func deadKeysAreFollowedBySpace(id: HostKeyboardLayoutID) {
        let dead = HostKeyboardLayout.layout(id).entries.filter { $0.value.count == 2 }.values
        #expect(dead.allSatisfy { $0.last?.usage == .space && $0.last?.modifiers == [] && $0.first?.usage != .space })
    }

    @Test func windowsSpanishTildeIsDeadAndLinuxSpanishTildeIsNot() {
        #expect(entry(.windowsSpanish, "~") == keystrokes(fromCell: "G21 dead"))
        #expect(entry(.linuxSpanish, "~") == keystrokes(fromCell: "G21"))
    }

    @Test(arguments: HostKeyboardLayoutID.allCases)
    func pinnedSymbolsMatchTheCitedSources(id: HostKeyboardLayoutID) {
        let cells = Self.cells(for: id)
        #expect(cells.count == 32)
        for (character, cell) in cells {
            #expect(entry(id, character) == keystrokes(fromCell: cell), "\(id.rawValue) \(character)")
        }
    }

    @Test func lettersDigitsAndSpaceUseTheSameUsagesEverywhere() {
        for layout in HostKeyboardLayout.all {
            #expect(layout.keystrokes(for: "a") == keystrokes(fromCell: "04"))
            #expect(layout.keystrokes(for: "Z") == keystrokes(fromCell: "S1D"))
            #expect(layout.keystrokes(for: "1") == keystrokes(fromCell: "1E"))
            #expect(layout.keystrokes(for: "9") == keystrokes(fromCell: "26"))
            #expect(layout.keystrokes(for: "0") == keystrokes(fromCell: "27"))
            #expect(layout.keystrokes(for: " ") == keystrokes(fromCell: "2C"))
        }
    }

    @Test func macISOKeysFollowAssumptionA1() {
        #expect(entry(.macSpanishISO, "<") == keystrokes(fromCell: "35"))
        #expect(entry(.macSpanishISO, ">") == keystrokes(fromCell: "S35"))
        #expect(entry(.macSpanishISO, "\\") == keystrokes(fromCell: "O64"))
        #expect(entry(.macUS, "`") == keystrokes(fromCell: "35"))
        #expect(entry(.macUS, "~") == keystrokes(fromCell: "S35"))
    }

    @Test func onlyTheMacLayoutsClaimAnyHardwareVerification() {
        for layout in HostKeyboardLayout.all {
            #expect(!layout.verification.isFullyVerified)
            if layout.host != .macOS {
                #expect(layout.verification.verifiedCharacters.isEmpty)
                #expect(layout.verification.evidence == nil)
                #expect(layout.verification.summary == "No verificada en hardware.")
            }
        }
    }

    @Test func macUSKeepsOnlyTheSpikeLineVerified() {
        let spike = Set<Character>("tonamxblehidk123 ")
        #expect(spike.count == 17)
        let verification = HostKeyboardLayout.macUS.verification
        #expect(verification.verifiedCharacters == spike)
        #expect(verification.evidence?.contains("tonamox ble hid ok 123") == true)
        #expect(verification.summary.hasPrefix("Verificado en hardware solo lo que tecleó la prueba"))
        #expect(verification.summary.contains("17 caracteres"))
        #expect(verification.unverifiedCharacters(in: "ls -la | ls") == ["s", "-", "|"])
        #expect(verification.unverifiedCharacters(in: "Ab") == ["A"])
        #expect(verification.unverifiedCharacters(in: "yzqw0456789") == Array("yzqw0456789"))
    }

    @Test func macSpanishISOHasExactlyTheProbeLineVerified() {
        let probe = Set<Character>(##" !"#$%&'()*+,-./09:;<=>?@A[\]^_`ntxz{|}~"##)
        #expect(probe.count == 40)
        #expect(Set(HostKeyboardLayout.probeSpanish) == probe)
        let verification = HostKeyboardLayout.macSpanishISO.verification
        #expect(verification.verifiedCharacters == probe)
        #expect(verification.evidence?.contains("Español - ISO") == true)
        #expect(verification.evidence?.contains("byte a byte") == true)
        #expect(verification.summary.hasPrefix("Verificado en hardware solo la línea de prueba de Español - ISO"))
        #expect(verification.summary.contains("40 caracteres"))
        #expect(verification.unverifiedCharacters(in: "ls -la") == ["l", "s", "a"])
    }

    @Test func everyHostOSHasLayoutsAndASpanishDefault() {
        #expect(HostKeyboardLayout.layouts(for: .macOS).map(\.id) == [.macUS, .macSpanishISO])
        #expect(HostKeyboardLayout.layouts(for: .windows).map(\.id) == [.windowsUS, .windowsSpanish, .windowsLatinAmerican])
        #expect(HostKeyboardLayout.layouts(for: .linux).map(\.id) == [.linuxUS, .linuxSpanish, .linuxLatinAmerican])
        for hostOS in HostOS.allCases {
            let fallback = HostKeyboardLayout.defaultLayout(for: hostOS)
            #expect(fallback.host == hostOS)
            #expect(fallback.title.hasPrefix("Español"))
        }
        #expect(HostKeyboardLayout.all.count == HostKeyboardLayoutID.allCases.count)
        #expect(HostKeyboardLayout.all.allSatisfy { !$0.sources.isEmpty && !$0.hostInputSource.isEmpty })
        #expect(HostOS.allCases.map(\.title) == ["macOS", "Windows", "Linux"])
    }

    @Test func resolveFallsBackForUnknownOrMismatchedIDs() {
        #expect(HostKeyboardLayout.resolve(rawID: nil, hostOS: .macOS).id == .macSpanishISO)
        #expect(HostKeyboardLayout.resolve(rawID: "nope", hostOS: .windows).id == .windowsSpanish)
        #expect(HostKeyboardLayout.resolve(rawID: "mac.us", hostOS: .linux).id == .linuxSpanish)
        #expect(HostKeyboardLayout.resolve(rawID: "mac.us", hostOS: .macOS).id == .macUS)
        #expect(HostKeyboardLayout.resolve(rawID: "win.latam", hostOS: .windows).id == .windowsLatinAmerican)
    }

    @Test(arguments: HostKeyboardLayoutID.allCases)
    func layoutIDsRoundTripThroughRawValues(id: HostKeyboardLayoutID) throws {
        #expect(HostKeyboardLayoutID(rawValue: id.rawValue) == id)
        #expect(HostKeyboardLayout.layout(id).id == id)
        let encoded = try JSONEncoder().encode(id)
        #expect(try JSONDecoder().decode(HostKeyboardLayoutID.self, from: encoded) == id)
    }

    @Test(arguments: HostKeyboardLayoutID.allCases)
    func probeLinesPassThePolicyRaiseNoWarningsAndEncode(id: HostKeyboardLayoutID) throws {
        let layout = HostKeyboardLayout.layout(id)
        #expect(CommandTextPolicy.validate(layout.probeLine).isEmpty)
        #expect(RiskyCommandRules.evaluate(layout.probeLine).isEmpty)
        let plan = try KeyboardTypingPlan.make(text: layout.probeLine, layout: layout, acknowledged: []).get()
        #expect(plan.text == layout.probeLine)
    }

    @Test(arguments: HostKeyboardLayoutID.allCases)
    func probeLinesQuoteEverySymbolAfterTheNullCommand(id: HostKeyboardLayoutID) {
        let probe = HostKeyboardLayout.layout(id).probeLine
        #expect(probe.hasPrefix(": '"))
        #expect(probe.hasSuffix("'"))
        #expect(probe.filter { $0 == "'" }.count == 2)
        let quoted = probe.dropFirst(3).dropLast()
        #expect(quoted.hasPrefix("tnx Az09 "))
    }

    @Test(arguments: HostKeyboardLayoutID.allCases)
    func probeLinesCoverEverySymbolOfTheirTable(id: HostKeyboardLayoutID) {
        let probe = HostKeyboardLayout.layout(id).probeLine
        let missing = HostKeyboardLayout.asciiSymbols.filter { !probe.contains($0) }
        #expect(missing.isEmpty)
        #expect(HostKeyboardLayout.asciiSymbols.count == 32)
        let symbolsInQuotes = probe.dropFirst(3).dropLast().filter { HostKeyboardLayout.asciiSymbols.contains($0) }
        #expect(Set(symbolsInQuotes).count == 31)
        #expect(!symbolsInQuotes.contains("'"))
    }
}
