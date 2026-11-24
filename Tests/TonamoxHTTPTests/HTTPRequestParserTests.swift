import Foundation
import Testing
@testable import TonamoxHTTP

func parse(_ text: String) -> HTTPParseOutcome {
    var parser = HTTPRequestParser()
    return parser.feed(Array(text.utf8))
}

func parse(_ bytes: [UInt8]) -> HTTPParseOutcome {
    var parser = HTTPRequestParser()
    return parser.feed(bytes)
}

func rejection(_ outcome: HTTPParseOutcome) -> Int? {
    if case .reject(let rejection) = outcome { return rejection.status }
    return nil
}

func head(_ outcome: HTTPParseOutcome) -> HTTPRequestHead? {
    if case .head(let head, _) = outcome { return head }
    return nil
}

@Suite("HTTPRequestParser")
struct HTTPRequestParserTests {
    @Test func parsesMinimalGET() throws {
        let outcome = parse("GET /v1/models HTTP/1.1\r\nHost: 127.0.0.1:1\r\n\r\n")
        let parsed = try #require(head(outcome))
        #expect(parsed.method == .get)
        #expect(parsed.target == "/v1/models")
        #expect(parsed.contentLength == 0)
        #expect(parsed.fields["HOST"] == "127.0.0.1:1")
        guard case .head(_, let consumed) = outcome else { return }
        #expect(consumed == "GET /v1/models HTTP/1.1\r\nHost: 127.0.0.1:1\r\n\r\n".utf8.count)
    }

    @Test func parsesPOSTWithContentLength() throws {
        let parsed = try #require(head(parse("POST /x HTTP/1.1\r\nHost: h\r\nContent-Length: 12\r\nExpect: 100-continue\r\n\r\nbody")))
        #expect(parsed.method == .post)
        #expect(parsed.contentLength == 12)
        #expect(parsed.expectsContinue)
    }

    @Test func rejectsHTTP10With505() {
        #expect(rejection(parse("GET / HTTP/1.0\r\nHost: h\r\n\r\n")) == 505)
    }

    @Test func rejectsMissingHost() {
        #expect(rejection(parse("GET / HTTP/1.1\r\nAccept: */*\r\n\r\n")) == 400)
    }

    @Test func rejectsDuplicateHost() {
        #expect(rejection(parse("GET / HTTP/1.1\r\nHost: a\r\nhost: b\r\n\r\n")) == 400)
    }

    @Test func rejectsDuplicateContentLength() {
        #expect(rejection(parse("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\n")) == 400)
    }

    @Test(arguments: ["+5", "-5", " 5x", "5 5", "0x5", "5.0"])
    func rejectsContentLengthWithSignOrSpaces(_ value: String) {
        #expect(rejection(parse("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: \(value)\r\n\r\n")) == 400)
    }

    @Test func rejectsContentLengthOver10Digits() {
        #expect(rejection(parse("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 12345678901\r\n\r\n")) == 400)
    }

    @Test func rejectsTransferEncodingWith411() {
        #expect(rejection(parse("POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n")) == 411)
    }

    @Test func rejectsTransferEncodingWithContentLength() {
        #expect(rejection(parse("POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\nContent-Length: 3\r\n\r\n")) == 400)
    }

    @Test func rejectsBareLF() {
        #expect(rejection(parse("GET / HTTP/1.1\nHost: a\r\n\r\n")) == 400)
        #expect(rejection(parse("GET / HTTP/1.1\r\nHost: a\n\r\n")) == 400)
    }

    @Test func rejectsLoneCR() {
        #expect(rejection(parse("GET / HTTP/1.1\r\nHost: a\rX: b\r\n\r\n")) == 400)
    }

    @Test func rejectsObsFold() {
        #expect(rejection(parse("GET / HTTP/1.1\r\nHost: a\r\nX-A: b\r\n c\r\n\r\n")) == 400)
    }

    @Test func rejectsSpaceBeforeColon() {
        #expect(rejection(parse("GET / HTTP/1.1\r\nHost : a\r\n\r\n")) == 400)
    }

