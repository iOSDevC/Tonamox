#if os(macOS)
import Foundation
import Testing
@testable import TerminalBridgeHelper
import TerminalBridgeKit

@Suite struct ScreenInjectorTests {
    @Test func stuffsTheExactArgvWithoutEnter() async throws {
        let scratch = TemporaryDirectory()
        defer { scratch.remove() }
        let runner = FakeProcessRunner()
        let injector = try makeInjector(runner, scratch: scratch)

        let outcome = await injector.type("printf 'a^Mb\\033c' \"$HOME\"")

        #expect(outcome == .typed(verified: true))
        #expect(runner.stuffInvocations == [["-S", "53730.tnx-h1", "-p", "0", "-X", "stuff", "printf 'a^Mb\\033c' \"$HOME\""]])
        let typed = try #require(runner.stuffInvocations.first?.last)
        #expect(!typed.utf8.contains(0x0A))
        #expect(!typed.utf8.contains(0x0D))
        let stuff = try #require(runner.invocations.first { $0.arguments.contains("stuff") })
        #expect(stuff.executable == "/usr/bin/screen")
    }

    @Test func checksRunInOrderBeforeTheStuff() async throws {
        let scratch = TemporaryDirectory()
        defer { scratch.remove() }
        let runner = FakeProcessRunner()
        _ = try await makeInjector(runner, scratch: scratch).type("true")
        let steps = runner.invocations.map { invocation -> String in
            let arguments = invocation.arguments
            guard arguments.count > 5 else { return arguments.first ?? "" }
            return arguments[5] == "hardcopy" ? "hardcopy -p \(arguments[3])" : arguments[5]
        }
        let otherWindows = (1...39).map { "hardcopy -p \($0)" }
        #expect(Array(steps.prefix(43)) == ["-ls"] + otherWindows + ["-A", "hardcopy -p 0", "stuff"])
        #expect(runner.invocations[40].executable == "/bin/ps")
        #expect(runner.invocations[40].arguments == ProcessTable.psArguments)
    }

    @Test func statusPollsSkipTheOtherWindowProbe() async throws {
        let scratch = TemporaryDirectory()
        defer { scratch.remove() }
        let runner = FakeProcessRunner()
        #expect(try await makeInjector(runner, scratch: scratch).currentTarget().state == .ready)
        #expect(runner.hardcopyPaths.count == 1)
    }

    @Test func aWindowWithoutAProcessIsStillAnotherWindow() async throws {
        let scratch = TemporaryDirectory()
        defer { scratch.remove() }
        var script = FakeProcessRunner.Script()
        script.windows = ["0", "17"]
        #expect(try await makeInjector(FakeProcessRunner(script), scratch: scratch).currentTarget().state == .ready)
        let writer = FakeProcessRunner(script)
        guard case .refused(.multipleWindows, let detail) = try await makeInjector(writer, scratch: scratch).type("true") else {
            Issue.record("a second window number must be refused even without a process")
            return
        }
        #expect(detail.contains("ventana 17"))
        #expect(writer.stuffInvocations.isEmpty)
        #expect(!writer.invocations.contains { $0.executable == ProcessTable.psPath })
    }

    @Test func hardcopiesUseFresh0600FilesInTheScratchDirAndAreDeleted() async throws {
        let scratch = TemporaryDirectory()
        defer { scratch.remove() }
        let runner = FakeProcessRunner()
        _ = try await makeInjector(runner, scratch: scratch).type("true")
        let paths = runner.hardcopyPaths
        #expect(paths.count >= 41)
        #expect(Set(paths).count == paths.count)
        #expect(paths.allSatisfy { $0.hasPrefix(scratch.path + "/hc-") })
        #expect(scratch.path.contains(" "))
        #expect(runner.hardcopyModes.allSatisfy { $0 == 0o600 })
        #expect(scratch.contents().isEmpty)
    }

    @Test func emptyHardcopyMeansTheWindowIsMissing() async throws {
        let scratch = TemporaryDirectory()
        defer { scratch.remove() }
        var script = FakeProcessRunner.Script()
        script.screen = nil
        let runner = FakeProcessRunner(script)
        let injector = try makeInjector(runner, scratch: scratch, window: "7")

        let outcome = await injector.type("true")

        guard case .refused(.windowMissing, _) = outcome else {
            Issue.record("expected windowMissing, got \(outcome)")
            return
        }
        #expect(runner.stuffInvocations.isEmpty)
        #expect(runner.invocations.contains { $0.arguments.prefix(6) == ["-S", "53730.tnx-h1", "-p", "7", "-X", "hardcopy"] })
        #expect(await injector.currentTarget().state == .windowMissing)
    }

