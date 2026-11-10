#if os(macOS)
import Foundation
import Network
import Synchronization

public enum USBMuxError: Error, Equatable, Sendable {
    case unavailable(String)
    case closed
    case codec(USBMuxCodecError)
    /// usbmuxd answered Result != 0: 2 BADDEV, 3 CONNREFUSED (app not listening), 6 BADVERSION.
    case result(Int)
    case deviceNotAttached(String)
    case unexpectedReply(String)

    public var message: String {
        switch self {
        case .unavailable(let reason): "usbmuxd no responde: \(reason)"
        case .closed: "usbmuxd cerró la conexión."
        case .codec(let error): "Respuesta de usbmuxd ilegible: \(error)"
        case .result(3): "El iPhone rechazó la conexión: abre Tonamox Terminal en primer plano."
        case .result(2): "usbmuxd ya no conoce el dispositivo."
        case .result(let number): "usbmuxd respondió Result \(number)."
        case .deviceNotAttached(let udid): "El iPhone \(udid) no está conectado por USB."
        case .unexpectedReply(let type): "Respuesta inesperada de usbmuxd: \(type)"
        }
    }
}

/// A value delivered once and awaited once; finishing before the wait is fine.
final class Completion<Value: Sendable>: Sendable {
    private enum Delivery {
        case waiting(CheckedContinuation<Value, any Error>?)
        case finished(Result<Value, any Error>)
    }

    private let slot = Mutex<Delivery>(.waiting(nil))

    func finish(_ result: Result<Value, any Error>) {
        let continuation: CheckedContinuation<Value, any Error>? = slot.withLock { delivery in
            guard case .waiting(let continuation) = delivery else { return nil }
            delivery = .finished(result)
            return continuation
        }
        continuation?.resume(with: result)
    }

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
            let ready: Result<Value, any Error>? = slot.withLock { delivery in
                switch delivery {
                case .waiting:
                    delivery = .waiting(continuation)
                    return nil
                case .finished(let result):
                    return result
                }
            }
            if let ready { continuation.resume(with: ready) }
        }
    }
}

/// One connection to usbmuxd. After a successful Connect the same connection is the raw tunnel.
final class USBMuxSocket: Sendable {
    let connection: NWConnection
    private let queue = DispatchQueue(label: "TerminalBridgeHelper.USBMuxSocket")

    init(socketPath: String) {
        connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
    }

    func open() async throws {
        let ready = Completion<Void>()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.finish(.success(()))
            case .waiting(let error), .failed(let error):
                ready.finish(.failure(USBMuxError.unavailable(error.debugDescription)))
            case .cancelled:
                ready.finish(.failure(USBMuxError.closed))
            default:
                break
            }
        }
        connection.start(queue: queue)
        do {
            try await ready.value()
        } catch {
            connection.cancel()
            throw error
        }
    }

    func send(_ packet: Data) async throws {
        let sent = Completion<Void>()
        connection.send(content: packet, completion: .contentProcessed { error in
            if let error {
                sent.finish(.failure(USBMuxError.unavailable(error.debugDescription)))
            } else {
                sent.finish(.success(()))
            }
        })
        try await sent.value()
    }

    /// Reads exactly `count` bytes so nothing after a Connect reply is consumed from the tunnel.
    func receiveExactly(_ count: Int) async throws -> Data {
        var collected = Data()
        while collected.count < count {
            collected.append(try await receiveChunk(upTo: count - collected.count))
        }
        return collected
    }

    private func receiveChunk(upTo count: Int) async throws -> Data {
        let chunk = Completion<Data>()
        connection.receive(minimumIncompleteLength: 1, maximumLength: count) { content, _, isComplete, error in
            if let content, !content.isEmpty {
                chunk.finish(.success(content))
            } else if let error {
                chunk.finish(.failure(USBMuxError.unavailable(error.debugDescription)))
            } else if isComplete {
                chunk.finish(.failure(USBMuxError.closed))
            } else {
                chunk.finish(.success(Data()))
            }
        }
        return try await chunk.value()
    }

    func receiveReply() async throws -> USBMuxReply {
        do {
            let header = try USBMuxCodec.decodeHeader(try await receiveExactly(USBMuxCodec.headerByteCount))
            return try USBMuxCodec.decodeBody(try await receiveExactly(header.bodyLength))
        } catch let error as USBMuxCodecError {
            throw USBMuxError.codec(error)
        }
    }

    func cancel() {
        connection.cancel()
    }
}

