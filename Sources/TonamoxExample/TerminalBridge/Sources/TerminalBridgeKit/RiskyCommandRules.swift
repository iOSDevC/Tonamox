import Foundation

/// Raw values are stable wire ids carried in `acknowledgedWarnings`. Misses aliases, functions, "$cmd",
/// base64, `env -S` and ssh remote commands: the real control is the owner reading the line.
public enum RiskyRule: String, CaseIterable, Codable, Sendable {
    case sudo
    case rmRecursiveForce
    case pipeToShell
    case gitForcePush
    case osascript
    case launchctl
    case dd
    case diskutilErase
    case recursiveChmodChown
    case diskDeviceRedirect
    case killall
    case defaultsWrite

    public var id: String { rawValue }

    /// Short chip label.
    public var title: String {
        switch self {
        case .sudo: "sudo"
        case .rmRecursiveForce: "rm -r/-f"
        case .pipeToShell: "Código a un shell"
        case .gitForcePush: "git push forzado"
        case .osascript: "osascript"
        case .launchctl: "launchctl"
        case .dd: "dd"
        case .diskutilErase: "diskutil erase"
        case .recursiveChmodChown: "chmod/chown -R"
        case .diskDeviceRedirect: "> /dev/disk"
        case .killall: "killall"
        case .defaultsWrite: "defaults write"
        }
    }

    /// One sentence for the confirmation dialog.
    public var explanation: String {
        switch self {
        case .sudo: "Se ejecuta como administrador."
        case .rmRecursiveForce: "Borra de forma recursiva o sin pedir confirmación."
        case .pipeToShell: "Pasa texto, por ejemplo descargado con curl, a un shell que lo ejecuta."
        case .gitForcePush: "Reescribe la historia de la rama remota."
        case .osascript: "Ejecuta AppleScript, que puede controlar otras apps."
        case .launchctl: "Modifica servicios de launchd."
        case .dd: "Copia bloques en bruto y puede sobrescribir discos."
        case .diskutilErase: "Borra un disco o un volumen."
        case .recursiveChmodChown: "Cambia permisos o dueño de forma recursiva."
        case .diskDeviceRedirect: "Escribe directamente en un dispositivo de disco."
        case .killall: "Termina procesos por nombre."
        case .defaultsWrite: "Cambia preferencias del sistema o de apps."
        }
    }
}

public enum RiskyCommandRules {
    /// Matched rules in declaration order, without duplicates.
    public static func evaluate(_ text: String) -> [RiskyRule] {
        let found = rules(in: text, depth: 0)
        return RiskyRule.allCases.filter { found.contains($0) }
    }

    /// Rules that match `text` and are not in `acknowledged` (wire ids).
    public static func unacknowledged(in text: String, acknowledged: [String]) -> [RiskyRule] {
        let accepted = Set(acknowledged)
        return evaluate(text).filter { !accepted.contains($0.rawValue) }
    }

    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh", "csh", "tcsh"]
    static let privilegeCommands: Set<String> = ["sudo", "doas", "su"]
    static let ownershipCommands: Set<String> = ["chmod", "chown", "chgrp"]
    static let findActions: Set<String> = ["-exec", "-execdir", "-ok", "-okdir"]
    static let diskutilEraseVerbs: Set<String> = ["secureerase", "zerodisk", "randomdisk"]
    /// `sh -c "sh -c '…'"` nests; deeper scripts are not inspected.
    static let maxNesting = 4
    static let watchSyntax = OptionSyntax(valued: ["-n", "--interval"], valuedLetters: ["n"])
    private static let plainCommand = ShellCommand()

    /// Every rule matched by the simple commands of `text`, including nested scripts.
    static func rules(in text: String, depth: Int) -> Set<RiskyRule> {
        let commands = ShellCommandParser.commands(in: ShellLexer.tokenize(text))
        return commands.reduce(into: Set<RiskyRule>()) { found, command in
            found.formUnion(matches(for: command, depth: depth))
        }
    }

