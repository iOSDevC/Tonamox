#if os(macOS)
import Darwin
import Foundation

public enum PrivateFileError: Error, Equatable, Sendable {
    case notFound(String)
    case symbolicLink(String)
    case notRegularFile(String)
    case wrongOwner(path: String, owner: UInt32)
    case insecurePermissions(path: String, mode: UInt16)
    case ioFailure(path: String, reason: String)

    public var message: String {
        switch self {
        case .notFound(let path):
            "No existe '\(path)'."
        case .symbolicLink(let path):
            "'\(path)' es un enlace simbólico; usa la ruta real."
        case .notRegularFile(let path):
            "'\(path)' no es un archivo normal."
        case .wrongOwner(let path, let owner):
            "'\(path)' pertenece al uid \(owner), no a ti (uid \(getuid()))."
        case .insecurePermissions(let path, let mode):
            "Permisos demasiado abiertos (\(String(mode, radix: 8))) en '\(path)'. Corrígelo con: chmod 600 '\(path)'"
        case .ioFailure(let path, let reason):
            "No se pudo usar '\(path)': \(reason)"
        }
    }
}

/// File helpers for secrets and logs: 0700 directories, 0600 files, no symlinks, owner checks.
/// Paths always come from `path(percentEncoded: false)`.
enum PrivateFiles {
    static let fileMode: mode_t = 0o600
    static let directoryMode: mode_t = 0o700

    static func path(_ url: URL) -> String {
        url.path(percentEncoded: false)
    }

    /// Creates missing directories with 0700 and leaves existing ones untouched.
    static func ensureDirectory(_ url: URL) throws(PrivateFileError) {
        let path = path(url)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw .notRegularFile(path) }
            return
        }
        do {
            try FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: Int(directoryMode)]
            )
        } catch {
            throw .ioFailure(path: path, reason: error.localizedDescription)
        }
    }

    /// Returns false when the file does not exist; throws when it exists but is not private.
    @discardableResult
    static func checkPrivate(_ url: URL) throws(PrivateFileError) -> Bool {
        let path = path(url)
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw .ioFailure(path: path, reason: errnoDescription())
        }
        try validate(info, path: path)
        return true
    }

    static func validate(_ info: stat, path: String) throws(PrivateFileError) {
        let type = info.st_mode & S_IFMT
        if type == S_IFLNK { throw .symbolicLink(path) }
        guard type == S_IFREG else { throw .notRegularFile(path) }
        guard info.st_uid == getuid() else { throw .wrongOwner(path: path, owner: info.st_uid) }
        guard info.st_mode & 0o077 == 0 else {
            throw .insecurePermissions(path: path, mode: UInt16(info.st_mode & 0o7777))
        }
    }

    static func read(_ url: URL) throws(PrivateFileError) -> Data {
        let path = path(url)
        guard try checkPrivate(url) else { throw .notFound(path) }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw .ioFailure(path: path, reason: errnoDescription()) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            return try handle.readToEnd() ?? Data()
        } catch {
            throw .ioFailure(path: path, reason: error.localizedDescription)
        }
    }

    /// The last `maxBytes` of a private file, cut to start at a line; nil when it does not exist.
    static func readTail(_ url: URL, maxBytes: Int) throws(PrivateFileError) -> (data: Data, isPartial: Bool)? {
        let path = path(url)
        guard try checkPrivate(url) else { return nil }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw .ioFailure(path: path, reason: errnoDescription()) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            let size = try handle.seekToEnd()
            let start = size > UInt64(max(0, maxBytes)) ? size - UInt64(max(0, maxBytes)) : 0
            try handle.seek(toOffset: start)
            let data = try handle.readToEnd() ?? Data()
            guard start > 0 else { return (data, false) }
            guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return (Data(), true) }
            return (data[data.index(after: newline)...], true)
        } catch {
            throw .ioFailure(path: path, reason: error.localizedDescription)
        }
    }

    /// Writes a 0600 temporary file next to `url`, syncs it and renames it into place.
    static func atomicWrite(_ data: Data, to url: URL) throws(PrivateFileError) {
        try ensureDirectory(url.deletingLastPathComponent())
        try checkPrivate(url)
        let temporary = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp", directoryHint: .notDirectory)
        let temporaryPath = path(temporary)
        let descriptor = open(temporaryPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, fileMode)
        guard descriptor >= 0 else { throw .ioFailure(path: temporaryPath, reason: errnoDescription()) }
        let written = writeAll(data, to: descriptor)
        let synced = fsync(descriptor) == 0
        close(descriptor)
        guard written, synced, rename(temporaryPath, path(url)) == 0 else {
            let reason = errnoDescription()
            unlink(temporaryPath)
            throw .ioFailure(path: path(url), reason: reason)
        }
    }

    /// Opens (creating with 0600 if needed) a private file for appending.
    static func openForAppending(_ url: URL) throws(PrivateFileError) -> Int32 {
        try ensureDirectory(url.deletingLastPathComponent())
        let path = path(url)
        let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, fileMode)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw .symbolicLink(path) }
            throw .ioFailure(path: path, reason: errnoDescription())
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            close(descriptor)
            throw .ioFailure(path: path, reason: errnoDescription())
        }
        do {
            try validate(info, path: path)
        } catch {
            close(descriptor)
            throw error
        }
        return descriptor
    }

    /// Creates an empty 0600 file that must not exist yet.
    static func createEmpty(_ url: URL) throws(PrivateFileError) {
        let path = path(url)
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, fileMode)
        guard descriptor >= 0 else { throw .ioFailure(path: path, reason: errnoDescription()) }
        close(descriptor)
    }

    /// A fresh 0700 directory under `parent` (mkdtemp).
    static func makeTemporaryDirectory(in parent: URL, prefix: String) throws(PrivateFileError) -> URL {
        let parentPath = path(parent).hasSuffix("/") ? String(path(parent).dropLast()) : path(parent)
        var template = Array("\(parentPath)/\(prefix).XXXXXX".utf8CString)
        guard let created = mkdtemp(&template) else {
            throw .ioFailure(path: parentPath, reason: errnoDescription())
        }
        return URL(filePath: String(cString: created), directoryHint: .isDirectory)
    }

    static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            guard var cursor = buffer.baseAddress else { return true }
            var remaining = buffer.count
            while remaining > 0 {
                let count = write(descriptor, cursor, remaining)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                cursor += count
                remaining -= count
            }
            return true
        }
    }

    static func errnoDescription() -> String {
        String(cString: strerror(errno))
    }
}
#endif
