import Foundation

/// The fixed files of the browser page (``ServerFeatures/browserPage``), compiled into the SDK. They hold no
/// server data: names, models and limits arrive in the capability hello, after pairing.
enum PageAsset: String, CaseIterable, Sendable {
    case html = "/"
    case script = "/app.js"
    case stylesheet = "/app.css"

    static func at(_ target: String) -> PageAsset? {
        PageAsset(rawValue: target)
    }

    var path: String { rawValue }

    var bytes: Data {
        switch self {
        case .html: Self.htmlBytes
        case .script: Self.scriptBytes
        case .stylesheet: Self.stylesheetBytes
        }
    }

    var contentType: String {
        switch self {
        case .html: "text/html; charset=utf-8"
        case .script: "text/javascript; charset=utf-8"
        case .stylesheet: "text/css; charset=utf-8"
        }
    }

    private static let htmlBytes = Data(PackageResources.index_html)
    private static let scriptBytes = Data(PackageResources.app_js)
    private static let stylesheetBytes = Data(PackageResources.app_css)

    static let contentSecurityPolicy = "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; "
        + "img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
}
