import CryptoKit
import Foundation
import Testing
@testable import TerminalBridgeKit

@Suite struct FrameAuthenticatorTests {
    private let helperToPhone = SymmetricKey(size: .bits256)
    private let phoneToHelper = SymmetricKey(size: .bits256)

    private func pair() -> (helper: FrameAuthenticator, phone: FrameAuthenticator) {
        (
            FrameAuthenticator(sendKey: helperToPhone, receiveKey: phoneToHelper),
            FrameAuthenticator(sendKey: phoneToHelper, receiveKey: helperToPhone)
        )
    }

    private func body(_ number: Int) -> Data {
        Data("{\"type\":\"ping\",\"n\":\(number)}".utf8)
    }

    @Test func opensFramesInOrder() throws {
        var (helper, phone) = pair()
        for number in 0..<3 {
            #expect(try phone.open(try helper.seal(body(number))) == body(number))
        }
        #expect(helper.sendCounter == 3)
        #expect(phone.receiveCounter == 3)
    }

    @Test func rejectsAReplay() throws {
        var (helper, phone) = pair()
        let first = try helper.seal(body(0))
        _ = try phone.open(first)
        #expect(throws: FrameAuthenticationError.badTag) { try phone.open(first) }
    }

    @Test func rejectsReordering() throws {
        var (helper, phone) = pair()
        let first = try helper.seal(body(0))
        let second = try helper.seal(body(1))
        #expect(throws: FrameAuthenticationError.badTag) { try phone.open(second) }
        #expect(throws: FrameAuthenticationError.alreadyFailed) { try phone.open(first) }
    }

    @Test func rejectsADroppedFrame() throws {
        var (helper, phone) = pair()
        _ = try helper.seal(body(0))
        let second = try helper.seal(body(1))
        #expect(throws: FrameAuthenticationError.badTag) { try phone.open(second) }
    }

    @Test func rejectsReflection() throws {
        var (helper, _) = pair()
        let sealed = try helper.seal(body(0))
        #expect(throws: FrameAuthenticationError.badTag) { try helper.open(sealed) }
    }

    @Test func rejectsTamperedTagOrBody() throws {
        var (helper, phone) = pair()
        var tamperedBody = try helper.seal(body(0))
        tamperedBody[tamperedBody.count - 2] ^= 0x01
        #expect(throws: FrameAuthenticationError.badTag) { try phone.open(tamperedBody) }

        var (helper2, phone2) = pair()
        var tamperedTag = try helper2.seal(body(0))
        tamperedTag[0] ^= 0x80
        #expect(throws: FrameAuthenticationError.badTag) { try phone2.open(tamperedTag) }
    }

    @Test func rejectsFramesWithoutABody() {
        var (_, phone) = pair()
        #expect(throws: FrameAuthenticationError.tooShort) { try phone.open(Data(count: 32)) }
        #expect(phone.hasFailed)
    }

    @Test func tagCoversTheCounterBigEndian() throws {
        var (helper, _) = pair()
        _ = try helper.seal(body(0))
        let sealed = try helper.seal(body(1))
        let expected = FrameAuthenticator.tag(for: body(1), counter: 1, key: helperToPhone)
        #expect(sealed.prefix(32) == expected)
        #expect(FrameAuthenticator.counterBytes(1) == Data([0, 0, 0, 0, 0, 0, 0, 1]))
    }
}
