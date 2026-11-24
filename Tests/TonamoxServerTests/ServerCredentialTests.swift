import CryptoKit
import Foundation
import Testing
import TonamoxHTTP
@testable import TonamoxServer

@Suite("Server credentials", .serialized)
@MainActor
struct ServerCredentialTests {
    static let unknownKey = "tnx_" + String(repeating: "Z", count: 43)

    @Test func issuedKeyShownOnceAndStoredAsDigest() async throws {
        let harness = try await ServerHarness.started()
        let issued = try #require(harness.key)
        #expect(issued.secret.hasPrefix("tnx_") && issued.secret.count == 47)
        #expect(!String(describing: issued).contains(issued.secret))
        #expect(!String(describing: harness.server.clients).contains(issued.secret))
        let stored = try harness.credentials.loadKeys()
        #expect(stored.count == 1)
        #expect(stored[0].keyHash == Data(SHA256.hash(data: Data(issued.secret.utf8))))
        let encoded = String(decoding: try JSONEncoder().encode(stored), as: UTF8.self)
        #expect(!encoded.contains(issued.secret))
        #expect(!encoded.contains(String(issued.secret.dropFirst(4))))
        await harness.server.stop()
    }

    @Test func firstUseIsSavedToTheStore() async throws {
        let harness = try await ServerHarness.started()
        #expect(try harness.credentials.loadKeys().first?.lastUsed == nil)
        #expect(try await harness.get("/v1/models").status == 200)
        let stored = try #require(try harness.credentials.loadKeys().first)
        #expect(stored.lastUsed != nil)
        #expect(stored.lastPeer == "127.0.0.1")
        await harness.server.stop()
    }

    @Test func wrongKeyIs401() async throws {
        let harness = try await ServerHarness.started()
        let response = try await harness.get("/v1/models", key: Self.unknownKey)
        #expect(response.status == 401)
        #expect(errorCode(response) == "invalid_api_key")
        let missing = try await harness.raw("GET /v1/models HTTP/1.1\r\nHost: \(harness.host)\r\n\r\n")
        #expect(missing.status == 401)
        await harness.server.stop()
    }

    @Test func expiredKeyIs401() async throws {
        let harness = try await ServerHarness.started()
        let short = try harness.server.issueAPIKey(label: "short", lifetime: .seconds(60))
        #expect(try await harness.get("/v1/models", key: short.secret).status == 200)
        harness.server.clock = ServerClock(monotonic: { ContinuousClock.now }, wall: { Date().addingTimeInterval(120) })
        let response = try await harness.get("/v1/models", key: short.secret)
        #expect(response.status == 401)
        #expect(errorCode(response) == "expired_api_key")
        #expect(try await harness.get("/v1/models").status == 200, "the 7-day default key is still valid")
        await harness.server.stop()
    }

    @Test func revokedKeyIs401() async throws {
        let harness = try await ServerHarness.started()
        let other = try harness.server.issueAPIKey(label: "other")
        #expect(try await harness.get("/v1/models", key: other.secret).status == 200)
        harness.server.revoke(other.client.id)
        #expect(try await harness.get("/v1/models", key: other.secret).status == 401)
        #expect(try harness.credentials.loadKeys().count == 1)
        #expect(!harness.server.clients.contains { $0.id == other.client.id })
        await harness.server.stop()
    }

    @Test func scopeEnforced() async throws {
        let harness = try await ServerHarness.started()
        let modelsOnly = try harness.server.issueAPIKey(label: "models", scopes: [.models])
        #expect(try await harness.get("/v1/models", key: modelsOnly.secret).status == 200)
        let chat = try await harness.chat(Bodies.chat(), key: modelsOnly.secret)
        #expect(chat.status == 403)
        #expect(errorCode(chat) == "insufficient_scope")
        let chatOnly = try harness.server.issueAPIKey(label: "chat", scopes: [.chat])
        #expect(try await harness.get("/v1/models", key: chatOnly.secret).status == 403)
        #expect(try await harness.chat(Bodies.chat(), key: chatOnly.secret).status == 200)
        await harness.server.stop()
    }

