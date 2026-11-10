#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import Synchronization
import TerminalBridgeKit

/// One JSONL line of the journal.
struct JournalEntry: Codable, Equatable, Sendable {
    var timestamp: String
    var event: String
    var id: UUID?
    var bytes: Int?
    var hmac: String?
    var result: String?
    var code: String?
    var warnings: [String]?
    var verified: Bool?
    var session: String?
    var window: String?
    var device: String?
    var detail: String?
    /// How many identical events this line stands for (coalesced rejections).
    var count: Int?

    enum CodingKeys: String, CodingKey {
        case timestamp = "ts"
        case event, id, bytes, hmac, result, code, warnings, verified, session, window, device, detail, count
    }
}

public enum JournalEvent: String, Sendable {
    case started
    case connected
    case disconnected
    case rejected
    case stopped
}

/// Commands are stored only as HMAC-SHA256 with the config's local key: a bare SHA-256 of a short
/// command is reversible with a dictionary.
public final class WriteJournal: WriteRecorder, Sendable {
    public static let writeEvent = "write"
    static let maxDetailCharacters = 200
    /// `run` seeds the replay ids and `status` counts from this much of the end of the file.
    public static let scanLimitBytes = 1 << 20
    static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    public let fileURL: URL
    private let key: SymmetricKey
    private let session: String
    private let window: String
    private let device: String
    private let descriptor: Mutex<Int32>

    /// ~/Library/Logs/TonamoxBridge/writes.log
    public static var defaultURL: URL {
        URL.libraryDirectory
            .appending(path: "Logs/TonamoxBridge", directoryHint: .isDirectory)
            .appending(path: "writes.log", directoryHint: .notDirectory)
    }

    public init(
        fileURL: URL,
        key: SymmetricKey,
        session: String,
        window: String,
        device: String
    ) throws(PrivateFileError) {
        self.fileURL = fileURL
        self.key = key
        self.session = session
        self.window = window
        self.device = device
        descriptor = Mutex(try PrivateFiles.openForAppending(fileURL))
    }

    deinit {
        close()
    }

    public func record(_ write: WriteRecord) async {
        append(entry(for: write, at: Date()))
    }

    public func note(_ event: JournalEvent, detail: String? = nil, count: Int? = nil) {
        var entry = baseEntry(event.rawValue, at: Date())
        entry.detail = detail.map { String($0.prefix(Self.maxDetailCharacters)) }
        entry.count = count
        append(entry)
    }

    public func close() {
        descriptor.withLock { descriptor in
            if descriptor >= 0 { Darwin.close(descriptor) }
            descriptor = -1
        }
    }

    func entry(for write: WriteRecord, at date: Date) -> JournalEntry {
        var entry = baseEntry(Self.writeEvent, at: date)
        entry.id = write.id
        entry.bytes = write.bytes
        entry.hmac = BridgeDigest.hmacSHA256Hex(write.text, key: key)
        entry.warnings = write.warnings
        entry.verified = write.verified
        switch write.outcome {
        case .typed:
            entry.result = "typed"
        case .alreadyTyped:
            entry.result = "alreadyTyped"
        case .refused(let code):
            entry.result = "refused"
            entry.code = code.wireValue
        }
        return entry
    }

    private func baseEntry(_ event: String, at date: Date) -> JournalEntry {
        JournalEntry(
            timestamp: date.formatted(Self.timestampStyle),
            event: event,
            session: session,
            window: window,
            device: device
        )
    }

    private func append(_ entry: JournalEntry) {
        guard let line = Self.line(for: entry) else { return }
        descriptor.withLock { descriptor in
            guard descriptor >= 0 else { return }
            _ = PrivateFiles.writeAll(line, to: descriptor)
        }
    }

    static func line(for entry: JournalEntry) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let json = try? encoder.encode(entry) else { return nil }
        return json + Data("\n".utf8)
    }

    /// Ids of writes that were really typed, oldest first, to seed the anti-replay LRU. Reads only the
    /// last `scanLimit` bytes: replays matter within minutes, and the file is never rotated.
    public static func typedWriteIDs(
        at url: URL,
        limit: Int = BridgeConstants.recentWriteCapacity,
        scanLimit: Int = scanLimitBytes
    ) throws(PrivateFileError) -> [UUID] {
        guard let tail = try PrivateFiles.readTail(url, maxBytes: scanLimit) else { return [] }
        let ids = entries(in: tail.data).compactMap { entry -> UUID? in
            guard entry.event == writeEvent, entry.result == "typed" else { return nil }
            return entry.id
        }
        return Array(ids.suffix(max(0, limit)))
    }

    /// Write results counted over the same tail `run` reads, for `status`.
    public struct Summary: Equatable, Sendable {
        public var counts: [String: Int]
        /// True when the file is longer than the scanned tail.
        public var isPartial: Bool
    }

    public static func summary(at url: URL, scanLimit: Int = scanLimitBytes) throws(PrivateFileError) -> Summary {
        guard let tail = try PrivateFiles.readTail(url, maxBytes: scanLimit) else {
            return Summary(counts: [:], isPartial: false)
        }
        let results = entries(in: tail.data).compactMap { $0.event == writeEvent ? $0.result : nil }
        return Summary(counts: Dictionary(grouping: results) { $0 }.mapValues(\.count), isPartial: tail.isPartial)
    }

    /// Decodes whole lines; a tail that starts mid-line drops its first, partial line.
    static func entries(in data: Data) -> [JournalEntry] {
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            try? decoder.decode(JournalEntry.self, from: line)
        }
    }
}
#endif
