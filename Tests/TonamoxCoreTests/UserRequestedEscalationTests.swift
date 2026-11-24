import Foundation
import Testing
import TonamoxCore

@Suite struct UserRequestedEscalationTests {
    private func decide(
        mode: EscalationPolicy.Mode = .askEachTime,
        allowCloud: Bool = true,
        cap: Decimal = 1,
        cloud: Bool,
        online: Bool = true,
        projected: Decimal? = 0,
        spent: Decimal = 0,
        unpriced: Int = 0
    ) -> UserRequestedDecision {
        EscalationRouter.decideUserRequested(RoutingInput(
            policy: EscalationPolicy(mode: mode, allowCloud: allowCloud, costCapUSDPerSession: cap),
            hasCandidateTarget: false, candidateIsCloud: cloud, online: online,
            projectedCostUSD: projected, sessionSpentUSD: spent, unpricedRecordCount: unpriced))
    }

    @Test func offRefusesWhateverElseHolds() {
        #expect(decide(mode: .off, cloud: false) == .refuse(.policyOff))
        #expect(decide(mode: .off, allowCloud: false, cloud: true, online: false, projected: 5, spent: 5)
            == .refuse(.policyOff))
    }

    @Test func cloudWithoutAllowCloudIsRefusedEvenOffline() {
        #expect(decide(allowCloud: false, cloud: true, online: false) == .refuse(.cloudNotAllowed))
        #expect(decide(mode: .autoWithConsentMemory, allowCloud: false, cloud: true) == .refuse(.cloudNotAllowed))
    }

    @Test func allowCloudDoesNotGateTheLAN() {
        #expect(decide(allowCloud: false, cloud: false) == .ask(reason: .userRequested))
    }

    @Test func cloudOfflineIsRefusedAndOfflineLANStillGoesThrough() {
        #expect(decide(cloud: true, online: false, projected: Decimal(string: "0.01")) == .refuse(.offline))
        #expect(decide(cloud: false, online: false) == .ask(reason: .userRequested))
        #expect(decide(mode: .autoWithConsentMemory, cloud: false, online: false) == .send)
    }

    @Test func exactlyAtTheCapIsAllowedAndOneCentOverIsRefused() {
        let half = Decimal(string: "0.5")!
        #expect(decide(cloud: true, projected: half, spent: half) == .ask(reason: .userRequested))
        #expect(decide(cloud: true, projected: Decimal(string: "0.51")!, spent: half) == .refuse(.overCostCap))
    }

    @Test func overTheCapIsRefusedBeforeAskingEvenWithUnpricedHistory() {
        #expect(decide(cloud: true, projected: 2, unpriced: 3) == .refuse(.overCostCap))
    }

    @Test func aFreeLANRequestIsNeverCapped() {
        #expect(decide(cap: 0, cloud: false, projected: 0, spent: 10) == .ask(reason: .userRequested))
        #expect(decide(mode: .autoWithConsentMemory, cap: 0, cloud: false, projected: 0, spent: 10) == .send)
    }

    @Test func unpricedCloudTargetAsksWithCostUnknown() {
        #expect(decide(cloud: true, projected: nil) == .ask(reason: .costUnknown))
        #expect(decide(mode: .autoWithConsentMemory, cloud: true, projected: nil) == .ask(reason: .costUnknown))
    }

    @Test func unpricedHistoryForcesAskOnCloudOnly() {
        #expect(decide(cloud: true, projected: Decimal(string: "0.01"), unpriced: 1) == .ask(reason: .costUnknown))
        #expect(decide(mode: .autoWithConsentMemory, cloud: false, unpriced: 1) == .send)
    }

    @Test func askEachTimeAsksForBothOrigins() {
        #expect(decide(cloud: true, projected: Decimal(string: "0.01")) == .ask(reason: .userRequested))
        #expect(decide(cloud: false) == .ask(reason: .userRequested))
    }

    @Test func autoAsksForCloudAndSendsToTheLAN() {
        #expect(decide(mode: .autoWithConsentMemory, cloud: true, projected: Decimal(string: "0.01"))
            == .ask(reason: .userRequested))
        #expect(decide(mode: .autoWithConsentMemory, cloud: false) == .send)
    }

    @Test func triggerFieldsAreIgnored() {
        let input = RoutingInput(
            policy: EscalationPolicy(mode: .askEachTime), hasCandidateTarget: false, candidateIsCloud: false,
            promptTokens: 0, localContextWindow: 8192, localAnswer: "a long and confident local answer, no doubt",
            domain: .medicine, projectedCostUSD: 0)
        #expect(EscalationRouter.decideUserRequested(input) == .ask(reason: .userRequested))
        #expect(EscalationRouter.decide(input) == .stayLocal)
    }
}
