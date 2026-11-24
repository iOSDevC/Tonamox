import Foundation
import JavaScriptCore
import Testing
@testable import TonamoxCore
@testable import TonamoxServer

/// The page's `AnswerFormat` block, evaluated alone in JavaScriptCore: no DOM, so it can only build plain objects.
@MainActor
private enum PageFormatter {
    static let begin = "  // BEGIN AnswerFormat."
    static let end = "  // END AnswerFormat"

    static var block: String? {
        let script = PageSource.script
        guard let start = script.range(of: begin), let stop = script.range(of: end, range: start.upperBound..<script.endIndex)
        else { return nil }
        return String(script[start.lowerBound..<stop.upperBound])
    }

    static let context: JSContext? = {
        guard let block, let context = JSContext() else { return nil }
        context.evaluateScript("'use strict';\n" + block + "\nvar format = AnswerFormat;")
        return context.exception == nil ? context : nil
    }()

    static func call(_ name: String, _ argument: String) -> JSValue? {
        context?.objectForKeyedSubscript("format")?.invokeMethod(name, withArguments: [argument])
    }

    static func string(_ name: String, _ argument: String) -> String? {
        call(name, argument)?.toString()
    }

    /// `blocks(display(text))`, as the page renders an answer.
    static func tree(_ text: String) -> Any? {
        guard let shown = string("display", text) else { return nil }
        return call("blocks", shown)?.toObject()
    }
}

/// Every node type in a block tree, and every string it holds.
private func walk(_ value: Any?, types: inout Set<String>, strings: inout [String]) {
    if let list = value as? [Any] {
        list.forEach { walk($0, types: &types, strings: &strings) }
    } else if let object = value as? [String: Any] {
        if let type = object["type"] as? String { types.insert(type) }
        for (key, child) in object where key != "type" {
            if let text = child as? String { strings.append(text) } else { walk(child, types: &types, strings: &strings) }
        }
    }
}

@MainActor
@Suite("Browser page answer formatting")
struct PageAnswerFormatTests {
    @Test func blockEvaluatesWithoutADOM() throws {
        #expect(PageFormatter.block != nil)
        #expect(PageFormatter.context != nil)
        #expect(!(try #require(PageFormatter.block)).contains("document"))
    }

    @Test(arguments: BoxedPageFixture.all)
    func pageAndSDKUnwrapBoxesAlike(_ fixture: BoxedPageFixture) {
        #expect(PageFormatter.string("display", fixture.input) == fixture.display)
        #expect(PageFormatter.string("plain", fixture.input) == fixture.plain)
        #expect(BoxedAnswer.display(fixture.input) == fixture.display)
        #expect(BoxedAnswer.plain(fixture.input) == fixture.plain)
    }

    @Test func fixturesAreShared() {
        #expect(BoxedPageFixture.all.count >= 20)
    }

    @Test func markdownSubsetBecomesPlainBlocks() throws {
        let tree = try #require(PageFormatter.tree("Hola **754** y *x* `c`\n\n- a\n- b\n\n3. tres\n4. cuatro\n\n```bash\nls -la\n```"))
        let blocks = try #require(tree as? [[String: Any]])
        #expect(blocks.map { $0["type"] as? String } == ["paragraph", "list", "list", "code"])
        let lists = blocks.filter { $0["type"] as? String == "list" }
        #expect(lists.map { $0["ordered"] as? Bool } == [false, true])
        #expect(lists.last?["start"] as? Int == 3)
        #expect(blocks.last?["text"] as? String == "ls -la")
        #expect(blocks.last?["language"] as? String == "bash")
        var types = Set<String>()
        var strings: [String] = []
        walk(blocks.first, types: &types, strings: &strings)
        #expect(types == ["paragraph", "text", "strong", "em", "code"])
    }

    @Test func boxedAnswerRendersBold() throws {
        let blocks = try #require(PageFormatter.tree("$\\boxed{754}$") as? [[String: Any]])
        let inlines = try #require(blocks.first?["inlines"] as? [[String: Any]])
        #expect(inlines.first?["type"] as? String == "strong")
        #expect((inlines.first?["children"] as? [[String: Any]])?.first?["text"] as? String == "754")
    }

