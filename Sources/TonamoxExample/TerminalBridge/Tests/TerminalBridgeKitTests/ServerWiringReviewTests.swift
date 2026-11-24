import Foundation
import Testing
@testable import TerminalBridgeKit

@Suite struct NetworkTicketTransitionTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private func time(_ date: Date) -> String { "HH:MM" }

    @Test func serverStopCancelsOnlyOpenTickets() {
        let open = NetworkTicketPhase.open(expiresAt: start.addingTimeInterval(600))
        let used = NetworkTicketPhase.used(receivedAt: start)
        #expect(open.endedByServerStop() == .cancelledByServerStop)
        #expect(used.endedByServerStop() == used)
        #expect(NetworkTicketPhase.cancelledByServerStop.endedByServerStop() == .cancelledByServerStop)
    }

    @Test func anArrivalMarksAnOpenTicketUsedAndCarriesAnEarlierRefusal() {
        let open = NetworkTicketPhase.open(expiresAt: start.addingTimeInterval(600))
        #expect(open.arrived(at: start, laterPostRefused: false) == .used(receivedAt: start))
        #expect(open.arrived(at: start, laterPostRefused: true) == .used(receivedAt: start, laterPostRefused: true))
        #expect(NetworkTicketPhase.cancelledByServerStop.arrived(at: start, laterPostRefused: false)
            == .cancelledByServerStop)
    }

    @Test func aRefusedPostAfterUseIsFlaggedOnTheRow() {
        let used = NetworkTicketPhase.used(receivedAt: start)
        let flagged = used.refusingLaterPost()
        #expect(flagged == .used(receivedAt: start, laterPostRefused: true))
        #expect(flagged.text(now: start, time: time).contains("se rechazó otro envío"))
        #expect(!used.text(now: start, time: time).contains("se rechazó otro envío"))
        let open = NetworkTicketPhase.open(expiresAt: start.addingTimeInterval(600))
        #expect(open.refusingLaterPost() == open)
    }

    @Test func openTextSaysTheLinkIsVisibleInPsAndTheClipboard() {
        let text = NetworkTicketPhase.open(expiresAt: start.addingTimeInterval(600)).text(now: start, time: time)
        #expect(text.contains("«ps»"))
        #expect(text.contains("portapapeles"))
    }
}

@Suite struct LaterPostRefusalTests {
    private let facts = IncomingOutputFacts(label: "1.1 make", peer: "127.0.0.1", receivedBytes: 2, exitStatus: nil,
                                            invalidSequences: 0, peerMatchesLock: true, laterPostRefused: false)

    @Test func aPreviewAlreadyOpenGetsTheWarning() throws {
        let paste = try #require(NetworkPaste.make(text: "ok", facts: facts, command: "make"))
        #expect(paste.warnings.isEmpty)
        let marked = paste.markingLaterPostRefused()
        #expect(marked.facts.laterPostRefused)
        #expect(marked.output == paste.output)
        #expect(marked.command == "make")
        #expect(marked.warnings.count == 1)
    }
}

@Suite struct IngestReachTests {
    @Test func loopbackNeedsAForwardOnTheComputer() {
        let hint = NetworkOutputLine.loopbackForwardHint(port: 47830)
        #expect(hint.command == "iproxy -s 127.0.0.1 47830:47830")
        #expect(hint.explanation.contains("127.0.0.1"))
    }

    @Test func onlyABackgroundPauseKeepsTicketsAlive() {
        #expect(WebServerSuspendReason.appBackgrounded.reopensByItself)
        #expect(!WebServerSuspendReason.idle(minutes: 15).reopensByItself)
        #expect(!WebServerSuspendReason.interfaceLost("en0").reopensByItself)
    }

    @Test func idleTextUsesTheConfiguredMinutes() {
        #expect(WebServerStatus.describe(.idle(minutes: 30)).contains("30 minutos"))
        #expect(WebServerStatus.describe(.idle(minutes: 1)).contains("1 minuto "))
    }
}

@Suite struct SheetQueueTests {
    enum Route: Hashable { case picker, preview, consent, pairing }

    @Test func nothingDemandedShowsNothing() {
        #expect(SheetQueue.next(showing: nil, demands: [Route]()) == nil)
        #expect(SheetQueue.next(showing: Route.picker, demands: []) == nil)
    }

    @Test func theSheetOnScreenStaysWhileItIsStillDemanded() {
        #expect(SheetQueue.next(showing: Route.preview, demands: [.pairing, .preview]) == .preview)
    }

    @Test func whenTheSheetOnScreenEndsTheFirstDemandShows() {
        #expect(SheetQueue.next(showing: Route.preview, demands: [.pairing, .consent]) == .pairing)
        #expect(SheetQueue.next(showing: nil, demands: [Route.consent]) == .consent)
    }
}
