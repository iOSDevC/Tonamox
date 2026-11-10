#if os(macOS)
import Foundation

public enum IdlePromptPatternError: Error, Equatable, Sendable {
    case invalid(pattern: String, reason: String)

    public var message: String {
        switch self {
        case .invalid(let pattern, let reason):
            "La regex de prompt '\(pattern)' no es válida: \(reason)"
        }
    }
}

/// Decides from a screen hardcopy whether the shell sits at an empty prompt: the last non-empty
/// line must match. The default allows one prompt character only, as the line's last character.
public struct IdlePromptPattern: Sendable {
    /// Rejects "% printf 100%" and "% echo #"; also prompts that already hold %, $ or # earlier
    /// ("[100%] ~ %"), which need --prompt-regex.
    public static let defaultPattern = "^[^%$#]*[%$#] ?$"

    public let pattern: String
    private let expression: NSRegularExpression

    public init(_ pattern: String = IdlePromptPattern.defaultPattern) throws(IdlePromptPatternError) {
        do {
            expression = try NSRegularExpression(pattern: pattern)
        } catch {
            throw .invalid(pattern: pattern, reason: error.localizedDescription)
        }
        self.pattern = pattern
    }

    public func matches(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return expression.firstMatch(in: line, range: range) != nil
    }

    /// Last line with visible content, trailing blanks removed (screen already strips them).
    public static func lastNonEmptyLine(of screenText: String) -> String? {
        screenText
            .split(whereSeparator: \.isNewline)
            .map(trimmingTrailingBlanks)
            .last { !$0.isEmpty }
    }

    static func trimmingTrailingBlanks(_ line: Substring) -> String {
        String(line.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
    }
}
#endif
