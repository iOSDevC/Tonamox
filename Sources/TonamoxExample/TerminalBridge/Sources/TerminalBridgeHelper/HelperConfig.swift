#if os(macOS)
import CryptoKit
import Foundation
import TerminalBridgeKit

/// Helper state kept in a 0600 JSON file: pairing secret, helper id, journal HMAC key and an
/// optional idle-prompt regex. Unpairing clears only the secret.
public struct HelperConfig: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let journalKeyByteCount = 32

    public var version: Int
    public var helperID: UUID
    /// Random local key for the journal's HMAC of each command; never leaves this file.
    public var journalKey: Data
    public var secret: Data?
    public var fingerprint: String?
    public var pairedAt: Date?
    public var promptRegex: String?

    public init(
        helperID: UUID = UUID(),
        journalKey: Data = HelperConfig.randomJournalKey(),
        secret: Data? = nil,
        fingerprint: String? = nil,
        pairedAt: Date? = nil,
        promptRegex: String? = nil
    ) {
        version = Self.currentVersion
        self.helperID = helperID
        self.journalKey = journalKey
        self.secret = secret
        self.fingerprint = fingerprint
        self.pairedAt = pairedAt
        self.promptRegex = promptRegex
    }

    public var isPaired: Bool {
        secret?.count == BridgeConstants.secretByteCount
    }

    public var journalSymmetricKey: SymmetricKey {
        SymmetricKey(data: journalKey)
    }

    public mutating func pair(with code: PairingCode, at date: Date = Date()) {
        secret = code.secret
        fingerprint = code.fingerprint
        // Whole seconds: the ISO 8601 coding in the file drops fractions.
        pairedAt = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    public mutating func unpair() {
        secret = nil
        fingerprint = nil
        pairedAt = nil
    }

    public static func randomJournalKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }
}

public enum HelperConfigError: Error, Equatable, Sendable {
    case file(PrivateFileError)
    case malformed(path: String, reason: String)
    case notPaired(path: String)

    public var message: String {
        switch self {
        case .file(let error):
            error.message
        case .malformed(let path, let reason):
            "La configuración '\(path)' no se puede leer: \(reason)"
        case .notPaired(let path):
            "No hay emparejamiento en '\(path)'. Ejecuta: tonamox-bridge pair (--new | --code CÓDIGO | --stdin)"
        }
    }
}

/// Loads and saves `HelperConfig`. Refuses, like ssh, a file other users could read or that
/// is not owned by this user; writes are atomic (0600 temp file + rename).
public struct HelperConfigStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = HelperConfigStore.defaultURL) {
        self.fileURL = fileURL
    }

    /// ~/Library/Application Support/TonamoxBridge/config.json
    public static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "TonamoxBridge", directoryHint: .isDirectory)
            .appending(path: "config.json", directoryHint: .notDirectory)
    }

    public var path: String {
        PrivateFiles.path(fileURL)
    }

    public func loadIfPresent() throws(HelperConfigError) -> HelperConfig? {
        do {
            guard try PrivateFiles.checkPrivate(fileURL) else { return nil }
        } catch {
            throw .file(error)
        }
        return try load()
    }

    public func load() throws(HelperConfigError) -> HelperConfig {
        let contents: Data
        do {
            contents = try PrivateFiles.read(fileURL)
        } catch {
            throw .file(error)
        }
        do {
            return try Self.decoder().decode(HelperConfig.self, from: contents)
        } catch {
            throw .malformed(path: path, reason: String(describing: error))
        }
    }

    public func loadPaired() throws(HelperConfigError) -> HelperConfig {
        guard let config = try loadIfPresent(), config.isPaired else { throw .notPaired(path: path) }
        return config
    }

    public func save(_ config: HelperConfig) throws(HelperConfigError) {
        let encoded: Data
        do {
            encoded = try Self.encoder().encode(config)
        } catch {
            throw .malformed(path: path, reason: String(describing: error))
        }
        do {
            try PrivateFiles.atomicWrite(encoded + Data("\n".utf8), to: fileURL)
        } catch {
            throw .file(error)
        }
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
#endif
