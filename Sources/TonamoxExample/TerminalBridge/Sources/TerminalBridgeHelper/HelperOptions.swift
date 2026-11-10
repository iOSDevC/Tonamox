#if os(macOS)
import Foundation
import TerminalBridgeKit

public enum PairSource: Equatable, Sendable {
    /// Generate a new secret here and print the code (simulator flow).
    case generate
    case code(String)
    case standardInput
}

public enum ConnectionMode: Equatable, Sendable {
    case simulator
    case device(udid: String)
}

/// Where the screen target is and how to recognize its idle prompt.
public struct TargetOptions: Equatable, Sendable {
    public var session = BridgeConstants.defaultSessionName
    public var window = BridgeConstants.defaultWindow
    public var promptRegex: String?

    public init(
        session: String = BridgeConstants.defaultSessionName,
        window: String = BridgeConstants.defaultWindow,
        promptRegex: String? = nil
    ) {
        self.session = session
        self.window = window
        self.promptRegex = promptRegex
    }
}

public struct RunOptions: Equatable, Sendable {
    public var mode: ConnectionMode
    public var port: UInt16 = BridgeConstants.defaultPort
    public var target = TargetOptions()
    public var configURL: URL?
    public var journalURL: URL?
    public var verbose = false

    public init(mode: ConnectionMode) {
        self.mode = mode
    }
}

public struct StatusOptions: Equatable, Sendable {
    public var target = TargetOptions()
    public var configURL: URL?
    public var journalURL: URL?
    public var listUSBDevices = false

    public init() {}
}

public enum HelperCommand: Equatable, Sendable {
    case pair(PairSource, configURL: URL?)
    case unpair(configURL: URL?)
    case run(RunOptions)
    case status(StatusOptions)
    /// Same options as status, minus --usb.
    case doctor(StatusOptions)
    case help
    case version
}

public struct HelperOptionsError: Error, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// Hand-written argv parser (the package has no dependencies).
public enum HelperOptions {
    public static let usage = """
    Uso:
      tonamox-bridge pair (--new | --code CÓDIGO | --stdin) [--config ARCHIVO] [--journal ARCHIVO]
      tonamox-bridge unpair [--config ARCHIVO] [--journal ARCHIVO]
      tonamox-bridge run (--simulator | --device UDID) [--port N] [--session NOMBRE]
                         [--prompt-regex REGEX] [--config ARCHIVO] [--journal ARCHIVO] [--verbose]
      tonamox-bridge status [--session NOMBRE] [--prompt-regex REGEX] [--config ARCHIVO]
                            [--journal ARCHIVO] [--usb]
      tonamox-bridge doctor [--session NOMBRE] [--prompt-regex REGEX] [--config ARCHIVO] [--journal ARCHIVO]
      tonamox-bridge help | version

    Teclea en la ventana 0 de una sesión GNU screen (/usr/bin/screen 4.00.03) lo que mandas desde
    Tonamox Terminal, sin pulsar nunca Enter. Por defecto: sesión 'tonamox', puerto 47821, regex de
    prompt inactivo '^[^%$#]*[%$#] ?$' (un solo %, $ o #, al final de la línea).
      --config   por defecto ~/Library/Application Support/TonamoxBridge/config.json (0600)
      --journal  por defecto ~/Library/Logs/TonamoxBridge/writes.log (0600)
    Todos los subcomandos aceptan --config y --journal, para pasar siempre las mismas rutas: pair y
    unpair no usan el journal, status y doctor solo lo leen y run escribe en él.

    Códigos de salida: 0 ok (también al parar run con Ctrl-C), 1 fallo o doctor con el destino
    no listo, 64 uso, 65 configuración/emparejamiento/permisos (también una regex inválida
    guardada en la config), 69 screen ausente o versión distinta de 4.00.03, 77 ejecutado como
    root. Un rechazo del teléfono nunca termina run.

    Antes de cada escritura: sesión exacta pid.nombre; ninguna ventana aparte de la 0 (se
    comprueban la 1 a la 39 con hardcopy, también las que no tienen proceso); -p 0; el shell hijo
    de login en primer plano y con tu uid; y la última línea no vacía es un prompt vacío.
    Límites conocidos (en todos, el texto imprimible actúa como teclas aunque no haya Enter):
      - Un read -k1/read -q del propio shell cuya última línea visible parezca un prompt pasa el
        chequeo: el primer carácter lo contestaría.
      - Modo vi (bindkey -v, set -o vi): en modo comando cada letra es una orden del editor; en
        bash 'v' abre el editor y al salir ejecuta la línea. Muestra el modo en PROMPT y ajusta
        --prompt-regex para que solo coincida el de inserción (doctor lo explica).
      - Cualquier superposición de screen en la pantalla adjunta recibe el texto: el aviso [y/n]
        de C-a k (una 'y' cierra la ventana), C-a :, la lista de ventanas o el modo copia. Usa
        una sesión dedicada y no dejes avisos abiertos; el modo copia sale como "no verificado".
      - Entre el último chequeo y el stuff pasan decenas de ms.
      - Con RPROMPT, prompts de varias líneas o que ya contienen %, $ o # ajusta --prompt-regex.
      - --code deja el código en la lista de procesos mientras corre; prefiere --stdin.
      - --device (usbmux) no está probado con un iPhone real.
    """

