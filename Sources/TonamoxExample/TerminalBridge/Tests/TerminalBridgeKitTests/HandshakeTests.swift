import CryptoKit
import Foundation
import Testing
@testable import TerminalBridgeKit

@Suite struct HandshakeTests {
    private let helperID = UUID()
    private let phoneID = UUID()

    private func makeHelper(secret: Data = TestSecrets.primary, protocols: [Int] = [1]) -> HelperHandshake {
        HelperHandshake(secret: secret, helperID: helperID, helperName: "tonamox-bridge 1 (test)", protocols: protocols)
    }

    private func makePhone(secret: Data = TestSecrets.primary) -> PhoneHandshake {
        PhoneHandshake(secret: secret, phoneID: phoneID)
    }

    @Test func mutualAuthenticationDerivesMatchingKeys() throws {
        var helper = makeHelper()
        var phone = makePhone()
        let challenge = try phone.handleHello(try helper.makeHello())
        let auth = try helper.handleChallenge(challenge)
        let completion = try phone.handleAuth(auth)
        let helperKeys = try helper.handleAuthOK(completion.reply)

        #expect(helper.stage == .established)
        #expect(phone.stage == .established)
        #expect(helper.phoneID == phoneID)
        #expect(phone.helperID == helperID)
        #expect(helperKeys.transcriptHash == completion.keys.transcriptHash)

        var helperSide = FrameAuthenticator.helperSide(helperKeys)
        var phoneSide = FrameAuthenticator.phoneSide(completion.keys)
        let body = Data("{\"type\":\"ping\",\"n\":1}".utf8)
        #expect(try phoneSide.open(try helperSide.seal(body)) == body)
        #expect(try helperSide.open(try phoneSide.seal(body)) == body)
    }

    @Test func directionKeysDiffer() throws {
        var helper = makeHelper()
        var phone = makePhone()
        let completion = try phone.handleAuth(try helper.handleChallenge(try phone.handleHello(try helper.makeHello())))
        let keys = completion.keys
        let h2p = keys.helperToPhone.withUnsafeBytes { Data($0) }
        let p2h = keys.phoneToHelper.withUnsafeBytes { Data($0) }
        #expect(h2p != p2h)
    }

    @Test func phoneRejectsAHelperWithTheWrongSecretWithoutRevealingAProof() throws {
        var helper = makeHelper(secret: TestSecrets.other)
        var phone = makePhone()
        let auth = try helper.handleChallenge(try phone.handleHello(try helper.makeHello()))
        #expect(throws: HandshakeError.authFailed) { try phone.handleAuth(auth) }
        #expect(phone.stage == .failed)

        let reply = try #require(PhoneHandshake.rejectionPayload(for: .authFailed))
        #expect(String(bytes: reply, encoding: .utf8)?.contains("proof") == false)
        guard case .error(let report) = try BridgeMessageCoder.decode(reply) else {
            Issue.record("expected an error frame")
            return
        }
        #expect(report.code == .authFailed)
        #expect(throws: HandshakeError.rejectedByPeer(.authFailed)) { try helper.handleAuthOK(reply) }
    }

    @Test func helperRejectsAFakePhoneProof() throws {
        var helper = makeHelper()
        var phone = makePhone()
        _ = try helper.handleChallenge(try phone.handleHello(try helper.makeHello()))
        let forged = try BridgeMessageCoder.encode(.authOK(ProofMessage(proof: Data(repeating: 7, count: 32))))
        #expect(throws: HandshakeError.authFailed) { try helper.handleAuthOK(forged) }
        #expect(helper.stage == .failed)
    }

    @Test func aPhoneWithTheWrongSecretNeverProves() throws {
        var helper = makeHelper()
        var phone = makePhone(secret: TestSecrets.other)
        let auth = try helper.handleChallenge(try phone.handleHello(try helper.makeHello()))
        #expect(throws: HandshakeError.authFailed) { try phone.handleAuth(auth) }
    }

    @Test func unsupportedProtocolIsRefused() throws {
        var helper = makeHelper(protocols: [2])
        var phone = makePhone()
        let hello = try helper.makeHello()
        #expect(throws: HandshakeError.unsupportedProtocol(offered: [2])) { try phone.handleHello(hello) }
        let reply = try #require(PhoneHandshake.rejectionPayload(for: .unsupportedProtocol(offered: [2])))
        guard case .error(let report) = try BridgeMessageCoder.decode(reply) else {
            Issue.record("expected an error frame")
            return
        }
        #expect(report.code == .unsupportedProtocol)
        #expect(report.supported == [1])
        #expect(throws: HandshakeError.rejectedByPeer(.unsupportedProtocol)) { try helper.handleChallenge(reply) }
    }

    @Test func picksTheHighestCommonVersion() throws {
        var helper = makeHelper(protocols: [1, 2, 3])
        var phone = PhoneHandshake(secret: TestSecrets.primary, phoneID: phoneID, protocols: [1, 2])
        _ = try phone.handleHello(try helper.makeHello())
        #expect(phone.negotiatedVersion == 2)
    }

    @Test func tamperedHelloBreaksTheTranscript() throws {
        var helper = makeHelper()
        var phone = makePhone()
        let hello = try helper.makeHello()
        let original = try #require(String(bytes: hello, encoding: .utf8))
        let tampered = Data(original.replacingOccurrences(of: "(test)", with: "(evil)").utf8)
        #expect(tampered != hello)
        let challenge = try phone.handleHello(tampered)
        #expect(HandshakeCrypto.transcriptHash(hello: hello, challenge: challenge)
            != HandshakeCrypto.transcriptHash(hello: tampered, challenge: challenge))
        let auth = try helper.handleChallenge(challenge)
        #expect(throws: HandshakeError.authFailed) { try phone.handleAuth(auth) }
    }

    @Test func outOfOrderCallsAreInvalid() throws {
        var helper = makeHelper()
        #expect(throws: HandshakeError.invalidState) { try helper.handleChallenge(Data("{}".utf8)) }
        var phone = makePhone()
        #expect(throws: HandshakeError.invalidState) { try phone.handleAuth(Data("{}".utf8)) }
        #expect(throws: HandshakeError.malformedMessage) { try phone.handleHello(Data("not json".utf8)) }
    }

    @Test func helloWithAShortNonceIsMalformed() throws {
        var phone = makePhone()
        let hello = HelloMessage(protocols: [1], helperID: helperID, helperName: "x", nonce: Data(count: 8))
        #expect(throws: HandshakeError.malformedMessage) {
            try phone.handleHello(try BridgeMessageCoder.encode(.hello(hello)))
        }
    }
}