/// Talks to usbmuxd over its Unix socket: Listen keeps the USB device map current,
/// ListDevices answers `status --usb`, Connect opens a tunnel to the phone's port.
public actor USBMuxClient {
    public static let defaultSocketPath = "/var/run/usbmuxd"

    private let socketPath: String
    private var nextTag: UInt32 = 0
    private var usbDevices: [String: Int] = [:]
    private var listener: Task<Void, Never>?
    private var listenerSocket: USBMuxSocket?

    public init(socketPath: String = USBMuxClient.defaultSocketPath) {
        self.socketPath = socketPath
    }

    public func listDevices() async throws -> [USBMuxDevice] {
        let socket = USBMuxSocket(socketPath: socketPath)
        defer { socket.cancel() }
        try await socket.open()
        try await socket.send(try USBMuxCodec.listDevices(tag: takeTag()))
        let reply = try await socket.receiveReply()
        guard case .deviceList(let devices) = reply else { throw USBMuxError.unexpectedReply("\(reply)") }
        return devices
    }

    /// A tunnel to `port` on the device. The returned connection is already `.ready`.
    public func connect(deviceID: Int, port: UInt16) async throws -> NWConnection {
        let socket = USBMuxSocket(socketPath: socketPath)
        do {
            try await socket.open()
            try await socket.send(try USBMuxCodec.connect(deviceID: deviceID, port: port, tag: takeTag()))
            let reply = try await socket.receiveReply()
            guard case .result(let number) = reply else { throw USBMuxError.unexpectedReply("\(reply)") }
            guard number == 0 else { throw USBMuxError.result(number) }
        } catch {
            socket.cancel()
            if case USBMuxError.result(2) = error { forget(deviceID: deviceID) }
            throw error
        }
        return socket.connection
    }

    /// The DeviceID of `udid` attached over USB, waiting up to `timeout` for Listen events.
    public func usbDeviceID(for udid: String, timeout: Duration) async throws -> Int {
        startListeningIfNeeded()
        let key = USBMuxDevice.normalizedUDID(udid)
        let deadline = ContinuousClock.now + timeout
        while usbDevices[key] == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let deviceID = usbDevices[key] else { throw USBMuxError.deviceNotAttached(udid) }
        return deviceID
    }

    public func stop() {
        listener?.cancel()
        listenerSocket?.cancel()
        listener = nil
        listenerSocket = nil
    }

    var knownUSBDevices: [String: Int] {
        usbDevices
    }

    private func takeTag() -> UInt32 {
        nextTag &+= 1
        return nextTag
    }

    private func startListeningIfNeeded() {
        guard listener == nil else { return }
        let socket = USBMuxSocket(socketPath: socketPath)
        let tag = takeTag()
        listenerSocket = socket
        listener = Task { await self.listen(on: socket, tag: tag) }
    }

    private func listen(on socket: USBMuxSocket, tag: UInt32) async {
        defer { listenerEnded(socket) }
        do {
            try await socket.open()
            try await socket.send(try USBMuxCodec.listen(tag: tag))
            guard try await socket.receiveReply() == .result(0) else { return }
            while !Task.isCancelled {
                apply(try await socket.receiveReply())
            }
        } catch {
            return
        }
    }

    private func apply(_ reply: USBMuxReply) {
        switch reply {
        case .attached(let device) where device.isUSB:
            usbDevices[USBMuxDevice.normalizedUDID(device.serialNumber)] = device.deviceID
        case .detached(let deviceID):
            forget(deviceID: deviceID)
        default:
            break
        }
    }

    private func forget(deviceID: Int) {
        usbDevices = usbDevices.filter { $0.value != deviceID }
    }

    /// A dropped Listen socket (usbmuxd restart) is reopened by the next dial.
    private func listenerEnded(_ socket: USBMuxSocket) {
        socket.cancel()
        guard listenerSocket === socket else { return }
        listener = nil
        listenerSocket = nil
        usbDevices = [:]
    }
}
#endif