    @Test func authFailuresBlockIPForFiveMinutes() {
        let start = ContinuousClock.now
        var budget = FailureBudget(limits: ServerLimits(), perIPEnabled: true, now: start)
        let floods = (0..<6).map { _ in budget.recordFailure(from: "192.168.1.9", now: start) }
        #expect(!floods.contains(true))
        #expect(budget.isBlocked("192.168.1.9", now: start + .seconds(299)))
        #expect(!budget.isBlocked("192.168.1.9", now: start + .seconds(301)))
        #expect(!budget.isBlocked("192.168.1.10", now: start))
        let loopback = FailureBudget(limits: ServerLimits(), perIPEnabled: false, now: start)
        #expect(!loopback.isBlocked("127.0.0.1", now: start))
    }

    @Test func expiredIPBlocksAreDropped() {
        let start = ContinuousClock.now
        var limits = ServerLimits()
        limits.authFailuresPerMinutePerIP = 1
        limits.globalAuthFailuresPerMinute = 1_000_000
        var budget = FailureBudget(limits: limits, perIPEnabled: true, now: start)
        for index in 0..<2_000 {
            let peer = "10.0.\(index / 256).\(index % 256)"
            let now = start + .seconds(index)
            _ = budget.recordFailure(from: peer, now: now)
            _ = budget.recordFailure(from: peer, now: now)
        }
        #expect(budget.isBlocked("10.0.7.207", now: start + .seconds(1_999)))
        #expect(budget.blockedCount <= 300 + KeyedTokenBuckets<String>.minimumPruneSize)
    }

    @Test func globalAuthFloodPausesUnauthenticatedAccepts() async throws {
        let harness = try await ServerHarness.started { $0.limits.globalAuthFailuresPerMinute = 3 }
        let events = harness.server.events()
        let statuses = try await repeated(3) { try await harness.get("/v1/models", key: Self.unknownKey).status }
        #expect(statuses == [401, 401, 401])
        let flooded = try await harness.get("/v1/models", key: Self.unknownKey)
        #expect(flooded.status == 429)
        #expect(flooded.header("Retry-After") != nil)
        var iterator = events.makeAsyncIterator()
        var sawFlood = false
        while let event = await iterator.next() {
            if event == .authFlood { sawFlood = true; break }
        }
        #expect(sawFlood)
        #expect(harness.server.state == .listening(ServerEndpoint(host: "127.0.0.1", port: harness.port, exposure: .loopback)))
        await harness.server.stop()
    }

    @Test func missingAuthorizationNotCountedAsFailure() async throws {
        let harness = try await ServerHarness.started { $0.limits.globalAuthFailuresPerMinute = 2 }
        let statuses = try await repeated(5) {
            try await harness.raw("GET /v1/models HTTP/1.1\r\nHost: \(harness.host)\r\n\r\n").status
        }
        #expect(statuses == [401, 401, 401, 401, 401])
        let malformed = try await repeated(5) { try await harness.get("/v1/models", key: "tnx_short").status }
        #expect(malformed == [401, 401, 401, 401, 401])
        #expect(try await harness.get("/v1/models", key: Self.unknownKey).status == 401, "the first counted failure")
        await harness.server.stop()
    }

    @Test func wrongCredentialsCountedAndFloodReturns429ButValidKeyWorks() async throws {
        let harness = try await ServerHarness.started { $0.limits.globalAuthFailuresPerMinute = 2 }
        _ = try await repeated(2) { try await harness.get("/v1/models", key: Self.unknownKey).status }
        #expect(try await harness.get("/v1/models", key: Self.unknownKey).status == 429)
        #expect(try await harness.get("/v1/models").status == 200)
        #expect(try await harness.chat(Bodies.chat()).status == 200)
        await harness.server.stop()
    }

    @Test func keychainStoreHoldsDigestsOnly() throws {
        let secret = "tnx_" + String(repeating: "k", count: 43)
        let key = StoredAPIKey(id: UUID(), label: "cli", scopes: [.chat, .models],
                               keyHash: Data(SHA256.hash(data: Data(secret.utf8))), createdAt: Date(), expiresAt: nil)
        let stored = try KeychainServerCredentials.encode([key])
        let text = String(decoding: stored, as: UTF8.self)
        #expect(!text.contains(secret))
        #expect(!text.contains(String(secret.dropFirst(4))))
        #expect(try KeychainServerCredentials.decode(stored) == [key])
    }
}

/// Runs `body` `count` times in sequence, so requests never overlap.
@MainActor
func repeated<T>(_ count: Int, _ body: () async throws -> T) async rethrows -> [T] {
    var results: [T] = []
    for _ in 0..<count {
        results.append(try await body())
    }
    return results
}
