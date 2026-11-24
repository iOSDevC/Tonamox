import Foundation

// Pure parts of TonamoxTerminal's remote reply engine: no network, no Tonamox import.

/// What a cumulative update adds to the text already emitted.
public enum TextDelta: Hashable, Sendable {
    /// Text to append; empty when the update repeats what was emitted.
    case append(String)
    /// The update does not start with what was emitted, so it cannot be turned into a delta.
    case diverged
}

/// Turns a stream of cumulative texts (each update is the whole answer so far) into deltas.
public struct CumulativeTextDiffer: Sendable {
    // Unicode scalars, not Characters: a combining mark arriving in the next update changes the last Character
    // of the emitted text, which a Character prefix check would report as a divergence.
    private var emitted: [Unicode.Scalar] = []

    public init() {}

    public mutating func next(_ cumulative: String) -> TextDelta {
        let scalars = Array(cumulative.unicodeScalars)
        guard !scalars.isEmpty else { return .append("") }
        guard scalars.count >= emitted.count, scalars.starts(with: emitted) else { return .diverged }
        var delta = String.UnicodeScalarView()
        delta.append(contentsOf: scalars[emitted.count...])
        emitted = scalars
        return .append(String(delta))
    }
}

/// Why a server address typed by the user was refused.
public enum ServerAddressRefusal: Error, Hashable, Sendable {
    case empty
    case invalid
    case unsupportedScheme
    case missingHost
    case containsCredentials
    case containsQueryOrFragment
    case plainHTTPOutsideLocalNetwork

    public var message: String {
        switch self {
        case .empty:
            "Escribe la dirección del servidor, por ejemplo http://192.168.1.20:8080/v1."
        case .invalid:
            "La dirección no es válida."
        case .unsupportedScheme:
            "Solo se admiten direcciones que empiecen por http:// o https://."
        case .missingHost:
            "Falta el servidor en la dirección."
        case .containsCredentials:
            "Quita el usuario y la contraseña de la dirección: la clave va en su propio campo."
        case .containsQueryOrFragment:
            "La dirección no puede llevar ? ni #."
        case .plainHTTPOutsideLocalNetwork:
            "Con http:// solo se admite una dirección IP de tu red local (por ejemplo 192.168.1.20) o 127.0.0.1. "
                + "Para un nombre o un servidor de internet usa https://."
        }
    }
}

/// The base URL of an OpenAI-compatible server (the part `chat/completions` is appended to).
public struct CompatibleServerAddress: Hashable, Sendable {
    public let url: URL
    /// The host is a loopback or private IP literal. Names, `.local` included, never count: they may resolve
    /// anywhere.
    public let isLocalNetwork: Bool

    /// Host and port as the consent sheet names them, e.g. `192.168.1.20:8080` or `[fe80::1]`.
    public var hostLabel: String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var host = components?.host ?? "?"
        if host.contains(":") && !host.hasPrefix("[") { host = "[" + host + "]" }
        return components?.port.map { host + ":\($0)" } ?? host
    }

    /// Scheme, host and port with the default port filled in: what a saved key is bound to.
    public var origin: String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let scheme = components?.scheme?.lowercased() ?? ""
        var host = (components?.host ?? "").lowercased()
        if host.contains(":") && !host.hasPrefix("[") { host = "[" + host + "]" }
        let port = components?.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }

    /// Plain http is accepted only for loopback and private IP literals; anything else needs https.
    public static func parse(_ raw: String) -> Result<CompatibleServerAddress, ServerAddressRefusal> {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        guard let components = URLComponents(string: text), let url = components.url,
              let scheme = components.scheme?.lowercased() else { return .failure(.invalid) }
        guard scheme == "http" || scheme == "https" else { return .failure(.unsupportedScheme) }
        guard let host = components.host, !host.isEmpty else { return .failure(.missingHost) }
        guard components.user == nil, components.password == nil else { return .failure(.containsCredentials) }
        guard components.query == nil, components.fragment == nil else {
            return .failure(.containsQueryOrFragment)
        }
        let isLocal = isPrivateIPLiteral(host)
        if scheme == "http" && !isLocal { return .failure(.plainHTTPOutsideLocalNetwork) }
        return .success(CompatibleServerAddress(url: url, isLocalNetwork: isLocal))
    }

    /// Loopback, RFC 1918, link-local, `::1`, `fc00::/7` and `fe80::/10` literals.
    static func isPrivateIPLiteral(_ rawHost: String) -> Bool {
        var host = rawHost
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            let b = withUnsafeBytes(of: &v4) { Array($0) }
            return b[0] == 127 || b[0] == 10
                || (b[0] == 172 && (16...31).contains(b[1]))
                || (b[0] == 192 && b[1] == 168)
                || (b[0] == 169 && b[1] == 254)
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            let b = withUnsafeBytes(of: &v6) { Array($0) }
            if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }
            if b[0] & 0xFE == 0xFC { return true }
            return b[0] == 0xFE && b[1] & 0xC0 == 0x80
        }
        return false
    }
}

/// Why a remote engine cannot be chosen right now, in the order the user has to fix it.
public enum RemoteEngineReadiness {
    public static func blocker(
        modeIsOff: Bool, isCloud: Bool, cloudAllowed: Bool, hasKey: Bool, isConfigured: Bool
    ) -> String? {
        RemoteLock.evaluate(
            modeIsOff: modeIsOff, isCloud: isCloud, cloudAllowed: cloudAllowed, hasKey: hasKey, isConfigured: isConfigured
        )?.message
    }
}

/// Lines the consent sheet shows above the payload of a remote turn.
public enum RemoteTurnDisclosure {
    public static func lines(pastedOutputBytes: Int?, isCloud: Bool, includesCapturedCommand: Bool = false)
        -> [String] {
        let destination = isCloud
            ? "Sale de tu red hacia un servidor de internet."
            : "Va a un servidor de tu red local; no se comprobó que sea tuyo."
        let pasted = pastedOutputBytes.map {
            "Este mensaje incluye salida de terminal pegada (\($0) bytes), enviada como datos entre delimitadores."
        } ?? "Este mensaje no incluye salida de terminal pegada."
        let scope = includesCapturedCommand
            ? "Incluye la última orden capturada. Solo se envía este mensaje: ni el historial ni otras órdenes."
            : "Solo se envía este mensaje: ni el historial ni otras órdenes."
        return [
            destination,
            pasted,
            scope,
            "Puede contener rutas, nombres de usuario o secretos de tu terminal. "
                + "La redacción automática es solo una ayuda.",
            "La respuesta solo propone órdenes: nada se escribe en el ordenador sin que toques un canal.",
        ]
    }
}
