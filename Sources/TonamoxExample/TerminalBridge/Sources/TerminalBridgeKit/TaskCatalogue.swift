import Foundation

/// Shells whose quoting the renderer targets. zsh and bash agree on everything the catalogue emits.
public enum CatalogueShell: String, CaseIterable, Codable, Sendable {
    case zsh
    case bash
}

public enum CatalogueTaskCategory: String, CaseIterable, Codable, Sendable {
    case disk
    case network
    case processes
    case system
    case files
    case git
    case homebrew
    case archives

    /// Spanish section title.
    public var title: String {
        switch self {
        case .disk: "Disco"
        case .network: "Red"
        case .processes: "Procesos"
        case .system: "Sistema"
        case .files: "Archivos"
        case .git: "Git"
        case .homebrew: "Homebrew"
        case .archives: "Archivos comprimidos"
        }
    }
}

public enum CatalogueVariantRole: String, Codable, Sendable {
    /// Only reads.
    case readOnly
    /// Read-only counterpart of a destructive variant; offered first.
    case preview
    /// Changes something; offered only after its task's preview was rendered.
    case destructive
}

/// One piece of a shell word: fixed text from the catalogue, or a validated parameter value.
public enum CatalogueSegment: Hashable, Sendable {
    case literal(String)
    case parameter(String)
}

/// One shell word, rendered by concatenating its segments.
public struct CatalogueWord: Hashable, Sendable {
    public let segments: [CatalogueSegment]

    public init(_ segments: [CatalogueSegment]) {
        self.segments = segments
    }

    public static func literal(_ text: String) -> CatalogueWord {
        CatalogueWord([.literal(text)])
    }

    public static func parameter(_ id: String) -> CatalogueWord {
        CatalogueWord([.parameter(id)])
    }

    /// The first segment when it is fixed text.
    var leadingLiteral: String? {
        if case .literal(let text)? = segments.first { return text }
        return nil
    }
}

public struct CatalogueTaskVariant: Identifiable, Hashable, Sendable {
    public let id: String
    /// Spanish button title.
    public let title: String
    public let role: CatalogueVariantRole
    /// Pipeline stages joined with " | "; most variants have one.
    public let stages: [[CatalogueWord]]
    /// What `RiskyCommandRules.evaluate` reports for any valid parameters; the renderer refuses a mismatch.
    public let expectedWarnings: [RiskyRule]

    public init(
        id: String,
        title: String,
        role: CatalogueVariantRole,
        stages: [[CatalogueWord]],
        expectedWarnings: [RiskyRule] = []
    ) {
        self.id = id
        self.title = title
        self.role = role
        self.stages = stages
        self.expectedWarnings = expectedWarnings
    }

    /// The program of each stage, in order.
    public var programs: [String] {
        stages.compactMap { $0.first?.leadingLiteral }
    }

    var parameterIDs: [String] {
        stages.flatMap { $0 }.flatMap(\.segments).compactMap { segment in
            if case .parameter(let id) = segment { return id }
            return nil
        }
    }
}

public struct CatalogueTask: Identifiable, Hashable, Sendable {
    /// Stable, dotted ("disk.free"); safe to persist.
    public let id: String
    /// Spanish.
    public let title: String
    /// Spanish, one line.
    public let summary: String
    public let category: CatalogueTaskCategory
    public let host: HostOS
    public let shells: Set<CatalogueShell>
    public let parameters: [CatalogueParameter]
    /// Preview first when the task has a destructive variant.
    public let variants: [CatalogueTaskVariant]

    public init(
        id: String,
        title: String,
        summary: String,
        category: CatalogueTaskCategory,
        host: HostOS = .macOS,
        shells: Set<CatalogueShell> = Set(CatalogueShell.allCases),
        parameters: [CatalogueParameter] = [],
        variants: [CatalogueTaskVariant]
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.category = category
        self.host = host
        self.shells = shells
        self.parameters = parameters
        self.variants = variants
    }

    public var hasDestructiveVariant: Bool {
        variants.contains { $0.role == .destructive }
    }

    public func variant(_ id: String) -> CatalogueTaskVariant? {
        variants.first { $0.id == id }
    }

    /// Destructive variants appear only once the preview of this task has been rendered for the same values.
    public func offeredVariants(previewRendered: Bool) -> [CatalogueTaskVariant] {
        variants.filter { $0.role != .destructive || previewRendered }
    }

    func parameter(_ id: String) -> CatalogueParameter? {
        parameters.first { $0.id == id }
    }
}
