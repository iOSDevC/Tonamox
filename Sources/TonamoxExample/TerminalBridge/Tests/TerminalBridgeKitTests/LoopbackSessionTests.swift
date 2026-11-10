import Foundation
import Testing
@testable import TerminalBridgeKit

/// Phone and helper sessions over a real 127.0.0.1 socket on an ephemeral port, in one process.
@Suite(.serialized) struct LoopbackSessionTests {
    private struct PhoneHarness {
        let session: PhoneBridgeSession
        let port: UInt16
        let events: EventLog
    }

    private func startPhone(clock: any BridgeClock = SystemBridgeClock()) async throws -> PhoneHarness {
        let session = PhoneBridgeSession(secret: TestSecrets.primary, phoneID: UUID(), port: 0, clock: clock)
        let events = EventLog.collecting(session.events)
        let port = try await session.start()
        return PhoneHarness(session: session, port: port, events: events)
    }

    private func makeHelper(
        secret: Data = TestSecrets.primary,
        injector: FakeInjector,
        recent: RecentWriteIDs = RecentWriteIDs(),
        recorder: RecordingRecorder? = nil,
        clock: any BridgeClock = SystemBridgeClock()
    ) -> HelperBridgeSession {
        HelperBridgeSession(
            secret: secret,
            helperID: UUID(),
            helperName: "tonamox-bridge 1 (test)",
            injector: injector,
            recentWrites: recent,
            recorder: recorder,
            clock: clock
        )
    }

    private func isConnected(_ phone: PhoneBridgeSession) async -> Bool {
        if case .connected = await phone.state { return true }
        return false
    }

    private func isListening(_ phone: PhoneBridgeSession) async -> Bool {
        if case .listening = await phone.state { return true }
        return false
    }

    @Test func everyFailedStartIsReported() async throws {
        let holder = LoopbackListener(port: 0)
        let port = try await holder.start()
        defer { holder.stop() }
        let session = PhoneBridgeSession(secret: TestSecrets.primary, phoneID: UUID(), port: port)
        let events = EventLog.collecting(session.events)
        let expected = LoopbackListenerError.portInUse(port)
        for _ in 0..<3 {
            await #expect(throws: expected) { try await session.start() }
        }
        let failure = PhoneBridgeEvent.stateChanged(.failed(.portInUse(port)))
        #expect(await eventually { events.all.filter { $0 == failure }.count == 3 })
    }

