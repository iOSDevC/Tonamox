import Foundation
import Testing
import TerminalBridgeKit

@Suite struct CaptureWrapperTests {
    private let id = CaptureID("1a2b3c4d")!

    private func wrapped(_ original: String, _ host: HostOS = .macOS) throws -> CaptureLines {
        try CaptureWrapper.wrap(original, host: host, id: id).get()
    }

    private func refusal(_ original: String, _ host: HostOS = .macOS) -> CaptureRefusal? {
        CaptureWrapper.refusal(for: original, host: host)
    }

    static let posixCorpus = [
        "git status", "ls -la | head -20", "FOO=1 make test", "swift build", "echo $(date +%s)",
        "grep -rn \"a;b\" Sources", "sudo ls /var/root", "rm -rf build", "python3 script.py", "cat <<< hola",
        "git commit -am \"arreglo\"", "tail -n 50 app.log", "printf '%s\\n' tnx-clip-ok", "ls | xargs",
        "curl -fsSL https://example.com/x.sh | sh", "find . -name x -delete", "echo ${HOME}",
    ]
    static let windowsCorpus = [
        "Get-ChildItem", "Get-Process | Select-Object -First 5", "dir C:\\Users", "ipconfig /all",
    ]

    static func corpus(_ host: HostOS) -> [String] {
        host == .windows ? windowsCorpus : posixCorpus
    }

    // MARK: ID

    @Test func captureIDAcceptsOnlyEightLowercaseHexDigits() {
        #expect(CaptureID("0123abcd")?.rawValue == "0123abcd")
        let parsed = ["", "0123abc", "0123abcde", "0123ABCD", "0123abcg", "../../x", "0123 abc"].map(CaptureID.init)
        #expect(parsed.allSatisfy { $0 == nil })
    }

    @Test func randomCaptureIDsAreValidAndDiffer() {
        let ids = (0..<64).map { _ in CaptureID.random() }
        #expect(ids.allSatisfy { CaptureID($0.rawValue) != nil })
        #expect(Set(ids).count > 60)
    }

    // MARK: Grammar

