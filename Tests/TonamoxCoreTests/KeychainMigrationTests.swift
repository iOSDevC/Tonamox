import Foundation
import Security
import XCTest
@testable import TonamoxCore

/// An in-memory keychain with iOS's access-group rules: writes without a group land in the app's default group,
/// reads and deletes without a group match every group the app can see. ``app(defaultGroup:sharedGroups:)`` gives
/// another app a view of the same items.
final class FakeKeychain: KeychainBackend, @unchecked Sendable {
    static let defaultGroup = "TEAMID.io.iosdevc.app"

    fileprivate struct Key: Hashable {
        let account: String
        let group: String
    }

    /// The device keychain every app view reads and writes.
    fileprivate final class ItemTable: @unchecked Sendable {
        let lock = NSLock()
        var items: [Key: Data] = [:]
        var locked = false
    }

    private let table: ItemTable
    private let appGroup: String
    /// `nil`: every group (a single-app test).
    private let visibleGroups: Set<String>?

    convenience init() {
        self.init(table: ItemTable(), appGroup: Self.defaultGroup, visibleGroups: nil)
    }

    private init(table: ItemTable, appGroup: String, visibleGroups: Set<String>?) {
        self.table = table
        self.appGroup = appGroup
        self.visibleGroups = visibleGroups
    }

    /// An app whose default group is `defaultGroup` and that also sees `sharedGroups`, on this device's items.
    func app(defaultGroup: String, sharedGroups: Set<String>) -> FakeKeychain {
        FakeKeychain(table: table, appGroup: defaultGroup, visibleGroups: sharedGroups.union([defaultGroup]))
    }

    func seed(_ value: String, account: String, group: String? = nil) {
        table.lock.withLock { table.items[Key(account: account, group: group ?? appGroup)] = Data(value.utf8) }
    }

    func value(account: String, group: String) -> String? {
        table.lock.withLock { table.items[Key(account: account, group: group)] }
            .map { String(decoding: $0, as: UTF8.self) }
    }

    func setLocked(_ isLocked: Bool) {
        table.lock.withLock { table.locked = isLocked }
    }

    var count: Int { table.lock.withLock { table.items.count } }

    func list(service: String) -> (status: OSStatus, items: [KeychainItem]) {
        table.lock.withLock {
            guard !table.locked else { return (errSecInteractionNotAllowed, []) }
            let found = table.items.keys.filter(isVisible).sorted { ($0.account, $0.group) < ($1.account, $1.group) }
                .map { KeychainItem(account: $0.account, accessGroup: $0.group) }
            return (found.isEmpty ? errSecItemNotFound : errSecSuccess, found)
        }
    }

    func read(service: String, account: String, accessGroup: String?) -> (status: OSStatus, data: Data?) {
        table.lock.withLock {
            guard !table.locked else { return (errSecInteractionNotAllowed, nil) }
            let match = matching(account: account, group: accessGroup).first
            return match.map { (errSecSuccess, table.items[$0]) } ?? (errSecItemNotFound, nil)
        }
    }

    func exists(service: String, account: String, accessGroup: String?) -> Bool {
        table.lock.withLock { !matching(account: account, group: accessGroup).isEmpty }
    }

    func add(_ data: Data, service: String, account: String, accessGroup: String?) -> OSStatus {
        table.lock.withLock {
            guard !table.locked else { return errSecInteractionNotAllowed }
            let key = Key(account: account, group: accessGroup ?? appGroup)
            guard isVisible(key) else { return errSecMissingEntitlement }
            guard table.items[key] == nil else { return errSecDuplicateItem }
            table.items[key] = data
            return errSecSuccess
        }
    }

    func update(_ data: Data, service: String, account: String, accessGroup: String?) -> OSStatus {
        table.lock.withLock {
            let keys = matching(account: account, group: accessGroup)
            guard !keys.isEmpty else { return errSecItemNotFound }
            keys.forEach { table.items[$0] = data }
            return errSecSuccess
        }
    }

    func delete(service: String, account: String, accessGroup: String?) -> OSStatus {
        table.lock.withLock {
            let keys = matching(account: account, group: accessGroup)
            keys.forEach { table.items[$0] = nil }
            return keys.isEmpty ? errSecItemNotFound : errSecSuccess
        }
    }

    private func isVisible(_ key: Key) -> Bool {
        visibleGroups?.contains(key.group) ?? true
    }