    static let maxSessionLength = 32

    public static func parse(_ arguments: [String]) throws(HelperOptionsError) -> HelperCommand {
        guard let verb = arguments.first else { return .help }
        var reader = ArgumentReader(Array(arguments.dropFirst()))
        switch verb {
        case "pair": return try parsePair(&reader)
        case "unpair": return .unpair(configURL: try parseStateFiles(&reader).configURL)
        case "run": return .run(try parseRun(&reader))
        case "status": return .status(try parseStatus(&reader))
        case "doctor": return try parseDoctor(&reader)
        case "help", "--help", "-h": return .help
        case "version", "--version": return .version
        default: throw HelperOptionsError("Subcomando desconocido '\(verb)'.")
        }
    }

    private static func parsePair(_ reader: inout ArgumentReader) throws(HelperOptionsError) -> HelperCommand {
        var source: PairSource?
        var configURL: URL?
        while let flag = reader.next() {
            switch flag {
            case "--new": source = try single(source, .generate)
            case "--stdin": source = try single(source, .standardInput)
            case "--code": source = try single(source, .code(try reader.value(for: flag)))
            case "--config": configURL = fileURL(try reader.value(for: flag))
            case "--journal": _ = try reader.value(for: flag)
            default: throw unknown(flag)
            }
        }
        guard let source else { throw HelperOptionsError("pair necesita --new, --code CÓDIGO o --stdin.") }
        return .pair(source, configURL: configURL)
    }

    private static func single(_ current: PairSource?, _ next: PairSource) throws(HelperOptionsError) -> PairSource {
        guard current == nil else { throw HelperOptionsError("Usa solo una de --new, --code o --stdin.") }
        return next
    }

    /// --config and --journal only; every subcommand accepts both so scripts can pass the same paths.
    private static func parseStateFiles(
        _ reader: inout ArgumentReader
    ) throws(HelperOptionsError) -> (configURL: URL?, journalURL: URL?) {
        var configURL: URL?
        var journalURL: URL?
        while let flag = reader.next() {
            switch flag {
            case "--config": configURL = fileURL(try reader.value(for: flag))
            case "--journal": journalURL = fileURL(try reader.value(for: flag))
            default: throw unknown(flag)
            }
        }
        return (configURL, journalURL)
    }

    private static func parseRun(_ reader: inout ArgumentReader) throws(HelperOptionsError) -> RunOptions {
        var mode: ConnectionMode?
        var target = TargetOptions()
        var port = BridgeConstants.defaultPort
        var configURL: URL?
        var journalURL: URL?
        var verbose = false
        while let flag = reader.next() {
            if try parseTarget(flag, &reader, into: &target) { continue }
            switch flag {
            case "--simulator": mode = try singleMode(mode, .simulator)
            case "--device": mode = try singleMode(mode, .device(udid: try udid(try reader.value(for: flag))))
            case "--port": port = try parsePort(try reader.value(for: flag))
            case "--config": configURL = fileURL(try reader.value(for: flag))
            case "--journal": journalURL = fileURL(try reader.value(for: flag))
            case "--verbose", "-v": verbose = true
            default: throw unknown(flag)
            }
        }
        guard let mode else { throw HelperOptionsError("run necesita --simulator o --device UDID.") }
        var options = RunOptions(mode: mode)
        options.port = port
        options.target = target
        options.configURL = configURL
        options.journalURL = journalURL
        options.verbose = verbose
        return options
    }

