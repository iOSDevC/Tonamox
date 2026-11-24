import Foundation
import Testing
import TerminalBridgeKit

@Suite struct APIKeyStorageTextTests {
    @Test func keychainFooterSaysWhereKeysLiveAndWhatIsKept() {
        let footer = APIKeyStorage.keychain.footer
        #expect(footer.contains("llavero de este iPhone"))
        #expect(footer.contains("SHA-256"))
        #expect(footer.contains("no se guarda"))
        #expect(footer.contains("iCloud"))
        #expect(footer.contains("ninguna otra app"))
        #expect(footer.contains("dirección del último equipo"))
        #expect(APIKeyStorage.keychain.warning == nil)
    }

    @Test func memoryOnlySaysKeysEndWithTheApp() throws {
        #expect(APIKeyStorage.memoryOnly.footer.contains("hasta que cierres la app"))
        let warning = try #require(APIKeyStorage.memoryOnly.warning)
        #expect(warning.contains("grupo propio del llavero"))
    }

    @Test func issuingStopsAtTheMaximum() {
        #expect(APIKeyStorageText.issueRefusal(liveKeys: APIKeyStorageText.maximumKeys - 1) == nil)
        let refusal = APIKeyStorageText.issueRefusal(liveKeys: APIKeyStorageText.maximumKeys)
        #expect(refusal?.contains("Revoca alguna") == true)
    }

    @Test func liveCountLeavesExpiredKeysOut() {
        let now = Date()
        let expiries: [Date?] = [nil, now.addingTimeInterval(60), now, now.addingTimeInterval(-1)]
        #expect(APIKeyStorageText.liveCount(expiries: expiries, now: now) == 2)
    }

    @Test func expiryTextNamesExpiredKeys() {
        let now = Date()
        #expect(APIKeyStorageText.expiry(expiresAt: nil, now: now, formatted: "") == "sin caducidad")
        #expect(APIKeyStorageText.expiry(expiresAt: now.addingTimeInterval(60), now: now, formatted: "1/1/27")
            == "caduca 1/1/27")
        #expect(APIKeyStorageText.expiry(expiresAt: now, now: now, formatted: "x").hasPrefix("caducada"))
    }

    @Test func failuresCarryTheStatusAndSayWhatHappened() {
        let issue = APIKeyStorageText.issueNotSaved(status: -25308)
        #expect(issue.contains("OSStatus -25308") && issue.contains("no se creó"))
        #expect(!APIKeyStorageText.issueNotSaved(status: nil).contains("OSStatus"))
        let revoke = APIKeyStorageText.revokeNotSaved(status: -25300)
        #expect(revoke.contains("no se pudo borrar del llavero") && revoke.contains("volvería a valer"))
        #expect(APIKeyStorageText.startRefusedUnreadable(status: -26275).contains("no se inicia"))
    }

    @Test func revokeAllTitleCountsKeys() {
        #expect(APIKeyStorageText.revokeAllTitle(count: 1) == "¿Revocar la clave?")
        #expect(APIKeyStorageText.revokeAllTitle(count: 3) == "¿Revocar las 3 claves?")
    }
}

@Suite struct PendingRevocationsTests {
    let first = UUID()
    let second = UUID()
    let third = UUID()

    @Test func aFailedRevokeHidesTheKeyUntilASaveSucceeds() {
        var pending = PendingRevocations()
        pending.recordFailedSave(known: [first, second], attempted: [first])
        #expect(pending.ids == [second])
        #expect(pending.filter([first, second, third]) == [first, third])
        pending.confirmSaved()
        #expect(pending.ids.isEmpty)
    }

    @Test func aFailedIssueRevokesNothing() {
        var pending = PendingRevocations()
        pending.recordFailedSave(known: [first], attempted: [first, second])
        #expect(pending.ids.isEmpty)
    }

    @Test func failuresAccumulate() {
        var pending = PendingRevocations()
        pending.recordFailedSave(known: [first, second, third], attempted: [first, third])
        pending.recordFailedSave(known: [first, second, third], attempted: [second])
        #expect(pending.ids == [first, second, third])
    }
}

@Suite struct OwnKeychainGroupTests {
    static let shared: Set<String> = ["group.io.example.shared"]

    @Test func theApplicationIdentifierIsOwn() {
        #expect(OwnKeychainGroup.isOwn("ABCDE12345.io.example.app", sharedGroups: Self.shared))
    }

    @Test func anAppGroupOrAnEmptyGroupIsNot() {
        #expect(!OwnKeychainGroup.isOwn("group.io.example.shared", sharedGroups: Self.shared))
        #expect(!OwnKeychainGroup.isOwn("group.io.example.other", sharedGroups: Self.shared))
        #expect(!OwnKeychainGroup.isOwn("", sharedGroups: Self.shared))
    }

    @Test func aListedSharedGroupWithoutThePrefixIsNot() {
        #expect(!OwnKeychainGroup.isOwn("ABCDE12345.shared", sharedGroups: ["ABCDE12345.shared"]))
    }
}
