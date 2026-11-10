import CryptoKit
import Foundation
import Testing
@testable import TerminalBridgeKit

@Suite struct RecentWriteIDsTests {
    private func makeIDs(_ count: Int) -> [UUID] {
        (0..<count).map { _ in UUID() }
    }

    @Test func remembersAndEvictsTheOldest() {
        let ids = makeIDs(4)
        let recent = RecentWriteIDs(capacity: 3)
        for id in ids {
            recent.insert(id)
        }
        #expect(recent.count == 3)
        #expect(!recent.contains(ids[0]))
        #expect(ids.dropFirst().allSatisfy(recent.contains))
    }

    @Test func seedKeepsTheNewestEntries() {
        let ids = makeIDs(300)
        let recent = RecentWriteIDs(seed: ids)
        #expect(recent.count == BridgeConstants.recentWriteCapacity)
        #expect(recent.contains(ids[299]))
        #expect(!recent.contains(ids[0]))
    }

    @Test func reinsertingRefreshesAnEntry() {
        let ids = makeIDs(3)
        let recent = RecentWriteIDs(capacity: 2, seed: [ids[0], ids[1]])
        recent.insert(ids[0])
        recent.insert(ids[2])
        #expect(recent.contains(ids[0]))
        #expect(!recent.contains(ids[1]))
    }

    @Test func digestsMatchIndependentValues() {
        // `printf %s "printf hello" | shasum -a 256`
        #expect(BridgeDigest.sha256Hex("printf hello")
            == "2189aff6492b39e6aa62f939b98cbc0cfaa1392da9df3a5ef73a7b0b369119d3")
        let key = SymmetricKey(data: Data(repeating: 1, count: 32))
        let keyed = BridgeDigest.hmacSHA256Hex("ls -la", key: key)
        #expect(keyed.count == 64)
        #expect(keyed != BridgeDigest.sha256Hex("ls -la"))
        #expect(keyed == BridgeDigest.hmacSHA256Hex("ls -la", key: key))
    }
}
