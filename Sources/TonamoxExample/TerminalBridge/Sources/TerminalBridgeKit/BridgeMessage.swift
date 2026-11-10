import Foundation

/// A string-coded value that keeps unknown wire values instead of failing to decode.
public protocol ForwardCompatibleCode: Codable, Hashable, Sendable {
    init(wireValue: String)
    var wireValue: String { get }
}

extension ForwardCompatibleCode {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(wireValue: try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

public enum BridgeErrorCode: ForwardCompatibleCode {
    case unsupportedProtocol
    case authFailed
    case policy
    case unacknowledgedWarnings
    case sessionMissing
    case ambiguousSession
    case windowMissing
    case multipleWindows
    case promptNotIdle
    case foregroundNotShell
    case screenUnavailable
    case screenFailed
    case unsupportedIntent
    case unsupportedMessage
    case rateLimited
    case busy
    case unrecognized(String)

    public init(wireValue: String) {
        switch wireValue {
        case "unsupportedProtocol": self = .unsupportedProtocol
        case "authFailed": self = .authFailed
        case "policy": self = .policy
        case "unacknowledgedWarnings": self = .unacknowledgedWarnings
        case "sessionMissing": self = .sessionMissing
        case "ambiguousSession": self = .ambiguousSession
        case "windowMissing": self = .windowMissing
        case "multipleWindows": self = .multipleWindows
        case "promptNotIdle": self = .promptNotIdle
        case "foregroundNotShell": self = .foregroundNotShell
        case "screenUnavailable": self = .screenUnavailable
        case "screenFailed": self = .screenFailed
        case "unsupportedIntent": self = .unsupportedIntent
        case "unsupportedMessage": self = .unsupportedMessage
        case "rateLimited": self = .rateLimited
        case "busy": self = .busy
        default: self = .unrecognized(wireValue)
        }
    }

    public var wireValue: String {
        switch self {
        case .unsupportedProtocol: "unsupportedProtocol"
        case .authFailed: "authFailed"
        case .policy: "policy"
        case .unacknowledgedWarnings: "unacknowledgedWarnings"
        case .sessionMissing: "sessionMissing"
        case .ambiguousSession: "ambiguousSession"
        case .windowMissing: "windowMissing"
        case .multipleWindows: "multipleWindows"
        case .promptNotIdle: "promptNotIdle"
        case .foregroundNotShell: "foregroundNotShell"
        case .screenUnavailable: "screenUnavailable"
        case .screenFailed: "screenFailed"
        case .unsupportedIntent: "unsupportedIntent"
        case .unsupportedMessage: "unsupportedMessage"
        case .rateLimited: "rateLimited"
        case .busy: "busy"
        case .unrecognized(let value): value
        }
    }
}

/// State of the screen window the helper types into, as reported in `status`.
public enum TargetState: ForwardCompatibleCode {
    case ready
    case sessionMissing
    case ambiguousSession
    case windowMissing
    case multipleWindows
    case promptNotIdle
    case foregroundNotShell
    case screenUnavailable
    case unrecognized(String)

    public init(wireValue: String) {
        switch wireValue {
        case "ready": self = .ready
        case "sessionMissing": self = .sessionMissing
        case "ambiguousSession": self = .ambiguousSession
        case "windowMissing": self = .windowMissing
        case "multipleWindows": self = .multipleWindows
        case "promptNotIdle": self = .promptNotIdle
        case "foregroundNotShell": self = .foregroundNotShell
        case "screenUnavailable": self = .screenUnavailable
        default: self = .unrecognized(wireValue)
        }
    }

    public var wireValue: String {
        switch self {
        case .ready: "ready"
        case .sessionMissing: "sessionMissing"
        case .ambiguousSession: "ambiguousSession"
        case .windowMissing: "windowMissing"
        case .multipleWindows: "multipleWindows"
        case .promptNotIdle: "promptNotIdle"
        case .foregroundNotShell: "foregroundNotShell"
        case .screenUnavailable: "screenUnavailable"
        case .unrecognized(let value): value
        }
    }

    /// The error code a write gets when the target is in this state; nil when ready.
    public var refusalCode: BridgeErrorCode? {
        switch self {
        case .ready: nil
        case .sessionMissing: .sessionMissing
        case .ambiguousSession: .ambiguousSession
        case .windowMissing: .windowMissing
        case .multipleWindows: .multipleWindows
        case .promptNotIdle: .promptNotIdle
        case .foregroundNotShell: .foregroundNotShell
        case .screenUnavailable, .unrecognized: .screenUnavailable
        }
    }
}

public enum AckResult: ForwardCompatibleCode {
    case typed
    case alreadyTyped
    case unrecognized(String)

    public init(wireValue: String) {
        switch wireValue {
        case "typed": self = .typed
        case "alreadyTyped": self = .alreadyTyped
        default: self = .unrecognized(wireValue)
        }
    }

    public var wireValue: String {
        switch self {
        case .typed: "typed"
        case .alreadyTyped: "alreadyTyped"
        case .unrecognized(let value): value
        }
    }
}

/// What a write asks the helper to do. v1 only types text; unknown kinds are kept, never typed.
public enum WriteIntent: Codable, Hashable, Sendable {
    case text
    case unrecognized(kind: String)

    private enum CodingKeys: String, CodingKey {
        case kind
    }

    public var kind: String {
        switch self {
        case .text: "text"
        case .unrecognized(let kind): kind
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        self = kind == "text" ? .text : .unrecognized(kind: kind)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
    }
}

/// H→P, first handshake frame.
public struct HelloMessage: Codable, Hashable, Sendable {
    public var protocols: [Int]
    public var helperID: UUID
    public var helperName: String
    public var nonce: Data

    public init(protocols: [Int], helperID: UUID, helperName: String, nonce: Data) {
        self.protocols = protocols
        self.helperID = helperID
        self.helperName = helperName
        self.nonce = nonce
    }
}

/// P→H, second handshake frame.
public struct ChallengeMessage: Codable, Hashable, Sendable {
    public var version: Int
    public var phoneID: UUID
    public var phoneName: String
    public var nonce: Data

    private enum CodingKeys: String, CodingKey {
        case version = "protocol"
        case phoneID, phoneName, nonce
    }

    public init(version: Int, phoneID: UUID, phoneName: String, nonce: Data) {
        self.version = version
        self.phoneID = phoneID
        self.phoneName = phoneName
        self.nonce = nonce
    }
}

/// H→P `auth` and P→H `authOK` both carry one 32-byte proof.
public struct ProofMessage: Codable, Hashable, Sendable {
    public var proof: Data

    public init(proof: Data) {
        self.proof = proof
    }
}

/// The screen window the helper types into.
public struct TargetStatus: Codable, Hashable, Sendable {
    public var session: String
    public var window: String
    public var state: TargetState
    public var foreground: String?

    public init(session: String, window: String, state: TargetState, foreground: String? = nil) {
        self.session = session
        self.window = window
        self.state = state
        self.foreground = foreground
    }
}

/// H→P, sent after authOK and whenever the target changes.
public struct StatusMessage: Codable, Hashable, Sendable {
    public var capabilities: [String]
    public var maxTextBytes: Int
    public var target: TargetStatus
    public var hint: String?

    public init(
        capabilities: [String] = [BridgeConstants.writeTextCapability],
        maxTextBytes: Int = BridgeConstants.maxTextBytes,
        target: TargetStatus,
        hint: String? = nil
    ) {
        self.capabilities = capabilities
        self.maxTextBytes = maxTextBytes
        self.target = target
        self.hint = hint
    }

    /// v1 status for `target`, with the command that fixes a missing session as the hint.
    public static func describing(_ target: TargetStatus) -> StatusMessage {
        let hint = target.state == .sessionMissing ? "screen -S \(target.session)" : nil
        return StatusMessage(target: target, hint: hint)
    }
}

/// P→H. There is no `seq`: the authenticated frame counter already orders frames.
public struct WriteRequest: Codable, Hashable, Sendable {
    public var id: UUID
    public var intent: WriteIntent
    public var text: String?
    public var acknowledgedWarnings: [String]

    public init(id: UUID, intent: WriteIntent = .text, text: String?, acknowledgedWarnings: [String] = []) {
        self.id = id
        self.intent = intent
        self.text = text
        self.acknowledgedWarnings = acknowledgedWarnings
    }
}

/// H→P, answer to a write that was typed (now or earlier with the same id).
public struct WriteAck: Codable, Hashable, Sendable {
    public var id: UUID
    public var result: AckResult
    public var bytes: Int
    public var textSHA256: String
    public var warnings: [String]
    public var verified: Bool

    private enum CodingKeys: String, CodingKey {
        case id, result, bytes, warnings, verified
        case textSHA256 = "sha256"
    }

    public init(id: UUID, result: AckResult, bytes: Int, textSHA256: String, warnings: [String], verified: Bool) {
        self.id = id
        self.result = result
        self.bytes = bytes
        self.textSHA256 = textSHA256
        self.warnings = warnings
        self.verified = verified
    }
}

/// An `error` frame. `id` is set when it answers a write.
public struct ErrorReport: Codable, Hashable, Sendable {
    public var id: UUID?
    public var code: BridgeErrorCode
    public var detail: String?
    public var warnings: [String]?
    public var supported: [Int]?

    public init(
        id: UUID? = nil,
        code: BridgeErrorCode,
        detail: String? = nil,
        warnings: [String]? = nil,
        supported: [Int]? = nil
    ) {
        self.id = id
        self.code = code
        self.detail = detail
        self.warnings = warnings
        self.supported = supported
    }
}

/// Every frame body, discriminated by its JSON `type`.
public enum BridgeMessage: Hashable, Sendable {
    case hello(HelloMessage)
    case challenge(ChallengeMessage)
    case auth(ProofMessage)
    case authOK(ProofMessage)
    case status(StatusMessage)
    case write(WriteRequest)
    case ack(WriteAck)
    case error(ErrorReport)
    case ping(Int)
    case pong(Int)
    /// A type this build does not know; decoding it never fails.
    case unrecognized(type: String)

    public var typeName: String {
        switch self {
        case .hello: "hello"
        case .challenge: "challenge"
        case .auth: "auth"
        case .authOK: "authOK"
        case .status: "status"
        case .write: "write"
        case .ack: "ack"
        case .error: "error"
        case .ping: "ping"
        case .pong: "pong"
        case .unrecognized(let type): type
        }
    }
}

extension BridgeMessage: Codable {
    private enum EnvelopeKeys: String, CodingKey {
        case type
        case number = "n"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: EnvelopeKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "hello": self = .hello(try HelloMessage(from: decoder))
        case "challenge": self = .challenge(try ChallengeMessage(from: decoder))
        case "auth": self = .auth(try ProofMessage(from: decoder))
        case "authOK": self = .authOK(try ProofMessage(from: decoder))
        case "status": self = .status(try StatusMessage(from: decoder))
        case "write": self = .write(try WriteRequest(from: decoder))
        case "ack": self = .ack(try WriteAck(from: decoder))
        case "error": self = .error(try ErrorReport(from: decoder))
        case "ping": self = .ping(try container.decode(Int.self, forKey: .number))
        case "pong": self = .pong(try container.decode(Int.self, forKey: .number))
        default: self = .unrecognized(type: type)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: EnvelopeKeys.self)
        try container.encode(typeName, forKey: .type)
        switch self {
        case .hello(let body): try body.encode(to: encoder)
        case .challenge(let body): try body.encode(to: encoder)
        case .auth(let body), .authOK(let body): try body.encode(to: encoder)
        case .status(let body): try body.encode(to: encoder)
        case .write(let body): try body.encode(to: encoder)
        case .ack(let body): try body.encode(to: encoder)
        case .error(let body): try body.encode(to: encoder)
        case .ping(let number), .pong(let number): try container.encode(number, forKey: .number)
        case .unrecognized: break
        }
    }
}

/// JSON bytes for frame bodies. Keys are sorted so equal messages encode to equal bytes.
public enum BridgeMessageCoder {
    public static func encode(_ message: BridgeMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(message)
    }

    public static func decode(_ data: Data) throws -> BridgeMessage {
        try JSONDecoder().decode(BridgeMessage.self, from: data)
    }
}
