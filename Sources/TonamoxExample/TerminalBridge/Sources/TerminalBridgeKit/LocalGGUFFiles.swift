import Foundation

/// `.gguf` files sitting directly in one folder (the Terminal app's Documents). Foundation only, so the
/// Kit's tests cover it.
public enum LocalGGUFFiles {
    private static let resourceKeys: [URLResourceKey] = [.isRegularFileKey]

    /// Model files in `directory`, sorted by name. Vision projectors (`mmproj`) are not text models.
    public static func list(in directory: URL, fileManager: FileManager = .default) -> [URL] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { isModelFile($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    public static func isModelFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        guard name.hasSuffix(".gguf"), name.count > ".gguf".count, !name.contains("mmproj") else { return false }
        return (try? url.resourceValues(forKeys: Set(resourceKeys)))?.isRegularFile == true
    }

    /// True when `url` is still a regular file right now.
    public static func exists(_ url: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        let found = fileManager.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
        return found && !isDirectory.boolValue
    }
}
