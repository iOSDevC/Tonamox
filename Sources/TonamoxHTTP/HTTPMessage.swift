import Foundation

/// Methods the parser recognises. Anything else is answered 501; the router answers 405 for a known path.
package enum HTTPMethod: String, Sendable, Equatable, CaseIterable {
    case get = "GET", head = "HEAD", post = "POST", put = "PUT", delete = "DELETE"
    case options = "OPTIONS", patch = "PATCH", trace = "TRACE"
}

package struct HTTPField: Sendable, Equatable {
    package let name: String
    package let value: String

    package init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// Request fields in arrival order; lookups ignore the name's case.
package struct HTTPFields: Sendable, Equatable {
    package private(set) var entries: [HTTPField] = []

    package init(_ entries: [HTTPField] = []) {
        self.entries = entries
    }

    package mutating func append(_ field: HTTPField) {
        entries.append(field)
    }

    package var count: Int { entries.count }

    package subscript(name: String) -> String? {
        let wanted = name.lowercased()
        return entries.first { $0.name.lowercased() == wanted }?.value
    }

    package func occurrences(of name: String) -> Int {
        let wanted = name.lowercased()
        return entries.reduce(0) { $0 + ($1.name.lowercased() == wanted ? 1 : 0) }
    }
}

package struct HTTPRequestHead: Sendable, Equatable {
    package let method: HTTPMethod
    /// Origin-form path, already validated: no query, no percent, no dot segments.
    package let target: String
    package let fields: HTTPFields
    package let contentLength: Int
    package let expectsContinue: Bool

    package init(method: HTTPMethod, target: String, fields: HTTPFields, contentLength: Int,
                 expectsContinue: Bool) {
        self.method = method
        self.target = target
        self.fields = fields
        self.contentLength = contentLength
        self.expectsContinue = expectsContinue
    }

    /// Wire form, used by tests to round-trip accepted heads.
    package var serialized: [UInt8] {
        var text = "\(method.rawValue) \(target) HTTP/1.1\r\n"
        text += fields.entries.map { "\($0.name): \($0.value)\r\n" }.joined()
        text += "\r\n"
        return Array(text.utf8)
    }
}

/// Why a request head was refused. The connection closes after the response.
package struct HTTPRejection: Sendable, Equatable, Error {
    package let status: Int
    package let reason: String

    package init(status: Int, reason: String) {
        self.status = status
        self.reason = reason
    }
}

package enum HTTPParseOutcome: Sendable, Equatable {
    case needMoreData
    case head(HTTPRequestHead, consumed: Int)
    case reject(HTTPRejection)
}

package struct HTTPParseLimits: Sendable, Equatable {
    package var maxRequestLine = 2048
    package var maxTarget = 1024
    package var maxHeaderBlock = 8192
    package var maxFields = 64

    package init() {}
}

package struct HTTPResponseHead: Sendable, Equatable {
    package var status: Int
    package var fields: [HTTPField]

    package init(status: Int, fields: [HTTPField] = []) {
        self.status = status
        self.fields = fields
    }

    /// Fields that are not a token name with a printable ASCII value are dropped, so no caller can split the response.
    package var serialized: Data {
        var text = "HTTP/1.1 \(status) \(HTTPStatusText.phrase(for: status))\r\n"
        text += fields.filter(Self.isWritable).map { "\($0.name): \($0.value)\r\n" }.joined()
        text += "\r\n"
        return Data(text.utf8)
    }

    package static func isWritable(_ field: HTTPField) -> Bool {
        !field.name.isEmpty && field.name.utf8.allSatisfy(HTTPRequestParser.isTokenByte)
            && field.value.utf8.allSatisfy { $0 == 0x09 || (0x20...0x7E).contains($0) }
    }
}

package enum HTTPStatusText {
    package static func phrase(for status: Int) -> String {
        switch status {
        case 100: "Continue"
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 410: "Gone"
        case 411: "Length Required"
        case 413: "Content Too Large"
        case 414: "URI Too Long"
        case 415: "Unsupported Media Type"
        case 417: "Expectation Failed"
        case 421: "Misdirected Request"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 503: "Service Unavailable"
        case 505: "HTTP Version Not Supported"
        default: "Status"
        }
    }
}

/// IMF-fixdate for the `Date` header.
package enum HTTPDate {
    package static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    package static func string(for date: Date) -> String {
        formatter.string(from: date)
    }
}
