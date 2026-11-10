#if os(macOS)
import Darwin
import Foundation

/// `$TMPDIR/tonamox-bridge.<pid>.XXXXXX` holds the hardcopies. A killed helper cannot remove its own,
/// so every start sweeps those whose pid is gone, plus empty ones from builds without the pid.
enum ScratchDirectories {
    static let prefix = "tonamox-bridge"

    static func make(in parent: URL, pid: Int32 = getpid()) throws(PrivateFileError) -> URL {
        try PrivateFiles.makeTemporaryDirectory(in: parent, prefix: "\(prefix).\(pid)")
    }

    /// Removes stale scratch directories owned by this user; returns their names.
    @discardableResult
    static func sweepStale(in parent: URL, isAlive: (Int32) -> Bool = processExists) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: PrivateFiles.path(parent))) ?? []
        return names.sorted().filter { name in
            guard let owner = owner(of: name) else { return false }
            // .notDirectory: a trailing "/" would make lstat follow a symlink planted under this name.
            let directory = parent.appending(path: name, directoryHint: .notDirectory)
            guard isOwnedDirectory(PrivateFiles.path(directory)) else { return false }
            switch owner {
            case .process(let pid):
                guard !isAlive(pid) else { return false }
                removeHardcopies(in: directory)
                return rmdir(PrivateFiles.path(directory)) == 0
            case .unknown:
                // Without a pid it may still be in use: rmdir only succeeds when it is empty.
                return rmdir(PrivateFiles.path(directory)) == 0
            }
        }
    }

    enum Owner: Equatable {
        case process(Int32)
        case unknown
    }

    /// "tonamox-bridge.<pid>.XXXXXX" or the older "tonamox-bridge.XXXXXX"; nil for anything else.
    static func owner(of name: String) -> Owner? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.first?.elementsEqual(prefix) == true, let suffix = parts.last, suffix.count == 6 else { return nil }
        switch parts.count {
        case 2:
            return .unknown
        case 3:
            guard let pid = Int32(parts[1]), pid > 0 else { return nil }
            return .process(pid)
        default:
            return nil
        }
    }

    static func processExists(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func removeHardcopies(in directory: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: PrivateFiles.path(directory))) ?? []
        for name in names where name.hasPrefix("hc-") && name.hasSuffix(".txt") {
            let path = PrivateFiles.path(directory.appending(path: name, directoryHint: .notDirectory))
            if isOwnedRegularFile(path) { unlink(path) }
        }
    }

    private static func isOwnedDirectory(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
    }

    private static func isOwnedRegularFile(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid()
    }
}
#endif
