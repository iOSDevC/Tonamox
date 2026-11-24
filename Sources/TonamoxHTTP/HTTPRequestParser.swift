import Foundation

/// Strict HTTP/1.1 request-head parser for the subset the server accepts. Pure: no I/O, no clock.
///
/// Every rule is decided from the bytes seen so far, scanning left to right, so the outcome does not depend on
/// how the input is split across `feed` calls. After a head or a rejection the outcome is final.
package struct HTTPRequestParser: Sendable {
    private static let cr: UInt8 = 0x0D
    private static let lf: UInt8 = 0x0A
    private static let space: UInt8 = 0x20
    private static let tab: UInt8 = 0x09
    private static let singletons: Set<String> = ["host", "content-length", "authorization", "origin", "content-type"]
    private static let tokenSymbols = Set("!#$%&'*+-.^_`|~".utf8)

    private let limits: HTTPParseLimits
    private var buffer: [UInt8] = []
    private var scanned = 0
    private var lineStart = 0
    private var headerStart: Int?
    private var method: HTTPMethod?
    private var target = ""
    private var fields = HTTPFields()
    private var outcome: HTTPParseOutcome?

    package init(limits: HTTPParseLimits = HTTPParseLimits()) {
        self.limits = limits
    }

    package mutating func feed(_ bytes: some Collection<UInt8>) -> HTTPParseOutcome {
        if let outcome { return outcome }
        buffer.append(contentsOf: bytes)
        while scanned < buffer.count {
            if let decided = step() {
                outcome = decided
                return decided
            }
        }
        return .needMoreData
    }

    // MARK: - Scanning

    private mutating func step() -> HTTPParseOutcome? {
        let index = scanned
        let byte = buffer[index]
        scanned += 1
        if byte == 0 { return Self.reject(400, "NUL in head") }
        if index > lineStart, buffer[index - 1] == Self.cr, byte != Self.lf {
            return Self.reject(400, "lone CR")
        }
        if byte == Self.lf {
            guard index > lineStart, buffer[index - 1] == Self.cr else { return Self.reject(400, "bare LF") }
            let line = lineStart..<(index - 1)
            lineStart = index + 1
            return completeLine(line, end: index + 1)
        }
        if let headerStart {
            if index + 1 - headerStart > limits.maxHeaderBlock { return Self.reject(431, "header block too large") }
        } else if index + 1 - lineStart > limits.maxRequestLine {
            return Self.reject(400, "request line too long")
        }
        return nil
    }

    private mutating func completeLine(_ line: Range<Int>, end: Int) -> HTTPParseOutcome? {
        guard headerStart != nil else {
            headerStart = end
            return parseRequestLine(line)
        }
        if line.isEmpty { return finish(consumed: end) }
        return parseField(line)
    }

    private mutating func parseRequestLine(_ line: Range<Int>) -> HTTPParseOutcome? {
        let parts = buffer[line].split(separator: Self.space, omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { return Self.reject(400, "malformed request line") }
        guard parts[0].allSatisfy(Self.isTokenByte) else { return Self.reject(400, "malformed method") }
        let version = Self.text(parts[2])
        guard Self.isVersionSyntax(version) else { return Self.reject(400, "malformed version") }
        guard version == "HTTP/1.1" else { return Self.reject(505, "only HTTP/1.1") }
        guard let known = HTTPMethod(rawValue: Self.text(parts[0])) else { return Self.reject(501, "unknown method") }
        let rawTarget = parts[1]
        guard rawTarget.first == UInt8(ascii: "/") else { return Self.reject(400, "target must be origin-form") }
        guard rawTarget.count <= limits.maxTarget else { return Self.reject(414, "target too long") }
        guard rawTarget.allSatisfy(Self.isTargetByte) else { return Self.reject(400, "forbidden byte in target") }
        let path = Self.text(rawTarget)
        guard !path.contains("//") else { return Self.reject(400, "empty path segment") }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.contains(where: { $0 == "." || $0 == ".." }) else { return Self.reject(400, "dot segment") }
        method = known
        target = path
        return nil
    }

    private mutating func parseField(_ line: Range<Int>) -> HTTPParseOutcome? {
        let first = buffer[line.lowerBound]
        if first == Self.space || first == Self.tab { return Self.reject(400, "obs-fold") }
        guard let colon = buffer[line].firstIndex(of: UInt8(ascii: ":")) else { return Self.reject(400, "field without colon") }
        let name = line.lowerBound..<colon
        guard !name.isEmpty else { return Self.reject(400, "empty field name") }
        guard buffer[name].allSatisfy(Self.isTokenByte) else { return Self.reject(400, "invalid field name") }
        let rawValue = (colon + 1)..<line.upperBound
        for byte in buffer[rawValue] where !Self.isValueByte(byte) {
            return Self.reject(400, byte >= 0x80 ? "obs-text in value" : "control byte in value")
        }
        guard fields.count < limits.maxFields else { return Self.reject(431, "too many fields") }
        let field = makeField(nameRange: name, valueRange: Self.trimmed(rawValue, in: buffer))
        if Self.singletons.contains(field.name.lowercased()), fields[field.name] != nil {
            return Self.reject(400, "duplicate \(field.name.lowercased())")
        }
        fields.append(field)
        return nil
    }

    private func makeField(nameRange: Range<Int>, valueRange: Range<Int>) -> HTTPField {
        HTTPField(name: Self.text(buffer[nameRange]), value: Self.text(buffer[valueRange]))
    }

    private func finish(consumed: Int) -> HTTPParseOutcome {
        guard let method else { return Self.reject(400, "no request line") }
        guard fields["host"] != nil else { return Self.reject(400, "missing host") }
        let length = fields["content-length"]
        if fields["transfer-encoding"] != nil {
            return length == nil ? Self.reject(411, "transfer-encoding not supported")
                                 : Self.reject(400, "transfer-encoding with content-length")
        }
        var contentLength = 0
        if let length {
            guard let parsed = Self.parseContentLength(length) else { return Self.reject(400, "invalid content-length") }
            contentLength = parsed
        } else if method == .post {
            return Self.reject(411, "content-length required")
        }
        var expectsContinue = false
        if let expect = fields["expect"] {
            guard expect.lowercased() == "100-continue" else { return Self.reject(417, "unsupported expectation") }
            expectsContinue = true
        }
        let head = HTTPRequestHead(method: method, target: target, fields: fields, contentLength: contentLength,
                                   expectsContinue: expectsContinue)
        return .head(head, consumed: consumed)
    }

    // MARK: - Byte classes

    /// 1-10 digits, no sign, no blanks, no leading zero unless the value is exactly `0`.
    package static func parseContentLength(_ value: String) -> Int? {
        let digits = Array(value.utf8)
        guard (1...10).contains(digits.count), digits.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        guard digits.count == 1 || digits[0] != 0x30 else { return nil }
        return Int(value)
    }

    package static func isTokenByte(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
            || tokenSymbols.contains(byte)
    }

    private static func isTargetByte(_ byte: UInt8) -> Bool {
        (0x21...0x7E).contains(byte) && byte != UInt8(ascii: "%") && byte != UInt8(ascii: "?")
            && byte != UInt8(ascii: "#") && byte != UInt8(ascii: "\\")
    }

    private static func isValueByte(_ byte: UInt8) -> Bool {
        (0x21...0x7E).contains(byte) || byte == space || byte == tab
    }

    private static func isVersionSyntax(_ version: String) -> Bool {
        let bytes = Array(version.utf8)
        guard bytes.count == 8, version.hasPrefix("HTTP/"), bytes[6] == UInt8(ascii: ".") else { return false }
        return (0x30...0x39).contains(bytes[5]) && (0x30...0x39).contains(bytes[7])
    }

    private static func trimmed(_ range: Range<Int>, in bytes: [UInt8]) -> Range<Int> {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, bytes[lower] == space || bytes[lower] == tab { lower += 1 }
        while upper > lower, bytes[upper - 1] == space || bytes[upper - 1] == tab { upper -= 1 }
        return lower..<upper
    }

    private static func text(_ bytes: some Sequence<UInt8>) -> String {
        String(decoding: Array(bytes), as: UTF8.self)
    }

    private static func reject(_ status: Int, _ reason: String) -> HTTPParseOutcome {
        .reject(HTTPRejection(status: status, reason: reason))
    }
}