    @Test func yesNoQuestionIsNotAnIdlePrompt() async throws {
        let scratch = TemporaryDirectory()
        defer { scratch.remove() }
        var script = FakeProcessRunner.Script()
        script.screen = ScreenFixtures.yesNoScreen
        let runner = FakeProcessRunner(script)
        let injector = try makeInjector(runner, scratch: scratch)

        let inspection = await injector.inspect()
        #expect(inspection.state == .promptNotIdle)
        #expect(inspection.lastLine == "Proceed [yn]?")
        #expect(inspection.promptMatches == false)
        guard case .refused(.promptNotIdle, _) = await injector.type("yarn build") else {
            Issue.record("expected promptNotIdle")
            return
        }
        #expect(runner.stuffInvocations.isEmpty)
    }

    @Test func halfTypedLineIsNotAnIdlePrompt() async throws {
        let scratch = TemporaryDirectory()
        defer { scratch.remove() }
        var script = FakeProcessRunner.Script()
        script.screen = ScreenFixtures.halfTypedScreen
        let runner = FakeProcessRunner(script)
        let inspection = try await makeInjector(runner, scratch: scratch).inspect()
        #expect(inspection.state == .promptNotIdle)
        #expect(inspection.lastLine == "% echo half")
    }

    @Test func customPromptRegexIsHonoured() async throws {
        let scratch = TemporaryDirectory()
        defer { scratch.remove() }
        var script = FakeProcessRunner.Script()
        script.screen = "user@mac ~/src ❯\n\n"
        let runner = FakeProcessRunner(script)
        #expect(try await makeInjector(runner, scratch: scratch).inspect().state == .promptNotIdle)
        #expect(try await makeInjector(runner, scratch: scratch, prompt: "❯ ?$").inspect().state == .ready)
    }

    @Test func catInTheForegroundIsRefused() async throws {
        let scratch = TemporaryDirectory()
        defer { scratch.remove() }
        var script = FakeProcessRunner.Script()
        script.processTable = ScreenFixtures.catInForegroundTable
        let runner = FakeProcessRunner(script)
        let injector = try makeInjector(runner, scratch: scratch)

        let target = await injector.currentTarget()
        #expect(target.state == .foregroundNotShell)
        #expect(target.foreground == "cat")
        guard case .refused(.foregroundNotShell, let detail) = await injector.type("true") else {
            Issue.record("expected foregroundNotShell")
            return
        }
        #expect(detail.contains("'cat'"))
        #expect(runner.stuffInvocations.isEmpty)
    }

    @Test func severalWindowsAreRefused() async throws {
        let scratch = TemporaryDirectory()
        defer { scratch.remove() }
        var script = FakeProcessRunner.Script()
        script.processTable = ScreenFixtures.twoWindowsTable
        let runner = FakeProcessRunner(script)
        let injector = try makeInjector(runner, scratch: scratch)
        guard case .refused(.multipleWindows, _) = await injector.type("true") else {
            Issue.record("expected multipleWindows")
            return
        }
        #expect(runner.stuffInvocations.isEmpty)
    }

    @Test func prefixSiblingIsNotAmbiguousButDuplicatesAre() async throws {
        let scratch = TemporaryDirectory()
        defer { scratch.remove() }
        var script = FakeProcessRunner.Script()
        script.listing = ScreenFixtures.prefixPair
        let runner = FakeProcessRunner(script)
        #expect(try await makeInjector(runner, scratch: scratch).type("true") == .typed(verified: true))
        #expect(runner.stuffInvocations.first?[1] == "53730.tnx-h1")

        var duplicated = FakeProcessRunner.Script()
        duplicated.listing = ScreenFixtures.duplicates
        let twins = FakeProcessRunner(duplicated)
        let inspection = try await makeInjector(twins, scratch: scratch, session: "tnx-dup").inspect()
        #expect(inspection.state == .ambiguousSession)
        #expect(inspection.candidates.count == 2)
        #expect(twins.stuffInvocations.isEmpty)
    }

    @Test func missingSessionTellsHowToOpenIt() async throws {
        let scratch = TemporaryDirectory()
        defer { scratch.remove() }
        var script = FakeProcessRunner.Script()
        script.listing = ScreenFixtures.none
        let runner = FakeProcessRunner(script)
        let inspection = try await makeInjector(runner, scratch: scratch, session: "tonamox").inspect()
        #expect(inspection.state == .sessionMissing)
        #expect(inspection.detail.contains("screen -S tonamox"))
        #expect(runner.invocations.count == 1)
    }

