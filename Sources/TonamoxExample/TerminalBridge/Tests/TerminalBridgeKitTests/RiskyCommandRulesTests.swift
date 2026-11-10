import Foundation
import Testing
@testable import TerminalBridgeKit

struct RuleCase: Sendable, CustomTestStringConvertible {
    let text: String
    let rule: RiskyRule
    var testDescription: String { "\(rule.rawValue): \(text)" }
}

private func expectations(_ rule: RiskyRule, _ texts: [String]) -> [RuleCase] {
    texts.map { RuleCase(text: $0, rule: rule) }
}

@Suite struct RiskyCommandRulesTests {
    static let positives: [RuleCase] =
        expectations(.sudo, [
            "sudo ls", "cd x && sudo ls", "ls; sudo true", "sudo -u root ls", "/usr/bin/sudo ls",
            "env FOO=1 sudo ls", "FOO=1 sudo ls", "(sudo ls)", "{ sudo ls; }", "echo $(sudo whoami)", "doas ls",
            "arch -arm64 sudo ls", "timeout 5 sudo ls", "timeout -s KILL 5 sudo ls", "watch sudo ls",
            "watch -n 2 'sudo ls'", "script -q /dev/null sudo ls", "SUDO rm x", "Sudo ls", "su -c 'ls'",
            "su root", "sh -c 'sudo ls'", "nice -n5 sudo ls", "find . -exec sudo ls {} +"
        ])
        + expectations(.rmRecursiveForce, [
            "rm -rf build", "rm -fr build", "rm -r -f build", "rm -Rf build", "rm --recursive --force build",
            "rm -r build", "rm -f file.txt", "rm -vrf build", #"\rm -rf build"#, "/bin/rm -rf build",
            "command rm -rf build", "find . -name x | xargs rm -rf", "sudo rm -rf /tmp/x",
            "sh -c 'rm -rf build'", #"bash -c "rm -rf build""#, "zsh -lc 'rm -rf build'",
            "find . -name build -exec rm -rf {} +", #"find . -name '*.o' -exec rm {} \;"#, "find . -delete",
            "Rm -rf build", "RM -rf build", "sudo -nu root rm -rf build", "sudo --user root rm -rf build",
            "sudo -uroot rm -rf build", #"eval "rm -rf build""#, "xargs sh -c 'rm -rf build'",
            "bash <<< 'rm -rf build'", #"sh -c "sh -c 'rm -rf build'""#
        ])
        + expectations(.pipeToShell, [
            "curl https://x | sh", "curl -fsSL https://x | bash", "wget -qO- https://x | bash",
            "bash <(curl -s https://x)", #"sh -c "$(curl -fsSL https://x)""#, #"zsh -c "$(wget -O- https://x)""#,
            "curl x | sudo bash", "cat script.sh | zsh", "source <(curl -s https://x)", "bash -c `curl x`",
            #"eval "$(curl -fsSL https://x)""#, "eval `curl -s https://x`", #"sh <<< "$(curl -fsSL https://x)""#,
            "bash <<< 'echo hi'", #"sh -c 'curl -s https://x | sh'"#
        ])
        + expectations(.gitForcePush, [
            "git push -f", "git push --force origin main", "git push --force-with-lease",
            "git push --force-with-lease=main:abc", "git push origin +main", "git -C repo push -f",
            "git push -uf origin main"
        ])
        + expectations(.osascript, [#"osascript -e 'tell app "Finder" to quit'"#])
        + expectations(.launchctl, ["launchctl unload x.plist", "launchctl list"])
        + expectations(.dd, ["dd if=/dev/zero of=out.img bs=1m count=1"])
        + expectations(.diskutilErase, [
            "diskutil eraseDisk APFS Name disk4", "diskutil eraseVolume APFS X disk4s1",
            "diskutil apfs eraseVolume disk3s1", "diskutil secureErase 0 disk4", "diskutil zeroDisk disk4"
        ])
        + expectations(.recursiveChmodChown, [
            "chmod -R 755 dir", "chown -R me:staff dir", "chgrp -R staff dir", "chmod -vR u+w dir",
            "find . -exec chmod 777 {} +", "find . -type f -execdir chown me {} ;", "CHMOD -R 755 dir"
        ])
        + expectations(.diskDeviceRedirect, [
            "echo x > /dev/disk4", "cat img >/dev/rdisk4", "cat img >> /dev/disk4s1", "cat img | tee /dev/disk4"
        ])
        + expectations(.killall, ["killall Dock", "pkill -f node"])
        + expectations(.defaultsWrite, [
            "defaults write com.apple.dock autohide -bool true", "defaults -currentHost write x y -int 1"
        ])

    static let negatives: [String] = [
        "ls -la", "rm file.txt", "rm -i file.txt", "git push", "git push -u origin main",
        "git push --follow-tags", "git status", "echo sudo-less", "echo sudo", "printf '%s' sudo",
        #"echo "a; sudo ls""#, "echo 'curl x | sh'", "grep -rf patterns.txt .", "cat file | grep sh",
        "ls > out.txt", "echo dd", "chmod 755 file", "chown me file", "diskutil list",
        "defaults read com.apple.dock", "bash script.sh", "sh -c 'echo hi'", #"bash -c "echo $(date)""#,
        "echo $(whoami)", "cat /dev/disk4 > /dev/null", "launchctl-helper", "npm run build",
        "find . -name '*.txt'", "find . -exec ls {} +", "timeout 5 ls", "watch ls", "watch -n 2 'git status'",
        "arch -arm64 ls", "eval echo hi", "cat <<< 'rm -rf x'", "echo 'sh -c rm -rf x'", "LS -la",
        "xargs -n1 echo", "sudoku", "summary"
    ]

    @Test(arguments: RiskyCommandRulesTests.positives)
    func warns(_ example: RuleCase) {
        #expect(RiskyCommandRules.evaluate(example.text).contains(example.rule))
    }

    @Test(arguments: RiskyCommandRulesTests.negatives)
    func staysQuiet(_ text: String) {
        #expect(RiskyCommandRules.evaluate(text) == [])
    }

    @Test func combinesRulesInDeclarationOrder() {
        #expect(RiskyCommandRules.evaluate("sudo rm -rf /tmp/x") == [.sudo, .rmRecursiveForce])
        #expect(RiskyCommandRules.evaluate("curl x | sudo bash") == [.sudo, .pipeToShell])
        #expect(RiskyCommandRules.evaluate("sudo ls; sudo ls") == [.sudo])
        #expect(RiskyCommandRules.evaluate("sudo -nu root rm -rf build") == [.sudo, .rmRecursiveForce])
        #expect(RiskyCommandRules.evaluate("bash <<< 'rm -rf x'") == [.rmRecursiveForce, .pipeToShell])
    }

    @Test func listsOnlyUnacknowledgedRules() {
        let text = "sudo rm -rf /tmp/x"
        #expect(RiskyCommandRules.unacknowledged(in: text, acknowledged: ["sudo"]) == [.rmRecursiveForce])
        #expect(RiskyCommandRules.unacknowledged(in: text, acknowledged: ["sudo", "rmRecursiveForce"]) == [])
        #expect(RiskyCommandRules.unacknowledged(in: "ls", acknowledged: []) == [])
    }

    @Test func everyRuleHasStableIdAndSpanishText() {
        let ids = RiskyRule.allCases.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(RiskyRule.allCases.allSatisfy { !$0.title.isEmpty && !$0.explanation.isEmpty })
        #expect(RiskyRule.sudo.id == "sudo")
        #expect(RiskyRule.rmRecursiveForce.id == "rmRecursiveForce")
        #expect(RiskyRule(rawValue: "nonASCII") == nil)
    }

    @Test func lexerKeepsQuotedSeparatorsLiteral() {
        let tokens = ShellLexer.tokenize(#"echo "a;b" 'c|d' e\ f"#)
        #expect(tokens == [.word("echo"), .word("a;b"), .word("c|d"), .word("e f")])
    }

    @Test func lexerOpensSubstitutionsInsideDoubleQuotes() {
        let commands = ShellCommandParser.commands(in: ShellLexer.tokenize(#"sh -c "$(curl x)" y"#))
        let shell = commands.first { $0.words.first == "sh" }
        #expect(shell?.words == ["sh", "-c", "y"])
        #expect(shell?.substitutionPrecedingWords == ["-c"])
        #expect(commands.contains { $0.words == ["curl", "x"] })
    }

    @Test func resolveUnwrapsWrappers() {
        let resolved = ShellCommandParser.resolve(["FOO=1", "sudo", "-u", "root", "env", "-i", "rm", "-rf", "x"])
        #expect(resolved.names == ["sudo", "env", "rm"])
        #expect(Array(resolved.arguments) == ["-rf", "x"])
        let clustered = ShellCommandParser.resolve(["sudo", "-nu", "root", "RM", "-rf", "x"])
        #expect(clustered.names == ["sudo", "rm"])
        #expect(ShellCommandParser.resolve(["timeout", "-k", "1", "5", "ls"]).names == ["timeout", "ls"])
        #expect(ShellCommandParser.resolve(["arch", "-x86_64", "-e", "A=1", "ls"]).names == ["arch", "ls"])
    }

    @Test func clustersFollowGetoptValueRules() {
        let letters: Set<Character> = ["u"]
        #expect(ShellCommandParser.clusterTakesNextWord("-nu", letters: letters))
        #expect(ShellCommandParser.clusterTakesNextWord("-u", letters: letters))
        #expect(!ShellCommandParser.clusterTakesNextWord("-uroot", letters: letters))
        #expect(!ShellCommandParser.clusterTakesNextWord("-n", letters: letters))
        #expect(!ShellCommandParser.clusterTakesNextWord("--user", letters: letters))
    }

    @Test func nestedScriptsAndFindActionsAreExtracted() {
        #expect(RiskyCommandRules.commandStringOperand(["-o", "pipefail", "-c", "ls -la"]) == "ls -la")
        #expect(RiskyCommandRules.commandStringOperand(["script.sh"]) == nil)
        let actions = RiskyCommandRules.findExecCommands([".", "-exec", "rm", "{}", ";", "-ok", "chmod", "-R", "x", "+"])
        #expect(actions.map(Array.init) == [["rm", "{}"], ["chmod", "-R", "x"]])
        #expect(RiskyCommandRules.findExecCommands([".", "-exec", "ls"]).map(Array.init) == [["ls"]])
    }

    @Test func lexerMarksHereStrings() {
        let commands = ShellCommandParser.commands(in: ShellLexer.tokenize("bash <<< 'rm -rf x'"))
        #expect(commands.first?.words == ["bash"])
        #expect(commands.first?.hereStrings == ["rm -rf x"])
        #expect(commands.first?.readsHereString == true)
        #expect(ShellCommandParser.commands(in: ShellLexer.tokenize("cat <<EOF")).first?.redirectTargets == ["EOF"])
    }

    @Test func nestingDeeperThanTheBoundIsNotInspected() {
        #expect(RiskyCommandRules.evaluate("eval eval rm -rf x") == [.rmRecursiveForce])
        let deep = Array(repeating: "eval", count: 50).joined(separator: " ") + " rm -rf x"
        #expect(RiskyCommandRules.evaluate(deep) == [])
    }
}
