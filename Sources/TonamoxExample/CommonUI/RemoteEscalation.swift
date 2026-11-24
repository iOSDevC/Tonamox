import Foundation
import TonamoxCore

/// A send the user asked for, to a target the user chose: applies the policy and the cost cap
/// (`EscalationRouter.decideUserRequested`), asks consent through `UIConsentGate`, then sends exactly the
/// payload the user saw.
@MainActor
enum RemoteEscalation {
    enum ConsentRule {
        /// Ask only when the policy says so.
        case policy
        /// Ask on every send, also when the policy would send without asking.
        case always
    }

    enum Failure: Error, Equatable {
        case refused(UserRequestRefusal)
        case declined
        /// Another consent request is on screen; nothing was asked or sent.
        case busy
    }

    /// A payload that passed policy, cost cap and consent; `send` delivers it unchanged.
    struct Authorized {
        let target: RemoteTarget
        let payload: EscalationPayload
        let ledger: CostLedger
        /// nil sends the SDK's default.
        var temperature: Float?

        func send(onToken: @escaping @MainActor (String) -> Void) async throws -> HybridEscalator.Result {
            try await HybridEscalator(ledger: ledger).escalate(
                payload, to: target, temperature: temperature, onToken: onToken)
        }
    }

    /// Builds the payload (no context, so compression keeps `question` whole), decides, and asks consent when
    /// the decision or `consentRule` requires it. Throws `Failure`, or `CancellationError` when the awaiting
    /// task was cancelled.
    static func authorize(
        target: RemoteTarget,
        systemPrompt: String?,
        question: String,
        maxTokens: Int,
        consentRule: ConsentRule = .policy,
        disclosures: [String] = [],
        temperature: Float? = nil,
        settings: HybridSettings? = nil,
        ledger: CostLedger? = nil
    ) async throws -> Authorized {
        // Optional instead of `= .shared`: a default argument is evaluated outside the main actor in Swift 5 mode.
        let settings = settings ?? .shared
        let ledger = ledger ?? .shared
        let policy = settings.policy
        let payload = HybridEscalator(ledger: ledger).preparePayload(
            for: target, systemPrompt: systemPrompt, context: "", question: question, maxTokens: maxTokens,
            keepRatio: policy.keepRatio, redactPII: policy.redactsPII(for: target))
        let projected = ledger.projectedCost(
            target: target, inputTokens: payload.estimatedInputTokens, maxOutput: payload.maxTokens)
        let input = RoutingInput(
            policy: policy, hasCandidateTarget: true, candidateIsCloud: !target.isLocalNetwork,
            online: NetworkMonitor.shared.isOnline, projectedCostUSD: projected,
            sessionSpentUSD: ledger.sessionCostUSD,
            // Estimated records are not exact either, so they still ask like unpriced ones.
            unpricedRecordCount: ledger.unpricedRecordCount + ledger.estimatedRecordCount)

        let reason: EscalationReason?
        switch EscalationRouter.decideUserRequested(input) {
        case .refuse(let refusal):
            throw Failure.refused(refusal)
        case .ask(let askReason):
            reason = askReason
        case .send:
            reason = consentRule == .always ? .userRequested : nil
        }

        if let reason {
            guard !settings.consent.hasActiveRequest else { throw Failure.busy }
            let offer = EscalationOffer(
                reason: reason, projectedCostUSD: projected, sessionSpentUSD: input.sessionSpentUSD,
                unpricedRecordCount: input.unpricedRecordCount, costCapUSD: policy.costCapUSDPerSession,
                payload: payload)
            let approved = await settings.consent.requestConsent(
                target: target, preview: payload.compression, offer: offer, disclosures: disclosures)
            guard approved else {
                if Task.isCancelled { throw CancellationError() }
                throw Failure.declined
            }
        }
        try Task.checkCancellation()
        return Authorized(target: target, payload: payload, ledger: ledger, temperature: temperature)
    }

    /// `authorize` then `send`, for screens that show the whole answer at once.
    static func run(
        target: RemoteTarget,
        systemPrompt: String?,
        question: String,
        maxTokens: Int,
        consentRule: ConsentRule = .policy,
        disclosures: [String] = [],
        temperature: Float? = nil,
        settings: HybridSettings? = nil,
        ledger: CostLedger? = nil,
        onToken: @escaping @MainActor (String) -> Void
    ) async throws -> HybridEscalator.Result {
        let authorized = try await authorize(
            target: target, systemPrompt: systemPrompt, question: question, maxTokens: maxTokens,
            consentRule: consentRule, disclosures: disclosures, temperature: temperature,
            settings: settings, ledger: ledger)
        return try await authorized.send(onToken: onToken)
    }

    /// English text for the SDK demo screens; TonamoxTerminal maps `Failure` to its own Spanish text.
    static func englishText(for failure: Failure) -> String {
        switch failure {
        case .refused(.policyOff): "Remote sending is Off. Change the mode in Settings."
        case .refused(.cloudNotAllowed): "Cloud providers are not allowed. Allow them in Settings."
        case .refused(.offline): "Offline: the cloud provider is not reachable."
        case .refused(.overCostCap): "Over your session cost cap. Raise it in Settings or start a new session."
        case .declined: "Escalation declined — keeping local."
        case .busy: "Another consent request is open — nothing was sent."
        }
    }
}
