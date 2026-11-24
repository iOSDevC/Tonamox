import Foundation

/// Where TonamoxTerminal keeps the server's API keys (their SHA-256 digests and metadata, never the key itself).
public enum APIKeyStorage: Hashable, Sendable {
    /// The app's own keychain access group, `WhenUnlockedThisDeviceOnly`, never synced.
    case keychain
    /// The app's own keychain group could not be determined, so nothing is written to the keychain.
    case memoryOnly

    public var footer: String {
        switch self {
        case .keychain:
            "Se guardan en el llavero de este iPhone, solo con su huella SHA-256, su nombre, permisos, fechas, "
                + "último uso y la dirección del último equipo que la usó: la clave en sí se muestra una vez y no se "
                + "guarda. No pasan a iCloud ni a otro dispositivo por "
                + "copia de seguridad, y ninguna otra app las ve. Siguen tras cerrar la app y caducan a los 7 días."
        case .memoryOnly:
            "Este arranque no puede usar el llavero propio de la app: las claves duran hasta que cierres la app y "
                + "luego dejan de valer. Caducan a los 7 días."
        }
    }

    /// Shown above the list when keys will not survive the app closing.
    public var warning: String? {
        switch self {
        case .keychain: nil
        case .memoryOnly:
            "No se pudo fijar el grupo propio del llavero, así que no se guarda nada en él (otra app de Tonamox "
                + "podría leerlo o cambiarlo). Las claves de este arranque se pierden al cerrar la app."
        }
    }
}

public enum APIKeyStorageText {
    /// Bounds the keychain item; expired keys are removed whenever a new key is issued.
    public static let maximumKeys = 20

    /// Nil when one more key may be issued.
    public static func issueRefusal(liveKeys: Int) -> String? {
        guard liveKeys >= maximumKeys else { return nil }
        return "Ya hay \(maximumKeys) claves sin caducar. Revoca alguna antes de crear otra."
    }

    /// The key was not issued: the SDK saves before it hands out the secret.
    public static func issueNotSaved(status: Int32?) -> String {
        "No se pudo guardar la clave en el llavero\(detail(status)), así que no se creó. Inténtalo otra vez."
    }

    /// The key no longer works in this launch but may still be in the keychain.
    public static func revokeNotSaved(status: Int32?) -> String {
        "La clave ya no vale mientras la app siga abierta, pero no se pudo borrar del llavero\(detail(status)). "
            + "Revócala otra vez; si cierras la app antes, volvería a valer."
    }

    public static func loadFailed(status: Int32?) -> String {
        "No se pudieron leer las claves guardadas en el llavero\(detail(status)). Para empezar de cero, toca "
            + "«Revocar todas»."
    }

    /// Start is refused while stored keys cannot be read: the first new key would overwrite them.
    public static func startRefusedUnreadable(status: Int32?) -> String {
        loadFailed(status: status) + " El servidor no se inicia mientras tanto."
    }

    public static let issueNeedsServer = "Para crear una clave, inicia el servidor: la dirección forma parte de las "
        + "instrucciones. Las claves guardadas se pueden revocar con el servidor detenido."

    public static let noKeys = "No hay claves guardadas."

    public static func revokeAllTitle(count: Int) -> String {
        count == 1 ? "¿Revocar la clave?" : "¿Revocar las \(count) claves?"
    }

    public static let revokeAllMessage = "Dejan de valer al momento y se borran del llavero. Los navegadores "
        + "emparejados no cambian."

    /// The expiry part of a key row; `formatted` is the host's rendering of `expiresAt`.
    public static func expiry(expiresAt: Date?, now: Date, formatted: String) -> String {
        guard let expiresAt else { return "sin caducidad" }
        return expiresAt <= now ? "caducada (se borra al crear otra clave)" : "caduca " + formatted
    }

    public static func liveCount(expiries: [Date?], now: Date) -> Int {
        expiries.filter { $0.map { $0 > now } ?? true }.count
    }

    private static func detail(_ status: Int32?) -> String {
        status.map { " (OSStatus \($0))" } ?? ""
    }
}

/// Keys revoked in memory whose removal the store has not confirmed: a later load hides them and a later
/// successful save, which no longer lists them, confirms it.
public struct PendingRevocations: Hashable, Sendable {
    public private(set) var ids: Set<UUID> = []

    public init() {}

    /// A failed save removed `known - attempted` from the list it meant to write.
    public mutating func recordFailedSave(known: Set<UUID>, attempted: Set<UUID>) {
        ids.formUnion(known.subtracting(attempted))
    }

    /// The ids a store should write or show: the pending ones are left out.
    public func filter(_ candidates: [UUID]) -> Set<UUID> {
        Set(candidates).subtracting(ids)
    }

    /// A save of a list without the pending ids succeeded, so the store no longer has them.
    public mutating func confirmSaved() {
        ids = []
    }
}
