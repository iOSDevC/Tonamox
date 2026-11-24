import Foundation
import Testing

/// One row of the `STRINGS` table in `app.js`.
private struct PageString {
    let key: String
    let spanish: String
    let english: String
}

private enum PageStrings {
    static let tableStart = "const STRINGS = {\n"
    static let tableEnd = "\n  };\n"
    static let entryPattern = #"^    '([A-Za-z0-9_.]+)': \{\n      es: '((?:[^'\\\n]|\\.)*)',\n      en: '((?:[^'\\\n]|\\.)*)',\n    \},$"#
    static let keyLinePattern = #"^    '[^'\n]*': \{$"#
    static let placeholderPattern = #"\{(\w+)\}"#
    static let keyLiteralPattern = #"'([A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+)'"#
    static let callPattern = #"(?<![\w.])t\('([^']*)'"#
    static let pluralPattern = #"(?<![\w.])plural\('([^']*)'"#
    /// Key arguments of the helpers that take one, so a key without a dot is still checked.
    static let helperPatterns = [#"(?<![\w.])say\('[^']*', '([^']*)'"#, #"(?<![\w.])showPairing\('([^']*)'"#,
                                 #"(?<![\w.])localized\('[^']*', '[^']*', '([^']*)'"#]
    /// Dotted literals in app.js that are not text keys.
    static let storageKeys: Set<String> = ["tonamox.token", "tonamox.lang", "tonamox.reason", "tonamox.length"]
    static let attributePattern = #"data-i18n(?:-[a-z-]+)?="([^"]*)""#

    /// The table block and the script without it.
    static func split(_ script: String) -> (block: String, rest: String)? {
        guard let start = script.range(of: tableStart),
              let end = script.range(of: tableEnd, range: start.upperBound..<script.endIndex) else { return nil }
        let block = String(script[start.upperBound..<end.lowerBound])
        return (block, String(script[..<start.lowerBound]) + String(script[end.upperBound...]))
    }

    static func entries(_ block: String) throws -> [PageString] {
        try groups(entryPattern, in: block, options: [.anchorsMatchLines]).map { row in
            PageString(key: row[0], spanish: row[1], english: row[2])
        }
    }

    static func placeholders(_ text: String) throws -> Set<String> {
        Set(try groups(placeholderPattern, in: text).map { $0[0] })
    }

    static func groups(_ pattern: String, in text: String,
                       options: NSRegularExpression.Options = []) throws -> [[String]] {
        let regex = try NSRegularExpression(pattern: pattern, options: options)
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (1..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }
}

@Suite("Browser page languages")
struct PageLocalizationTests {
    private func table() throws -> (rows: [PageString], block: String, rest: String) {
        let parts = try #require(PageStrings.split(PageSource.script), "app.js has no STRINGS table")
        return (try PageStrings.entries(parts.block), parts.block, parts.rest)
    }

    @Test func everyStringHasSpanishAndEnglish() throws {
        let (rows, block, _) = try table()
        #expect(rows.count >= 100)
        let keyLines = try PageStrings.groups("(" + PageStrings.keyLinePattern + ")", in: block,
                                              options: [.anchorsMatchLines])
        #expect(keyLines.count == rows.count, "an entry in STRINGS does not have the es/en line shape")
        let contentLines = block.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        #expect(contentLines.count == rows.count * 4, "STRINGS holds a line that is not part of an entry")
        #expect(Set(rows.map(\.key)).count == rows.count, "duplicate key in STRINGS")
        for row in rows {
            #expect(!row.spanish.trimmingCharacters(in: .whitespaces).isEmpty, "\(row.key) has no Spanish")
            #expect(!row.english.trimmingCharacters(in: .whitespaces).isEmpty, "\(row.key) has no English")
            #expect(try PageStrings.placeholders(row.spanish) == PageStrings.placeholders(row.english),
                    "\(row.key) has different placeholders in es and en")
        }
    }

    @Test func everyKeyIsDefinedAndUsed() throws {
        let (rows, _, rest) = try table()
        let keys = Set(rows.map(\.key))
        let pluralBases = Set(try PageStrings.groups(PageStrings.pluralPattern, in: rest).map { $0[0] })
        #expect(pluralBases.count >= 3)
        let pluralForms = pluralBases.flatMap { [$0 + ".one", $0 + ".other"] }
        let literals = try PageStrings.groups(PageStrings.keyLiteralPattern, in: rest).map { $0[0] }
            .filter { !PageStrings.storageKeys.contains($0) && !pluralBases.contains($0) }
        let helpers = try PageStrings.helperPatterns.flatMap { try PageStrings.groups($0, in: rest).map { $0[0] } }
        #expect(helpers.count >= 10)
        let calls = try PageStrings.groups(PageStrings.callPattern, in: rest).map { $0[0] } + helpers
        let attributes = try PageStrings.groups(PageStrings.attributePattern, in: PageSource.html).map { $0[0] }
        for key in literals + calls + attributes + pluralForms {
            #expect(keys.contains(key), "\(key) is referenced but not in STRINGS")
        }
        let used = Set(literals + calls + attributes + pluralForms)
        for key in keys.subtracting(used).sorted() {
            Issue.record("\(key) is in STRINGS but never used")
        }
        #expect(calls.count >= 50)
        #expect(attributes.count >= 20)
    }

    /// Static on purpose: the brand (`<h1>`, the pre-script `<title>`), each language's own name on the switch, the
    /// code placeholder, and the bilingual fallback shown when app.js never runs.
    @Test func htmlTextComesFromTheTable() throws {
        let html = PageSource.html
        let body = try #require(html.range(of: "<body>").map { String(html[$0.upperBound...]) })
        let texts = try PageStrings.groups(#">([^<>]*)<"#, in: body).map { $0[0].trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let loading = try #require(try table().rows.first { $0.key == "loading.text" })
        let fallback = ["This page needs JavaScript.", "Esta página necesita JavaScript.", loading.spanish, loading.english]
        #expect(texts.sorted() == (["English", "Español", "Tonamox"] + fallback).sorted())
        #expect(html.contains(#"<span lang="es">\#(loading.spanish)</span>"#))
        #expect(html.contains(#"<span lang="en">\#(loading.english)</span>"#))
        #expect(html.contains(#"<span lang="es">Esta página necesita JavaScript.</span>"#))
        #expect(html.contains("<title>Tonamox</title>"))
        let attributes = try PageStrings.groups(#"\s(placeholder|aria-label|title|alt|value)="([^"]*)""#, in: html)
        #expect(attributes.map { $0[0] + "=" + $0[1] } == ["placeholder=XXXX-XXXX"])
        #expect(PageSource.script.contains("document.title = t('doc.title')"))
        #expect(PageSource.script.contains("document.documentElement.lang = state.lang"))
    }

    @Test func languageSwitchIsAnAccessibleControl() throws {
        let html = PageSource.html
        #expect(html.contains(#"<div id="language" class="language" role="group" data-i18n-aria-label="lang.group">"#))
        let buttons = try PageStrings.groups(
            #"<button type="button" class="secondary" data-lang="(es|en)" lang="(es|en)" aria-pressed="false">([^<]*)</button>"#,
            in: html)
        #expect(buttons.map { $0[0] } == ["es", "en"])
        #expect(buttons.allSatisfy { $0[0] == $0[1] })
        #expect(buttons.map { $0[2] } == ["Español", "English"])
        let script = PageSource.script
        #expect(script.contains("button.setAttribute('aria-pressed', String(button.dataset.lang === state.lang))"))
    }

    /// The rule the page uses: the first browser language that is Spanish or English decides; a choice is kept per
    /// tab only.
    @Test func defaultLanguageFollowsTheBrowserAndStaysInTheTab() {
        let script = PageSource.script
        #expect(script.contains("navigator.languages && navigator.languages.length ? navigator.languages : [navigator.language]"))
        #expect(script.contains("/^(es|en)(-|$)/i.exec(String(preferred[index] || ''))"))
        #expect(script.contains("return 'en';\n  }\n\n  function applyStatic()"))
        #expect(script.contains("sessionStorage.setItem(LANG_KEY, lang)"))
        #expect(!script.contains("localStorage"))
        #expect(!script.contains("document.cookie"))
    }

    @Test func missingTextNeverShowsTheKey() {
        let script = PageSource.script
        #expect(script.contains("if (!entry) return '';"))
        #expect(script.contains("return entry[state.lang] || entry[other] || '';"))
        #expect(script.contains("return value === undefined || value === null ? whole : String(value);"))
    }

    /// Error codes, interface kinds and scopes come from the server; "constructor" must not match Object.prototype.
    @Test func serverValuesAreLookedUpAsOwnKeysOnly() throws {
        let script = PageSource.script
        #expect(script.contains("return Object.prototype.hasOwnProperty.call(map, key) ? map[key] : undefined;"))
        let indexed = try PageStrings.groups(#"\b([A-Z_]*(?:KEYS|STRINGS))\["#, in: script).map { $0[0] }
        #expect(indexed.isEmpty, "plain lookup into \(indexed)")
        for map in ["ERROR_KEYS", "NETWORK_KEYS", "SCOPE_KEYS", "STRINGS", "DEVICE_KEYS", "RETRY_KEYS"] {
            #expect(script.contains("own(\(map), "), "\(map) is not read through own()")
        }
    }

    /// Every code in APIError.swift that the page can receive has page text, so no API message reaches the page.
    @Test func everyServerErrorCodeHasPageText() throws {
        let source = try String(contentsOf: PageSource.directory.deletingLastPathComponent()
                                    .appendingPathComponent("APIError.swift"),
                                encoding: .utf8)
        let codes = Set(try PageStrings.groups(#"code: "([a-z_]+)""#, in: source).map { $0[0] }
            + PageStrings.groups(#"invalidRequest\("([a-z_]+)""#, in: source).map { $0[0] })
        // Ingest tickets are posted by curl to /i/, never by the page.
        let pageCodes = codes.subtracting(["ticket_used", "ticket_in_use", "ticket_expired"])
        #expect(pageCodes.count >= 25)
        for code in pageCodes.sorted() {
            #expect(PageSource.script.contains("    \(code): 'err."), "\(code) has no page text")
        }
    }

    @Test func countsUsePluralRules() throws {
        let (rows, _, _) = try table()
        let keys = Set(rows.map(\.key))
        for key in keys where key.hasSuffix(".one") {
            #expect(keys.contains(String(key.dropLast(4)) + ".other"), "\(key) has no .other form")
        }
        #expect(PageSource.script.contains("PLURAL_RULES[state.lang].select(count) === 'one' ? 'one' : 'other'"))
    }

    @Test func formattersAreBuiltOncePerLanguage() throws {
        let lines = PageSource.script.split(separator: "\n").filter { $0.contains("Intl.") }
        #expect(lines.count == 6)
        #expect(lines.allSatisfy { $0.hasPrefix("    es: new Intl.") || $0.hasPrefix("    en: new Intl.") })
        #expect(!PageSource.script.contains("toLocale"))
    }
}