    static func matches(for command: ShellCommand, depth: Int = 0) -> Set<RiskyRule> {
        var found = matches(words: command.words[...], in: command, depth: depth)
        if command.redirectTargets.contains(where: isDiskDevice) { found.insert(.diskDeviceRedirect) }
        return found
    }

    private static func matches(words: ArraySlice<String>, in command: ShellCommand, depth: Int) -> Set<RiskyRule> {
        let resolved = ShellCommandParser.resolve(words)
        guard let name = resolved.names.last else { return [] }
        var found = Set<RiskyRule>()
        if resolved.names.contains(where: privilegeCommands.contains) { found.insert(.sudo) }
        let arguments = Array(resolved.arguments)
        if let rule = rule(named: name, arguments: arguments, command: command) { found.insert(rule) }
        guard depth < maxNesting else { return found }
        if name == "find" { found.formUnion(findMatches(arguments, depth: depth + 1)) }
        for script in nestedScripts(named: name, arguments: arguments, command: command) {
            found.formUnion(rules(in: script, depth: depth + 1))
        }
        return found
    }

    /// Text that `name` runs as shell code: `sh -c`, here-strings fed to a shell, eval and watch.
    static func nestedScripts(named name: String, arguments: [String], command: ShellCommand) -> [String] {
        if shells.contains(name) || name == "su" {
            var scripts = command.hereStrings
            if let script = commandStringOperand(arguments) { scripts.append(script) }
            return scripts
        }
        switch name {
        case "eval":
            return [arguments.joined(separator: " ")]
        case "watch":
            let start = ShellCommandParser.skipOptions(arguments[...], from: 0, syntax: watchSyntax)
            return [arguments[start...].joined(separator: " ")]
        default:
            return []
        }
    }

    /// The SCRIPT of `sh -c SCRIPT`, also for clusters such as `-lc`.
    static func commandStringOperand(_ arguments: [String]) -> String? {
        guard let flag = arguments.firstIndex(where: { isShortOptionCluster($0) && $0.contains("c") }) else {
            return nil
        }
        return arguments[(flag + 1)...].first { !$0.hasPrefix("-") }
    }

    /// `find … -exec CMD {} +` runs CMD on every match, so rm and chmod/chown count as recursive there.
    private static func findMatches(_ arguments: [String], depth: Int) -> Set<RiskyRule> {
        var found = Set<RiskyRule>()
        if arguments.contains("-delete") { found.insert(.rmRecursiveForce) }
        for words in findExecCommands(arguments) {
            found.formUnion(matches(words: words, in: plainCommand, depth: depth))
            guard let executed = ShellCommandParser.resolve(words).names.last else { continue }
            if executed == "rm" { found.insert(.rmRecursiveForce) }
            if ownershipCommands.contains(executed) { found.insert(.recursiveChmodChown) }
        }
        return found
    }

    /// The words after each `-exec`/`-execdir`/`-ok`, up to its `;` or `+`.
    static func findExecCommands(_ arguments: [String]) -> [ArraySlice<String>] {
        var commands: [ArraySlice<String>] = []
        var index = 0
        while index < arguments.count {
            guard findActions.contains(arguments[index]) else {
                index += 1
                continue
            }
            let start = index + 1
            let end = arguments[start...].firstIndex { $0 == ";" || $0 == "+" } ?? arguments.endIndex
            commands.append(arguments[start..<end])
            index = end + 1
        }
        return commands
    }

    private static func rule(named name: String, arguments: [String], command: ShellCommand) -> RiskyRule? {
        switch name {
        case "rm":
            return isRecursiveOrForcedRemoval(arguments) ? .rmRecursiveForce : nil
        case _ where shells.contains(name):
            return feedsCodeToShell(arguments, command: command) ? .pipeToShell : nil
        case "source", ".":
            return command.hasProcessSubstitution ? .pipeToShell : nil
        case "eval":
            let runsGeneratedCode = command.hasProcessSubstitution || !command.substitutionPrecedingWords.isEmpty
            return runsGeneratedCode ? .pipeToShell : nil
        case "git":
            return isForcePush(arguments) ? .gitForcePush : nil
        case "osascript":
            return .osascript
        case "launchctl":
            return .launchctl
        case "dd":
            return .dd
        case "diskutil":
            return isDiskutilErase(arguments) ? .diskutilErase : nil
        case _ where ownershipCommands.contains(name):
            return isRecursiveOwnershipChange(arguments) ? .recursiveChmodChown : nil
        case "killall", "pkill":
            return .killall
        case "defaults":
            return operands(arguments).first == "write" ? .defaultsWrite : nil
        case "tee":
            return arguments.contains(where: isDiskDevice) ? .diskDeviceRedirect : nil
        default:
            return nil
        }
    }