    /// The default group first, as an unscoped query returned it in the experiment.
    private func matching(account: String, group: String?) -> [Key] {
        table.items.keys.filter { $0.account == account && (group == nil || $0.group == group) && isVisible($0) }
            .sorted { ($0.group == appGroup ? 0 : 1, $0.group) < ($1.group == appGroup ? 0 : 1, $1.group) }
    }
}

final class KeychainMigrationTests: XCTestCase {
    private let group = "group.io.iosdevc.tonamox"
    private let service = "dev.auralocal.remote"

    func testCopiesPrivateItemsIntoTheGroupAndKeepsTheOriginals() {
        let keychain = FakeKeychain()
        keychain.seed("hf", account: "download.huggingface")
        keychain.seed("sk", account: "openai")
        keychain.seed("shared", account: "anthropic", group: group)

        let report = KeychainStore.migrateToAccessGroup(group, service: service, backend: keychain)

        XCTAssertEqual(report.copied, ["download.huggingface", "openai"])
        XCTAssertEqual(report.alreadyShared, ["anthropic"])
        XCTAssertFalse(report.isPending)
        XCTAssertEqual(keychain.value(account: "download.huggingface", group: group), "hf")
        XCTAssertEqual(keychain.value(account: "download.huggingface", group: FakeKeychain.defaultGroup), "hf")
        XCTAssertEqual(keychain.count, 5)
        XCTAssertEqual(KeychainStore.migrateToAccessGroup(group, service: service, backend: keychain).copied, [])
    }

    func testAGroupCopyIsNeverOverwritten() {
        let keychain = FakeKeychain()
        keychain.seed("old", account: "download.huggingface")
        keychain.seed("new", account: "download.huggingface", group: group)

        let report = KeychainStore.migrateToAccessGroup(group, service: service, backend: keychain)

        XCTAssertEqual(report.copied, [])
        XCTAssertEqual(keychain.value(account: "download.huggingface", group: group), "new")
    }

    func testALockedDeviceLeavesTheMigrationPendingAndARetryFinishesIt() {
        let keychain = FakeKeychain()
        keychain.seed("hf", account: "download.huggingface")
        keychain.setLocked(true)

        let locked = KeychainStore.migrateToAccessGroup(group, service: service, backend: keychain)
        keychain.setLocked(false)
        let retried = KeychainStore.migrateToAccessGroup(group, service: service, backend: keychain)

        XCTAssertTrue(locked.isPending)
        XCTAssertEqual(locked.copied, [])
        XCTAssertFalse(retried.isPending)
        XCTAssertEqual(retried.copied, ["download.huggingface"])
    }

    func testBeforeTheMergeReadsPreferTheGroupAndDeleteRemovesEveryCopy() throws {
        let keychain = FakeKeychain()
        keychain.seed("old", account: "download.huggingface")
        keychain.seed("new", account: "download.huggingface", group: group)
        keychain.seed("private only", account: "openai")

        try withKeychain(keychain, flag: makeFlag()) {
            XCTAssertEqual(KeychainStore.read(for: "download.huggingface"), "new")
            XCTAssertEqual(KeychainStore.read(for: "openai"), "private only")
            XCTAssertTrue(KeychainStore.hasKey(for: "openai"))

            KeychainStore.delete(for: "download.huggingface")
            XCTAssertNil(KeychainStore.read(for: "download.huggingface"))
            XCTAssertFalse(KeychainStore.hasKey(for: "download.huggingface"))

            try KeychainStore.save("saved", for: "anthropic")
            XCTAssertEqual(keychain.value(account: "anthropic", group: group), "saved")
            XCTAssertNil(keychain.value(account: "anthropic", group: FakeKeychain.defaultGroup))
        }
    }

    func testAfterTheMergeReadsAndHasKeyLookInTheGroupOnly() throws {
        let keychain = FakeKeychain()
        keychain.seed("private only", account: "openai")
        keychain.seed("shared", account: "anthropic", group: group)
        let flag = makeFlag()
        flag.set()

        try withKeychain(keychain, flag: flag) {
            XCTAssertNil(KeychainStore.read(for: "openai"))
            XCTAssertFalse(KeychainStore.hasKey(for: "openai"))
            XCTAssertEqual(KeychainStore.read(for: "anthropic"), "shared")
            XCTAssertTrue(KeychainStore.hasKey(for: "anthropic"))
        }
    }