    @Test func controlBytesNeverReachScreenEvenWhenThePolicyIsBypassed() async throws {
        let scratch = TemporaryDirectory()
        defer { scratch.remove() }
        let runner = FakeProcessRunner()
        let injector = try makeInjector(runner, scratch: scratch)
        let hostile = ["ls\r", "ls\n", "a\tb", "\u{1B}[A", "x\u{7F}", "\u{85}x", "echo \u{200B}", "rm -rf ~\u{0}", " ls", "ls ", ""]
        for text in hostile {
            #expect(await injector.deliver(text, to: "53730.tnx-h1") == ScreenInjector.policyRefusal)
            #expect(await injector.type(text) == ScreenInjector.policyRefusal)
        }
        let tooLong = String(repeating: "a", count: BridgeConstants.maxTextBytes + 1)
        #expect(await injector.deliver(tooLong, to: "53730.tnx-h1") == ScreenInjector.policyRefusal)
        #expect(runner.stuffInvocations.isEmpty)
        #expect(await injector.deliver(String(repeating: "a", count: BridgeConstants.maxTextBytes), to: "53730.tnx-h1")
            == .typed(verified: true))
    }

    @Test func screenFailureIsReported() async throws {
        let scratch = TemporaryDirectory()
        defer { scratch.remove() }
        var script = FakeProcessRunner.Script()
        script.stuffStatus = 1
        script.stuffError = "No screen session found.\n"
        let runner = FakeProcessRunner(script)
        let outcome = try await makeInjector(runner, scratch: scratch).type("true")
        guard case .refused(.screenFailed, let detail) = outcome else {
            Issue.record("expected screenFailed, got \(outcome)")
            return
        }
        #expect(detail.contains("No screen session found."))
    }

    @Test func textThatNeverShowsUpIsTypedButUnverified() async throws {
        let scratch = TemporaryDirectory()
        defer { scratch.remove() }
        var script = FakeProcessRunner.Script()
        script.echoesStuff = false
        let runner = FakeProcessRunner(script)
        #expect(try await makeInjector(runner, scratch: scratch).type("printf two") == .typed(verified: false))
        #expect(runner.stuffInvocations.count == 1)
    }

    @Test func verificationJoinsWrappedLines() {
        let wrapped = "% printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nbbb'\n\n"
        let text = "printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaabbb'"
        #expect(ScreenInjector.screen(wrapped, endsWith: ScreenInjector.compacted(text)))
        #expect(!ScreenInjector.screen("% printf other\n", endsWith: ScreenInjector.compacted(text)))
    }

    @Test func idlePromptHelpers() throws {
        #expect(IdlePromptPattern.lastNonEmptyLine(of: "a\n%  \n\n   \n") == "%")
        #expect(IdlePromptPattern.lastNonEmptyLine(of: "\n\n") == nil)
        let pattern = try IdlePromptPattern()
        #expect(pattern.matches("Cristophers-MacBook-Pro%"))
        #expect(pattern.matches("bash-3.2$ "))
        #expect(pattern.matches("root#"))
        #expect(pattern.matches("%"))
        #expect(pattern.matches("user@host ~ %"))
        #expect(!pattern.matches("Proceed [yn]?"))
        #expect(!pattern.matches("Password:"))
        #expect(!pattern.matches("% ls"))
        #expect(throws: IdlePromptPatternError.self) { try IdlePromptPattern("([") }
    }

    @Test(arguments: ["% printf 100%", "% cat $", "% echo #", "$ echo $", "# ls #", "[100%] ~ %"])
    func aLineEndingInAPromptCharacterAfterTypedTextIsNotIdle(_ line: String) throws {
        #expect(!(try IdlePromptPattern()).matches(line))
    }

    @Test func halfTypedLinesEndingInPromptCharactersAreRefused() async throws {
        let scratch = TemporaryDirectory()
        defer { scratch.remove() }
        var script = FakeProcessRunner.Script()
        script.screen = "% printf one\none\n% printf 100%\n\n"
        let runner = FakeProcessRunner(script)
        let injector = try makeInjector(runner, scratch: scratch)
        #expect(await injector.inspect().state == .promptNotIdle)
        guard case .refused(.promptNotIdle, _) = await injector.type("true") else {
            Issue.record("expected promptNotIdle")
            return
        }
        #expect(runner.stuffInvocations.isEmpty)
    }
}
#endif
