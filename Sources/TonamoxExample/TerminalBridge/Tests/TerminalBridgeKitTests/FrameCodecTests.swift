import Foundation
import Testing
@testable import TerminalBridgeKit

@Suite struct FrameCodecTests {
    private func singleByte(_ byte: UInt8) -> Data {
        Data([byte])
    }

    @Test func roundTripsOneFrame() throws {
        let payload = Data("{\"type\":\"ping\",\"n\":1}".utf8)
        let framed = try FrameCodec.encode(payload)
        #expect(framed.prefix(4) == Data([0, 0, 0, UInt8(payload.count)]))
        var reader = FrameReader()
        #expect(try reader.feed(framed) == [payload])
        #expect(reader.bufferedByteCount == 0)
    }

    @Test func reassemblesOneByteChunks() throws {
        let payload = Data(repeating: 0x41, count: 300)
        let framed = try FrameCodec.encode(payload)
        var reader = FrameReader()
        var frames: [Data] = []
        for byte in framed {
            frames += try reader.feed(singleByte(byte))
        }
        #expect(frames == [payload])
    }

    @Test func splitsThreeFramesInOneRead() throws {
        let payloads = [Data("a".utf8), Data("bb".utf8), Data("ccc".utf8)]
        var stream = Data()
        for payload in payloads {
            stream += try FrameCodec.encode(payload)
        }
        var reader = FrameReader()
        #expect(try reader.feed(stream) == payloads)
    }

    @Test func waitsForAnIncompleteHeaderOrBody() throws {
        var reader = FrameReader()
        #expect(try reader.feed(Data([0, 0])) == [])
        #expect(try reader.feed(Data([0, 3, 0x61])) == [])
        #expect(try reader.feed(Data([0x62, 0x63])) == [Data("abc".utf8)])
    }

    @Test func rejectsZeroLength() {
        var reader = FrameReader()
        #expect(throws: FrameError.emptyFrame) { try reader.feed(Data([0, 0, 0, 0])) }
    }

    @Test func rejectsLengthAboveTheLimit() {
        var reader = FrameReader()
        let length = BridgeConstants.maxFrameBytes + 1
        let header = Data([0, UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
        #expect(throws: FrameError.frameTooLarge(length: 16_385)) { try reader.feed(header) }
    }

    @Test func acceptsExactlyTheLimit() throws {
        let payload = Data(repeating: 0x7A, count: BridgeConstants.maxFrameBytes)
        var reader = FrameReader()
        #expect(try reader.feed(try FrameCodec.encode(payload)) == [payload])
    }

    @Test func errorsAreSticky() {
        var reader = FrameReader()
        #expect(throws: FrameError.emptyFrame) { try reader.feed(Data([0, 0, 0, 0])) }
        #expect(throws: FrameError.emptyFrame) { try reader.feed(Data([0, 0, 0, 1, 0x61])) }
    }

    @Test func encoderRejectsEmptyAndOversizedPayloads() {
        #expect(throws: FrameError.emptyFrame) { try FrameCodec.encode(Data()) }
        let oversized = Data(repeating: 0, count: BridgeConstants.maxFrameBytes + 1)
        #expect(throws: FrameError.frameTooLarge(length: 16_385)) { try FrameCodec.encode(oversized) }
    }

    @Test func honoursBytesBufferedBeforeTheReader() throws {
        let framed = try FrameCodec.encode(Data("x".utf8))
        var reader = FrameReader(bufferedBytes: framed.prefix(3))
        #expect(try reader.feed(framed.suffix(from: 3)) == [Data("x".utf8)])
    }
}
