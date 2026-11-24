import SwiftUI
import Combine
import TonamoxCore

/// App-level hybrid escalation settings + the consent gate the escalation flow awaits.
@MainActor
final class HybridSettings: ObservableObject {
    static let shared = HybridSettings()

    /// Escalation policy used by the manual/auto escalation flow.
    @Published var policy = EscalationPolicy(mode: .askEachTime, allowCloud: false)

    /// The consent gate presented before any cloud send.
    let consent = UIConsentGate()

    private init() {}
}

/// A ``ConsentGate`` that presents a SwiftUI sheet and suspends until the user
/// approves or declines. Fail-closed: one request at a time (a concurrent one is
/// declined), and cancelling the awaiting task declines its request.
@MainActor
final class UIConsentGate: ObservableObject, ConsentGate {
    struct Request: Identifiable {
        let id = UUID()
        let target: RemoteTarget
        let preview: CompressionResult
        /// nil when the target's price is unknown.
        let cost: Decimal?
        /// Why it was offered, with the session's spend and cap; nil when the caller passed only a cost.
        let offer: EscalationOffer?
        /// Caller-written lines shown above the payload (what the request contains, what it does not).
        var disclosures: [String] = []

        /// The exact request sent on approval, when the offer carries it.
        var payload: EscalationPayload? { offer?.payload }
    }

    @Published var pending: Request?
    private var activeRequestID: UUID?
    /// A request is awaiting an answer; a new one would be declined.
    var hasActiveRequest: Bool { activeRequestID != nil }
    private var continuation: CheckedContinuation<Bool, Never>?

    func requestConsent(
        target: RemoteTarget,
        preview: CompressionResult,
        projectedCostUSD: Decimal?
    ) async -> Bool {
        await present(Request(target: target, preview: preview, cost: projectedCostUSD, offer: nil))
    }

    /// Shows the session budget, so the user can decide on an offer over the cost cap.
    func requestConsent(
        target: RemoteTarget,
        preview: CompressionResult,
        offer: EscalationOffer
    ) async -> Bool {
        await requestConsent(target: target, preview: preview, offer: offer, disclosures: [])
    }

    func requestConsent(
        target: RemoteTarget,
        preview: CompressionResult,
        offer: EscalationOffer,
        disclosures: [String]
    ) async -> Bool {
        await present(Request(
            target: target, preview: preview, cost: offer.projectedCostUSD, offer: offer, disclosures: disclosures))
    }

    private func present(_ request: Request) async -> Bool {
        guard activeRequestID == nil, !Task.isCancelled else { return false }
        let id = request.id
        activeRequestID = id
        return await withTaskCancellationHandler {
            // The body runs synchronously up to the first suspension, so the continuation is set before any
            // cancellation hop can look for it.
            await withCheckedContinuation { cont in
                self.continuation = cont
                self.pending = request
            }
        } onCancel: {
            Task { @MainActor in self.resolve(false, requestID: id) }
        }
    }

    /// Called by the consent sheet with the id of the request it shows; a stale id is ignored.
    func resolve(_ approved: Bool, requestID: UUID) {
        guard requestID == activeRequestID, let continuation else { return }
        pending = nil
        activeRequestID = nil
        self.continuation = nil
        continuation.resume(returning: approved)
    }

    /// Declines the request on screen, if any (app sent to the background, a stop button).
    func declinePending() {
        guard let activeRequestID else { return }
        resolve(false, requestID: activeRequestID)
    }
}
