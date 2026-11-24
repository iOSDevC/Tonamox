import Foundation
import TonamoxCore
import TonamoxHTTP

/// An OpenAI-style error: `{"error":{"message","type","param","code"}}`. Messages are fixed text, never request
/// content or internals.
struct APIError: Error, Sendable, Equatable {
    let status: Int
    let type: String
    let code: String
    let message: String
    var param: String?
    var retryAfter: Int?
    var allow: String?

    var body: Data {
        let error: [String: Any] = ["message": message, "type": type, "code": code, "param": param ?? NSNull()]
        return WireJSON.data(["error": error])
    }

    /// One ASCII line for routes whose answer curl prints into a terminal.
    var textBody: Data {
        Data("tonamox: \(message) [\(code)]\n".utf8)
    }

    static func invalidRequest(_ code: String, _ message: String, param: String? = nil) -> APIError {
        APIError(status: 400, type: "invalid_request_error", code: code, message: message, param: param)
    }

    static func unsupported(_ param: String) -> APIError {
        invalidRequest("unsupported_parameter", "The parameter '\(param)' is not supported by this server.",
                       param: param)
    }

    static func invalidJSON(_ message: String = "The request body is not valid JSON.", param: String? = nil) -> APIError {
        invalidRequest("invalid_json", message, param: param)
    }

    static func invalidMessages(_ message: String) -> APIError {
        invalidRequest("invalid_messages", message, param: "messages")
    }

    static let missingKey = APIError(status: 401, type: "authentication_error", code: "invalid_api_key",
                                     message: "Missing API key: send Authorization: Bearer <key>.")
    static let invalidKey = APIError(status: 401, type: "authentication_error", code: "invalid_api_key",
                                     message: "Invalid API key.")
    static let expiredKey = APIError(status: 401, type: "authentication_error", code: "expired_api_key",
                                     message: "The API key has expired.")
    static let insufficientScope = APIError(status: 403, type: "permission_error", code: "insufficient_scope",
                                            message: "The API key does not allow this route.")
    static let originNotAllowed = APIError(status: 403, type: "permission_error", code: "origin_not_allowed",
                                           message: "Cross-origin requests are not allowed.")
    static let crossSite = APIError(status: 403, type: "permission_error", code: "cross_site",
                                    message: "Cross-site requests are not allowed.")
    static let notFound = APIError(status: 404, type: "not_found_error", code: "not_found", message: "Not found.")
    static let misdirected = APIError(status: 421, type: "invalid_request_error", code: "misdirected_request",
                                      message: "This server does not answer for that Host.")
    static let tooLarge = APIError(status: 413, type: "invalid_request_error", code: "request_too_large",
                                   message: "The request body is too large for this route.")
    static let mediaType = APIError(status: 415, type: "invalid_request_error", code: "unsupported_media_type",
                                    message: "Send the body as application/json.")
    static let rateLimited = APIError(status: 429, type: "rate_limit_error", code: "rate_limited",
                                      message: "Too many requests.", retryAfter: 60)
    static let authFlood = APIError(status: 429, type: "rate_limit_error", code: "rate_limited",
                                    message: "Too many failed authentications; try again later.", retryAfter: 60)
    static let serverBusy = APIError(status: 429, type: "rate_limit_error", code: "server_busy",
                                     message: "The model is busy; try again shortly.", retryAfter: 5)
    static let bodyBudget = APIError(status: 503, type: "server_error", code: "server_busy",
                                     message: "The server is receiving too much data; try again shortly.",
                                     retryAfter: 1)
    static let appBackgrounded = APIError(status: 503, type: "server_error", code: "app_backgrounded",
                                          message: "The app left the foreground.")
    static let modelUnavailable = APIError(status: 503, type: "server_error", code: "model_unavailable",
                                           message: "The model is not available.")
    static let modelChanged = APIError(status: 503, type: "server_error", code: "model_changed",
                                       message: "The model was removed from this server.")
    static let ticketUsed = APIError(status: 409, type: "invalid_request_error", code: "ticket_used",
                                     message: "This ticket was already used.")
    static let ticketInUse = APIError(status: 409, type: "invalid_request_error", code: "ticket_in_use",
                                      message: "Another upload with this ticket is in progress.")
    static let ticketExpired = APIError(status: 410, type: "invalid_request_error", code: "ticket_expired",
                                        message: "This ticket has expired.")
    static let ingestTooLarge = APIError(status: 413, type: "invalid_request_error", code: "request_too_large",
                                         message: "The output is larger than this ticket allows.")
    static let invalidExitStatus = invalidRequest("invalid_header",
                                                  "X-Tonamox-Exit-Status must be one decimal 32-bit integer.",
                                                  param: "X-Tonamox-Exit-Status")
    static let expiredSession = APIError(status: 401, type: "authentication_error", code: "expired_api_key",
                                         message: "The browser session has expired; pair again.")
    static let pairingClosed = APIError(status: 403, type: "permission_error", code: "pairing_closed",
                                        message: "Pairing is closed; open a pairing window on the device first.")
    static let pairingBusy = APIError(status: 409, type: "invalid_request_error", code: "pairing_busy",
                                      message: "Another pairing request is pending.")
    static let pairingExpired = APIError(status: 410, type: "invalid_request_error", code: "pairing_expired",
                                         message: "The pairing request has expired.")
    static let wrongPairingCode = APIError(status: 403, type: "permission_error", code: "invalid_pairing_code",
                                           message: "The code does not match.")
    static let originRequired = APIError(status: 403, type: "permission_error", code: "origin_not_allowed",
                                         message: "Pairing is only accepted from this server's own page.")
    static let internalError = APIError(status: 500, type: "server_error", code: "internal",
                                        message: "Internal server error.")