    static func isDiskDevice(_ path: String) -> Bool {
        path.hasPrefix("/dev/disk") || path.hasPrefix("/dev/rdisk")
    }

    static func isShortOptionCluster(_ word: String) -> Bool {
        word.count > 1 && word.hasPrefix("-") && !word.hasPrefix("--")
    }

    /// Arguments before a literal `--`.
    static func options(_ arguments: [String]) -> ArraySlice<String> {
        arguments.prefix { $0 != "--" }
    }

    /// Arguments that do not start with `-`.
    static func operands(_ arguments: [String]) -> [String] {
        arguments.filter { !$0.hasPrefix("-") }
    }

    private static func isRecursiveOrForcedRemoval(_ arguments: [String]) -> Bool {
        options(arguments).contains { word in
            if word == "--recursive" || word == "--force" { return true }
            return isShortOptionCluster(word) && word.contains { $0 == "r" || $0 == "R" || $0 == "f" }
        }
    }

    private static func feedsCodeToShell(_ arguments: [String], command: ShellCommand) -> Bool {
        if command.pipedInput || command.hasProcessSubstitution || command.readsHereString { return true }
        // `sh -c "$(curl …)"`: a substitution right after an option cluster that holds `c`.
        return command.substitutionPrecedingWords.contains { word in
            guard let word else { return false }
            return isShortOptionCluster(word) && word.contains("c")
        }
    }

