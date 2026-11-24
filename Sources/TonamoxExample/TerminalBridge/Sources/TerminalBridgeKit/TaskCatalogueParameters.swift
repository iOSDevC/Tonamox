import Foundation

public struct CatalogueChoice: Hashable, Sendable {
    /// Typed as is; written in the catalogue, never by the user.
    public let value: String
    /// Spanish.
    public let title: String

    public init(value: String, title: String) {
        self.value = value
        self.title = title
    }
}

public enum CatalogueParameterKind: Hashable, Sendable {
    /// A file or folder. `~` and `~/…` stay expandable; a leading dash gets "./".
    case path
    /// A `find -name` pattern: `*` and `?` are globs for find, never for the shell; no slash.
    case fileName
    case port
    /// Letters, digits, space, `_`, `-` and `.`: the value is a pgrep/pkill regex, so metacharacters are refused
    /// and dots are matched literally.
    case processName
    /// A fixed string for `grep -F`; any printable ASCII.
    case textPattern
    case count(ClosedRange<Int>)
    case choice([CatalogueChoice])
    /// A host name or IPv4 address.
    case host
    /// An http or https URL.
    case url

    /// UTF-8 bytes; keeps every rendered line far below `CommandTextPolicy.maxBytes`.
    var maxBytes: Int {
        switch self {
        case .path: 200
        case .fileName: 100
        case .port: 5
        case .processName: 64
        case .textPattern: 120
        case .count: 6
        case .choice: 32
        case .host: 253
        case .url: 300
        }
    }
}

public struct CatalogueParameter: Hashable, Sendable {
    /// Matches `CatalogueSegment.parameter`.
    public let id: String
    /// Spanish form label.
    public let label: String
    public let kind: CatalogueParameterKind
    /// A valid value, shown as placeholder.
    public let example: String

    public init(id: String, label: String, kind: CatalogueParameterKind, example: String) {
        self.id = id
        self.label = label
        self.kind = kind
        self.example = example
    }

    /// The value unchanged when valid; never trims or rewrites.
    public func validate(_ raw: String) -> Result<String, CatalogueParameterError> {
        guard !raw.isEmpty else { return .failure(.empty(label: label)) }
        if raw.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return .failure(.controlCharacter(label: label))
        }
        if raw.unicodeScalars.contains(where: { $0.value > 0x7E }) {
            return .failure(.nonASCII(label: label))
        }
        if raw.utf8.count > kind.maxBytes {
            return .failure(.tooLong(label: label, maxBytes: kind.maxBytes))
        }
        if let error = kindError(raw) { return .failure(error) }
        return .success(raw)
    }

    private func kindError(_ raw: String) -> CatalogueParameterError? {
        switch kind {
        case .path, .textPattern:
            return nil
        case .fileName:
            return raw.contains("/") ? .slashInFileName(label: label) : nil
        case .port:
            return numberError(raw, range: 1...65535)
        case .count(let range):
            return numberError(raw, range: range)
        case .processName:
            return raw.unicodeScalars.allSatisfy(Self.isProcessNameScalar) ? nil : .processNameCharacters(label: label)
        case .choice(let choices):
            return choices.contains { $0.value == raw } ? nil : .notAChoice(label: label, choices: choices.map(\.value))
        case .host:
            return Self.isHost(raw) ? nil : .invalidHost(label: label)
        case .url:
            return Self.isURL(raw) ? nil : .invalidURL(label: label)
        }
    }

    private func numberError(_ raw: String, range: ClosedRange<Int>) -> CatalogueParameterError? {
        guard raw.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }), let number = Int(raw) else {
            return .notANumber(label: label)
        }
        return range.contains(number) ? nil : .outOfRange(label: label, range: range)
    }

    static func isProcessNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", " ", "_", "-", ".": true
        default: false
        }
    }

    /// RFC 1123 labels without length checks per label; the first character is never `-` or `.`.
    static func isHost(_ raw: String) -> Bool {
        guard let first = raw.unicodeScalars.first, isAlphanumeric(first) else { return false }
        return raw.unicodeScalars.allSatisfy { isAlphanumeric($0) || $0 == "-" || $0 == "." }
    }

    /// Scheme check only; spaces are refused because a URL never contains one unescaped.
    static func isURL(_ raw: String) -> Bool {
        let lowered = raw.lowercased()
        let scheme = ["https://", "http://"].first { lowered.hasPrefix($0) }
        guard let scheme, raw.count > scheme.count else { return false }
        return !raw.contains(" ")
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9": true
        default: false
        }
    }
}

/// Spanish messages for the form; each names the field.
public enum CatalogueParameterError: Error, Hashable, Sendable {
    case missing(label: String)
    case empty(label: String)
    case controlCharacter(label: String)
    case nonASCII(label: String)
    case tooLong(label: String, maxBytes: Int)
    case notANumber(label: String)
    case outOfRange(label: String, range: ClosedRange<Int>)
    case notAChoice(label: String, choices: [String])
    case slashInFileName(label: String)
    case processNameCharacters(label: String)
    case invalidHost(label: String)
    case invalidURL(label: String)

    public var message: String {
        switch self {
        case .missing(let label):
            "Falta «\(label)»."
        case .empty(let label):
            "«\(label)» está vacío."
        case .controlCharacter(let label):
            "«\(label)» contiene un salto de línea, un tabulador u otro carácter de control."
        case .nonASCII(let label):
            "«\(label)» contiene acentos, eñes u otros caracteres no ASCII que no se pueden teclear."
        case .tooLong(let label, let maxBytes):
            "«\(label)» es demasiado largo; el máximo es \(maxBytes) caracteres."
        case .notANumber(let label):
            "«\(label)» debe ser un número entero, solo con cifras."
        case .outOfRange(let label, let range):
            "«\(label)» debe estar entre \(range.lowerBound) y \(range.upperBound)."
        case .notAChoice(let label, let choices):
            "«\(label)» debe ser una de estas opciones: \(choices.joined(separator: ", "))."
        case .slashInFileName(let label):
            "«\(label)» es un nombre, no una ruta: quita las barras."
        case .processNameCharacters(let label):
            "«\(label)» solo admite letras, cifras, espacios, guiones, guiones bajos y puntos."
        case .invalidHost(let label):
            "«\(label)» debe ser un nombre de equipo o una dirección IPv4, por ejemplo example.com o 192.168.1.1."
        case .invalidURL(let label):
            "«\(label)» debe empezar por http:// o https:// y no llevar espacios."
        }
    }
}
