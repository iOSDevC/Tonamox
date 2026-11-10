import Foundation
import Testing
@testable import TerminalBridgeKit

@Suite struct BridgeMessageCodingTests {
    private static let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    private static let nonce = Data(repeating: 0xAB, count: 32)

    static let samples: [BridgeMessage] = [
        .hello(HelloMessage(protocols: [1], helperID: id, helperName: "tonamox-bridge 1 (mac)", nonce: nonce)),
        .challenge(ChallengeMessage(version: 1, phoneID: id, phoneName: "Tonamox Terminal", nonce: nonce)),
        .auth(ProofMessage(proof: nonce)),
        .authOK(ProofMessage(proof: nonce)),
        .status(StatusMessage(
            target: TargetStatus(session: "tonamox", window: "0", state: .foregroundNotShell, foreground: "vim"),
            hint: "screen -S tonamox"
        )),
        .write(WriteRequest(id: id, text: "ls -la", acknowledgedWarnings: ["sudo"])),
        .ack(WriteAck(id: id, result: .alreadyTyped, bytes: 6, textSHA256: "ab", warnings: [], verified: true)),
        .error(ErrorReport(id: id, code: .unacknowledgedWarnings, detail: "sudo", warnings: ["sudo"])),
        .error(ErrorReport(code: .unsupportedProtocol, supported: [1])),
        .ping(3),
        .pong(3)
    ]

    private func json(_ message: BridgeMessage) throws -> [String: Any] {
        let data = try BridgeMessageCoder.encode(message)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test(arguments: BridgeMessageCodingTests.samples)
    func roundTrips(_ message: BridgeMessage) throws {
        #expect(try BridgeMessageCoder.decode(try BridgeMessageCoder.encode(message)) == message)
        #expect(try json(message)["type"] as? String == message.typeName)
    }

    @Test func unknownTypeIsKept() throws {
        let decoded = try BridgeMessageCoder.decode(Data(#"{"type":"futureThing","x":1}"#.utf8))
        #expect(decoded == .unrecognized(type: "futureThing"))
    }

    @Test func unknownIntentKindKeepsTheText() throws {
        let raw = #"{"type":"write","id":"\#(Self.id.uuidString)","#
            + #""intent":{"kind":"task","name":"git.status"},"text":"x","acknowledgedWarnings":[]}"#
        guard case .write(let request) = try BridgeMessageCoder.decode(Data(raw.utf8)) else {
            Issue.record("expected a write")
            return
        }
        #expect(request.intent == .unrecognized(kind: "task"))
        #expect(request.text == "x")
    }

    @Test func extraFieldsAreIgnored() throws {
        let raw = #"{"type":"ping","n":9,"future":{"a":[1,2]}}"#
        #expect(try BridgeMessageCoder.decode(Data(raw.utf8)) == .ping(9))
    }

    @Test func unknownCodesAndStatesAreKept() throws {
        let raw = #"{"type":"error","code":"quotaExceeded"}"#
        guard case .error(let report) = try BridgeMessageCoder.decode(Data(raw.utf8)) else {
            Issue.record("expected an error")
            return
        }
        #expect(report.code == .unrecognized("quotaExceeded"))
        #expect(TargetState(wireValue: "sleeping") == .unrecognized("sleeping"))
        #expect(TargetState.unrecognized("sleeping").refusalCode == .screenUnavailable)
        #expect(TargetState.ready.refusalCode == nil)
    }

    @Test func wireNamesMatchTheProtocol() throws {
        let write = try json(.write(WriteRequest(id: Self.id, text: "ls")))
        #expect(write["seq"] == nil)
        #expect((write["intent"] as? [String: Any])?["kind"] as? String == "text")
        #expect(write["id"] as? String == Self.id.uuidString)

        let ack = try json(.ack(WriteAck(
            id: Self.id, result: .typed, bytes: 2, textSHA256: "ff", warnings: [], verified: false
        )))
        #expect(ack["sha256"] as? String == "ff")
        #expect(ack["result"] as? String == "typed")

        let challenge = try json(.challenge(ChallengeMessage(
            version: 1, phoneID: Self.id, phoneName: "p", nonce: Self.nonce
        )))
        #expect(challenge["protocol"] as? Int == 1)
        #expect(challenge["nonce"] as? String == Self.nonce.base64EncodedString())

        let status = try json(.status(StatusMessage(target: TargetStatus(session: "s", window: "0", state: .ready))))
        #expect(status["capabilities"] as? [String] == ["write.text"])
        #expect(status["maxTextBytes"] as? Int == 512)
    }

    @Test func statusHintNamesTheMissingSession() {
        let missing = TargetStatus(session: "tonamox", window: "0", state: .sessionMissing)
        #expect(StatusMessage.describing(missing).hint == "screen -S tonamox")
        #expect(StatusMessage.describing(TargetStatus(session: "tonamox", window: "0", state: .ready)).hint == nil)
    }

    @Test func equalMessagesEncodeToEqualBytes() throws {
        let target = TargetStatus(session: "s", window: "0", state: .ready)
        let message = BridgeMessage.status(StatusMessage(target: target))
        #expect(try BridgeMessageCoder.encode(message) == BridgeMessageCoder.encode(message))
    }
}