    func testAKeyAnotherAppDeletedStaysDeletedAfterARelaunch() throws {
        let device = FakeKeychain()
        let example = device.app(defaultGroup: "TEAMID.io.iosdevc.AuraExample", sharedGroups: [group])
        let chat = device.app(defaultGroup: "TEAMID.io.iosdevc.TonamoxChat", sharedGroups: [group])
        example.seed("hf", account: "download.huggingface")
        let exampleFlag = makeFlag()
        let chatFlag = makeFlag()

        try withKeychain(example, flag: exampleFlag) {
            XCTAssertEqual(KeychainStore.migrateToAccessGroupIfNeeded()?.copied, ["download.huggingface"])
        }
        try withKeychain(chat, flag: chatFlag) {
            XCTAssertEqual(KeychainStore.migrateToAccessGroupIfNeeded()?.copied, [])
            XCTAssertEqual(KeychainStore.read(for: "download.huggingface"), "hf")
            KeychainStore.delete(for: "download.huggingface")
        }
        try withKeychain(example, flag: exampleFlag) {
            XCTAssertNil(KeychainStore.migrateToAccessGroupIfNeeded())
            XCTAssertNil(KeychainStore.read(for: "download.huggingface"))
            XCTAssertFalse(KeychainStore.hasKey(for: "download.huggingface"))
        }
        try withKeychain(chat, flag: chatFlag) {
            XCTAssertNil(KeychainStore.read(for: "download.huggingface"))
        }
        XCTAssertEqual(device.value(account: "download.huggingface", group: "TEAMID.io.iosdevc.AuraExample"), "hf")
        XCTAssertNil(device.value(account: "download.huggingface", group: group))
    }

    func testALockedDeviceLeavesTheMergeFlagUnsetUntilAPassFinishes() throws {
        let keychain = FakeKeychain()
        keychain.seed("hf", account: "download.huggingface")
        let flag = makeFlag()

        try withKeychain(keychain, flag: flag) {
            keychain.setLocked(true)
            XCTAssertEqual(KeychainStore.migrateToAccessGroupIfNeeded()?.isPending, true)
            XCTAssertFalse(flag.isSet)
            keychain.setLocked(false)
            XCTAssertEqual(KeychainStore.migrateToAccessGroupIfNeeded()?.copied, ["download.huggingface"])
            XCTAssertTrue(flag.isSet)
            XCTAssertNil(KeychainStore.migrateToAccessGroupIfNeeded())
        }
    }

    /// The Security framework itself, on a service of its own so the real `dev.auralocal.remote` items are untouched.
    func testRealKeychainRoundTripOnATestService() throws {
        let location = KeychainStore.Location(service: "dev.auralocal.tests.\(UUID().uuidString)", accessGroup: nil)
        try KeychainStore.$locationOverride.withValue(location) {
            defer { KeychainStore.delete(for: "probe") }
            do {
                try KeychainStore.save("first", for: "probe")
            } catch {
                throw XCTSkip("Keychain unavailable in this test host: \(error)")
            }
            try KeychainStore.save("second", for: "probe")

            XCTAssertEqual(KeychainStore.read(for: "probe"), "second")
            XCTAssertTrue(KeychainStore.hasKey(for: "probe"))
            XCTAssertNil(KeychainStore.read(for: "absent"))
            KeychainStore.delete(for: "probe")
            XCTAssertFalse(KeychainStore.hasKey(for: "probe"))
        }
    }

    private var suites: [String] = []

    override func tearDown() {
        suites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
        suites = []
        super.tearDown()
    }

    private func makeFlag() -> KeychainStore.MergeFlag {
        let suite = "dev.auralocal.tests.keychain.\(UUID().uuidString)"
        suites.append(suite)
        return KeychainStore.MergeFlag(defaults: UserDefaults(suiteName: suite)!)
    }

    private func withKeychain(_ keychain: FakeKeychain, flag: KeychainStore.MergeFlag,
                              _ body: () throws -> Void) throws {
        let location = KeychainStore.Location(service: service, accessGroup: group)
        try KeychainStore.$backendOverride.withValue(keychain) {
            try KeychainStore.$locationOverride.withValue(location) {
                try KeychainStore.$mergeFlagOverride.withValue(flag, operation: body)
            }
        }
    }
}
