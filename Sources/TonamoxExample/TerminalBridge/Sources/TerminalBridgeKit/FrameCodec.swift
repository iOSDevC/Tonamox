import Foundation

public enum FrameError: Error, Equatable, Sendable {
    case emptyFrame
    case frameTooLarge(length: Int)
}

/// Length-prefixed framing: u32 big-endian L (1...maxFrameBytes), then L bytes.
public enum FrameCodec {
    public static let headerByteCount = 4

    public static func encode(
        _ payload: Data,
        maxFrameBytes: Int = BridgeConstants.maxFrameBytes
    ) throws(FrameError) -> Data {
        guard !payload.isEmpty else { throw .emptyFrame }
        guard payload.count <= maxFrameBytes else { throw .frameTooLarge(length: payload.count) }
        var framed = Data(capacity: headerByteCount + payload.count)
        let length = UInt32(payload.count)
        framed.append(UInt8(truncatingIfNeeded: length >> 24))
        framed.append(UInt8(truncatingIfNeeded: length >> 16))
        framed.append(UInt8(truncatingIfNeeded: length >> 8))
        framed.append(UInt8(truncatingIfNeeded: length))
        framed.append(payload)
        return framed
    }
}

/// Incremental decoder: accepts arbitrary chunks, yields whole frames, rejects bad lengths.
public struct FrameReader: Sendable {
    public let maxFrameBytes: Int
    private var buffer: Data
    private var failure: FrameError?

    public init(maxFrameBytes: Int = BridgeConstants.maxFrameBytes, bufferedBytes: Data = Data()) {
        self.maxFrameBytes = maxFrameBytes
        self.buffer = bufferedBytes
    }

    public var bufferedByteCount: Int { buffer.count }

    public mutating func append(_ chunk: Data) {
        buffer.append(chunk)
    }

    /// The next complete frame body, or nil when more bytes are needed. Errors are sticky.
    public mutating func nextFrame() throws(FrameError) -> Data? {
        if let failure { throw failure }
        guard buffer.count >= FrameCodec.headerByteCount else { return nil }
        let start = buffer.startIndex
        let length = Int(buffer[start]) << 24 | Int(buffer[start + 1]) << 16
            | Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
        guard length > 0 else { return try fail(.emptyFrame) }
        guard length <= maxFrameBytes else { return try fail(.frameTooLarge(length: length)) }
        let bodyStart = start + FrameCodec.headerByteCount
        guard buffer.count - FrameCodec.headerByteCount >= length else { return nil }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
        buffer.removeSubrange(start..<(bodyStart + length))
        return body
    }

    /// Appends `chunk` and drains every complete frame.
    public mutating func feed(_ chunk: Data) throws(FrameError) -> [Data] {
        append(chunk)
        var frames: [Data] = []
        while let frame = try nextFrame() {
            frames.append(frame)
        }
        return frames
    }

    private mutating func fail(_ error: FrameError) throws(FrameError) -> Data? {
        failure = error
        throw error
    }
}