    @Test func boxTheModelAlreadyMadeBoldShowsNoStrayAsterisks() throws {
        for reply in ["**\\boxed{754}**", "**Respuesta: \\boxed{754}**", "*\\boxed{754}*"] {
            let tree = try #require(PageFormatter.tree(reply))
            var types = Set<String>()
            var strings: [String] = []
            walk(tree, types: &types, strings: &strings)
            #expect(!strings.joined().contains("*"), "\(reply)")
            #expect(strings.joined().contains("754"))
        }
    }

    @Test func boxContentKeepsItsAsterisks() {
        #expect(PageFormatter.string("shownText", "\\boxed{2*3*4} y \\boxed{2**3}") == "2*3*4 y 2**3")
    }

    @Test func copiedTextIsTheShownText() {
        #expect(PageFormatter.string("shownText", "**Respuesta:** \\{a\\} y $\\boxed{754}$") == "Respuesta: {a} y 754")
        #expect(PageFormatter.string("shownText", "Pasos:\n\n1. uno\n2. *dos*\n\n- [guía](https://e.x/g)\n\n```\nls **x**\n```")
                == "Pasos:\n\n1. uno\n2. dos\n\n- guía (https://e.x/g)\n\nls **x**")
    }

    @Test func strayMarkersStayLinear() throws {
        let reply = String(repeating: "a *b _c ", count: 4000)
        let start = ContinuousClock.now
        _ = try #require(PageFormatter.tree(reply))
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func codeKeepsItsBoxesAndMarkup() throws {
        let blocks = try #require(PageFormatter.tree("```\n**\\boxed{7}** <b>\n```") as? [[String: Any]])
        #expect(blocks.count == 1)
        #expect(blocks.first?["text"] as? String == "**\\boxed{7}** <b>")
    }

    /// HTML in an answer is text: there is no node type for it, and the strings keep it verbatim for textContent.
    @Test(arguments: [
        "<script>alert(1)</script>",
        "<img src=x onerror=alert(1)>",
        "[pulsa](javascript:alert(document.cookie))",
        "[x](data:text/html,<script>alert(1)</script>)",
        "&lt;b&gt; &amp; &#60;i&#62;",
        "**<iframe src=//evil>**",
        "<a href=\"https://evil.example\">x</a>",
    ])
    func hostileReplyStaysText(_ reply: String) throws {
        let tree = try #require(PageFormatter.tree(reply))
        var types = Set<String>()
        var strings: [String] = []
        walk(tree, types: &types, strings: &strings)
        #expect(types.isSubset(of: ["paragraph", "list", "code", "text", "strong", "em", "link"]))
        let joined = strings.joined()
        for marker in ["<", "&"] where reply.contains(marker) {
            #expect(joined.contains(marker), "\(marker) was dropped or decoded")
        }
    }

    @Test func linksAreShownAsTextWithTheirAddress() throws {
        let script = PageSource.script
        #expect(script.contains("parent.appendChild(element('span', 'answer-link', shown));"))
        #expect(script.contains("node.label + ' (' + node.url + ')'"))
        #expect(!script.contains("createElement('a')"))
        #expect(!script.contains("element('a'"))
        #expect(!script.contains(".href ="))
        let blocks = try #require(PageFormatter.tree("Mira [la guía](https://example.com/g)") as? [[String: Any]])
        let inlines = try #require(blocks.first?["inlines"] as? [[String: Any]])
        #expect(inlines.last?["type"] as? String == "link")
        #expect(inlines.last?["url"] as? String == "https://example.com/g")
    }

    @Test func answerIsBuiltFromElementsAndTextNodes() {
        let script = PageSource.script
        #expect(script.contains("renderAnswer(target, reply.answer);"))
        #expect(script.contains("AnswerFormat.blocks(AnswerFormat.display(answer))"))
        #expect(script.contains("parent.appendChild(document.createTextNode(node.text));"))
        #expect(!script.contains("target.textContent = reply.answer"))
    }

    @Test func copyButtonCopiesTheShownAnswerOnAnyPage() {
        let script = PageSource.script
        #expect(script.contains("copyText(AnswerFormat.shownText(answer))"))
        #expect(script.contains("if (!answer) return;"))
        #expect(script.contains("addCopyButton(target, reply.answer);"))
        // Off a secure page the clipboard API is missing; the fallback copies a selected text area set through value.
        #expect(script.contains("if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(text);"))
        #expect(script.contains("area.value = text;"))
        #expect(script.contains("document.execCommand('copy')"))
    }

    @Test func streamedAnswerIsDrawnOncePerFrameAndAtTheEnd() {
        let script = PageSource.script
        #expect(script.contains("scheduleAnswer(target, reply);"))
        #expect(script.contains("requestAnimationFrame(function () { flushAnswer(target, reply); });"))
        #expect(script.contains("      await streamChat(model.id, target, reply, controller.signal);\n      flushAnswer(target, reply);"))
        #expect(script.contains("    } finally {\n      flushAnswer(target, reply);"))
    }

    @Test func reasoningAndLengthAreLabelledSelectsSentPerRequestAndKeptInTheTab() {
        let html = PageSource.html
        #expect(html.contains(#"<label for="reason" class="visually-hidden" data-i18n="chat.reason"></label>"#))
        #expect(html.contains(#"<select id="reason" class="compact"></select>"#))
        #expect(html.contains(#"<label for="length" class="visually-hidden" data-i18n="chat.length"></label>"#))
        #expect(html.contains(#"<select id="length" class="compact"></select>"#))
        #expect(!html.contains("checkbox"))
        let script = PageSource.script
        #expect(script.contains("reasoning_effort: state.reason,\n        max_tokens: state.maxTokens,"))
        #expect(!script.contains("chat_template_kwargs"))
        #expect(script.contains("sessionStorage.setItem(REASON_KEY, effort);"))
        #expect(script.contains("sessionStorage.setItem(LENGTH_KEY, String(tokens));"))
        #expect(script.contains("if (saved === 'off') return 'none';"))
        #expect(script.contains("byId('reason').disabled = busy;"))
        #expect(script.contains("byId('length').disabled = busy;"))
        #expect(!script.contains("localStorage"))
    }

    @Test func reasoningLevelsAreEffortsTheServerAccepts() throws {
        let efforts = try Regex(#"\{ effort: '([a-z]+)', key: 'chat\.reason\.([a-z]+)' \}"#)
        let levels = PageSource.script.matches(of: efforts).map { (String($0.output[1].substring!), String($0.output[2].substring!)) }
        #expect(levels.map(\.0) == ["none", "low", "medium", "high"])
        #expect(levels.allSatisfy { $0.0 == $0.1 })
        for (effort, _) in levels where effort != "none" {
            #expect(ChatCompletionDecoder.effortBudgets[effort] != nil, "\(effort) is not a reasoning_effort")
        }
    }

    /// `lengthChoices` evaluated alone in JavaScriptCore with the page's own choices.
    @Test(arguments: [("4096", "512,1024,2048,4096"), ("2000", "512,1024"), ("300", "300"), ("undefined", "512,1024,2048,4096")])
    func lengthChoicesStopAtTheHelloCap(_ cap: String, _ offered: String) throws {
        let script = PageSource.script
        let constant = try #require(script.split(separator: "\n").first { $0.contains("const LENGTH_CHOICES = [") })
        let start = try #require(script.range(of: "  function lengthChoices(limits) {"))
        let end = try #require(script.range(of: "\n  }\n", range: start.upperBound..<script.endIndex))
        let context = try #require(JSContext())
        context.evaluateScript(String(constant) + "\n" + String(script[start.lowerBound..<end.upperBound]))
        let result = context.evaluateScript("lengthChoices({ maxTokensCap: \(cap) }).join(',')")
        #expect(result?.toString() == offered)
        #expect(context.exception == nil)
    }

    @Test func cutReasoningSaysSo() {
        let script = PageSource.script
        #expect(script.contains("event.tonamox && event.tonamox.reasoning && event.tonamox.reasoning.cut === true"))
        #expect(script.contains("plural('chat.reasoning.cut', seconds, { seconds: number(seconds) })"))
        #expect(script.contains("es: 'Razonamiento recortado tras {seconds} segundos',"))
        #expect(script.contains("en: 'Reasoning cut after {seconds} seconds',"))
    }
}

struct BoxedPageFixture: Decodable, Sendable, CustomTestStringConvertible {
    let name: String
    let input: String
    let display: String
    let plain: String

    var testDescription: String { name }

    static let all: [BoxedPageFixture] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SharedFixtures/boxed-answers.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([BoxedPageFixture].self, from: data)) ?? []
    }()
}
