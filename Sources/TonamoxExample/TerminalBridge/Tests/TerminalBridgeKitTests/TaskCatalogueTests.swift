import Foundation
import Testing
@testable import TerminalBridgeKit

/// Renders a variant, rendering the task's preview first when the variant is destructive.
func renderCatalogueVariant(
    _ task: CatalogueTask,
    _ variant: CatalogueTaskVariant,
    values: [String: String],
    shell: CatalogueShell = .zsh
) -> Result<RenderedCatalogueLine, CatalogueRenderError> {
    var preview: RenderedCatalogueLine?
    if variant.role == .destructive, let previewVariant = task.variants.first(where: { $0.role == .preview }) {
        switch TaskCatalogueRenderer.render(task, variantID: previewVariant.id, values: values, shell: shell) {
        case .success(let line): preview = line
        case .failure(let error): return .failure(error)
        }
    }
    return TaskCatalogueRenderer.render(task, variantID: variant.id, values: values, shell: shell, preview: preview)
}

func catalogueExampleValues(_ task: CatalogueTask) -> [String: String] {
    Dictionary(uniqueKeysWithValues: task.parameters.map { ($0.id, $0.example) })
}

@Suite struct TaskCatalogueTests {
    static let variants: [(CatalogueTask, CatalogueTaskVariant)] = TaskCatalogue.macOS.flatMap { task in
        task.variants.map { (task, $0) }
    }
    static let macLayouts = HostKeyboardLayout.layouts(for: .macOS)

