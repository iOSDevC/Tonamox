import Foundation
import TonamoxCore

// TonamoxCore's labels are English-only; these switch on the same cases so TonamoxUI can show them translated.
// English values must stay identical to Core's `label`.

extension CompatibilityVerdict {
    var localizedLabel: String {
        switch self {
        case .runnable: String(localized: "Runs", bundle: .module)
        case .runnableWithCaveats: String(localized: "Runs, with caveats", bundle: .module)
        case .notRunnable: String(localized: "Won't run", bundle: .module)
        case .unknown: String(localized: "Unknown", bundle: .module)
        }
    }
}

extension HuggingFaceSearch.Sort {
    var localizedLabel: String {
        switch self {
        case .downloads: String(localized: "Downloads", bundle: .module)
        case .likes: String(localized: "Likes", bundle: .module)
        case .lastModified: String(localized: "Recent", bundle: .module)
        case .trendingScore: String(localized: "Trending", bundle: .module)
        }
    }
}

extension ModelFitLevel {
    var localizedLabel: String {
        switch self {
        case .excellent: String(localized: "Excellent", bundle: .module)
        case .good: String(localized: "Good", bundle: .module)
        case .marginal: String(localized: "Marginal", bundle: .module)
        case .streamingRequired: String(localized: "Streaming", bundle: .module)
        case .tooLarge: String(localized: "Too Large", bundle: .module)
        }
    }
}

extension SpeedLevel {
    var localizedLabel: String {
        switch self {
        case .fast: String(localized: "fast", bundle: .module)
        case .usable: String(localized: "usable", bundle: .module)
        case .slow: String(localized: "slow", bundle: .module)
        case .unusable: String(localized: "too slow", bundle: .module)
        case .unknown: String(localized: "speed unknown", bundle: .module)
        }
    }
}

extension FindingSeverity {
    var localizedLabel: String {
        switch self {
        case .blocker: String(localized: "Blocker", bundle: .module)
        case .caveat: String(localized: "Caveat", bundle: .module)
        case .info: String(localized: "Info", bundle: .module)
        }
    }
}

extension DetectedFormat {
    var localizedLabel: String {
        switch self {
        case .mlx: "MLX"
        case .gguf: "GGUF"
        case .imageGeneration: String(localized: "Image generation", bundle: .module)
        case .unconvertedSafetensors: String(localized: "Transformers safetensors", bundle: .module)
        case .noWeights: String(localized: "No MLX/GGUF weights", bundle: .module)
        case .unknown: String(localized: "Unknown", bundle: .module)
        }
    }
}

extension ModelArtifactKind {
    var localizedLabel: String {
        switch self {
        case .standaloneModel: String(localized: "Model", bundle: .module)
        case .adapter: String(localized: "Adapter (LoRA)", bundle: .module)
        case .auxiliary(.visionProjector): String(localized: "Vision projector", bundle: .module)
        case .auxiliary(.importanceMatrix): String(localized: "Importance matrix", bundle: .module)
        }
    }
}

extension DevicePreset {
    /// Core's ``DevicePreset/budgetText``, translated: `20.0 GB (measured)` / `≈3.0 GB (estimate)`.
    var localizedBudgetText: String {
        let amount = String(format: "%.1f", budgetGB)
        return isMeasured ? String(localized: "\(amount) GB (measured)", bundle: .module)
            : String(localized: "≈\(amount) GB (estimate)", bundle: .module)
    }
}

extension FitEstimate {
    /// Core's ``FitEstimate/summary``, translated: `Good · 12.0 of 20.0 GB`.
    var localizedSummary: String {
        String(format: String(localized: "%@ · %.1f of %.1f GB", bundle: .module), rating.localizedLabel,
               requiredGB, budgetGB)
    }

    /// Core's ``FitEstimate/decodeText``, translated.
    var localizedDecodeText: String? {
        if let range = tokensPerSecondRange {
            return String(format: String(localized: "~%.0f–%.0f tok/s (uncalibrated MoE range)", bundle: .module),
                          range.lowerBound, range.upperBound)
        }
        return tokensPerSecond.map { String(format: "~%.0f tok/s", $0) }
    }
}

enum CoreText {
    /// ``QuantHint`` returns a closed set of English phrases; the catalog carries each one, and an unknown phrase
    /// shows as is.
    static func quantHint(for label: String) -> String? {
        QuantHint.text(for: label).map { Bundle.module.localizedString(forKey: $0, value: $0, table: nil) }
    }
}

extension Tonamox.VisionRunMode {
    var localizedLabel: String {
        switch self {
        case .standard: String(localized: "Standard", bundle: .module)
        case .stream: String(localized: "Stream", bundle: .module)
        }
    }
}
