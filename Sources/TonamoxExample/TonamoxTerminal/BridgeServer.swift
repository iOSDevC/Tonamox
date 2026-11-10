import Combine
import Foundation
import os
import TerminalBridgeKit
import UIKit

/// Thin main-actor layer over the Kit's PhoneBridgeSession: listens on 127.0.0.1 while the app is active,
/// publishes the connection and screen status, and forwards writes.
final class BridgeServer: ObservableObject {
    @Published private(set) var connectionState: PhoneConnectionState = .stopped
    @Published private(set) var latestStatus: StatusMessage?
    @Published private(set) var rejectedAttempts = 0
    @Published private(set) var helperName: String?
    @Published private(set) var lastConnectedAt: Date?
    @Published private(set) var currentCode: PairingCode
    @Published private(set) var storageProblem: String?
    /// When a helper last failed the proof; the indicator turns red only for a while after it.
    @Published private(set) var lastRejectedAt: Date?
    /// Set after a write was typed and cleared once the helper reports an idle prompt again.
    @Published private(set) var pendingTypedTarget: String?
    /// True once the automatic listener retries are used up; the UI then offers "Reintentar".
    @Published private(set) var retriesExhausted = false

    static let maxStartRetries = 5
    static let startRetryDelay: Duration = .seconds(2)
    static let rejectionDisplayWindow: TimeInterval = 60
    static let log = Logger(subsystem: "io.iosdevc.TonamoxTerminal", category: "bridge")

    private let store: PairingStore
    private let phoneID: UUID
    private var session: PhoneBridgeSession
    private var eventsTask: Task<Void, Never>?
    private var lifecycle: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var rejectionExpiry: Task<Void, Never>?
    private var startRetries = 0
    private var wantsListening = false

    init(store: PairingStore = PairingStore()) {
        self.store = store
        let credentials = store.loadOrCreate()
        var code = credentials.code
        var problem = credentials.problem
        #if DEBUG && targetEnvironment(simulator)
        if let adopted = PairingStore.debugLaunchCode(), adopted != code {
            code = adopted
            problem = store.save(adopted) ?? problem
        }
        #endif
        phoneID = credentials.phoneID
        currentCode = code
        storageProblem = problem
        session = Self.makeSession(code: code, phoneID: credentials.phoneID)
        observe(session)
    }

    var isConnected: Bool {
        if case .connected = connectionState { return true }
        return false
    }

    /// "tonamox:0" once the helper has reported its target.
    var targetLabel: String? {
        latestStatus.map { "\($0.target.session):\($0.target.window)" }
    }

    // MARK: Lifecycle

    func start() {
        wantsListening = true
        startRetries = 0
        retriesExhausted = false
        startListening()
    }

    /// The indicator shows "Rechazado" only for recent rejections, not for the whole app session.
    func hasRecentRejection(at now: Date = .now) -> Bool {
        guard let lastRejectedAt else { return false }
        return now.timeIntervalSince(lastRejectedAt) < Self.rejectionDisplayWindow
    }

    func noteTyped(_ ack: WriteAck) {
        switch ack.result {
        case .typed, .alreadyTyped:
            pendingTypedTarget = targetLabel
        case .unrecognized:
            break
        }
    }

    /// Cancels the listener and every connection, so the helper sees the reset at once.
    func stop() {
        wantsListening = false
        retryTask?.cancel()
        retryTask = nil
        let activity = BackgroundActivity.begin(named: "TonamoxBridgeStop")
        let stopping = session
        enqueue {
            await stopping.stop()
            activity.end()
        }
    }

    /// A new secret: the paired Mac is locked out until it pairs again with the new code.
    func regeneratePairing() {
        let fresh = PairingCode.generate()
        storageProblem = store.save(fresh)
        install(fresh)
    }

    func write(text: String, id: UUID, acknowledgedWarnings: [String]) async throws -> WriteAck {
        try await session.write(text: text, id: id, acknowledgedWarnings: acknowledgedWarnings)
    }

    // MARK: Private

    private static func makeSession(code: PairingCode, phoneID: UUID) -> PhoneBridgeSession {
        PhoneBridgeSession(secret: code.secret, phoneID: phoneID)
    }

    private func install(_ code: PairingCode) {
        let previous = session
        currentCode = code
        session = Self.makeSession(code: code, phoneID: phoneID)
        connectionState = .stopped
        latestStatus = nil
        helperName = nil
        rejectedAttempts = 0
        lastRejectedAt = nil
        pendingTypedTarget = nil
        observe(session)
        enqueue { await previous.stop() }
        if wantsListening { startListening() }
    }

    // Retries follow the error start() throws: identical failure events could be deduplicated upstream.
    private func startListening() {
        let starting = session
        enqueue { [weak self] in
            do {
                _ = try await starting.start()
            } catch let failure as LoopbackListenerError {
                self?.scheduleRetry(after: failure, for: starting)
            } catch {
                Self.log.error("Bridge start failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // Start and stop run in order on one chain, so a quick background/foreground cannot reorder them.
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = lifecycle
        lifecycle = Task {
            await previous?.value
            await operation()
        }
    }

    private func observe(_ observed: PhoneBridgeSession) {
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            for await event in observed.events {
                self?.apply(event)
            }
        }
    }

    private func apply(_ event: PhoneBridgeEvent) {
        switch event {
        case .stateChanged(let state):
            connectionState = state
            if case .connected(let name, _) = state {
                helperName = name
                lastConnectedAt = .now
            }
            if case .failed(.failed(let reason)) = state {
                Self.log.error("Bridge listener failed: \(reason, privacy: .public)")
            }
            if case .listening = state {
                startRetries = 0
                retriesExhausted = false
            }
            UIApplication.shared.isIdleTimerDisabled = isConnected
        case .status(let status):
            latestStatus = status
            if status.target.state == .ready { pendingTypedTarget = nil }
        case .rejectedAttempt(let total):
            rejectedAttempts = total
            lastRejectedAt = .now
            rejectionExpiry?.cancel()
            rejectionExpiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.rejectionDisplayWindow))
                guard !Task.isCancelled else { return }
                self?.objectWillChange.send()
            }
        case .disconnected:
            latestStatus = nil
            pendingTypedTarget = nil
        }
    }

    // The previous listener can hold the port for a moment after a quick background/foreground.
    private func scheduleRetry(after failure: LoopbackListenerError, for failed: PhoneBridgeSession) {
        guard wantsListening, failed === session, failure != .alreadyStarted, failure != .stopped else { return }
        guard startRetries < Self.maxStartRetries else {
            retriesExhausted = true
            return
        }
        startRetries += 1
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.startRetryDelay)
            guard let self, !Task.isCancelled, self.wantsListening else { return }
            self.startListening()
        }
    }
}

/// Asks iOS for a few seconds to finish closing sockets after the app moves to the background.
private final class BackgroundActivity {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    static func begin(named name: String) -> BackgroundActivity {
        let activity = BackgroundActivity()
        activity.identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak activity] in
            activity?.end()
        }
        return activity
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
