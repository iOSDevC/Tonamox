import Foundation

/// Names one capture file. Nothing in it comes from the command, the user, the host or the time.
public struct CaptureID: Hashable, Sendable {
    /// Exactly 8 lowercase hex digits.
    public let rawValue: String

    public init?(_ rawValue: String) {
        guard RandomHex.isEightLowercaseHex(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    /// 32 bits from `SystemRandomNumberGenerator`.
    public static func random() -> CaptureID {
        CaptureID(validated: RandomHex.eight())
    }

    private init(validated: String) {
        rawValue = validated
    }
}

/// Why a line is not wrapped for capture. The first matching reason is reported.
public enum CaptureRefusal: Error, Hashable, Sendable {
    /// The original fails `CommandTextPolicy`.
    case policy([CommandTextViolation])
    /// An open quote, `$(`, `${`, `$[` or backtick, or a trailing backslash.
    case unbalancedQuoting
    /// An unquoted word starting with `#`.
    case comment
    /// `;`, `&&`, `||`, `&`, a subshell, a brace group, a shell keyword or an empty pipeline stage.
    case compound(String)
    /// Any input or output redirection, heredocs included; here-strings are allowed.
    case redirection
    /// cd, export, source... (lowercased name).
    case changesShellState(String)
    /// vim, less, top, ssh, REPLs without a script...
    case interactive(String)
    /// tail -f, watch, log stream...: never ends, so nothing would be copied.
    case follows(String)
    /// sudo -i, env or nohup with no command after them.
    case missingWrappedCommand(String)
    /// POSIX only: `$_`, `$?` or `$!`, whose value the wrapper's own commands replace.
    case specialParameter(String)
    /// macOS only: pbcopy and other clipboard writers, whose result the final `| pbcopy` would overwrite.
    case writesClipboard(String)
    /// Windows only: the PowerShell escape character.
    case backtick
    /// The wrapped line would exceed `CommandTextPolicy.maxBytes`.
    case tooLongWhenWrapped(bytes: Int)

    static let sendWithoutCapture = " Se puede enviar sin capturar."

    /// Spanish, ends with "Se puede enviar sin capturar." where that is true.
    public var message: String {
        switch self {
        case .policy(let violations):
            "La orden no cumple las reglas de texto: "
                + violations.map(\.message).joined(separator: "; ") + "."
        case .unbalancedQuoting:
            "Tiene comillas, «$(», «${», «$[», un acento grave o una barra invertida sin cerrar: la captura quedaría dentro "
                + "y cambiaría la orden."
        case .comment:
            "Tiene un comentario (#): la captura quedaría comentada." + Self.sendWithoutCapture
        case .compound(let token):
            "Contiene «\(token)»: varias órdenes, un grupo o una estructura del shell no se capturan, porque el "
                + "envoltorio cambiaría su significado." + Self.sendWithoutCapture
        case .redirection:
            "Ya redirige su entrada o su salida: la captura no sabría qué guardar." + Self.sendWithoutCapture
        case .changesShellState(let name):
            "«\(name)» cambia el estado de la sesión (carpeta, variables, alias u opciones). Capturada se "
                + "ejecutaría en un subshell y ese cambio se perdería." + Self.sendWithoutCapture
        case .interactive(let name):
            "«\(name)» es interactivo: necesita el terminal y su salida no se puede guardar." + Self.sendWithoutCapture
        case .follows(let name):
            "«\(name)» no termina por sí solo: nunca se copiaría nada." + Self.sendWithoutCapture
        case .missingWrappedCommand(let name):
            "«\(name)» no lleva una orden detrás: abriría un shell o no habría nada que capturar."
                + Self.sendWithoutCapture
        case .specialParameter(let name):
            "Usa «\(name)»: dentro de la captura se referiría a las órdenes del envoltorio, no a la orden "
                + "anterior." + Self.sendWithoutCapture
        case .writesClipboard(let name):
            "«\(name)» escribe en el portapapeles y la captura lo sobrescribiría con la salida."
                + Self.sendWithoutCapture
        case .backtick:
            "Tiene un acento grave (`), el carácter de escape de PowerShell: la captura podría cambiar de "
                + "significado." + Self.sendWithoutCapture
        case .tooLongWhenWrapped(let bytes):
            "Con la captura ocuparía \(bytes) bytes; el máximo es \(CommandTextPolicy.maxBytes)."
                + Self.sendWithoutCapture
        }
    }
}

/// The lines a capture produces, all single-line printable ASCII.
public struct CaptureLines: Hashable, Sendable {
    public let host: HostOS
    public let id: CaptureID
    public let original: String
    /// The single line to send instead of `original`.
    public let wrapped: String
    /// Re-reads the saved output; on macOS also copies it (`| pbcopy`).
    public let readBack: String
    /// True only for macOS.
    public let returnsToClipboard: Bool
    /// As typed, unexpanded, for the UI: "$HOME/.tonamox-capture/c-1a2b3c4d.txt".
    public let filePath: String
}

/// Wraps one command so its output is saved to a private file (and, on macOS, copied). Pure text generation.
public enum CaptureWrapper {
    /// macOS and Linux. Under `$HOME`, never `/tmp`: a predictable name in a world-writable folder invites a symlink race.
    /// App-specific, because the wrapper chmods it and the cleanup line deletes `c-*.txt` inside it.
    public static let directory = "$HOME/.tonamox-capture"
    public static let windowsFilePrefix = "$env:LOCALAPPDATA\\tnx-c-"
    public static let readBackBytes = 8192
    static let windowsReadBackLines = 200

    public static func refusal(for original: String, host: HostOS) -> CaptureRefusal? {
        if let refusal = CaptureRefusalRules.refusal(for: original, host: host) { return refusal }
        let bytes = wrappedLine(original, host: host, id: placeholderID).utf8.count
        return bytes > CommandTextPolicy.maxBytes ? .tooLongWhenWrapped(bytes: bytes) : nil
    }

    public static func wrap(_ original: String, host: HostOS, id: CaptureID) -> Result<CaptureLines, CaptureRefusal> {
        if let refusal = refusal(for: original, host: host) { return .failure(refusal) }
        return .success(CaptureLines(
            host: host,
            id: id,
            original: original,
            wrapped: wrappedLine(original, host: host, id: id),
            readBack: readBackLine(host: host, id: id),
            returnsToClipboard: host == .macOS,
            filePath: filePath(host: host, id: id)
        ))
    }

    /// Removes every capture file of this scheme; sent by the user at the end of a session.
    public static func cleanupLine(host: HostOS) -> String {
        switch host {
        case .macOS, .linux:
            "rm -- \"\(directory)\"/c-*.txt && rmdir -- \"\(directory)\""
        case .windows:
            "Remove-Item \"\(windowsFilePrefix)*.txt\""
        }
    }

    /// Longest original that still fits: 280 bytes macOS, 345 Linux, 445 Windows (pinned by tests).
    public static func maxOriginalBytes(host: HostOS) -> Int {
        CommandTextPolicy.maxBytes - wrappedLine("", host: host, id: placeholderID).utf8.count
    }

    private static let placeholderID = CaptureID("00000000")!

    static func filePath(host: HostOS, id: CaptureID) -> String {
        switch host {
        case .macOS, .linux: "\(directory)/c-\(id.rawValue).txt"
        case .windows: "\(windowsFilePrefix)\(id.rawValue).txt"
        }
    }

    static func wrappedLine(_ original: String, host: HostOS, id: CaptureID) -> String {
        let file = "\"" + filePath(host: host, id: id) + "\""
        let quotedDirectory = "\"\(directory)\""
        // mkdir -m does not change an existing folder, hence the separate chmod; && fails closed before CMD runs.
        let prepare = "mkdir -p \(quotedDirectory) && chmod 700 \(quotedDirectory) && "
        // The group keeps a pipeline in CMD together under 2>&1 and records CMD's status; only tee gets umask 077.
        let capture = "{ \(original); echo \"[estado: $?]\"; } 2>&1 | (umask 077 && tee \(file))"
        switch host {
        case .macOS:
            return prepare + capture + " && tail -c \(readBackBytes) \(file) | pbcopy"
        case .linux:
            return prepare + capture
        case .windows:
            return "\(original) 2>&1 | Tee-Object -FilePath \(file)"
        }
    }

    static func readBackLine(host: HostOS, id: CaptureID) -> String {
        let file = "\"" + filePath(host: host, id: id) + "\""
        switch host {
        case .macOS: return "tail -c \(readBackBytes) \(file) | pbcopy"
        case .linux: return "tail -c \(readBackBytes) \(file)"
        case .windows: return "Get-Content -Tail \(windowsReadBackLines) \(file)"
        }
    }
}

enum RandomHex {
    static let digits = Set("0123456789abcdef")

    static func eight() -> String {
        var generator = SystemRandomNumberGenerator()
        let hex = String(UInt32.random(in: .min ... .max, using: &generator), radix: 16)
        return String(repeating: "0", count: 8 - hex.count) + hex
    }

    static func isEightLowercaseHex(_ text: String) -> Bool {
        text.count == 8 && text.allSatisfy(digits.contains)
    }
}

// MARK: - Refusal rules

/// Quote-aware scan of one line: which characters sit outside quotes and whether every quote,
/// `$(` and backtick closes. PowerShell mode has no backslash escape and no backtick context.
struct ShellQuoteScan {
    private enum Context: Equatable {
        case top
        case single
        case double
        case substitution(depth: Int)
        /// `${...}`, closed by `}`.
        case parameter
        /// `$[...]`, closed by the matching `]`.
        case arithmetic(depth: Int)
        case backtick
    }

    let characters: [Character]
    private(set) var unquoted: [Bool]
    /// True at each `$` that the shell expands (outside single quotes, not escaped).
    private(set) var expandedDollar: [Bool]
    private(set) var isBalanced = true
    private var contexts: [Context] = [.top]
    private let backslashEscapes: Bool
    private let backtickOpensSubstitution: Bool

    init(_ text: String, posix: Bool) {
        characters = Array(text)
        unquoted = Array(repeating: false, count: characters.count)
        expandedDollar = Array(repeating: false, count: characters.count)
        backslashEscapes = posix
        backtickOpensSubstitution = posix
        run()
    }

    private mutating func run() {
        var index = 0
        while index < characters.count {
            index = step(at: index)
        }
        if contexts != [.top] { isBalanced = false }
    }

    private func next(_ index: Int) -> Character? {
        index + 1 < characters.count ? characters[index + 1] : nil
    }

    /// Returns the index of the next character to read.
    private mutating func step(at index: Int) -> Int {
        let character = characters[index]
        switch contexts.last ?? .top {
        case .single:
            if character == "'" { contexts.removeLast() }
            return index + 1
        case .double:
            return stepDoubleQuoted(character, at: index)
        case .top, .substitution, .parameter, .arithmetic, .backtick:
            return stepUnquoted(character, at: index)
        }
    }

    private mutating func stepDoubleQuoted(_ character: Character, at index: Int) -> Int {
        if backslashEscapes, character == "\\" {
            if next(index) == nil { isBalanced = false }
            return index + 2
        }
        if character == "\"" {
            contexts.removeLast()
        } else if character == "$" {
            expandedDollar[index] = true
            if let opened = openExpansion(at: index) {
                contexts.append(opened)
                return index + 2
            }
        } else if backtickOpensSubstitution, character == "`" {
            contexts.append(.backtick)
        }
        return index + 1
    }

    private mutating func stepUnquoted(_ character: Character, at index: Int) -> Int {
        if backslashEscapes, character == "\\" {
            if next(index) == nil { isBalanced = false }
            return index + 2
        }
        switch character {
        case "'":
            contexts.append(.single)
        case "\"":
            contexts.append(.double)
        case "$":
            unquoted[index] = true
            expandedDollar[index] = true
            guard let opened = openExpansion(at: index) else { return index + 1 }
            unquoted[index + 1] = true
            contexts.append(opened)
            return index + 2
        case "}" where contexts.last == .parameter:
            unquoted[index] = true
            contexts.removeLast()
        case "[":
            unquoted[index] = true
            if case .arithmetic(let depth)? = contexts.last {
                contexts[contexts.count - 1] = .arithmetic(depth: depth + 1)
            }
        case "]":
            unquoted[index] = true
            if case .arithmetic(let depth)? = contexts.last {
                if depth == 0 {
                    contexts.removeLast()
                } else {
                    contexts[contexts.count - 1] = .arithmetic(depth: depth - 1)
                }
            }
        case "`" where backtickOpensSubstitution:
            if contexts.last == .backtick { contexts.removeLast() } else { contexts.append(.backtick) }
        case "(":
            unquoted[index] = true
            if case .substitution(let depth)? = contexts.last {
                contexts[contexts.count - 1] = .substitution(depth: depth + 1)
            }
        case ")":
            unquoted[index] = true
            if case .substitution(let depth)? = contexts.last {
                if depth == 0 {
                    contexts.removeLast()
                } else {
                    contexts[contexts.count - 1] = .substitution(depth: depth - 1)
                }
            }
        default:
            unquoted[index] = true
        }
        return index + 1
    }

    /// `$(`, and on POSIX `${` and `$[`, open a context that must close.
    private func openExpansion(at index: Int) -> Context? {
        switch next(index) {
        case "(": .substitution(depth: 0)
        case "{" where backslashEscapes: .parameter
        case "[" where backslashEscapes: .arithmetic(depth: 0)
        default: nil
        }
    }

    /// The first expanded `$_`, `$?`, `$!` or their braced forms (`$_x` is another variable).
    var firstSpecialParameter: String? {
        for index in characters.indices where expandedDollar[index] {
            let rest = characters[(index + 1)...].prefix(3)
            let braced = rest.count == 3 && rest.first == "{" && rest.last == "}" ? rest.dropFirst().first : nil
            if let braced, "_?!".contains(braced) { return "${\(braced)}" }
            guard let name = rest.first, "_?!".contains(name) else { continue }
            if name == "_", let following = rest.dropFirst().first, following.isLetter || following.isNumber
                || following == "_" {
                continue
            }
            return "$\(name)"
        }
        return nil
    }

    static let wordBoundaries: Set<Character> = [" ", "\t", ";", "&", "|", "(", ")", "<", ">"]

    func isUnquoted(_ index: Int) -> Bool {
        index >= 0 && index < characters.count && unquoted[index]
    }

    /// True when the character at `index` stands alone as a word.
    func isStandaloneWord(_ index: Int) -> Bool {
        let before = index == 0 || (isUnquoted(index - 1) && Self.wordBoundaries.contains(characters[index - 1]))
        let after = index == characters.count - 1
            || (isUnquoted(index + 1) && Self.wordBoundaries.contains(characters[index + 1]))
        return before && after
    }

    var hasComment: Bool {
        characters.indices.contains { index in
            guard characters[index] == "#", unquoted[index] else { return false }
            return index == 0 || (isUnquoted(index - 1) && Self.wordBoundaries.contains(characters[index - 1]))
        }
    }

    /// The first unquoted list operator: `&&`, `||`, `;` or a background `&` (not `>&`, `&>` or `|&`).
    var firstListOperator: String? {
        var index = 0
        while index < characters.count {
            defer { index += 1 }
            guard unquoted[index] else { continue }
            let character = characters[index]
            let following = isUnquoted(index + 1) ? characters[index + 1] : nil
            if character == ";" { return ";" }
            if character == "|", following == "|" { return "||" }
            if character == "|" { index += following == "&" ? 1 : 0 }
            guard character == "&" else { continue }
            if following == "&" { return "&&" }
            let previous = isUnquoted(index - 1) ? characters[index - 1] : nil
            if following == ">" || previous == ">" || previous == "<" { continue }
            return "&"
        }
        return nil
    }

    /// The first unquoted `<` or `>`, for PowerShell where the POSIX lexer is not authoritative.
    var hasUnquotedAngleBracket: Bool {
        characters.indices.contains { unquoted[$0] && (characters[$0] == "<" || characters[$0] == ">") }
    }
}

/// Conservative: when unsure, do not wrap. Checked in plan order; the first match is reported.
enum CaptureRefusalRules {
    static let posixKeywords: Set<String> = [
        "{", "}", "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac",
        "select", "function", "repeat", "coproc", "[[", "]]",
    ]
    static let powerShellKeywords: Set<String> = [
        "foreach", "switch", "try", "catch", "finally", "trap", "param", "begin", "process", "end", "filter",
        "workflow", "class", "enum", "using", "data", "dynamicparam",
    ]
    static let stateCommands: Set<String> = [
        "cd", "pushd", "popd", "dirs", "export", "unset", "source", ".", "alias", "unalias", "set", "setopt",
        "unsetopt", "shopt", "eval", "exec", "typeset", "declare", "local", "readonly", "integer", "float",
        "autoload", "unfunction", "functions", "bindkey", "zle", "hash", "rehash", "umask", "ulimit", "limit",
        "unlimit", "trap", "shift", "fc", "r", "history", "fg", "bg", "jobs", "wait", "disown", "exit", "logout",
        "return", "read", "getopts", "let", "zmodload", "emulate", "enable", "disable", "compdef", "compinit",
        "nvm", "conda", "mamba", "micromamba", "deactivate", "workon", "activate", "z", "zi", "j", "autojump",
        "chruby", "rvm", "sdk", "direnv", "mapfile", "readarray", "vared", "zstyle", "complete", "compctl",
        "compopt", "bind", "take", "newgrp", "suspend",
    ]
    static let versionManagers: Set<String> = ["pyenv", "rbenv", "nodenv", "jenv", "goenv", "asdf", "mise", "rtx"]
    static let versionManagerStateSubcommands: Set<String> = ["shell", "activate", "deactivate"]
    /// Clipboard writers on the Mac; pbcopy alone would do, the rest only appear through ssh or ports.
    static let clipboardWriters: Set<String> = [
        "pbcopy", "xclip", "xsel", "wl-copy", "clip", "clip.exe", "set-clipboard", "scb",
    ]
    static let powerShellStateCommands: Set<String> = [
        "set-location", "sl", "chdir", "push-location", "pop-location", "set-variable", "sv", "new-variable",
        "nv", "remove-variable", "rv", "clear-variable", "clv", "set-alias", "sal", "new-alias", "nal",
        "import-module", "ipmo", "remove-module", "set-item", "si", "set-strictmode", "set-psdebug",
    ]
    static let interactiveCommands: Set<String> = [
        "vi", "vim", "nvim", "view", "vimdiff", "nano", "pico", "emacs", "less", "more", "most", "man", "info",
        "top", "htop", "btop", "atop", "ssh", "mosh", "telnet", "ftp", "sftp", "screen", "tmux", "su", "passwd",
        "visudo", "vipw", "sudoedit",
    ]
    /// Interactive when run with no operand and nothing on standard input.
    static let replCommands: Set<String> = [
        "python", "python3", "node", "irb", "ruby", "ghci", "lua", "redis-cli", "sh", "bash", "zsh", "dash",
        "ksh", "fish", "csh", "tcsh", "pwsh", "powershell", "cmd", "perl", "php",
    ]
    /// Without wrapped command these open a shell or do nothing to capture; xargs alone runs echo.
    static let wrapperWithoutCommandExempt: Set<String> = ["xargs"]
    static let logFollowers: Set<String> = ["docker", "podman", "kubectl", "oc"]

    static func refusal(for original: String, host: HostOS) -> CaptureRefusal? {
        let violations = CommandTextPolicy.validate(original)
        if !violations.isEmpty { return .policy(violations) }
        // A backtick changes PowerShell's quoting, so the scans below would be meaningless.
        if host == .windows, original.contains("`") { return .backtick }
        let scan = ShellQuoteScan(original, posix: host != .windows)
        guard scan.isBalanced else { return .unbalancedQuoting }
        if scan.hasComment { return .comment }
        let tokens = ShellLexer.tokenize(original)
        let commands = ShellCommandParser.commands(in: tokens)
        let context = Context(host: host, scan: scan, tokens: tokens, commands: commands, original: original)
        let checks: [(Context) -> CaptureRefusal?] = [
            compoundRefusal, redirectionRefusal, stateRefusal, specialParameterRefusal, clipboardRefusal,
            interactiveRefusal, followsRefusal, missingRefusal,
        ]
        for check in checks {
            if let refusal = check(context) { return refusal }
        }
        return nil
    }

    struct Context {
        let host: HostOS
        let scan: ShellQuoteScan
        let tokens: [ShellToken]
        let commands: [ShellCommand]
        let original: String

        var isWindows: Bool { host == .windows }

        /// Resolved names (lowercased) and arguments, lowercased on Windows where flags are case-insensitive.
        func resolved(_ command: ShellCommand) -> (names: [String], arguments: [String]) {
            let resolved = ShellCommandParser.resolve(command.words[...])
            let arguments = Array(resolved.arguments)
            return (resolved.names, isWindows ? arguments.map { $0.lowercased() } : arguments)
        }
    }

    // MARK: Compound

    private static func compoundRefusal(_ context: Context) -> CaptureRefusal? {
        if let list = context.scan.firstListOperator { return .compound(list) }
        if context.isWindows, context.original.contains("--%") { return .compound("--%") }
        for token in context.tokens {
            switch token {
            case .symbol(.sequence): return .compound(";")
            case .symbol(.andThen): return .compound("&&")
            case .symbol(.orElse): return .compound("||")
            case .symbol(.groupOpen): return .compound("(")
            case .symbol(.groupClose): return .compound(")")
            default: continue
            }
        }
        if let pipe = emptyPipelineStage(context.tokens) { return .compound(pipe) }
        if let keyword = leadingKeyword(context) { return .compound(keyword) }
        if !context.isWindows, let brace = standaloneBrace(context.scan) { return .compound(brace) }
        return nil
    }

    private static func emptyPipelineStage(_ tokens: [ShellToken]) -> String? {
        for (index, token) in tokens.enumerated() where token == .symbol(.pipe) {
            let previous = index > 0 ? tokens[index - 1] : nil
            let following = index + 1 < tokens.count ? tokens[index + 1] : nil
            guard isStageEnd(previous), isStageStart(following) else { return "|" }
        }
        return nil
    }

    private static func isStageEnd(_ token: ShellToken?) -> Bool {
        switch token {
        case .word?, .symbol(.close)?: true
        default: false
        }
    }

    private static func isStageStart(_ token: ShellToken?) -> Bool {
        switch token {
        case .word?, .symbol(.commandSubstitution)?: true
        default: false
        }
    }

    private static func leadingKeyword(_ context: Context) -> String? {
        for command in context.commands {
            let first = command.words.first { !ShellCommandParser.isAssignment($0) && $0 != "!" }
            guard let first else { continue }
            if posixKeywords.contains(first) { return first }
            if context.isWindows, posixKeywords.contains(first.lowercased())
                || powerShellKeywords.contains(first.lowercased()) {
                return first
            }
        }
        return nil
    }

    /// zsh treats a sole `}` as closing a brace group anywhere on the line, so either brace alone refuses.
    private static func standaloneBrace(_ scan: ShellQuoteScan) -> String? {
        let index = scan.characters.indices.first { index in
            let character = scan.characters[index]
            return (character == "{" || character == "}") && scan.isUnquoted(index) && scan.isStandaloneWord(index)
        }
        return index.map { String(scan.characters[$0]) }
    }

    // MARK: Redirection

    private static func redirectionRefusal(_ context: Context) -> CaptureRefusal? {
        if context.tokens.contains(.symbol(.redirect)) { return .redirection }
        if context.isWindows, context.scan.hasUnquotedAngleBracket { return .redirection }
        return nil
    }

    // MARK: Shell state

    private static func stateRefusal(_ context: Context) -> CaptureRefusal? {
        for command in context.commands {
            if let name = stateChange(in: command, context: context) { return .changesShellState(name) }
        }
        return nil
    }

    private static func stateChange(in command: ShellCommand, context: Context) -> String? {
        guard let first = command.words.first else { return nil }
        if command.words.allSatisfy(isAnyAssignment) {
            return String(first.prefix { $0 != "=" && $0 != "[" && $0 != "+" }) + "="
        }
        if context.isWindows, first.hasPrefix("$") { return first }
        if !context.isWindows, command.words.count == 1, changesDirectoryAlone(first) { return first }
        let (names, arguments) = context.resolved(command)
        if let name = names.first(where: stateCommands.contains) { return name }
        if context.isWindows, let name = names.first(where: powerShellStateCommands.contains) { return name }
        guard let name = names.last else { return nil }
        if versionManagers.contains(name),
           let subcommand = RiskyCommandRules.operands(arguments).first,
           versionManagerStateSubcommands.contains(subcommand) {
            return name
        }
        if name == "kill", arguments.contains(where: { $0.hasPrefix("%") }) { return name }
        if !context.isWindows, name == "printf" || name == "print", setsVariable(name, arguments) {
            return name + " " + (name == "printf" ? "-v" : "-v/-z/-s")
        }
        return nil
    }

    /// `NAME=`, `NAME+=` and `NAME[...]=` (bash and zsh); `ShellCommandParser.isAssignment` only knows the first.
    static func isAnyAssignment(_ word: String) -> Bool {
        var rest = Substring(word)
        guard let first = rest.first, first.isASCII, first.isLetter || first == "_" else { return false }
        rest = rest.drop { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
        if rest.first == "[" {
            guard let close = rest.firstIndex(of: "]") else { return false }
            rest = rest[rest.index(after: close)...]
        }
        if rest.first == "+" { rest = rest.dropFirst() }
        return rest.first == "="
    }

    /// zsh AUTO_CD, oh-my-zsh's `-`, `..`, `...` and digit aliases: a lone word that changes the folder.
    private static func changesDirectoryAlone(_ word: String) -> Bool {
        word == "-" || word == "~" || word.hasSuffix("/") || (word.count >= 2 && word.allSatisfy { $0 == "." })
            || word.allSatisfy(\.isASCII) && word.allSatisfy(\.isNumber)
    }

    /// bash `printf -v VAR`, zsh `print -v VAR`, `print -z` (edit buffer) and `print -s` (history).
    private static func setsVariable(_ name: String, _ arguments: [String]) -> Bool {
        let letters: Set<Character> = name == "printf" ? ["v"] : ["v", "z", "s"]
        for word in arguments {
            guard word.hasPrefix("-"), word != "-", word != "--" else { return false }
            if RiskyCommandRules.isShortOptionCluster(word), word.dropFirst().contains(where: letters.contains) {
                return true
            }
        }
        return false
    }

    // MARK: Special parameters and clipboard

    private static func specialParameterRefusal(_ context: Context) -> CaptureRefusal? {
        guard !context.isWindows, let name = context.scan.firstSpecialParameter else { return nil }
        return .specialParameter(name)
    }

    private static func clipboardRefusal(_ context: Context) -> CaptureRefusal? {
        guard context.host == .macOS else { return nil }
        for command in context.commands {
            if let name = context.resolved(command).names.first(where: clipboardWriters.contains) {
                return .writesClipboard(name)
            }
        }
        return nil
    }

    // MARK: Interactive

    private static func interactiveRefusal(_ context: Context) -> CaptureRefusal? {
        for command in context.commands {
            if let name = interactiveProgram(in: command, context: context) { return .interactive(name) }
        }
        return nil
    }

    private static func interactiveProgram(in command: ShellCommand, context: Context) -> String? {
        let (names, arguments) = context.resolved(command)
        guard let name = names.last else { return nil }
        if interactiveCommands.contains(name) { return name }
        if names.contains("sudo"), sudoEdits(command) { return "sudo -e" }
        let hasInput = command.pipedInput || command.readsHereString
        let operands = RiskyCommandRules.operands(arguments)
        switch name {
        case "crontab":
            return arguments.contains("-e") ? "crontab -e" : nil
        case "git":
            return interactiveGit(arguments)
        case "psql", "mysql":
            let runsGiven = arguments.contains { word in
                ["-c", "-f", "-e", "--command", "--file", "--execute"].contains { word == $0 || word.hasPrefix($0 + "=") }
            }
            return runsGiven || hasInput ? nil : name
        case "sqlite3":
            return operands.count >= 2 || hasInput ? nil : name
        case "bc":
            return hasInput ? nil : name
        case _ where replCommands.contains(name):
            return operands.isEmpty && !hasInput ? name : nil
        default:
            return nil
        }
    }

    /// `sudo -e FILE` / `sudo --edit`: an option of sudo itself, before the command.
    private static func sudoEdits(_ command: ShellCommand) -> Bool {
        guard let sudo = command.words.firstIndex(where: { ShellCommandParser.basename($0).lowercased() == "sudo" })
        else { return false }
        let syntax = ShellCommandParser.sudoSyntax
        var index = sudo + 1
        while index < command.words.count {
            let word = command.words[index]
            guard word.hasPrefix("-"), word != "--" else { return false }
            if word == "--edit" { return true }
            if syntax.valued.contains(word) {
                index += 2
                continue
            }
            if RiskyCommandRules.isShortOptionCluster(word), word.contains("e") { return true }
            index += ShellCommandParser.clusterTakesNextWord(word, letters: syntax.valuedLetters) ? 2 : 1
        }
        return false
    }

    private static func interactiveGit(_ arguments: [String]) -> String? {
        guard let index = gitSubcommandIndex(arguments) else { return nil }
        let subcommand = arguments[index]
        let rest = Array(arguments[(index + 1)...])
        switch subcommand {
        case "commit":
            let givesMessage = rest.contains { word in
                ["--message", "--file", "--reuse-message", "--no-edit"].contains { word == $0 || word.hasPrefix($0 + "=") }
                    || (RiskyCommandRules.isShortOptionCluster(word) && word.contains { "mFC".contains($0) })
            }
            return givesMessage ? nil : "git commit"
        case "rebase":
            return rest.contains { $0 == "-i" || $0 == "--interactive" } ? "git rebase -i" : nil
        case "add", "checkout", "reset", "restore", "stash":
            let patch = rest.contains { $0 == "-p" || $0 == "--patch" }
            let interactive = subcommand == "add" && rest.contains { $0 == "-i" || $0 == "--interactive" }
            return patch || interactive ? "git \(subcommand) -p" : nil
        default:
            return nil
        }
    }

    private static func gitSubcommandIndex(_ arguments: [String]) -> Int? {
        let optionsWithValue: Set<String> = ["-C", "-c", "--git-dir", "--work-tree", "--namespace"]
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            if optionsWithValue.contains(word) {
                index += 2
            } else if word.hasPrefix("-") {
                index += 1
            } else {
                return index
            }
        }
        return nil
    }

    // MARK: Follows

    private static func followsRefusal(_ context: Context) -> CaptureRefusal? {
        for command in context.commands {
            if let name = followingProgram(in: command, context: context) { return .follows(name) }
        }
        return nil
    }

    private static func followingProgram(in command: ShellCommand, context: Context) -> String? {
        let (names, arguments) = context.resolved(command)
        guard let name = names.last else { return nil }
        let operands = RiskyCommandRules.operands(arguments)
        switch name {
        case "watch", "yes":
            return name
        case "tail", "journalctl":
            return arguments.contains(where: isFollowFlag) ? name : nil
        case _ where logFollowers.contains(name):
            let follows = arguments.contains(where: isFollowFlag) || arguments.contains { $0 == "-w" || $0 == "--watch" }
            return follows && (operands.contains("logs") || operands.contains("get")) ? "\(name) \(operands[0])" : nil
        case "log":
            return operands.first == "stream" ? "log stream" : nil
        case "dmesg":
            return arguments.contains { $0 == "-w" || $0 == "-W" || $0 == "--follow" || $0 == "--follow-new" }
                ? name : nil
        case "ping":
            if context.isWindows { return arguments.contains("-t") ? name : nil }
            return arguments.contains { $0 == "-c" || $0.hasPrefix("-c") } ? nil : name
        case "tcpdump":
            return arguments.contains { $0 == "-c" || $0.hasPrefix("-c") } ? nil : name
        case "get-content", "gc", "cat", "type":
            return context.isWindows && arguments.contains("-wait") ? name : nil
        default:
            return nil
        }
    }

    private static func isFollowFlag(_ word: String) -> Bool {
        if word == "--follow" || word.hasPrefix("--follow=") { return true }
        return RiskyCommandRules.isShortOptionCluster(word) && word.contains { $0 == "f" || $0 == "F" }
    }

    // MARK: Missing wrapped command

    private static func missingRefusal(_ context: Context) -> CaptureRefusal? {
        for command in context.commands {
            let resolved = ShellCommandParser.resolve(command.words[...])
            guard let name = resolved.names.last, resolved.arguments.isEmpty else { continue }
            if ShellCommandParser.wrappers[name] != nil, !wrapperWithoutCommandExempt.contains(name) {
                return .missingWrappedCommand(name)
            }
        }
        return nil
    }
}
