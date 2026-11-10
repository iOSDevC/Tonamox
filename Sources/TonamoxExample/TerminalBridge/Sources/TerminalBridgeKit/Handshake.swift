import CryptoKit
import Foundation

public enum HandshakeError: Error, Equatable, Sendable {
    case malformedMessage
    case unexpectedMessage(String)
    case unsupportedProtocol(offered: [Int])
    /// The peer's proof did not verify: it does not hold the pairing secret.
    case authFailed
    /// The peer answered with an `error` frame.
    case rejectedByPeer(BridgeErrorCode)
    case invalidState
    case timedOut
}

/// Per-direction frame keys derived from the secret and the handshake transcript.
public struct SessionKeys: Sendable {
    public let helperToPhone: SymmetricKey
    public let phoneToHelper: SymmetricKey
    public let transcriptHash: Data
}

enum HandshakeCrypto {
    static let proofByteCount = 32

    /// SHA256(u32(len hello) || hello || u32(len challenge) || challenge) over the exact bytes sent.
    static func transcriptHash(hello: Data, challenge: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: lengthPrefix(hello.count))
        hasher.update(data: hello)
        hasher.update(data: lengthPrefix(challenge.count))
        hasher.update(data: challenge)
        return Data(hasher.finalize())
    }

    static func authKey(secret: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: Data(BridgeConstants.authSalt.utf8),
            info: Data(),
            outputByteCount: 32
        )
    }

    static func helperProof(authKey: SymmetricKey, transcript: Data) -> Data {
        let message = Data(BridgeConstants.helperProofLabel.utf8) + transcript
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: authKey))
    }

    static func phoneProofMessage(transcript: Data, helperProof: Data) -> Data {
        Data(BridgeConstants.phoneProofLabel.utf8) + transcript + helperProof
    }

    static func phoneProof(authKey: SymmetricKey, transcript: Data, helperProof: Data) -> Data {
        let message = phoneProofMessage(transcript: transcript, helperProof: helperProof)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: authKey))
    }

    static func sessionKeys(secret: Data, transcript: Data) -> SessionKeys {
        let ikm = SymmetricKey(data: secret)
        return SessionKeys(
            helperToPhone: HKDF<SHA256>.deriveKey(
                inputKeyMaterial: ikm,
                salt: transcript,
                info: Data(BridgeConstants.helperToPhoneInfo.utf8),
                outputByteCount: 32
            ),
            phoneToHelper: HKDF<SHA256>.deriveKey(
                inputKeyMaterial: ikm,
                salt: transcript,
                info: Data(BridgeConstants.phoneToHelperInfo.utf8),
                outputByteCount: 32
            ),
            transcriptHash: transcript
        )
    }

    static func lengthPrefix(_ count: Int) -> Data {
        let length = UInt32(count)
        return Data([
            UInt8(truncatingIfNeeded: length >> 24),
            UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 8),
            UInt8(truncatingIfNeeded: length)
        ])
    }

    static func encode(_ message: BridgeMessage) throws(HandshakeError) -> Data {
        do {
            return try BridgeMessageCoder.encode(message)
        } catch {
            throw .malformedMessage
        }
    }

    static func decode(_ payload: Data) throws(HandshakeError) -> BridgeMessage {
        do {
            return try BridgeMessageCoder.decode(payload)
        } catch {
            throw .malformedMessage
        }
    }
}

/// Helper side of the 4-frame handshake. The helper proves first, so a fake phone
/// never sees anything it could use, and the phone never proves to a fake helper.
public struct HelperHandshake: Sendable {
    public enum Phase: Sendable, Equatable {
        case start, awaitingChallenge, awaitingAuthOK, established, failed
    }

    public private(set) var stage: Phase = .start
    public private(set) var phoneID: UUID?
    public private(set) var phoneName: String?
    public private(set) var negotiatedVersion: Int?

    private let secret: Data
    private let helperID: UUID
    private let helperName: String
    private let protocols: [Int]
    private let nonce: Data
    private var helloBytes = Data()
    private var transcript = Data()
    private var sentProof = Data()

    public init(
        secret: Data,
        helperID: UUID,
        helperName: String,
        protocols: [Int] = BridgeConstants.supportedProtocols,
        nonce: Data? = nil
    ) {
        self.secret = secret
        self.helperID = helperID
        self.helperName = helperName
        self.protocols = protocols
        self.nonce = nonce ?? BridgeRandom.bytes(BridgeConstants.nonceByteCount)
    }

    /// Frame 1 (H→P).
    public mutating func makeHello() throws(HandshakeError) -> Data {
        guard stage == .start else { throw .invalidState }
        let hello = HelloMessage(protocols: protocols, helperID: helperID, helperName: helperName, nonce: nonce)
        helloBytes = try HandshakeCrypto.encode(.hello(hello))
        stage = .awaitingChallenge
        return helloBytes
    }

    /// Takes frame 2 (P→H) and returns frame 3, the helper's proof.
    public mutating func handleChallenge(_ payload: Data) throws(HandshakeError) -> Data {
        guard stage == .awaitingChallenge else { throw .invalidState }
        stage = .failed
        switch try HandshakeCrypto.decode(payload) {
        case .challenge(let challenge):
            guard protocols.contains(challenge.version) else {
                throw .unsupportedProtocol(offered: [challenge.version])
            }
            guard challenge.nonce.count == BridgeConstants.nonceByteCount else { throw .malformedMessage }
            phoneID = challenge.phoneID
            phoneName = challenge.phoneName
            negotiatedVersion = challenge.version
        case .error(let report):
            throw .rejectedByPeer(report.code)
        case let other:
            throw .unexpectedMessage(other.typeName)
        }
        transcript = HandshakeCrypto.transcriptHash(hello: helloBytes, challenge: payload)
        let authKey = HandshakeCrypto.authKey(secret: secret)
        sentProof = HandshakeCrypto.helperProof(authKey: authKey, transcript: transcript)
        let auth = try HandshakeCrypto.encode(.auth(ProofMessage(proof: sentProof)))
        stage = .awaitingAuthOK
        return auth
    }