    private static func isForcePush(_ arguments: [String]) -> Bool {
        guard let pushIndex = gitSubcommandIndex(arguments), arguments[pushIndex] == "push" else { return false }
        return arguments[(pushIndex + 1)...].contains { word in
            if word == "--force" || word.hasPrefix("--force-with-lease") || word == "--force-if-includes" {
                return true
            }
            if word.hasPrefix("+") && word.count > 1 { return true }
            return isShortOptionCluster(word) && word.contains("f")
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

    private static func isDiskutilErase(_ arguments: [String]) -> Bool {
        operands(arguments).prefix(2).contains { word in
            let verb = word.lowercased()
            return verb.hasPrefix("erase") || diskutilEraseVerbs.contains(verb)
        }
    }

    private static func isRecursiveOwnershipChange(_ arguments: [String]) -> Bool {
        options(arguments).contains { word in
            word == "--recursive" || (isShortOptionCluster(word) && word.contains("R"))
        }
    }
}

// MARK: - Minimal shell lexer and parser

enum ShellOperator: Equatable, Sendable {
    case sequence
    case andThen
    case orElse
    case pipe
    case redirect
    /// `<<<`: the next word is fed to the command as its standard input.
    case hereString
    case commandSubstitution
    case processSubstitution
    case groupOpen
    case groupClose
    case close
}

enum ShellToken: Equatable, Sendable {
    case word(String)
    case symbol(ShellOperator)
}

/// Splits a line into words and operators. Quotes are honoured enough to keep `;` and `|`
/// inside them literal, while `$(…)` and backticks still open nested commands.
struct ShellLexer {
    private enum Context {
        case doubleQuote
        case backtick
        case substitution(depth: Int)
    }

    private let characters: [Character]
    private var index = 0
    private var word = ""
    private var wordIsQuoted = false
    private var contexts: [Context] = []
    private(set) var tokens: [ShellToken] = []

    init(_ text: String) {
        characters = Array(text)
    }

    static func tokenize(_ text: String) -> [ShellToken] {
        var lexer = ShellLexer(text)
        lexer.run()
        return lexer.tokens
    }

    mutating func run() {
        while index < characters.count {
            if case .doubleQuote? = contexts.last {
                lexDoubleQuoted()
            } else {
                lexUnquoted()
            }
        }
        flushWord()
    }

    private func peek(_ offset: Int) -> Character? {
        let position = index + offset
        return position < characters.count ? characters[position] : nil
    }

    private mutating func emit(_ symbol: ShellOperator) {
        tokens.append(.symbol(symbol))
    }

    private mutating func flushWord() {
        if !word.isEmpty || wordIsQuoted {
            tokens.append(.word(word))
        }
        word.removeAll()
        wordIsQuoted = false
    }

    private mutating func flushNonEmptyWord() {
        if !word.isEmpty { tokens.append(.word(word)) }
        word.removeAll()
        wordIsQuoted = false
    }

    private mutating func lexUnquoted() {
        let character = characters[index]
        switch character {
        case " ", "\t", "\n", "\r":
            flushWord()
            if character == "\n" { emit(.sequence) }
            index += 1
        case "'":
            wordIsQuoted = true
            index += 1
            readSingleQuoted()
        case "\"":
            wordIsQuoted = true
            contexts.append(.doubleQuote)
            index += 1
        case "\\":
            if let next = peek(1) { word.append(next) }
            index += 2
        case "$" where peek(1) == "(":
            flushWord()
            openSubstitution(.commandSubstitution)
            index += 2
        case "`":
            flushWord()
            toggleBacktick()
            index += 1
        case "(":
            flushWord()
            adjustSubstitutionDepth(by: 1)
            emit(.groupOpen)
            index += 1
        case ")":
            flushWord()
            closeParenthesis()
            index += 1
        case ";":
            flushWord()
            emit(.sequence)
            index += peek(1) == ";" ? 2 : 1
        case "&":
            lexAmpersand()
        case "|":
            flushWord()
            if peek(1) == "|" {
                emit(.orElse)
                index += 2
            } else {
                emit(.pipe)
                index += peek(1) == "&" ? 2 : 1
            }
        case ">", "<":
            lexRedirection()
        default:
            word.append(character)
            index += 1
        }
    }

    private mutating func lexDoubleQuoted() {
        let character = characters[index]
        switch character {
        case "\"":
            contexts.removeLast()
            index += 1
        case "\\":
            if let next = peek(1), "\"\\$`".contains(next) {
                word.append(next)
                index += 2
            } else {
                word.append(character)
                index += 1
            }
        case "$" where peek(1) == "(":
            flushNonEmptyWord()
            openSubstitution(.commandSubstitution)
            index += 2
        case "`":
            flushNonEmptyWord()
            emit(.commandSubstitution)
            contexts.append(.backtick)
            index += 1
        default:
            word.append(character)
            index += 1
        }
    }

    private mutating func readSingleQuoted() {
        while index < characters.count, characters[index] != "'" {
            word.append(characters[index])
            index += 1
        }
        index += 1
    }

    private mutating func openSubstitution(_ symbol: ShellOperator) {
        emit(symbol)
        contexts.append(.substitution(depth: 0))
    }

    private mutating func toggleBacktick() {
        if case .backtick? = contexts.last {
            contexts.removeLast()
            emit(.close)
        } else {
            emit(.commandSubstitution)
            contexts.append(.backtick)
        }
    }

    private mutating func adjustSubstitutionDepth(by delta: Int) {
        if case .substitution(let depth)? = contexts.last {
            contexts[contexts.count - 1] = .substitution(depth: depth + delta)
        }
    }

    private mutating func closeParenthesis() {
        if case .substitution(let depth)? = contexts.last {
            if depth == 0 {
                contexts.removeLast()
                emit(.close)
            } else {
                adjustSubstitutionDepth(by: -1)
                emit(.groupClose)
            }
        } else {
            emit(.groupClose)
        }
    }

    private mutating func lexAmpersand() {
        flushWord()
        if peek(1) == "&" {
            emit(.andThen)
            index += 2
        } else if peek(1) == ">" {
            emit(.redirect)
            index += peek(2) == ">" ? 3 : 2
        } else {
            emit(.sequence)
            index += 1
        }
    }

    private mutating func lexRedirection() {
        if peek(1) == "(" {
            flushWord()
            openSubstitution(.processSubstitution)
            index += 2
            return
        }
        // `2>` and friends: a bare number right before the operator is a file descriptor.
        if !wordIsQuoted, !word.isEmpty, word.allSatisfy(\.isNumber) {
            word.removeAll()
        } else {
            flushWord()
        }
        let start = index
        index += 1
        while index < characters.count, ">&|<".contains(characters[index]) {
            index += 1
        }
        emit(characters[start..<index].elementsEqual("<<<") ? .hereString : .redirect)
    }
}

/// One simple command: its words, redirection targets and how it is fed.
struct ShellCommand: Sendable {
    var words: [String] = []
    var redirectTargets: [String] = []
    /// Literal words after `<<<`; a substitution there only sets `readsHereString`.
    var hereStrings: [String] = []
    var pipedInput = false
    var hasProcessSubstitution = false
    var readsHereString = false
    /// For each `$(…)` or backtick inside this command, the word written right before it.
    var substitutionPrecedingWords: [String?] = []
}

/// How a wrapper's options are spelled, so the wrapped command can be found after them.
struct OptionSyntax: Sendable {
    /// Words that take the next word as their value ("-u", "--user", "-arch").
    var valued: Set<String> = []
    /// getopt letters that take a value inside a cluster: "-nu root", "-uroot".
    var valuedLetters: Set<Character> = []
    /// Operands before the wrapped command, such as timeout's DURATION.
    var leadingOperands = 0
}

enum ShellCommandParser {
    static let sudoSyntax = OptionSyntax(
        valued: [
            "-u", "-g", "-h", "-p", "-C", "-U", "-D", "-r", "-t", "-T", "--user", "--group", "--host",
            "--prompt", "--close-from", "--other-user", "--chdir", "--role", "--type", "--command-timeout",
        ],
        valuedLetters: ["u", "g", "h", "p", "C", "U", "D", "r", "t", "T"]
    )
    static let timeoutSyntax = OptionSyntax(
        valued: ["-s", "-k", "--signal", "--kill-after"],
        valuedLetters: ["s", "k"],
        leadingOperands: 1
    )

    /// Wrappers that run the command that follows them. Names are compared lowercased: macOS
    /// resolves `SUDO` to /usr/bin/sudo on its case-insensitive volume.
    static let wrappers: [String: OptionSyntax] = [
        "sudo": sudoSyntax,
        "doas": OptionSyntax(valued: ["-u", "-C"], valuedLetters: ["u", "C"]),
        "command": OptionSyntax(),
        "builtin": OptionSyntax(),
        "exec": OptionSyntax(valued: ["-a"], valuedLetters: ["a"]),
        "nohup": OptionSyntax(),
        "time": OptionSyntax(),
        "nice": OptionSyntax(valued: ["-n"], valuedLetters: ["n"]),
        "env": OptionSyntax(valued: ["-u", "-P", "-S", "--unset"], valuedLetters: ["u", "P", "S"]),
        "xargs": OptionSyntax(
            valued: ["-I", "-J", "-L", "-n", "-P", "-R", "-S", "-s", "-E", "-d"],
            valuedLetters: ["I", "J", "L", "n", "P", "R", "S", "s", "E", "d"]
        ),
        "noglob": OptionSyntax(),
        "nocorrect": OptionSyntax(),
        "caffeinate": OptionSyntax(valued: ["-t", "-w"], valuedLetters: ["t", "w"]),
        // -arm64 and -x86_64 are whole words, not getopt clusters.
        "arch": OptionSyntax(valued: ["-arch", "-e", "-d"]),
        "timeout": timeoutSyntax,
        "gtimeout": timeoutSyntax,
        "script": OptionSyntax(valued: ["-F", "-t", "-T"], valuedLetters: ["F", "t", "T"], leadingOperands: 1),
        "stdbuf": OptionSyntax(valued: ["-i", "-o", "-e"], valuedLetters: ["i", "o", "e"]),
    ]
    static let prefixKeywords: Set<String> = [
        "!", "{", "}", "if", "then", "else", "elif", "do", "while", "until", "fi", "done"
    ]

    static func commands(in tokens: [ShellToken]) -> [ShellCommand] {
        var finished: [ShellCommand] = []
        var outer: [ShellCommand] = []
        var current = makeCommand(pipedInput: false)
        var pendingTarget: ShellOperator?
        for token in tokens {
            switch token {
            case .word(let word):
                switch pendingTarget {
                case .redirect?: current.redirectTargets.append(word)
                case .hereString?: current.hereStrings.append(word)
                default: current.words.append(word)
                }
                pendingTarget = nil
            case .symbol(let symbol):
                pendingTarget = symbol == .redirect || symbol == .hereString ? symbol : nil
                apply(symbol, current: &current, outer: &outer, finished: &finished)
            }
        }
        finished.append(current)
        finished.append(contentsOf: outer)
        return finished.filter { !$0.words.isEmpty || !$0.redirectTargets.isEmpty }
    }

    private static func apply(
        _ symbol: ShellOperator,
        current: inout ShellCommand,
        outer: inout [ShellCommand],
        finished: inout [ShellCommand]
    ) {
        switch symbol {
        case .redirect:
            break
        case .hereString:
            current.readsHereString = true
        case .pipe:
            finished.append(current)
            current = makeCommand(pipedInput: true)
        case .sequence, .andThen, .orElse, .groupOpen, .groupClose:
            finished.append(current)
            current = makeCommand(pipedInput: false)
        case .commandSubstitution:
            current.substitutionPrecedingWords.append(current.words.last)
            outer.append(current)
            current = makeCommand(pipedInput: false)
        case .processSubstitution:
            current.hasProcessSubstitution = true
            outer.append(current)
            current = makeCommand(pipedInput: false)
        case .close:
            finished.append(current)
            current = outer.popLast() ?? makeCommand(pipedInput: false)
        }
    }

    static func makeCommand(pipedInput: Bool) -> ShellCommand {
        var command = ShellCommand()
        command.pipedInput = pipedInput
        return command
    }

    /// Unwraps `sudo`, `env`, `command`… Returns every command name seen (lowercased basenames)
    /// and the arguments of the last one.
    static func resolve(_ words: ArraySlice<String>) -> (names: [String], arguments: ArraySlice<String>) {
        var names: [String] = []
        var index = words.startIndex
        while index < words.endIndex {
            let word = words[index]
            if isAssignment(word) || prefixKeywords.contains(word) {
                index += 1
                continue
            }
            let name = basename(word).lowercased()
            names.append(name)
            index += 1
            guard let syntax = wrappers[name] else {
                return (names, words[index...])
            }
            index = skipOptions(words, from: index, syntax: syntax)
        }
        return (names, [])
    }

    /// Index of the first word after a wrapper's options and leading operands.
    static func skipOptions(_ words: ArraySlice<String>, from start: Int, syntax: OptionSyntax) -> Int {
        var index = start
        while index < words.endIndex {
            let word = words[index]
            if word == "--" {
                index += 1
                break
            }
            if syntax.valued.contains(word) {
                index += 2
                continue
            }
            guard word.hasPrefix("-") || isAssignment(word) else { break }
            index += clusterTakesNextWord(word, letters: syntax.valuedLetters) ? 2 : 1
        }
        return min(words.endIndex, index + syntax.leadingOperands)
    }

    /// getopt: the first value-taking letter of "-xyz" takes the rest of the cluster, or the next word.
    static func clusterTakesNextWord(_ word: String, letters: Set<Character>) -> Bool {
        guard RiskyCommandRules.isShortOptionCluster(word) else { return false }
        let cluster = word.dropFirst()
        guard let position = cluster.firstIndex(where: letters.contains) else { return false }
        return cluster.index(after: position) == cluster.endIndex
    }

    static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals]
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    static func basename(_ word: String) -> String {
        guard let slash = word.lastIndex(of: "/"), word.index(after: slash) < word.endIndex else { return word }
        return String(word[word.index(after: slash)...])
    }
}