    static func modelNotFound(_ id: String) -> APIError {
        APIError(status: 404, type: "not_found_error", code: "model_not_found",
                 message: "The model '\(WireJSON.printable(id, limit: 80))' does not exist.", param: "model")
    }

    static func contextLengthExceeded(limit: Int) -> APIError {
        invalidRequest("context_length_exceeded",
                       "The prompt plus max_tokens exceeds the model's context of \(limit) tokens.",
                       param: "messages")
    }

    static let unsupportedLanguage = invalidRequest("unsupported_language",
                                                    "The model does not support the language of this request.")

    static func methodNotAllowed(_ allow: String) -> APIError {
        APIError(status: 405, type: "invalid_request_error", code: "method_not_allowed",
                 message: "Method not allowed.", allow: allow)
    }

    /// A head the parser refused.
    static func http(_ rejection: HTTPRejection) -> APIError {
        let type = rejection.status >= 500 ? "server_error" : "invalid_request_error"
        return APIError(status: rejection.status, type: type, code: "bad_request",
                        message: HTTPStatusText.phrase(for: rejection.status) + ".")
    }

    /// A model failure, given whether the server is suspended right now.
    static func from(_ error: Error, suspended: Bool) -> APIError {
        switch error as? ServedModelError {
        case .busy?: return .serverBusy
        case .notLoaded?: return .modelUnavailable
        case .interrupted?: return suspended ? .appBackgrounded : .modelUnavailable
        case .contextLengthExceeded(let limit)?: return .contextLengthExceeded(limit: limit)
        case .unsupported(let param)?: return .unsupported(param)
        case .toolsNotAllowed?: return .unsupported("tools")
        case .unsupportedLanguage?: return .unsupportedLanguage
        case nil:
            if let api = error as? APIError { return api }
            return LlamaDecodeFailure.matches(error) ? .modelUnavailable : .internalError
        }
    }

    /// The type and case of an error ``from(_:suspended:)`` had to classify, for the log; `nil` for errors that
    /// already name their code. Never the payload, which can quote the request.
    static func cause(of error: any Error) -> String? {
        guard !(error is APIError), !(error is ServedModelError) else { return nil }
        if Swift.type(of: error) is NSError.Type {
            let bridged = error as NSError
            return "\(bridged.domain) \(bridged.code)"
        }
        let name = String(reflecting: Swift.type(of: error))
        let mirror = Mirror(reflecting: error)
        guard mirror.displayStyle == .enum else { return name }
        if let label = mirror.children.first?.label { return name + "." + label }
        let plain = String(describing: error)
        return plain.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } ? name + "." + plain : name
    }
}

enum WireJSON {
    static func data(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// Printable ASCII only, truncated: untrusted text echoed in an error message.
    static func printable(_ text: String, limit: Int) -> String {
        String(text.unicodeScalars.filter { (0x20...0x7E).contains($0.value) }.prefix(limit).map(Character.init))
    }
}