    /// Takes frame 4 (P→H) and returns the session keys once the phone's proof verifies.
    public mutating func handleAuthOK(_ payload: Data) throws(HandshakeError) -> SessionKeys {
        guard stage == .awaitingAuthOK else { throw .invalidState }
        stage = .failed
        switch try HandshakeCrypto.decode(payload) {
        case .authOK(let message):
            let expected = HandshakeCrypto.phoneProofMessage(transcript: transcript, helperProof: sentProof)
            guard message.proof.count == HandshakeCrypto.proofByteCount,
                  HMAC<SHA256>.isValidAuthenticationCode(
                    message.proof,
                    authenticating: expected,
                    using: HandshakeCrypto.authKey(secret: secret)
                  )
            else { throw .authFailed }
        case .error(let report):
            throw .rejectedByPeer(report.code)
        case let other:
            throw .unexpectedMessage(other.typeName)
        }
        stage = .established
        return HandshakeCrypto.sessionKeys(secret: secret, transcript: transcript)
    }
}

/// Phone side of the handshake.
public struct PhoneHandshake: Sendable {
    public enum Phase: Sendable, Equatable {
        case awaitingHello, awaitingAuth, established, failed
    }

    public struct Completion: Sendable {
        /// Frame 4 (P→H) to send.
        public let reply: Data
        public let keys: SessionKeys
    }

    public private(set) var stage: Phase = .awaitingHello
    public private(set) var helperID: UUID?
    public private(set) var helperName: String?
    public private(set) var negotiatedVersion: Int?

    private let secret: Data
    private let phoneID: UUID
    private let phoneName: String
    private let protocols: [Int]
    private let nonce: Data
    private var helloBytes = Data()
    private var challengeBytes = Data()

    public init(
        secret: Data,
        phoneID: UUID,
        phoneName: String = BridgeConstants.defaultPhoneName,
        protocols: [Int] = BridgeConstants.supportedProtocols,
        nonce: Data? = nil
    ) {
        self.secret = secret
        self.phoneID = phoneID
        self.phoneName = phoneName
        self.protocols = protocols
        self.nonce = nonce ?? BridgeRandom.bytes(BridgeConstants.nonceByteCount)
    }

    /// Takes frame 1 (H→P) and returns frame 2. Picks the highest common protocol version.
    public mutating func handleHello(_ payload: Data) throws(HandshakeError) -> Data {
        guard stage == .awaitingHello else { throw .invalidState }
        stage = .failed
        let message = try HandshakeCrypto.decode(payload)
        guard case .hello(let hello) = message else { throw .unexpectedMessage(message.typeName) }
        guard hello.nonce.count == BridgeConstants.nonceByteCount else { throw .malformedMessage }
        guard let version = Set(hello.protocols).intersection(protocols).max() else {
            throw .unsupportedProtocol(offered: hello.protocols)
        }
        helperID = hello.helperID
        helperName = hello.helperName
        negotiatedVersion = version
        helloBytes = payload
        let challenge = ChallengeMessage(version: version, phoneID: phoneID, phoneName: phoneName, nonce: nonce)
        challengeBytes = try HandshakeCrypto.encode(.challenge(challenge))
        stage = .awaitingAuth
        return challengeBytes
    }

    /// Takes frame 3 (H→P). Only a valid helper proof gets the phone's proof back.
    public mutating func handleAuth(_ payload: Data) throws(HandshakeError) -> Completion {
        guard stage == .awaitingAuth else { throw .invalidState }
        stage = .failed
        let decoded = try HandshakeCrypto.decode(payload)
        guard case .auth(let message) = decoded else { throw .unexpectedMessage(decoded.typeName) }
        let transcript = HandshakeCrypto.transcriptHash(hello: helloBytes, challenge: challengeBytes)
        let authKey = HandshakeCrypto.authKey(secret: secret)
        let expected = Data(BridgeConstants.helperProofLabel.utf8) + transcript
        guard message.proof.count == HandshakeCrypto.proofByteCount,
              HMAC<SHA256>.isValidAuthenticationCode(message.proof, authenticating: expected, using: authKey)
        else { throw .authFailed }
        let proof = HandshakeCrypto.phoneProof(authKey: authKey, transcript: transcript, helperProof: message.proof)
        let reply = try HandshakeCrypto.encode(.authOK(ProofMessage(proof: proof)))
        stage = .established
        return Completion(reply: reply, keys: HandshakeCrypto.sessionKeys(secret: secret, transcript: transcript))
    }

    /// The `error` frame the phone sends before closing, if any. It never carries a proof.
    public static func rejectionPayload(for error: HandshakeError) -> Data? {
        let report: ErrorReport
        switch error {
        case .authFailed:
            report = ErrorReport(code: .authFailed)
        case .unsupportedProtocol:
            report = ErrorReport(code: .unsupportedProtocol, supported: BridgeConstants.supportedProtocols)
        default:
            return nil
        }
        return try? BridgeMessageCoder.encode(.error(report))
    }
}
