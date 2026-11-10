import CryptoKit
import Foundation

public enum FrameAuthenticationError: Error, Equatable, Sendable {
    case tooShort
    /// Wrong key, tampered body, replayed, reordered, dropped or reflected frame.
    case badTag
    /// A previous frame failed; the connection must be closed.
    case alreadyFailed
    case counterExhausted
}

/// Seals and opens authenticated frame bodies: tag(32) || JSON, where
/// tag = HMAC-SHA256(directionKey, UInt64BE(counter) || JSON). Each direction counts from 0.
public struct FrameAuthenticator: Sendable {
    public private(set) var sendCounter: UInt64 = 0
    public private(set) var receiveCounter: UInt64 = 0
    public private(set) var hasFailed = false

    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey

    public init(sendKey: SymmetricKey, receiveKey: SymmetricKey) {
        self.sendKey = sendKey
        self.receiveKey = receiveKey
    }

    public static func helperSide(_ keys: SessionKeys) -> FrameAuthenticator {
        FrameAuthenticator(sendKey: keys.helperToPhone, receiveKey: keys.phoneToHelper)
    }

    public static func phoneSide(_ keys: SessionKeys) -> FrameAuthenticator {
        FrameAuthenticator(sendKey: keys.phoneToHelper, receiveKey: keys.helperToPhone)
    }

    public mutating func seal(_ body: Data) throws(FrameAuthenticationError) -> Data {
        guard sendCounter < UInt64.max else { throw .counterExhausted }
        let tag = Self.tag(for: body, counter: sendCounter, key: sendKey)
        sendCounter += 1
        return tag + body
    }

    /// Verifies the next incoming frame and returns its JSON body. Any failure is permanent.
    public mutating func open(_ frame: Data) throws(FrameAuthenticationError) -> Data {
        guard !hasFailed else { throw .alreadyFailed }
        guard frame.count > BridgeConstants.tagByteCount else {
            hasFailed = true
            throw .tooShort
        }
        let tagEnd = frame.startIndex + BridgeConstants.tagByteCount
        let tag = frame.subdata(in: frame.startIndex..<tagEnd)
        let body = frame.subdata(in: tagEnd..<frame.endIndex)
        let message = Self.counterBytes(receiveCounter) + body
        guard receiveCounter < UInt64.max,
              HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: message, using: receiveKey)
        else {
            hasFailed = true
            throw .badTag
        }
        receiveCounter += 1
        return body
    }

    static func tag(for body: Data, counter: UInt64, key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: counterBytes(counter) + body, using: key))
    }

    static func counterBytes(_ counter: UInt64) -> Data {
        withUnsafeBytes(of: counter.bigEndian) { Data($0) }
    }
}
