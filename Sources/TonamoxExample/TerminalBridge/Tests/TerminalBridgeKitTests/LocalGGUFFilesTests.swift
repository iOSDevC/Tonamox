import Foundation
import Testing
import TerminalBridgeKit

@Suite struct LocalGGUFFilesTests {
    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "tonamox kit \(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
            .appending(path: "Mis Modelos", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(atPath: folder.path(percentEncoded: false), withIntermediateDirectories: true)
        return folder
    }

    private func touch(_ folder: URL, _ name: String) {
        let path = folder.appending(path: name, directoryHint: .notDirectory).path(percentEncoded: false)
        FileManager.default.createFile(atPath: path, contents: Data("gguf".utf8))
    }

    @Test func listsOnlyTextModelFilesInAFolderWithASpace() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(atPath: folder.deletingLastPathComponent().path(percentEncoded: false)) }
        ["qwen 0.5b.gguf", "B-model.GGUF", "a-model.gguf", "mmproj-vision.gguf", ".hidden.gguf", ".gguf", "notes.txt"]
            .forEach { touch(folder, $0) }
        let directory = folder.appending(path: "folder.gguf", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(atPath: directory.path(percentEncoded: false), withIntermediateDirectories: true)

        let names = LocalGGUFFiles.list(in: folder).map(\.lastPathComponent)

        #expect(names == ["a-model.gguf", "B-model.GGUF", "qwen 0.5b.gguf"])
        #expect(folder.path(percentEncoded: false).contains("Mis Modelos"))
        #expect(!LocalGGUFFiles.isModelFile(directory))
    }

    @Test func existsMeansARegularFileRightNow() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(atPath: folder.deletingLastPathComponent().path(percentEncoded: false)) }
        touch(folder, "model one.gguf")
        let file = folder.appending(path: "model one.gguf", directoryHint: .notDirectory)
        #expect(LocalGGUFFiles.exists(file))
        #expect(!LocalGGUFFiles.exists(folder))
        try FileManager.default.removeItem(atPath: file.path(percentEncoded: false))
        #expect(!LocalGGUFFiles.exists(file))
        #expect(LocalGGUFFiles.list(in: folder.appending(path: "missing", directoryHint: .isDirectory)) == [])
    }
}
