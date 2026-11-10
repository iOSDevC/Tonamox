import Foundation
import Testing
@testable import TerminalBridgeKit

@Suite struct CodeBlockParserTests {
    private func blocks(_ segments: [ReplySegment]) -> [CodeBlock] {
        segments.compactMap { segment in
            if case .code(let block) = segment { return block }
            return nil
        }
    }

    private func texts(_ markdown: String) -> [String] {
        blocks(CodeBlockParser.parse(markdown)).flatMap(\.candidates).map(\.text)
    }

    @Test func eachShellLineGetsACandidate() {
        let reply = "Prueba esto:\n```bash\nls -la\npwd\nwhoami\n```\nListo."
        let segments = CodeBlockParser.parse(reply)
        #expect(segments.count == 3)
        #expect(segments.first == .prose("Prueba esto:"))
        #expect(segments.last == .prose("Listo."))
        #expect(texts(reply) == ["ls -la", "pwd", "whoami"])
        #expect(blocks(segments).first?.isClosed == true)
    }

    @Test func nonShellLanguagesHaveNoCandidates() {
        let segments = CodeBlockParser.parse("```swift\nprint(1)\n```")
        let block = blocks(segments).first
        #expect(block?.isShell == false)
        #expect(block?.candidates == [])
        #expect(block?.lines == ["print(1)"])
    }

    @Test func acceptsTildeFencesAndEveryShellLanguage() {
        #expect(texts("~~~zsh\necho hi\n~~~") == ["echo hi"])
        #expect(texts("```\necho plain\n```") == ["echo plain"])
        #expect(texts("```console\n$ echo c\n```") == ["echo c"])
        #expect(texts("```Shell\necho s\n```") == ["echo s"])
        #expect(texts("````sh\necho long\n````") == ["echo long"])
    }

    @Test(arguments: ["bash:", "Bash", " bash ", "{bash}", "{.sh}", "zsh;", "sh,", "bash: ", "shell-session", "terminal"])
    func normalizesFenceTagsSmallModelsWrite(_ tag: String) {
        let block = blocks(CodeBlockParser.parse("```\(tag)\nls -la\n```")).first
        #expect(block?.isShell == true)
        #expect(block?.candidates.map(\.text) == ["ls -la"])
    }

    @Test(arguments: ["python", "swift:", "bash2", "{python}", "text", "bashrc"])
    func otherFenceTagsStayNonShell(_ tag: String) {
        let block = blocks(CodeBlockParser.parse("```\(tag)\nls -la\n```")).first
        #expect(block?.isShell == false)
        #expect(block?.candidates == [])
    }

    @Test func normalizedLanguageKeepsOnlyTheTag() {
        #expect(CodeBlockParser.normalizedLanguage("bash: title=x") == "bash")
        #expect(CodeBlockParser.normalizedLanguage("{.bash .numberLines}") == "bash")
        #expect(CodeBlockParser.normalizedLanguage("") == "")
        #expect(CodeBlockParser.normalizedLanguage(":") == "")
    }

    @Test func linesOfAMultilineCommandAreNotTypeable() {
        let loop = "```bash\nfor f in *.txt\ndo\n  echo $f\ndone\n```"
        let candidates = blocks(CodeBlockParser.parse(loop)).first?.candidates ?? []
        #expect(candidates.count == 4)
        #expect(candidates.allSatisfy { !$0.isTypeable && $0.violations.isEmpty })
        let continued = blocks(CodeBlockParser.parse("```bash\nls\nfind . \\\n  -name x\n```")).first?.candidates ?? []
        #expect(continued.map(\.isTypeable) == [true, false, false])
        #expect(CommandCandidate.multilineNote.contains("una sola línea"))
    }

    @Test func anUnclosedBlockIsFlaggedButStillParsed() {
        let segments = CodeBlockParser.parse("Mira:\n```bash\nls\npwd")
        #expect(blocks(segments).first?.isClosed == false)
        #expect(texts("Mira:\n```bash\nls\npwd") == ["ls", "pwd"])
    }

    @Test func stripsPromptIndentationAndTrailingBlanks() {
        let reply = "```bash\n$ ls\n% pwd\n    echo indented\n\techo tab\necho trailing   \n$ $HOME\n```"
        #expect(texts(reply) == ["ls", "pwd", "echo indented", "echo tab", "echo trailing", "$HOME"])
    }

    @Test func skipsCommentsAndBlankLines() {
        let reply = "```bash\n# list files\n\nls\n   # indented comment\n#!/bin/zsh\npwd\n```"
        #expect(texts(reply) == ["ls", "pwd"])
    }

    @Test func handlesWindowsLineEndings() {
        #expect(texts("```bash\r\nls\r\npwd\r\n```\r\n") == ["ls", "pwd"])
    }

    @Test func backslashContinuationMarksBothLines() {
        let reply = "```bash\nls\nfind . \\\n  -name x\npwd\n```"
        let candidates = blocks(CodeBlockParser.parse(reply)).first?.candidates ?? []
        #expect(candidates.map(\.isPartOfMultilineCommand) == [false, true, true, false])
    }

    @Test func heredocAndSplitLoopsMarkTheWholeBlock() {
        let heredoc = "```bash\ncat <<EOF > x.txt\nhola\nEOF\n```"
        #expect(blocks(CodeBlockParser.parse(heredoc)).first?.candidates.allSatisfy(\.isPartOfMultilineCommand) == true)
        let loop = "```bash\nfor f in *.txt\ndo\n  echo $f\ndone\n```"
        #expect(blocks(CodeBlockParser.parse(loop)).first?.candidates.allSatisfy(\.isPartOfMultilineCommand) == true)
        let oneLiner = "```bash\nfor f in *.txt; do echo $f; done\n```"
        #expect(blocks(CodeBlockParser.parse(oneLiner)).first?.candidates.first?.isPartOfMultilineCommand == false)
        let hereString = "```bash\ncat <<< hola\n```"
        #expect(blocks(CodeBlockParser.parse(hereString)).first?.candidates.first?.isPartOfMultilineCommand == false)
    }

    @Test func candidatesCarryPolicyAndWarnings() {
        let reply = "```bash\nsudo ls\nls\tx\necho año\nls\n```"
        let candidates = blocks(CodeBlockParser.parse(reply)).first?.candidates ?? []
        #expect(candidates.count == 4)
        #expect(candidates[0].warnings == [.sudo])
        #expect(candidates[0].isTypeable)
        #expect(candidates[1].isTypeable == false)
        #expect(candidates[1].violations == [.disallowedCharacter(scalar: 0x09, offset: 2)])
        #expect(candidates[2].isTypeable == false)
        #expect(candidates[3].isTypeable && candidates[3].warnings.isEmpty)
        #expect(candidates.map(\.lineIndex) == [0, 1, 2, 3])
        #expect(Set(candidates.map(\.id)).count == 4)
    }

    @Test func keepsProseBetweenSeveralBlocks() {
        let reply = "Uno\n```bash\nls\n```\nDos\n\n```sh\npwd\n```"
        let segments = CodeBlockParser.parse(reply)
        #expect(segments.count == 4)
        #expect(segments[0] == .prose("Uno"))
        #expect(segments[2] == .prose("Dos"))
        #expect(texts(reply) == ["ls", "pwd"])
    }

    @Test func proseWithoutBlocksIsOneSegment() {
        #expect(CodeBlockParser.parse("Solo texto.\nSin bloques.") == [.prose("Solo texto.\nSin bloques.")])
        #expect(CodeBlockParser.parse("") == [])
    }
}