    @Test func rejectsNULInHead() {
        #expect(rejection(parse("GET / HTTP/1.1\r\nHost: a\0\r\n\r\n")) == 400)
    }

    @Test func rejectsObsTextInValue() {
        var bytes = Array("GET / HTTP/1.1\r\nHost: a\r\nX: ".utf8)
        bytes += [0xC3, 0xA9]
        bytes += Array("\r\n\r\n".utf8)
        #expect(rejection(parse(bytes)) == 400)
    }

    @Test func rejectsAbsoluteForm() {
        #expect(rejection(parse("GET http://evil/ HTTP/1.1\r\nHost: a\r\n\r\n")) == 400)
    }

    @Test func rejectsAuthorityForm() {
        #expect(rejection(parse("GET evil.com:443 HTTP/1.1\r\nHost: a\r\n\r\n")) == 400)
    }

    @Test func rejectsAsteriskForm() {
        #expect(rejection(parse("OPTIONS * HTTP/1.1\r\nHost: a\r\n\r\n")) == 400)
    }

    @Test func rejectsPercentInTarget() {
        #expect(rejection(parse("GET /v1/%2e%2e HTTP/1.1\r\nHost: a\r\n\r\n")) == 400)
    }

    @Test func rejectsQueryString() {
        #expect(rejection(parse("GET /v1/models?x=1 HTTP/1.1\r\nHost: a\r\n\r\n")) == 400)
        #expect(rejection(parse("GET /v1/models#frag HTTP/1.1\r\nHost: a\r\n\r\n")) == 400)
    }

    @Test func rejectsDotSegments() {
        #expect(rejection(parse("GET /v1/../etc HTTP/1.1\r\nHost: a\r\n\r\n")) == 400)
        #expect(rejection(parse("GET /v1/./models HTTP/1.1\r\nHost: a\r\n\r\n")) == 400)
        #expect(rejection(parse("GET /v1/.. HTTP/1.1\r\nHost: a\r\n\r\n")) == 400)
    }

    @Test func rejectsDoubleSlash() {
        #expect(rejection(parse("GET //v1/models HTTP/1.1\r\nHost: a\r\n\r\n")) == 400)
    }

    @Test func rejectsBackslash() {
        #expect(rejection(parse("GET /v1\\models HTTP/1.1\r\nHost: a\r\n\r\n")) == 400)
    }

    @Test func targetOver1KiBIs414() {
        let target = "/" + String(repeating: "a", count: 1100)
        #expect(rejection(parse("GET \(target) HTTP/1.1\r\nHost: a\r\n\r\n")) == 414)
    }

    @Test func headerBlockOver8KiBIs431() {
        let value = String(repeating: "v", count: 9000)
        #expect(rejection(parse("GET / HTTP/1.1\r\nHost: a\r\nX-Big: \(value)\r\n\r\n")) == 431)
    }

    @Test func moreThan64FieldsIs431() {
        let fields = (0..<65).map { "X-\($0): v\r\n" }.joined()
        #expect(rejection(parse("GET / HTTP/1.1\r\nHost: a\r\n\(fields)\r\n")) == 431)
    }

    @Test func unknownMethodIs501() {
        #expect(rejection(parse("BREW /pot HTTP/1.1\r\nHost: a\r\n\r\n")) == 501)
    }

    @Test func unknownExpectIs417() {
        #expect(rejection(parse("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 1\r\nExpect: 200-ok\r\n\r\n")) == 417)
    }

    @Test func http2PrefaceIsRejected() {
        #expect(rejection(parse("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")) != nil)
    }

    @Test func leadingZeroContentLengthRejected() {
        #expect(rejection(parse("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 05\r\n\r\n")) == 400)
        #expect(head(parse("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 0\r\n\r\n"))?.contentLength == 0)
    }

    @Test func requestLineOver2KiBIs400() {
        let target = "/" + String(repeating: "a", count: 2100)
        #expect(rejection(parse("GET \(target) HTTP/1.1\r\nHost: a\r\n\r\n")) == 400)
    }
}
