import Foundation
import Security
import Synchronization
import Testing
import TonamoxHTTP
@testable import TonamoxCore
@testable import TonamoxServer

/// Query construction only: nothing here touches a real keychain.
@Suite("Keychain credential queries")
struct KeychainCredentialQueryTests {
    static let group = "ABCDE12345.io.example.app"

    @Test func everyPathNamesTheAccessGroupAndNeverSyncs() {
        let store = KeychainServerCredentials(accessGroup: Self.group)
        let data = Data("[]".utf8)
        for query in [store.baseQuery, store.loadQuery, store.addQuery(data)] {
            #expect(query[kSecAttrAccessGroup as String] as? String == Self.group)
            #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
            #expect(query[kSecAttrService as String] as? String == KeychainServerCredentials.service)
            #expect(query[kSecAttrAccount as String] as? String == "server.apikeys")
            #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        }
        #expect(store.loadQuery[kSecReturnData as String] as? Bool == true)
    }

    @Test func updateAndAddWriteADeviceOnlyItem() {
        let store = KeychainServerCredentials(accessGroup: Self.group)
        let data = Data("[]".utf8)
        let expected = kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        #expect(store.updateAttributes(data)[kSecAttrAccessible as String] as? String == expected)
        #expect(store.updateAttributes(data)[kSecValueData as String] as? Data == data)
        #expect(store.addQuery(data)[kSecAttrAccessible as String] as? String == expected)
        #expect(store.addQuery(data)[kSecValueData as String] as? Data == data)
    }

    @Test func withoutAGroupNoGroupIsNamedButSyncIsStillOff() {
        let store = KeychainServerCredentials()
        #expect(store.accessGroup == nil)
        #expect(store.baseQuery[kSecAttrAccessGroup as String] == nil)
        #expect(store.addQuery(Data())[kSecAttrAccessGroup as String] == nil)
        #expect(store.baseQuery[kSecUseDataProtectionKeychain as String] == nil)
        #expect(store.baseQuery[kSecAttrSynchronizable as String] as? Bool == false)
    }

    @Test func usageIsSavedAtMostOnceAMinute() {
        let now = Date()
        #expect(TonamoxServer.usageIsDue(lastSaved: nil, now: now))
        #expect(!TonamoxServer.usageIsDue(lastSaved: now.addingTimeInterval(-59), now: now))
        #expect(TonamoxServer.usageIsDue(lastSaved: now.addingTimeInterval(-60), now: now))
    }
}

/// A store whose loads and saves can be made to fail.
final class FailingCredentialStore: ServerCredentialStore {
    private let ledger = Mutex<(keys: [StoredAPIKey], fails: Bool, loadFails: Bool)>(([], false, false))

    func setFailing(_ fails: Bool) { ledger.withLock { $0.fails = fails } }
    func setLoadFailing(_ fails: Bool) { ledger.withLock { $0.loadFails = fails } }
    /// What was last saved, read even while loads fail.
    var savedKeys: [StoredAPIKey] { ledger.withLock { $0.keys } }
    func loadKeys() throws -> [StoredAPIKey] {
        try ledger.withLock {
            if $0.loadFails { throw ServerCredentialError.keychain(errSecInteractionNotAllowed) }
            return $0.keys
        }
    }
    func save(_ keys: [StoredAPIKey]) throws {
        try ledger.withLock {
            if $0.fails { throw ServerCredentialError.keychain(errSecInteractionNotAllowed) }
            $0.keys = keys
        }
    }
}

/// A wall clock a test moves by hand.
final class ManualWallClock: Sendable {
    private let current: Mutex<Date>

    init(_ start: Date) { current = Mutex(start) }

    var now: Date { current.withLock { $0 } }
    func set(_ date: Date) { current.withLock { $0 = date } }
}

@Suite("Credential store writes", .serialized)
@MainActor
struct CredentialStoreWriteTests {
    @Test func aKeyTheStoreCannotSaveIsNotIssued() throws {
        let store = FailingCredentialStore()
        let server = Self.server(store)
        store.setFailing(true)
        #expect(throws: ServerCredentialError.keychain(errSecInteractionNotAllowed)) {
            try server.issueAPIKey(label: "x")
        }
        #expect(server.clients.isEmpty)
        #expect(try store.loadKeys().isEmpty)
    }

    @Test func issuingDropsExpiredKeysFromTheStore() throws {
        let store = FailingCredentialStore()
        let server = Self.server(store)
        let short = try server.issueAPIKey(label: "short", lifetime: .seconds(60))
        server.clock = ServerClock(monotonic: { ContinuousClock.now }, wall: { Date().addingTimeInterval(120) })
        let next = try server.issueAPIKey(label: "next")
        let stored = try store.loadKeys().map(\.id)
        #expect(stored == [next.client.id])
        #expect(!server.clients.contains { $0.id == short.client.id })
    }

    @Test func keysFromTheStoreAreListedBeforeAnyStart() throws {
        let store = FailingCredentialStore()
        let issued = try Self.server(store).issueAPIKey(label: "kept")
        let relaunched = Self.server(store)
        #expect(relaunched.state == .stopped)
        #expect(relaunched.clients.map(\.id) == [issued.client.id])
    }

    @Test func revokeWhileStoppedReachesTheStore() throws {
        let store = FailingCredentialStore()
        let server = Self.server(store)
        let issued = try server.issueAPIKey(label: "gone")
        server.revoke(issued.client.id)
        #expect(try store.loadKeys().isEmpty)
    }

    @Test func steadyUseIsSavedOnceAMinuteFromTheLastWrite() throws {
        let store = FailingCredentialStore()
        let server = Self.server(store)
        let start = Date()
        let wall = ManualWallClock(start)
        server.clock = ServerClock(monotonic: { ContinuousClock.now }, wall: { wall.now })
        let issued = try server.issueAPIKey(label: "steady")
        let peer = PeerAddress(host: "127.0.0.1")
        let header = "Bearer " + issued.secret
        var saved: [Date?] = []
        for offset in [0.0, 30, 70, 100] {
            wall.set(start.addingTimeInterval(offset))
            _ = server.authenticate(header, peer: peer)
            saved.append(store.savedKeys.first?.lastUsed)
        }
        #expect(saved == [0.0, 0, 70, 70].map { start.addingTimeInterval($0) })
    }

    @Test func aServerThatCouldNotReadTheStoreNeverSavesOverIt() throws {
        let store = FailingCredentialStore()
        let kept = try Self.server(store).issueAPIKey(label: "kept")
        store.setLoadFailing(true)
        let server = Self.server(store)
        #expect(server.credentialLoadFailure != nil)
        #expect(server.clients.isEmpty)
        #expect(throws: ServerCredentialError.keychain(errSecInteractionNotAllowed)) {
            try server.issueAPIKey(label: "lost")
        }
        server.revoke(kept.client.id)
        #expect(store.savedKeys.map(\.id) == [kept.client.id])
        store.setLoadFailing(false)
        let next = try server.issueAPIKey(label: "next")
        #expect(server.credentialLoadFailure == nil)
        #expect(store.savedKeys.map(\.id) == [kept.client.id, next.client.id])
    }

    static func server(_ store: FailingCredentialStore) -> TonamoxServer {
        TonamoxServer(configuration: ServerConfiguration(serverName: "test"), models: [], credentials: store,
                      lifecycle: BackgroundLifecycle(notificationCenter: NotificationCenter(),
                                                     didEnterBackground: ServerHarness.background,
                                                     willEnterForeground: ServerHarness.foreground),
                      clock: .live, log: LogCollector().log)
    }
}