    @Test func catalogueHasTwentyToThirtyTasksWithUniqueStableIDs() {
        let ids = TaskCatalogue.macOS.map(\.id)
        #expect((20...30).contains(ids.count))
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0.range(of: #"^[a-z]+\.[A-Za-z]+$"#, options: .regularExpression) != nil })
        #expect(Set(TaskCatalogue.macOS.map(\.category)) == Set(CatalogueTaskCategory.allCases))
    }

    @Test(arguments: TaskCatalogue.macOS)
    func everyTaskIsMacOSForZshAndBashWithSpanishOneLineText(task: CatalogueTask) {
        #expect(task.host == .macOS)
        #expect(task.shells == [.zsh, .bash])
        #expect(!task.title.isEmpty && !task.summary.isEmpty)
        #expect(!task.title.contains("\n") && !task.summary.contains("\n"))
        #expect(TaskCatalogue.task(task.id) == task)
    }

    @Test(arguments: TaskCatalogue.macOS)
    func parametersAreDeclaredUsedAndTheirExamplesValidate(task: CatalogueTask) throws {
        let used = Set(task.variants.flatMap(\.parameterIDs))
        #expect(used == Set(task.parameters.map(\.id)))
        #expect(Set(task.parameters.map(\.id)).count == task.parameters.count)
        for definition in task.parameters {
            #expect(try definition.validate(definition.example).get() == definition.example)
        }
    }

    @Test(arguments: TaskCatalogue.macOS)
    func aDestructiveVariantComesAfterAWarningFreePreviewWithTheSameParameters(task: CatalogueTask) {
        let variantIDs = task.variants.map(\.id)
        #expect(Set(variantIDs).count == variantIDs.count)
        guard task.hasDestructiveVariant else {
            #expect(task.variants.allSatisfy { $0.role == .readOnly })
            return
        }
        let previews = task.variants.filter { $0.role == .preview }
        #expect(previews.count == 1)
        #expect(task.variants.first?.role == .preview)
        #expect(previews.allSatisfy { $0.expectedWarnings.isEmpty })
        let previewParameters = Set(previews.flatMap(\.parameterIDs))
        #expect(task.variants.filter { $0.role == .destructive }.allSatisfy {
            Set($0.parameterIDs) == previewParameters
        })
        #expect(task.offeredVariants(previewRendered: false).allSatisfy { $0.role != .destructive })
        #expect(task.offeredVariants(previewRendered: true) == task.variants)
    }

    @Test(arguments: variants)
    func everyVariantRendersAndPassesTheAppGatesAsDeclared(task: CatalogueTask, variant: CatalogueTaskVariant) throws {
        let line = try renderCatalogueVariant(task, variant, values: catalogueExampleValues(task)).get()
        #expect(line.role == variant.role)
        #expect(CommandTextPolicy.validate(line.text).isEmpty)
        #expect(RiskyCommandRules.evaluate(line.text) == variant.expectedWarnings)
        let outgoing = try OutgoingLine.make(
            candidate: line.commandCandidate(), isPossiblyTruncated: false, capture: nil
        ).get()
        #expect(outgoing.text == line.text)
        #expect(outgoing.localWarnings == variant.expectedWarnings.map(\.id))
        #expect(Self.macLayouts.count == 2)
        #expect(Self.macLayouts.allSatisfy { (try? HIDTextEncoder.encode(line.text, layout: $0).get()) != nil })
        let bash = try renderCatalogueVariant(task, variant, values: catalogueExampleValues(task), shell: .bash).get()
        #expect(bash.text == line.text)
    }

    @Test(arguments: variants)
    func everyRenderedLineIsTheDeclaredPipelineOfSimpleCommands(task: CatalogueTask, variant: CatalogueTaskVariant)
        throws {
        let line = try renderCatalogueVariant(task, variant, values: catalogueExampleValues(task)).get()
        let commands = ShellCommandParser.commands(in: ShellLexer.tokenize(line.text))
        #expect(commands.count == variant.stages.count)
        #expect(commands.map { ShellCommandParser.resolve($0.words[...]).names } == variant.programs.map { [$0] })
        #expect(commands.map(\.words.count) == variant.stages.map(\.count))
        #expect(commands.allSatisfy { $0.redirectTargets.isEmpty && $0.substitutionPrecedingWords.isEmpty })
        #expect(commands.dropFirst().allSatisfy { $0.pipedInput })
    }

    static let golden: [(String, String, String)] = [
        ("disk.free", "run", "df -h"),
        ("disk.folderSize", "run", "du -sh ~/Downloads"),
        ("disk.largestEntries", "run", "du -ah ~/Downloads | sort -rh | head -n 10"),
        ("disk.bigFiles", "run", "find ~/Downloads -type f -size +500M"),
        ("network.portListener", "run", "lsof -nP -iTCP:8080 -sTCP:LISTEN"),
        ("network.localAddress", "run", "ipconfig getifaddr en0"),
        ("network.ping", "run", "ping -c 4 example.com"),
        ("network.httpHeaders", "run", "curl -g -I https://example.com"),
        ("processes.find", "run", "pgrep -fl -- Safari"),
        ("processes.terminate", "preview", "pgrep -lx -- Safari"),
        ("processes.terminate", "terminate", "pkill -x -- Safari"),
        ("system.version", "run", "sw_vers"),
        ("system.architecture", "run", "uname -m"),
        ("system.memory", "run", "sysctl -n hw.memsize"),
        ("files.findByName", "run", "find ~/Downloads -type f -name '*.pdf'"),
        ("files.searchText", "run", "grep -rnF -e TODO ~/Downloads"),
        ("files.lineCount", "run", "wc -l notas.txt"),
        ("files.head", "run", "head -n 20 notas.txt"),
        ("files.tail", "run", "tail -n 20 notas.txt"),
        ("files.sizeBytes", "run", "stat -f %z notas.txt"),
        ("files.type", "run", "file notas.txt"),
        ("files.dsStore", "preview", "find ~/Downloads -type f -name .DS_Store -print"),
        ("files.dsStore", "delete", "find ~/Downloads -type f -name .DS_Store -delete"),
        ("git.status", "run", "git status -sb"),
        ("git.log", "run", "git log --oneline -n 10"),
        ("git.diffStat", "run", "git diff --stat"),
        ("git.branches", "run", "git branch -vv"),
        ("brew.installed", "run", "brew list --versions"),
        ("brew.outdated", "run", "brew outdated"),
        ("brew.cleanup", "preview", "brew cleanup -n"),
        ("brew.cleanup", "cleanup", "brew cleanup"),
        ("archives.tar", "run", "tar -tf copia.tar"),
        ("archives.zip", "run", "unzip -l fotos.zip"),
    ]

    @Test func goldenLinesCoverEveryVariant() {
        #expect(Self.golden.count == Self.variants.count)
        #expect(Set(Self.golden.map { $0.0 + "/" + $0.1 }) == Set(Self.variants.map { $0.0.id + "/" + $0.1.id }))
    }

    @Test(arguments: golden)
    func exampleValuesRenderTheGoldenLine(taskID: String, variantID: String, expected: String) throws {
        let task = try #require(TaskCatalogue.task(taskID))
        let variant = try #require(task.variant(variantID))
        #expect(try renderCatalogueVariant(task, variant, values: catalogueExampleValues(task)).get().text == expected)
    }

    @Test func quotingIsBareOnlyForInertWordsAndEscapesSingleQuotes() {
        #expect(TaskCatalogueRenderer.quote("notas.txt") == "notas.txt")
        #expect(TaskCatalogueRenderer.quote("a-b_c/d:e@f+g,h") == "a-b_c/d:e@f+g,h")
        #expect(TaskCatalogueRenderer.quote("") == "''")
        #expect(TaskCatalogueRenderer.quote("it's") == #"'it'\''s'"#)
        #expect(TaskCatalogueRenderer.quote("=ls") == "'=ls'")
        #expect(TaskCatalogueRenderer.quote("~x") == "'~x'")
        #expect(TaskCatalogueRenderer.quote("a b") == "'a b'")
        #expect(TaskCatalogueRenderer.quote("%1") == "'%1'")
        #expect(TaskCatalogueRenderer.quote("!!") == "'!!'")
    }

    @Test func aHomePathKeepsTheTildeUnquotedAndQuotesTheRest() throws {
        let task = try #require(TaskCatalogue.task("disk.folderSize"))
        let line = try TaskCatalogueRenderer.render(task, variantID: "run", values: ["path": "~/Mis Documentos"]).get()
        #expect(line.text == "du -sh ~/'Mis Documentos'")
        #expect(ShellCommandParser.commands(in: ShellLexer.tokenize(line.text)).first?.words
            == ["du", "-sh", "~/Mis Documentos"])
        let other = try TaskCatalogueRenderer.render(task, variantID: "run", values: ["path": "~root"]).get()
        #expect(other.text == "du -sh '~root'")
    }

    @Test func processNameDotsAreMatchedLiterally() throws {
        let task = try #require(TaskCatalogue.task("processes.find"))
        let line = try TaskCatalogueRenderer.render(task, variantID: "run", values: ["name": "com.apple.Safari"]).get()
        #expect(line.text == "pgrep -fl -- 'com[.]apple[.]Safari'")
    }

    @Test func aDestructiveVariantNeedsThisTasksPreviewForTheSameValues() throws {
        let task = try #require(TaskCatalogue.task("processes.terminate"))
        let values = ["name": "Safari"]
        #expect(TaskCatalogueRenderer.render(task, variantID: "terminate", values: values) == .failure(.previewRequired))
        let preview = try TaskCatalogueRenderer.render(task, variantID: "preview", values: values).get()
        let otherValues = TaskCatalogueRenderer.render(
            task, variantID: "terminate", values: ["name": "Mail"], preview: preview
        )
        #expect(otherValues == .failure(.previewRequired))
        let dsStore = try #require(TaskCatalogue.task("files.dsStore"))
        let foreignPreview = try TaskCatalogueRenderer.render(dsStore, variantID: "preview", values: ["path": "x"]).get()
        let foreign = TaskCatalogueRenderer.render(task, variantID: "terminate", values: values, preview: foreignPreview)
        #expect(foreign == .failure(.previewRequired))
        let line = try TaskCatalogueRenderer.render(task, variantID: "terminate", values: values, preview: preview).get()
        #expect(line.expectedWarnings == [.killall])
    }

    @Test func wrongHostUnknownVariantAndMissingValuesAreRefused() throws {
        let task = try #require(TaskCatalogue.task("files.head"))
        #expect(TaskCatalogueRenderer.render(task, variantID: "run", values: catalogueExampleValues(task), host: .linux)
            == .failure(.unsupportedHost(.linux)))
        #expect(TaskCatalogueRenderer.render(task, variantID: "nope", values: [:]) == .failure(.unknownVariant("nope")))
        let missing = TaskCatalogueRenderer.render(task, variantID: "run", values: ["path": "a.txt"])
        #expect(missing == .failure(.parameter(.missing(label: "Líneas"))))
        if case .failure(let error) = missing {
            #expect(error.message == "Falta «Líneas». No se ha preparado ninguna orden.")
        }
    }

    @Test(arguments: ["!", "("])
    func aPathFindWouldReadAsAnExpressionGetsADotSlash(path: String) throws {
        let task = try #require(TaskCatalogue.task("files.dsStore"))
        let line = try TaskCatalogueRenderer.render(task, variantID: "preview", values: ["path": path]).get()
        #expect(ShellCommandParser.commands(in: ShellLexer.tokenize(line.text)).first?.words.dropFirst().first
            == "./" + path)
        let folder = try #require(TaskCatalogue.task("disk.folderSize"))
        let du = try TaskCatalogueRenderer.render(folder, variantID: "run", values: ["path": "!x"]).get()
        #expect(du.text == "du -sh '!x'")
    }

    @Test func curlNeverExpandsItsOwnURLGlobs() throws {
        let task = try #require(TaskCatalogue.task("network.httpHeaders"))
        let line = try TaskCatalogueRenderer.render(
            task, variantID: "run", values: ["url": "https://example.com/[1-99999]{a,b}"]
        ).get()
        #expect(line.text == "curl -g -I 'https://example.com/[1-99999]{a,b}'")
    }

    @Test func theUnquotedTextCheckCatchesExpansionsTheLexerKeepsAsWords() {
        let expansions = ["du -sh $HOME", "find . -name *.pdf", "ls {a,b}", "ls ~root", "ls a~", "ls [ab]", "ls 'a"]
        for line in expansions {
            #expect(!TaskCatalogueRenderer.hasOnlyInertUnquotedText(line), "\(line)")
        }
        #expect(TaskCatalogueRenderer.parsesBack("du -sh $HOME", to: [["du", "-sh", "$HOME"]]))
        let safe = ["du -sh ~/'Mis $x'", "du -sh ~", "stat -f %z 'it'\\''s'", "du -ah ~/x | sort -rh"]
        for line in safe {
            #expect(TaskCatalogueRenderer.hasOnlyInertUnquotedText(line), "\(line)")
        }
        #expect(!TaskCatalogueRenderer.hasOnlyInertUnquotedText("ls a\\b"))
    }

    @Test func parseBackRefusesAnyOperatorOrWordDrift() {
        #expect(TaskCatalogueRenderer.parsesBack("ls -l", to: [["ls", "-l"]]))
        #expect(TaskCatalogueRenderer.parsesBack("a | b", to: [["a"], ["b"]]))
        #expect(!TaskCatalogueRenderer.parsesBack("ls; rm x", to: [["ls"]]))
        #expect(!TaskCatalogueRenderer.parsesBack("ls $(id)", to: [["ls"]]))
        #expect(!TaskCatalogueRenderer.parsesBack("ls a b", to: [["ls", "a b"]]))
        #expect(!TaskCatalogueRenderer.parsesBack("ls > x", to: [["ls"]]))
    }
}
