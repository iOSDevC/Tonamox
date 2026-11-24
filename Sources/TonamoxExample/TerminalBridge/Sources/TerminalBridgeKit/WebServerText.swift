import Foundation

// Pure parts of TonamoxTerminal's "Servidor web" screen. The app maps the SDK's types onto these, so this package
// never imports the SDK.

/// Why a typed port was refused.
public enum WebServerPortRefusal: Error, Hashable, Sendable {
    case empty
    case notANumber
    case outOfRange

    public var message: String {
        switch self {
        case .empty: "Escribe un número de puerto, por ejemplo \(WebServerPort.defaultPort)."
        case .notANumber: "El puerto solo puede llevar cifras."
        case .outOfRange: "Usa un puerto entre \(WebServerPort.range.lowerBound) y \(WebServerPort.range.upperBound)."
        }
    }
}

public enum WebServerPort {
    public static let defaultPort: UInt16 = 47830
    /// Below 1024 are the well-known service ports; no reason to take one on a phone.
    public static let range: ClosedRange<UInt16> = 1024...65535

    public static func validate(_ text: String) -> Result<UInt16, WebServerPortRefusal> {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard trimmed.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }) else { return .failure(.notANumber) }
        // Digits only, so a failed conversion means the value is larger than any port.
        guard trimmed.count <= 5, let value = UInt16(trimmed), range.contains(value) else {
            return .failure(.outOfRange)
        }
        return .success(value)
    }
}

/// What a network interface probably is (the SDK guesses it from the interface name).
public enum WebServerInterfaceKind: Hashable, Sendable {
    case wifi
    case personalHotspot
    case wired
    case other

    public var title: String {
        switch self {
        case .wifi: "Wi-Fi"
        case .personalHotspot: "Punto de acceso personal"
        case .wired: "Cable (USB o Ethernet)"
        case .other: "Otra red local"
        }
    }

    /// One row of the "where it listens" picker: plain name, address, and the system name for the curious.
    public func rowTitle(address: String, interfaceName: String) -> String {
        "\(title): \(address) (\(interfaceName))"
    }

    /// Shown before starting on this network: no encryption, so the conversation is readable there.
    public var networkWarning: String {
        let who = switch self {
        case .wifi: "cualquier equipo conectado a esta misma Wi-Fi"
        case .personalHotspot: "cualquier equipo conectado a tu punto de acceso personal"
        case .wired: "cualquier equipo conectado por este cable o red"
        case .other: "cualquier equipo de esta red"
        }
        return "Sin cifrado: \(who) puede leer y cambiar lo que viaja, la conversación y las claves incluidas. "
            + "Úsalo solo en una red en la que confíes."
    }

    public static let peerLockExplanation = "Bloqueo de equipo: el primer ordenador que se empareje o use una clave "
        + "pasa a ser el único que puede conectarse. «Permitir otro equipo» deja entrar a uno más durante 2 minutos."
}

public enum WebServerSuspendReason: Hashable, Sendable {
    case appBackgrounded
    case interfaceLost(String)
    /// `minutes`: the server's idle shutdown.
    case idle(minutes: Int)

    /// Only a background pause reopens the port by itself; the others stay paused until "Detener".
    public var reopensByItself: Bool {
        if case .appBackgrounded = self { return true }
        return false
    }
}

public enum WebServerFailure: Hashable, Sendable {
    case portInUse(UInt16)
    case alreadyRunning
    case listener(String)
    case interfaceUnavailable(String)
}

/// The server's state with only plain values, for the Spanish text on screen.
public enum WebServerStatus: Hashable, Sendable {
    case stopped
    case starting
    case listening(url: String, observableByNetwork: Bool)
    case suspended(WebServerSuspendReason)
    case failed(WebServerFailure)

    public var title: String {
        switch self {
        case .stopped: "Detenido"
        case .starting: "Arrancando…"
        case .listening: "Escuchando"
        case .suspended: "En pausa"
        case .failed: "No pudo arrancar"
        }
    }

    public var detail: String {
        switch self {
        case .stopped:
            "Nadie puede conectarse. El servidor solo arranca cuando tocas «Iniciar» y no vuelve a arrancar solo "
                + "al abrir la app otra vez."
        case .starting:
            "Abriendo el puerto…"
        case .listening(_, let observable):
            observable
                ? "Abre esta dirección en el navegador del otro equipo. La conexión no está cifrada."
                : "Solo este iPhone, o un ordenador conectado por cable con un reenvío a 127.0.0.1, puede abrir "
                    + "esta dirección."
        case .suspended(let reason):
            Self.describe(reason)
        case .failed(let failure):
            Self.describe(failure)
        }
    }

    /// The state needs the user's attention (shown in orange or red).
    public var isProblem: Bool {
        switch self {
        case .suspended, .failed: true
        case .stopped, .starting, .listening: false
        }
    }

    /// The toolbar indicator is on: the port is open or will reopen by itself on return to the foreground.
    public var isActive: Bool {
        switch self {
        case .listening, .starting: true
        case .suspended(let reason): reason.reopensByItself
        case .stopped, .failed: false
        }
    }

    public static func describe(_ reason: WebServerSuspendReason) -> String {
        switch reason {
        case .appBackgrounded:
            "La app pasó a segundo plano: el puerto se cerró y se volverá a abrir al volver a la app."
        case .interfaceLost(let name):
            "La red elegida (\(name)) cambió de dirección o desapareció. Detén el servidor y elige la red de nuevo."
        case .idle(let minutes):
            "Se pausó tras \(minutes) \(minutes == 1 ? "minuto" : "minutos") sin uso en la red. Detén el servidor y "
                + "vuelve a iniciarlo para seguir."
        }
    }

