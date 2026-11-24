import CryptoKit
import Foundation
import Testing
@testable import TonamoxHTTP

@Suite("Tokens and limits")
struct TokenAndLimitTests {
    @Test func secretTokenHasRequestedEntropyAndAlphabet() {
        let token = SecretToken.random(bits: 256, prefix: "tnx_")
        #expect(token.text.hasPrefix("tnx_"))
        let body = token.text.dropFirst(4)
        #expect(body.count == 43)
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        #expect(body.allSatisfy { alphabet.contains($0) })
        #expect(SecretToken.random(bits: 128).text.count == 22)
        #expect(token.text != SecretToken.random(bits: 256, prefix: "tnx_").text)
    }

    @Test func secretTokenDescriptionHidesValue() {
        let token = SecretToken.random(bits: 256)
        #expect(!String(describing: token).contains(token.text))
        #expect(!String(reflecting: token).contains(token.text))
        #expect(!"\(token)".contains(token.text))
    }

    @Test func matchesComparesWholeDigest() {
        let token = SecretToken.random(bits: 256, prefix: "tnx_")
        #expect(SecretToken.matches(token.text, storedHash: token.storedHash))
        #expect(!SecretToken.matches(token.text + "x", storedHash: token.storedHash))
        var lastByteDiffers = Array(token.storedHash)
        lastByteDiffers[31] ^= 1
        #expect(!SecretToken.constantTimeEqual(Array(token.storedHash), lastByteDiffers))
        var firstByteDiffers = Array(token.storedHash)
        firstByteDiffers[0] ^= 0x80
        #expect(!SecretToken.constantTimeEqual(Array(token.storedHash), firstByteDiffers))
        #expect(!SecretToken.constantTimeEqual(Array(token.storedHash), Array(Array(token.storedHash).prefix(31))))
    }

    @Test func crockfordNormalizesCaseHyphenAndAmbiguousLetters() {
        #expect(CrockfordCode.normalize("abcd-efgh") == "ABCDEFGH")
        #expect(CrockfordCode.normalize("I1L0-o0OK") == "1110000K")
        #expect(CrockfordCode.normalize("ilo") == "110")
        #expect(CrockfordCode.normalize("O-o-0") == "000")
        #expect(CrockfordCode.normalize("ABCU") == nil)
        #expect(CrockfordCode.normalize("AB C") == nil)
        let code = CrockfordCode.random(length: 8)
        #expect(code.count == 8)
        #expect(CrockfordCode.normalize(code.lowercased()) == code)
    }

    @Test func tokenBucketRefillsOnInjectedClock() {
        let start = ContinuousClock.now
        var bucket = TokenBucket(capacity: 2, per: .seconds(60), now: start)
        let offsets: [Duration] = [.zero, .zero, .zero, .seconds(29), .seconds(31)]
        let taken = offsets.map { bucket.take(now: start + $0) }
        #expect(taken == [true, true, false, false, true])
        let refilled = bucket.remaining(now: start + .seconds(600))
        #expect(refilled == 2)
    }

    @Test func tokenBucketBlocksAfterBudget() {
        let start = ContinuousClock.now
        var buckets = KeyedTokenBuckets<String>(capacity: 3, per: .seconds(60))
        let taken = (0..<5).map { _ in buckets.take("a", now: start) }
        #expect(taken == [true, true, true, false, false])
        let otherKey = buckets.take("b", now: start)
        #expect(otherKey)
    }

    @Test func keyedBucketsDropRefilledKeys() {
        let start = ContinuousClock.now
        var buckets = KeyedTokenBuckets<Int>(capacity: 3, per: .seconds(60))
        for index in 0..<5_000 {
            _ = buckets.take(index, now: start + .seconds(index))
        }
        // Only keys used within the last minute are still partly drained; the rest are full and dropped.
        #expect(buckets.count <= 2 * KeyedTokenBuckets<Int>.minimumPruneSize)
        let recentKeyStillServed = buckets.take(4_999, now: start + .seconds(4_999))
        #expect(recentKeyStillServed)
    }
}