    @Test func macOSWrapperMatchesTheDocumentedGrammar() throws {
        let lines = try wrapped("git status")
        #expect(lines.wrapped == "mkdir -p \"$HOME/.tonamox-capture\" && chmod 700 \"$HOME/.tonamox-capture\" && { git status; echo "
            + "\"[estado: $?]\"; } 2>&1 | (umask 077 && tee \"$HOME/.tonamox-capture/c-1a2b3c4d.txt\") && tail -c 8192 "
            + "\"$HOME/.tonamox-capture/c-1a2b3c4d.txt\" | pbcopy")
        #expect(lines.returnsToClipboard)
        #expect(lines.host == .macOS && lines.id == id && lines.original == "git status")
    }

    @Test func linuxWrapperHasNoClipboardStep() throws {
        let lines = try wrapped("swift build", .linux)
        #expect(lines.wrapped == "mkdir -p \"$HOME/.tonamox-capture\" && chmod 700 \"$HOME/.tonamox-capture\" && { swift build; echo "
            + "\"[estado: $?]\"; } 2>&1 | (umask 077 && tee \"$HOME/.tonamox-capture/c-1a2b3c4d.txt\")")
        #expect(!lines.wrapped.contains("pbcopy") && !lines.readBack.contains("pbcopy"))
        #expect(!lines.returnsToClipboard)
    }

    @Test func windowsWrapperUsesTeeObjectInLocalAppData() throws {
        let lines = try wrapped("Get-ChildItem", .windows)
        #expect(lines.wrapped == "Get-ChildItem 2>&1 | Tee-Object -FilePath \"$env:LOCALAPPDATA\\tnx-c-1a2b3c4d.txt\"")
        #expect(!lines.returnsToClipboard)
    }

    @Test func readBackLinesMatchTheDocumentedGrammarPerHost() throws {
        #expect(try wrapped("ls").readBack == "tail -c 8192 \"$HOME/.tonamox-capture/c-1a2b3c4d.txt\" | pbcopy")
        #expect(try wrapped("ls", .linux).readBack == "tail -c 8192 \"$HOME/.tonamox-capture/c-1a2b3c4d.txt\"")
        #expect(try wrapped("dir", .windows).readBack
            == "Get-Content -Tail 200 \"$env:LOCALAPPDATA\\tnx-c-1a2b3c4d.txt\"")
    }

    @Test func cleanupLinesMatchTheDocumentedGrammarPerHost() {
        let posix = "rm -- \"$HOME/.tonamox-capture\"/c-*.txt && rmdir -- \"$HOME/.tonamox-capture\""
        #expect(CaptureWrapper.cleanupLine(host: .macOS) == posix)
        #expect(CaptureWrapper.cleanupLine(host: .linux) == posix)
        #expect(CaptureWrapper.cleanupLine(host: .windows) == "Remove-Item \"$env:LOCALAPPDATA\\tnx-c-*.txt\"")
    }

    @Test(arguments: HostOS.allCases)
    func wrappedLineIsASingleLineThatPassesCommandTextPolicy(host: HostOS) throws {
        for original in Self.corpus(host) {
            let lines = try wrapped(original, host)
            for line in [lines.wrapped, lines.readBack, CaptureWrapper.cleanupLine(host: host)] {
                #expect(CommandTextPolicy.validate(line).isEmpty, "\(line)")
                #expect(!line.contains("\n") && !line.contains("\r"))
            }
        }
    }

    @Test(arguments: HostOS.allCases)
    func wrapperAddsNoRiskyRuleOfItsOwn(host: HostOS) throws {
        for original in Self.corpus(host) {
            let lines = try wrapped(original, host)
            #expect(RiskyCommandRules.evaluate(lines.wrapped) == RiskyCommandRules.evaluate(original), "\(original)")
        }
        #expect(RiskyCommandRules.evaluate(try wrapped("sudo rm -rf build", host).wrapped) == [.sudo, .rmRecursiveForce])
    }

    @Test(arguments: HostOS.allCases)
    func cleanupAndReadBackLinesTriggerNoRiskyRule(host: HostOS) throws {
        #expect(RiskyCommandRules.evaluate(CaptureWrapper.cleanupLine(host: host)).isEmpty)
        #expect(RiskyCommandRules.evaluate(try wrapped("ls", host).readBack).isEmpty)
    }

    @Test(arguments: HostOS.allCases)
    func wrapperCharactersAvoidDeadKeysAndQuotes(host: HostOS) throws {
        let lines = try wrapped("ls", host)
        let added = lines.wrapped.replacingOccurrences(of: "ls", with: "") + lines.readBack
            + CaptureWrapper.cleanupLine(host: host)
        for forbidden: Character in ["~", "^", "`", "'"] {
            #expect(!added.contains(forbidden), "\(forbidden)")
        }
        let addedCharacters = Set(added)
        for layout in HostKeyboardLayout.layouts(for: host) {
            #expect(addedCharacters.isDisjoint(with: layout.deadCharacters), "\(layout.id)")
        }
    }

    @Test func everyWrapperEncodesOnEveryLayout() throws {
        for layout in HostKeyboardLayout.all {
            let original = layout.host == .windows ? "Get-ChildItem" : "ls -la"
            let lines = try wrapped(original, layout.host)
            for line in [lines.wrapped, lines.readBack, CaptureWrapper.cleanupLine(host: layout.host)] {
                let encoded = HIDTextEncoder.encode(line, layout: layout)
                #expect((try? encoded.get()) != nil, "\(layout.id): \(line)")
            }
        }
    }

    // MARK: Privacy of the file

    @Test func filePathContainsOnlyTheCaptureIDAndFixedText() throws {
        #expect(try wrapped("git status").filePath == "$HOME/.tonamox-capture/c-1a2b3c4d.txt")
        #expect(try wrapped("make secret-target").filePath == "$HOME/.tonamox-capture/c-1a2b3c4d.txt")
        #expect(try wrapped("swift build", .linux).filePath == "$HOME/.tonamox-capture/c-1a2b3c4d.txt")
        #expect(try wrapped("dir", .windows).filePath == "$env:LOCALAPPDATA\\tnx-c-1a2b3c4d.txt")
    }

    @Test(arguments: HostOS.allCases)
    func filePathIsUnderHomeNeverTmp(host: HostOS) throws {
        let lines = try wrapped(host == .windows ? "dir" : "ls", host)
        #expect(lines.filePath.hasPrefix("$HOME/") || lines.filePath.hasPrefix("$env:LOCALAPPDATA\\"))
        for shared in ["/tmp", "TMPDIR", "TEMP", "/var/", "Public"] {
            #expect(!lines.wrapped.contains(shared), "\(shared)")
        }
    }

    @Test func directoryIsCreatedThenChmodded700BeforeTheCommandRuns() throws {
        for host in [HostOS.macOS, .linux] {
            let line = try wrapped("git status", host).wrapped
            #expect(line.hasPrefix("mkdir -p \"$HOME/.tonamox-capture\" && chmod 700 \"$HOME/.tonamox-capture\" && { git status;"))
        }
    }

    @Test func teeAloneRunsUnderUmask077() throws {
        let line = try wrapped("git status").wrapped
        #expect(line.components(separatedBy: "umask").count == 2)
        let group = try #require(line.range(of: "{ git status; echo \"[estado: $?]\"; } 2>&1 | "))
        let umask = try #require(line.range(of: "(umask 077 && tee \"$HOME/.tonamox-capture/c-1a2b3c4d.txt\")"))
        #expect(group.upperBound == umask.lowerBound)
    }

    @Test func exitStatusIsRecordedInsideTheGroup() throws {
        #expect(try wrapped("ls -la | head -20").wrapped.contains("{ ls -la | head -20; echo \"[estado: $?]\"; } 2>&1"))
    }

    // MARK: Length

    @Test func maxOriginalBytesPerHostIsPinned() {
        #expect(CaptureWrapper.maxOriginalBytes(host: .macOS) == 280)
        #expect(CaptureWrapper.maxOriginalBytes(host: .linux) == 345)
        #expect(CaptureWrapper.maxOriginalBytes(host: .windows) == 445)
    }

    @Test(arguments: HostOS.allCases)
    func originalAtTheLimitWrapsAndOneByteMoreIsRefused(host: HostOS) throws {
        let limit = CaptureWrapper.maxOriginalBytes(host: host)
        let fitting = "echo " + String(repeating: "a", count: limit - 5)
        let lines = try wrapped(fitting, host)
        #expect(lines.wrapped.utf8.count == CommandTextPolicy.maxBytes)
        #expect(refusal(fitting + "a", host) == .tooLongWhenWrapped(bytes: CommandTextPolicy.maxBytes + 1))
    }

    // MARK: Refusals

    @Test func originalFailingPolicyIsRefusedBeforeWrapping() {
        #expect(refusal("") == .policy([.empty]))
        #expect(refusal(" ls") == .policy([.leadingSpace]))
        #expect(refusal("echo café") == .policy([.disallowedCharacter(scalar: 0xE9, offset: 8)]))
        guard case .failure(.policy) = CaptureWrapper.wrap("ls\nrm x", host: .macOS, id: id) else {
            Issue.record("a newline must be refused by the policy")
            return
        }
    }

    @Test func unbalancedSingleQuoteIsRefused() {
        #expect(refusal("echo 'abc") == .unbalancedQuoting)
        #expect(refusal("echo 'it''s'", .windows) == nil)
    }

    @Test func unbalancedDoubleQuoteIsRefused() {
        #expect(refusal("echo \"abc") == .unbalancedQuoting)
        #expect(refusal("echo \"a\\\"b\"") == nil)
        #expect(refusal("echo $(date") == .unbalancedQuoting)
        #expect(refusal("echo `date") == .unbalancedQuoting)
    }

    @Test func trailingBackslashIsRefused() {
        #expect(refusal("echo abc\\") == .unbalancedQuoting)
        #expect(refusal("echo \"abc\\") == .unbalancedQuoting)
    }

    @Test func quotedHashIsAllowedButUnquotedCommentIsRefused() {
        #expect(refusal("ls # lista") == .comment)
        #expect(refusal("#ls") == .comment)
        #expect(refusal("echo \"#x\"") == nil)
        #expect(refusal("echo '#x'") == nil)
        #expect(refusal("echo a#b") == nil)
        #expect(refusal("echo \\#x") == nil)
        #expect(refusal("Get-ChildItem # x", .windows) == .comment)
    }

    @Test func sequenceAndThenOrElseAndBackgroundAreRefused() {
        #expect(refusal("npm test && npm run lint") == .compound("&&"))
        #expect(refusal("make || echo fallo") == .compound("||"))
        #expect(refusal("ls; pwd") == .compound(";"))
        #expect(refusal("sleep 5 &") == .compound("&"))
        #expect(refusal("ls | grep \"a&&b\"") == nil)
        #expect(refusal("ls |& cat") == nil)
        #expect(refusal("ls |") == .compound("|"))
        #expect(refusal("Get-ChildItem; Get-Date", .windows) == .compound(";"))
        #expect(refusal("& notepad", .windows) == .compound("&"))
        #expect(refusal("icacls --% x", .windows) == .compound("--%"))
    }

    @Test func subshellAndBraceGroupAndKeywordsAreRefused() {
        #expect(refusal("(cd src)") == .compound("("))
        #expect(refusal("{ ls }") == .compound("{"))
        #expect(refusal("echo }") == .compound("}"))
        #expect(refusal("echo \"}\"") == nil)
        #expect(refusal("echo {a,b}") == nil)
        for keyword in ["if", "for", "while", "until", "case", "select", "function", "repeat", "coproc", "[["] {
            #expect(refusal("\(keyword) x") == .compound(keyword), "\(keyword)")
        }
        #expect(refusal("foreach x", .windows) == .compound("foreach"))
    }

    @Test func anyRedirectionIsRefusedButHereStringIsAllowed() {
        for line in ["ls > out.txt", "ls 2>/dev/null", "cat < x", "cat <<EOF", "ls &> x", "ls >| x", "ls 2>&1"] {
            #expect(refusal(line) == .redirection, "\(line)")
        }
        #expect(refusal("cat <<< hola") == nil)
        #expect(refusal("Get-ChildItem 2>$null", .windows) == .redirection)
        #expect(refusal("Get-ChildItem > out.txt", .windows) == .redirection)
    }

    static let stateCommands = [
        "cd", "pushd", "popd", "dirs", "export", "unset", "source", ".", "alias", "unalias", "set", "setopt",
        "unsetopt", "shopt", "eval", "exec", "typeset", "declare", "local", "readonly", "integer", "float",
        "autoload", "unfunction", "functions", "bindkey", "zle", "hash", "rehash", "umask", "ulimit", "limit",
        "unlimit", "trap", "shift", "fc", "history", "fg", "bg", "jobs", "wait", "disown", "exit", "logout",
        "return", "read", "getopts", "let", "zmodload", "emulate", "enable", "disable", "compdef", "compinit",
        "nvm", "conda", "mamba", "micromamba", "deactivate", "workon", "activate", "z", "zi", "j", "autojump",
        "chruby", "rvm", "sdk", "direnv",
    ]

    @Test(arguments: stateCommands)
    func everyStateChangingBuiltinIsRefused(name: String) {
        #expect(refusal("\(name) foo") == .changesShellState(name))
        #expect(refusal("\(name.uppercased()) foo") == .changesShellState(name))
    }

    @Test func stateChangeBehindWrappersIsRefused() {
        #expect(refusal("sudo cd /var/root") == .changesShellState("cd"))
        #expect(refusal("builtin cd src") == .changesShellState("cd"))
        #expect(refusal("command export FOO=1") == .changesShellState("export"))
        #expect(refusal("env FOO=1 source x") == .changesShellState("source"))
        #expect(refusal("exec ls") == .changesShellState("exec"))
    }

    @Test func stateChangeInsideCommandSubstitutionIsRefused() {
        #expect(refusal("echo $(cd /tmp)") == .changesShellState("cd"))
        #expect(refusal("ls \"$(pwd)\"") == nil)
    }

    @Test func bareAssignmentIsRefusedButAssignmentPrefixIsAllowed() {
        #expect(refusal("FOO=1") == .changesShellState("FOO="))
        #expect(refusal("A=1 B=2") == .changesShellState("A="))
        #expect(refusal("FOO=1 make test") == nil)
    }

    @Test func appendAndIndexedAssignmentsAreRefused() {
        #expect(refusal("A+=1") == .changesShellState("A="))
        #expect(refusal("arr[1]=x") == .changesShellState("arr="))
        #expect(refusal("arr[1]+=x B=2") == .changesShellState("arr="))
        #expect(refusal("FOO+=1 make test") == nil)
    }

    @Test(arguments: ["mapfile", "readarray", "vared", "zstyle", "complete", "compctl", "compopt", "bind", "take",
                      "newgrp", "suspend"])
    func moreStateChangingCommandsAreRefused(name: String) {
        #expect(refusal("\(name) foo") == .changesShellState(name))
    }

    @Test func printfAndPrintThatSetVariablesOrTheEditBufferAreRefused() {
        #expect(refusal("printf -v A %s 9") == .changesShellState("printf -v"))
        #expect(refusal("print -z ls") == .changesShellState("print -v/-z/-s"))
        #expect(refusal("print -rs hola") == .changesShellState("print -v/-z/-s"))
        #expect(refusal("printf '%s\\n' hola") == nil)
        #expect(refusal("print -r hola") == nil)
    }

    @Test(arguments: ["-", "..", "...", "~", "~/src/", "/", "1", "42"])
    func loneWordThatChangesTheFolderIsRefused(word: String) {
        #expect(refusal(word) == .changesShellState(word))
    }

    @Test func loneWordsThatRunProgramsAreStillWrapped() {
        #expect(refusal("ls") == nil)
        #expect(refusal("./build.sh") == nil)
        #expect(refusal("ls src/") == nil)
    }

    @Test func specialParametersTheWrapperReplacesAreRefused() {
        #expect(refusal("echo $_") == .specialParameter("$_"))
        #expect(refusal("rm -r \"$_\"") == .specialParameter("$_"))
        #expect(refusal("echo $?") == .specialParameter("$?"))
        #expect(refusal("echo ${?}") == .specialParameter("${?}"))
        #expect(refusal("echo ${_}") == .specialParameter("${_}"))
        #expect(refusal("kill $!") == .specialParameter("$!"))
        #expect(refusal("echo '$_ $?'") == nil)
        #expect(refusal("echo \\$?") == nil)
        #expect(refusal("echo $_x ${_x}") == nil)
        #expect(refusal("Get-Process | Where-Object { $_.CPU -gt 1 }", .windows) == nil)
    }

    @Test func clipboardWritersAreRefusedOnlyOnMacOS() {
        #expect(refusal("echo x | pbcopy") == .writesClipboard("pbcopy"))
        #expect(refusal("sudo /usr/bin/pbcopy") == .writesClipboard("pbcopy"))
        #expect(refusal("echo x | xclip") == .writesClipboard("xclip"))
        #expect(refusal("pbpaste | wc -c") == nil)
        #expect(refusal("echo x | xclip", .linux) == nil)
    }

    @Test func unclosedParameterAndArithmeticExpansionsAreRefused() {
        #expect(refusal("echo ${HOME") == .unbalancedQuoting)
        #expect(refusal("echo \"${HOME\"") == .unbalancedQuoting)
        #expect(refusal("echo $[1+") == .unbalancedQuoting)
        #expect(refusal("echo ${HOME} \"${USER}\" $[1+2] $[a[1]+1]") == nil)
    }

    @Test func versionManagerShellSubcommandsAreRefused() {
        for manager in ["pyenv", "rbenv", "nodenv", "jenv", "goenv", "asdf", "mise", "rtx"] {
            #expect(refusal("\(manager) shell 3.12") == .changesShellState(manager))
            #expect(refusal("\(manager) activate venv") == .changesShellState(manager))
            #expect(refusal("\(manager) versions") == nil)
        }
    }

    @Test func killWithJobSpecIsRefused() {
        #expect(refusal("kill %1") == .changesShellState("kill"))
        #expect(refusal("kill 1234") == nil)
    }

    static let interactiveCommands = [
        "vi", "vim", "nvim", "view", "vimdiff", "nano", "pico", "emacs", "less", "more", "most", "man", "info",
        "top", "htop", "btop", "atop", "ssh", "mosh", "telnet", "ftp", "sftp", "screen", "tmux", "su", "passwd",
        "visudo", "vipw", "sudoedit",
    ]

    @Test(arguments: interactiveCommands)
    func interactiveProgramsAreRefused(name: String) {
        #expect(refusal("\(name) foo") == .interactive(name))
    }

    @Test func sudoEditAndCrontabEditAreRefused() {
        #expect(refusal("sudo -e /etc/hosts") == .interactive("sudo -e"))
        #expect(refusal("sudo -u root --edit x") == .interactive("sudo -e"))
        #expect(refusal("crontab -e") == .interactive("crontab -e"))
        #expect(refusal("crontab -l") == nil)
        #expect(refusal("sudo grep -e x f") == nil)
    }

    @Test func replsWithoutOperandAreRefusedButScriptsAreAllowed() {
        for repl in ["python", "python3", "node", "irb", "ruby", "ghci", "lua", "redis-cli", "sh", "bash", "zsh",
                     "dash", "ksh", "fish", "csh", "tcsh", "pwsh"] {
            #expect(refusal(repl) == .interactive(repl), "\(repl)")
            #expect(refusal("\(repl) script.x") == nil, "\(repl)")
        }
        #expect(refusal("python3 -c \"print(1)\"") == nil)
        #expect(refusal("echo 1+1 | bc") == nil)
        #expect(refusal("bc <<< 1+1") == nil)
        #expect(refusal("bc") == .interactive("bc"))
        #expect(refusal("bc file.bc") == .interactive("bc"))
        #expect(refusal("psql mydb") == .interactive("psql"))
        #expect(refusal("psql -c \"select 1\" mydb") == nil)
        #expect(refusal("mysql -e \"select 1\"") == nil)
        #expect(refusal("sqlite3 db.sqlite") == .interactive("sqlite3"))
        #expect(refusal("sqlite3 db.sqlite \"select 1\"") == nil)
        #expect(refusal("sudo python3") == .interactive("python3"))
    }

    @Test func gitCommitWithoutMessageAndInteractiveGitAreRefused() {
        #expect(refusal("git commit") == .interactive("git commit"))
        #expect(refusal("git commit --amend") == .interactive("git commit"))
        #expect(refusal("git commit -m \"x\"") == nil)
        #expect(refusal("git commit -am \"x\"") == nil)
        #expect(refusal("git commit --message=x") == nil)
        #expect(refusal("git commit --amend --no-edit") == nil)
        #expect(refusal("git commit -F msg.txt") == nil)
        #expect(refusal("git rebase -i HEAD~3") == .interactive("git rebase -i"))
        #expect(refusal("git rebase main") == nil)
        #expect(refusal("git add -p") == .interactive("git add -p"))
        #expect(refusal("git add --interactive") == .interactive("git add -p"))
        #expect(refusal("git -C repo add .") == nil)
    }

    @Test func followingCommandsAreRefused() {
        #expect(refusal("tail -f app.log") == .follows("tail"))
        #expect(refusal("tail -F app.log") == .follows("tail"))
        #expect(refusal("tail --follow app.log") == .follows("tail"))
        #expect(refusal("tail -n 20 app.log") == nil)
        #expect(refusal("journalctl -f") == .follows("journalctl"))
        #expect(refusal("watch ls") == .follows("watch"))
        #expect(refusal("log stream") == .follows("log stream"))
        #expect(refusal("docker logs -f web") == .follows("docker logs"))
        #expect(refusal("kubectl logs --follow web") == .follows("kubectl logs"))
        #expect(refusal("docker logs web") == nil)
        #expect(refusal("ping example.com") == .follows("ping"))
        #expect(refusal("ping -c 3 example.com") == nil)
        #expect(refusal("yes") == .follows("yes"))
        #expect(refusal("Get-Content app.log -Wait", .windows) == .follows("get-content"))
        #expect(refusal("ping example.com", .windows) == nil)
    }

    @Test func wrapperWithoutCommandIsRefused() {
        for line in ["sudo", "sudo -i", "sudo -s", "sudo -u root"] {
            #expect(refusal(line) == .missingWrappedCommand("sudo"), "\(line)")
        }
        #expect(refusal("env") == .missingWrappedCommand("env"))
        #expect(refusal("nohup") == .missingWrappedCommand("nohup"))
        #expect(refusal("time") == .missingWrappedCommand("time"))
        #expect(refusal("sudo -i ls") == nil)
        #expect(refusal("ls | xargs") == nil)
    }

    @Test func windowsBacktickAndPowerShellStateCommandsAreRefused() {
        #expect(refusal("Write-Output `n", .windows) == .backtick)
        #expect(refusal("Set-Location C:\\src", .windows) == .changesShellState("set-location"))
        #expect(refusal("cd C:\\src", .windows) == .changesShellState("cd"))
        #expect(refusal("$x = 1", .windows) == .changesShellState("$x"))
        #expect(refusal("$env:FOO = \"1\"", .windows) == .changesShellState("$env:FOO"))
        #expect(refusal(". .\\profile.ps1", .windows) == .changesShellState("."))
        #expect(refusal("Import-Module Az", .windows) == .changesShellState("import-module"))
        #expect(refusal("pwsh", .windows) == .interactive("pwsh"))
        #expect(refusal("Get-Process | Where-Object { $_.CPU -gt 1 }", .windows) == nil)
    }

    @Test func refusalMessagesAreSpanishAndNonEmpty() {
        let sendable: [CaptureRefusal] = [
            .comment, .compound("&&"), .redirection, .changesShellState("cd"), .interactive("vim"),
            .follows("tail"), .missingWrappedCommand("sudo"), .backtick, .tooLongWhenWrapped(bytes: 600),
            .specialParameter("$_"), .writesClipboard("pbcopy"),
        ]
        for refusal in sendable {
            #expect(refusal.message.hasSuffix("Se puede enviar sin capturar."), "\(refusal)")
        }
        for refusal in [CaptureRefusal.policy([.empty]), .unbalancedQuoting] {
            #expect(!refusal.message.isEmpty && !refusal.message.hasSuffix("Se puede enviar sin capturar."))
        }
        #expect(CaptureRefusal.changesShellState("cd").message.contains("«cd»"))
        #expect(CaptureRefusal.tooLongWhenWrapped(bytes: 600).message.contains("600 bytes"))
    }
}