    public static func describe(_ failure: WebServerFailure) -> String {
        switch failure {
        case .portInUse(let port):
            "Otra app ya usa el puerto \(port). Elige otro puerto y vuelve a iniciar."
        case .alreadyRunning:
            "El servidor ya estaba en marcha."
        case .listener:
            "El sistema no dejó abrir el puerto. Vuelve a intentarlo o elige otro puerto."
        case .interfaceUnavailable(let name):
            "La red elegida (\(name)) ya no está disponible. Elige otra o usa «Solo este iPhone»."
        }
    }
}

/// «Mantener la pantalla encendida mientras sirve»: Auto-Lock backgrounds the app, and iOS closes the port there.
public enum WebServerScreenAwake {
    public static let defaultsKey = "webServer.keepsScreenAwake"
    public static let defaultEnabled = true

    public static let toggleTitle = "Mantener la pantalla encendida mientras sirve"
    public static let footer = "Evita que el bloqueo automático mande la app a segundo plano. Gasta más batería. Si "
        + "sales de la app o bloqueas el iPhone, el puerto se cierra igual."

    /// A missing value is the default, so the toggle starts on.
    public static func isEnabled(stored: Bool?) -> Bool {
        stored ?? defaultEnabled
    }

    /// Held while the port is open or opening, with the toggle on and the app in front. A pause that needs
    /// «Detener», a failure or a stop releases it.
    public static func holdsScreen(status: WebServerStatus, enabled: Bool, inForeground: Bool) -> Bool {
        guard enabled, inForeground else { return false }
        switch status {
        case .starting, .listening: return true
        case .stopped, .suspended, .failed: return false
        }
    }
}

/// `m:ss` left in a countdown; never negative.
public enum WebServerCountdown {
    public static func secondsLeft(until deadline: Date, now: Date) -> Int {
        max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
    }

    public static func format(secondsLeft: Int) -> String {
        let seconds = max(0, secondsLeft)
        let rest = seconds % 60
        return "\(seconds / 60):" + (rest < 10 ? "0" : "") + "\(rest)"
    }
}

public enum APIKeyLabelRefusal: Error, Hashable, Sendable {
    case empty

    public var message: String {
        "Escribe un nombre para la clave, por ejemplo «editor» o «Mac del trabajo»."
    }
}

/// A name for an API key: shown in lists and in the server's content-free activity log.
public enum APIKeyLabel {
    public static let maxLength = 40

    /// Accents folded, then only ASCII letters, digits, space, `.`, `_` and `-` kept, runs of spaces collapsed.
    public static func sanitize(_ text: String) -> Result<String, APIKeyLabelRefusal> {
        let folded = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "es"))
        var kept = String.UnicodeScalarView()
        var lastWasSpace = true
        for scalar in folded.unicodeScalars {
            if scalar == " " || scalar == "\t" {
                if !lastWasSpace { kept.append(" ") }
                lastWasSpace = true
            } else if isAllowed(scalar) {
                kept.append(scalar)
                lastWasSpace = false
            }
        }
        let label = String(String(kept).trimmingCharacters(in: .whitespaces).prefix(maxLength))
            .trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? .failure(.empty) : .success(label)
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
            || scalar == "." || scalar == "_" || scalar == "-"
    }
}

/// How to use a new API key from a Mac without putting it on a command line (where `ps` shows it).
public struct APIKeyInstructions: Hashable, Sendable {
    /// Writes the copied header line into a file only the user can read.
    public let saveLine: String
    /// Lists the models with the saved header.
    public let testLine: String
    /// The base URL an OpenAI-compatible client asks for.
    public let openAIBaseURL: String

    public static let headerFile = "~/.tonamox-key"

    /// `baseURL` is the server's `http://host:port`, without a trailing slash.
    public init(baseURL: String) {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        saveLine = "(umask 077; pbpaste > \(Self.headerFile))"
        // `~` does not expand after `@`, so the curl line names the file through $HOME.
        testLine = "curl -sS -H @\"$HOME/.tonamox-key\" \(base)/v1/models"
        openAIBaseURL = base + "/v1"
    }
}

/// The id a served model gets in `/v1/models`: the server refuses `%` in a path, so only URL-safe ASCII.
public enum ServedModelName {
    public static let fallback = "modelo-local"
    public static let maxLength = 64

    public static func id(from title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive],
                                   locale: Locale(identifier: "es"))
        var kept = String.UnicodeScalarView()
        var lastWasDash = true
        for scalar in folded.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "." || scalar == "_" {
                kept.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                kept.append("-")
                lastWasDash = true
            }
        }
        let trimmed = String(String(kept).prefix(maxLength)).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? fallback : trimmed
    }
}

/// Which of the root screen's sheets shows. SwiftUI presents one sheet at a time and refuses a second one silently,
/// so every sheet is a demand in priority order: the one on screen stays while it is still demanded, and when it
/// ends the first remaining demand shows. Nothing is dropped and nothing on screen is replaced.
public enum SheetQueue {
    public static func next<Route: Hashable>(showing: Route?, demands: [Route]) -> Route? {
        if let showing, demands.contains(showing) { return showing }
        return demands.first
    }
}
