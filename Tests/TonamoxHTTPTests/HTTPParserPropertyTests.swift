import Foundation
import Testing
@testable import TonamoxHTTP

/// Deterministic generator; the seed of a failing case is in the expectation's message.
struct SplitMix64 {
    private(set) var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func reseed(_ seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func below(_ bound: Int) -> Int {
        bound <= 0 ? 0 : Int(next() % UInt64(bound))
    }

    mutating func byte() -> UInt8 {
        UInt8(truncatingIfNeeded: next())
    }
}

enum Fuzz {
    static let iterations = ProcessInfo.processInfo.environment["TONAMOX_FUZZ_ITERATIONS"].flatMap(Int.init) ?? 10_000
    static let baseSeed = ProcessInfo.processInfo.environment["TONAMOX_FUZZ_SEED"].flatMap(UInt64.init) ?? 0x7A6F_5EED

    static let corpus: [[UInt8]] = [
        "GET /v1/models HTTP/1.1\r\nHost: 127.0.0.1:47830\r\nAuthorization: Bearer tnx_x\r\n\r\n",
        "POST /v1/chat/completions HTTP/1.1\r\nHost: localhost:1\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}",
        "POST /i/abc HTTP/1.1\r\nHost: h:1\r\nContent-Length: 0\r\nExpect: 100-continue\r\nUser-Agent: curl/8.7.1\r\n\r\n",
        "GET /v1/models/qwen3_1_7b HTTP/1.1\r\nHost: h\r\nOrigin: http://h\r\nSec-Fetch-Site: same-origin\r\nX-Empty:\r\n\r\n",
    ].map { Array($0.utf8) }

    static let tokens: [[UInt8]] = ["\r\n", "\r", "\n", " ", ":", "\0", "Host: a\r\n", "Content-Length: 9\r\n",
                                    "Transfer-Encoding: chunked\r\n", "%", "..", "//", "\t", "\u{7F}", "é"]
        .map { Array($0.utf8) }

    static func randomBytes(_ rng: inout SplitMix64) -> [UInt8] {
        (0..<rng.below(600)).map { _ in rng.byte() }
    }

    static func mutated(_ rng: inout SplitMix64) -> [UInt8] {
        var bytes = corpus[rng.below(corpus.count)]
        for _ in 0..<(1 + rng.below(4)) {
            applyMutation(&bytes, &rng)
        }
        return bytes
    }

    private static func applyMutation(_ bytes: inout [UInt8], _ rng: inout SplitMix64) {
        let position = rng.below(bytes.count + 1)
        switch rng.below(5) {
        case 0 where position < bytes.count: bytes[position] = rng.byte()
        case 1 where position < bytes.count: bytes.remove(at: position)
        case 2: bytes.insert(contentsOf: tokens[rng.below(tokens.count)], at: position)
        case 3: bytes.insert(rng.byte(), at: position)
        default: bytes.insert(contentsOf: bytes[position...].prefix(rng.below(40)), at: position)
        }
    }

    static func input(_ rng: inout SplitMix64) -> [UInt8] {
        switch rng.below(3) {
        case 0: randomBytes(&rng)
        case 1: mutated(&rng)
        default: corpus[rng.below(corpus.count)]
        }
    }

    static func whole(_ bytes: [UInt8]) -> HTTPParseOutcome {
        var parser = HTTPRequestParser()
        return parser.feed(bytes)
    }

    static func split(_ bytes: [UInt8], _ rng: inout SplitMix64) -> HTTPParseOutcome {
        var parser = HTTPRequestParser()
        var outcome = HTTPParseOutcome.needMoreData
        var start = 0
        while start < bytes.count {
            let end = min(bytes.count, start + 1 + rng.below(32))
            outcome = parser.feed(bytes[start..<end])
            start = end
        }
        return bytes.isEmpty ? parser.feed([]) : outcome
    }

    static func byteByByte(_ bytes: [UInt8]) -> HTTPParseOutcome {
        var parser = HTTPRequestParser()
        var outcome = parser.feed([])
        for index in bytes.indices {
            outcome = parser.feed(bytes[index...index])
        }
        return outcome
    }

    /// Runs `check` for every iteration until it fails once.
    static func forAll(_ property: String, _ check: (inout SplitMix64, UInt64) -> Bool) {
        var rng = SplitMix64(seed: baseSeed)
        for iteration in 0..<iterations {
            let seed = baseSeed &+ UInt64(iteration)
            rng.reseed(seed)
            guard check(&rng, seed) else {
                Issue.record("\(property) failed: TONAMOX_FUZZ_SEED base \(baseSeed), case seed \(seed)")
                return
            }
        }
    }
}

@Suite("HTTPRequestParser properties")
struct HTTPParserPropertyTests {
    @Test func parserNeverTrapsOnRandomBytes() {
        Fuzz.forAll("random bytes") { rng, _ in
            _ = Fuzz.whole(Fuzz.randomBytes(&rng))
            return true
        }
    }

    @Test func parserNeverTrapsOnMutatedValidRequests() {
        Fuzz.forAll("mutated requests") { rng, _ in
            _ = Fuzz.whole(Fuzz.mutated(&rng))
            return true
        }
    }

    @Test func parserIsSplitInvariant() {
        Fuzz.forAll("split invariance") { rng, _ in
            let bytes = Fuzz.input(&rng)
            return Fuzz.split(bytes, &rng) == Fuzz.whole(bytes)
        }
    }

    @Test func byteByByteEqualsWholeBuffer() {
        Fuzz.forAll("byte by byte") { rng, _ in
            let bytes = Fuzz.input(&rng)
            return Fuzz.byteByByte(bytes) == Fuzz.whole(bytes)
        }
    }

    @Test func truncationAtEveryOffsetIsIncompleteOrRejected() {
        Fuzz.forAll("truncation") { rng, _ in
            let bytes = Fuzz.input(&rng)
            guard case .head(_, let consumed) = Fuzz.whole(bytes) else { return true }
            return (0..<consumed).allSatisfy { offset in
                switch Fuzz.whole(Array(bytes[..<offset])) {
                case .head: false
                case .needMoreData, .reject: true
                }
            }
        }
    }

    @Test func acceptedHeadsRoundTrip() {
        Fuzz.forAll("round trip") { rng, _ in
            guard case .head(let parsed, _) = Fuzz.whole(Fuzz.input(&rng)) else { return true }
            guard case .head(let again, let consumed) = Fuzz.whole(parsed.serialized) else { return false }
            return again == parsed && consumed == parsed.serialized.count
        }
    }

    @Test func parserNeverConsumesPastHead() {
        Fuzz.forAll("consumed bound") { rng, _ in
            let bytes = Fuzz.input(&rng)
            guard case .head(_, let consumed) = Fuzz.whole(bytes) else { return true }
            return consumed <= bytes.count && consumed >= 4 && Array(bytes[(consumed - 4)..<consumed]) == [13, 10, 13, 10]
        }
    }
}
