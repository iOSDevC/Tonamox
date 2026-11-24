import Testing
@testable import TonamoxServer

@MainActor
@Suite struct ServerHarnessTests {
    @Test func droppingAStartedHarnessStopsItsServer() async throws {
        var harness: ServerHarness? = try await ServerHarness.started()
        let server = try #require(harness?.server)
        #expect(server.state != .stopped)
        harness = nil
        #expect(await eventually { server.state == .stopped })
    }

    @Test func listenerPortsAreDistinctAndBelowTheEphemeralRange() {
        let ports = (0..<64).map { _ in TestListenerPorts.take() }
        #expect(Set(ports).count == ports.count)
        #expect(ports.allSatisfy { TestListenerPorts.range.contains($0) && $0 < 49_152 })
    }
}