    @Test func stopDuringStartWinsAndReleasesThePort() async throws {
        let probe = LoopbackListener(port: 0)
        let port = try await probe.start()
        probe.stop()
        try await Task.sleep(for: .milliseconds(100))
        let session = PhoneBridgeSession(secret: TestSecrets.primary, phoneID: UUID(), port: port)
        await session.setAfterBindHookForTesting { await session.stop() }
        await #expect(throws: LoopbackListenerError.stopped) { try await session.start() }
        #expect(await session.state == .stopped)
        await session.setAfterBindHookForTesting(nil)

        try await Task.sleep(for: .milliseconds(100))
        let rebind = LoopbackListener(port: port)
        #expect(try await rebind.start() == port)
        rebind.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await session.start() == port)
        #expect(await session.state == .listening(port: port))
        await session.stop()
    }

    @Test func writeIsTypedOnceAndAcknowledged() async throws {
        let phone = try await startPhone()
        defer { Task { await phone.session.stop() } }
        let injector = FakeInjector()
        let recorder = RecordingRecorder()
        let helper = makeHelper(injector: injector, recorder: recorder)
        let channel = BridgeChannel.loopbackClient(port: phone.port)
        let run = Task { await helper.run(on: channel) }

        #expect(await eventually { await isConnected(phone.session) })
        #expect(await eventually { await phone.session.latestStatus?.target.state == .ready })

        let id = UUID()
        let ack = try await phone.session.write(text: "printf hello", id: id)
        #expect(ack.id == id)
        #expect(ack.result == .typed)
        #expect(ack.bytes == 12)
        #expect(ack.textSHA256 == "2189aff6492b39e6aa62f939b98cbc0cfaa1392da9df3a5ef73a7b0b369119d3")
        #expect(ack.verified)
        #expect(await injector.typedTexts == ["printf hello"])
        let records = await recorder.records
        #expect(records.map(\.outcome) == [.typed])
        #expect(records.first?.bytes == 12)

        channel.close()
        #expect(await run.value == .closedByPeer)
    }

    @Test func retryAfterReconnectIsAlreadyTyped() async throws {
        let phone = try await startPhone()
        defer { Task { await phone.session.stop() } }
        let injector = FakeInjector()
        let recent = RecentWriteIDs()
        let id = UUID()

        let firstChannel = BridgeChannel.loopbackClient(port: phone.port)
        let firstRun = Task { await makeHelper(injector: injector, recent: recent).run(on: firstChannel) }
        #expect(await eventually { await isConnected(phone.session) })
        #expect(try await phone.session.write(text: "printf once", id: id).result == .typed)

        firstChannel.close()
        #expect(await firstRun.value == .closedByPeer)
        #expect(await eventually { phone.events.contains(.disconnected(.closedByPeer)) })
        #expect(await eventually { await isListening(phone.session) })
        await #expect(throws: PhoneWriteError.notConnected) {
            try await phone.session.write(text: "printf once", id: id)
        }

        let secondChannel = BridgeChannel.loopbackClient(port: phone.port)
        let secondRun = Task { await makeHelper(injector: injector, recent: recent).run(on: secondChannel) }
        #expect(await eventually { await isConnected(phone.session) })
        let retry = try await phone.session.write(text: "printf once", id: id)
        #expect(retry.result == .alreadyTyped)
        #expect(await injector.typedTexts == ["printf once"])

        secondChannel.close()
        _ = await secondRun.value
    }

    @Test func helperWithTheWrongSecretIsRejected() async throws {
        let phone = try await startPhone()
        defer { Task { await phone.session.stop() } }
        let injector = FakeInjector()
        let helper = makeHelper(secret: TestSecrets.other, injector: injector)

        let end = await helper.run(on: BridgeChannel.loopbackClient(port: phone.port))
        #expect(end == .rejectedByPhone(.authFailed))
        #expect(await eventually { await phone.session.rejectedAttempts == 1 })
        #expect(phone.events.contains(.rejectedAttempt(total: 1)))
        #expect(await isListening(phone.session))
        #expect(await injector.typedTexts.isEmpty)
    }

    @Test func phoneDropsASilentHelperAfterTwentyFiveSeconds() async throws {
        let clock = ManualClock()
        let phone = try await startPhone(clock: clock)
        defer { Task { await phone.session.stop() } }
        let channel = BridgeChannel.loopbackClient(port: phone.port)
        let run = Task { await makeHelper(injector: FakeInjector()).run(on: channel) }

        #expect(await eventually { await isConnected(phone.session) })
        // The first status frame refreshes lastTraffic; if it lands after advance(24) the watchdog never fires.
        #expect(await eventually { await phone.session.latestStatus != nil })
        // Only the heartbeat watchdog sleeps once the handshake watchdog is cancelled.
        #expect(await eventually { clock.sleeperCount == 1 })
        clock.advance(by: .seconds(24))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await isConnected(phone.session))

        clock.advance(by: .seconds(2))
        #expect(await eventually { phone.events.contains(.disconnected(.heartbeatTimeout)) })
        #expect(await eventually { await isListening(phone.session) })
        #expect(await run.value == .closedByPeer)
    }

    @Test func newerHelperReplacesTheActiveOne() async throws {
        let phone = try await startPhone()
        defer { Task { await phone.session.stop() } }
        let firstRun = Task { await makeHelper(injector: FakeInjector()).run(on: .loopbackClient(port: phone.port)) }
        #expect(await eventually { await isConnected(phone.session) })

        let injector = FakeInjector()
        let secondChannel = BridgeChannel.loopbackClient(port: phone.port)
        let secondRun = Task { await makeHelper(injector: injector).run(on: secondChannel) }
        #expect(await firstRun.value == .closedByPeer)
        #expect(phone.events.contains(.disconnected(.replaced)))
        #expect(await isConnected(phone.session))
        #expect(try await phone.session.write(text: "true", id: UUID()).result == .typed)
        #expect(await injector.typedTexts == ["true"])

        secondChannel.close()
        _ = await secondRun.value
    }

    @Test func phoneChecksPolicyAndWarningsBeforeSending() async throws {
        let phone = try await startPhone()
        defer { Task { await phone.session.stop() } }
        await #expect(throws: PhoneWriteError.policy([.disallowedCharacter(scalar: 0x0A, offset: 2)])) {
            try await phone.session.write(text: "ls\n", id: UUID())
        }
        await #expect(throws: PhoneWriteError.unacknowledgedWarnings([.sudo])) {
            try await phone.session.write(text: "sudo ls", id: UUID())
        }
        await #expect(throws: PhoneWriteError.notConnected) {
            try await phone.session.write(text: "sudo ls", id: UUID(), acknowledgedWarnings: ["sudo"])
        }
    }

    @Test func helperRefusalsReachTheWriter() async throws {
        let phone = try await startPhone()
        defer { Task { await phone.session.stop() } }
        let injector = FakeInjector()
        await injector.setOutcome(.refused(.promptNotIdle, detail: "[yn]?"))
        let channel = BridgeChannel.loopbackClient(port: phone.port)
        let run = Task { await makeHelper(injector: injector).run(on: channel) }
        #expect(await eventually { await isConnected(phone.session) })

        let id = UUID()
        await #expect(throws: PhoneWriteError.rejected(ErrorReport(id: id, code: .promptNotIdle, detail: "[yn]?"))) {
            try await phone.session.write(text: "printf x", id: id)
        }
        channel.close()
        _ = await run.value
    }

    @Test func phoneAnswersPingsAndUnknownTypes() async throws {
        let phone = try await startPhone()
        defer { Task { await phone.session.stop() } }
        let channel = BridgeChannel.loopbackClient(port: phone.port)
        defer { channel.close() }
        try await channel.start()
        var handshake = HelperHandshake(secret: TestSecrets.primary, helperID: UUID(), helperName: "raw helper")
        try await channel.sendFrame(try handshake.makeHello())
        try await channel.sendFrame(try handshake.handleChallenge(try await channel.receiveFrame()))
        let keys = try handshake.handleAuthOK(try await channel.receiveFrame())
        try await channel.enableAuthentication(.helperSide(keys))

        try await channel.send(.unrecognized(type: "futureThing"))
        guard case .error(let report) = try await channel.receive() else {
            Issue.record("expected an error frame")
            return
        }
        #expect(report.code == .unsupportedMessage)
        #expect(report.detail == "futureThing")

        try await channel.send(.ping(7))
        #expect(try await channel.receive() == .pong(7))
        #expect(await isConnected(phone.session))
    }

    @Test func helperPingsAndGivesUpWithoutTraffic() async throws {
        let clock = ManualClock()
        let listener = LoopbackListener(port: 0)
        let port = try await listener.start()
        defer { listener.stop() }
        let helper = makeHelper(injector: FakeInjector(), clock: clock)
        let run = Task { await helper.run(on: .loopbackClient(port: port)) }

        var accepted = listener.connections.makeAsyncIterator()
        let phoneSide = try #require(await accepted.next())
        defer { phoneSide.close() }
        try await phoneSide.start()
        var handshake = PhoneHandshake(secret: TestSecrets.primary, phoneID: UUID())
        try await phoneSide.sendFrame(try handshake.handleHello(try await phoneSide.receiveFrame()))
        let completion = try handshake.handleAuth(try await phoneSide.receiveFrame())
        try await phoneSide.sendFrame(completion.reply)
        try await phoneSide.enableAuthentication(.phoneSide(completion.keys))
        guard case .status = try await phoneSide.receive() else {
            Issue.record("expected status first")
            return
        }

        // Status poll and heartbeat sleepers.
        #expect(await eventually { clock.sleeperCount == 2 })
        clock.advance(by: .seconds(10))
        #expect(try await phoneSide.receive() == .ping(1))
        try await phoneSide.send(.pong(1))
        #expect(await eventually { await helper.lastTrafficForTesting == .seconds(10) })

        #expect(await eventually { clock.sleeperCount == 2 })
        clock.advance(by: .seconds(10))
        #expect(try await phoneSide.receive() == .ping(2))

        #expect(await eventually { clock.sleeperCount == 2 })
        clock.advance(by: .seconds(10))
        // 30 s with traffic at 10 s: still alive, thanks to the pong.
        #expect(try await phoneSide.receive() == .ping(3))

        #expect(await eventually { clock.sleeperCount == 2 })
        clock.advance(by: .seconds(10))
        #expect(await run.value == .heartbeatTimeout)
    }
}