    private static func singleMode(
        _ current: ConnectionMode?,
        _ next: ConnectionMode
    ) throws(HelperOptionsError) -> ConnectionMode {
        guard current == nil else { throw HelperOptionsError("Usa --simulator o --device, no los dos.") }
        return next
    }

    private static func parseStatus(
        _ reader: inout ArgumentReader,
        allowsUSB: Bool = true
    ) throws(HelperOptionsError) -> StatusOptions {
        var options = StatusOptions()
        while let flag = reader.next() {
            if try parseTarget(flag, &reader, into: &options.target) { continue }
            switch flag {
            case "--config": options.configURL = fileURL(try reader.value(for: flag))
            case "--journal": options.journalURL = fileURL(try reader.value(for: flag))
            case "--usb" where allowsUSB: options.listUSBDevices = true
            default: throw unknown(flag)
            }
        }
        return options
    }

    private static func parseDoctor(_ reader: inout ArgumentReader) throws(HelperOptionsError) -> HelperCommand {
        .doctor(try parseStatus(&reader, allowsUSB: false))
    }

    /// Consumes --session, --window and --prompt-regex; returns false for any other flag.
    private static func parseTarget(
        _ flag: String,
        _ reader: inout ArgumentReader,
        into target: inout TargetOptions
    ) throws(HelperOptionsError) -> Bool {
        switch flag {
        case "--session":
            target.session = try validated(try reader.value(for: flag), maxLength: maxSessionLength, flag)
        case "--window":
            // Accepted only as 0: writes require a dedicated single-window session and always use -p 0.
            guard try reader.value(for: flag) == BridgeConstants.defaultWindow else {
                throw HelperOptionsError("--window solo admite 0: se exige una sesión de una sola ventana.")
            }
        case "--prompt-regex":
            let pattern = try reader.value(for: flag)
            do {
                _ = try IdlePromptPattern(pattern)
            } catch {
                throw HelperOptionsError(error.message)
            }
            target.promptRegex = pattern
        default:
            return false
        }
        return true
    }

    /// 1...maxLength characters from A-Z a-z 0-9 _ -.
    static func isPlainName(_ value: String, maxLength: Int) -> Bool {
        (1...maxLength).contains(value.count) && value.unicodeScalars.allSatisfy { scalar in
            guard scalar.isASCII else { return false }
            return scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "_" || scalar == "-"
        }
    }

    private static func validated(
        _ value: String,
        maxLength: Int,
        _ flag: String
    ) throws(HelperOptionsError) -> String {
        guard isPlainName(value, maxLength: maxLength) else {
            throw HelperOptionsError("\(flag) '\(value)' no es válido (1-\(maxLength) de A-Z a-z 0-9 _ -).")
        }
        return value
    }

    private static func udid(_ value: String) throws(HelperOptionsError) -> String {
        let isHex = value.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isASCIIHexDigit || $0 == "-") }
        guard isHex, (20...64).contains(value.count) else {
            throw HelperOptionsError("UDID '\(value)' no es válido.")
        }
        return value
    }

    private static func parsePort(_ value: String) throws(HelperOptionsError) -> UInt16 {
        guard let port = UInt16(value), port > 0 else {
            throw HelperOptionsError("--port '\(value)' no es un puerto válido (1-65535).")
        }
        return port
    }

    static func fileURL(_ path: String) -> URL {
        URL(filePath: NSString(string: path).expandingTildeInPath, directoryHint: .notDirectory)
    }

    private static func unknown(_ flag: String) -> HelperOptionsError {
        HelperOptionsError("Opción desconocida '\(flag)'.")
    }
}

struct ArgumentReader {
    private var remaining: ArraySlice<String>

    init(_ arguments: [String]) {
        remaining = arguments[...]
    }

    mutating func next() -> String? {
        remaining.popFirst()
    }

    mutating func value(for flag: String) throws(HelperOptionsError) -> String {
        guard let value = remaining.popFirst() else { throw HelperOptionsError("\(flag) necesita un valor.") }
        return value
    }
}
#endif
