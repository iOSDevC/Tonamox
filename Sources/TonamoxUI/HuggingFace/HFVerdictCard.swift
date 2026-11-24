import SwiftUI
import TonamoxCore

/// The first answer on a repo's detail screen: can it be used on this device, and with which file.
struct HFVerdictCard: View {
    let result: CompatibilityReport

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label(answer.title, systemImage: answer.symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(answer.tint)
                ForEach(Array(answer.lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.callout)
                }
                if let need = answer.memory {
                    MemoryBar(requiredGB: need.requiredGB, budgetGB: need.budgetGB, rating: need.rating)
                    Text(HFFitText.needs(need))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let note = answer.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }

    private var answer: HFVerdictAnswer { HFVerdictAnswer(result) }
}

/// The card's content, decided once from the report.
struct HFVerdictAnswer {
    let title: String
    let symbol: String
    let tint: Color
    var lines: [String] = []
    var memory: FitEstimate?
    var note: String?

    init(_ result: CompatibilityReport) {
        let device = HFFitText.deviceName(result.target)
        let blocker = result.blockers.first
        if result.artifact.kind.isAdapter {
            title = result.artifact.isCertain ? String(localized: "Not a standalone model", bundle: .module)
                : String(localized: "Probably an adapter, not a model", bundle: .module)
            symbol = "puzzlepiece.extension"
            tint = .orange
            if case .adapter(let base?) = result.artifact.kind { lines = [String(localized: "Adapter (LoRA) for \(base)", bundle: .module)] }
            note = blocker?.detail
        } else if result.status.isRunnable, result.suggestedEntry != nil {
            let quant = result.recommendedQuant
            (title, symbol, tint) = Self.runnableHeading(quant: quant, fit: quant?.memory ?? result.weightsFit,
                                                         device: device)
            if let quant {
                let name = quant.option.label ?? quant.option.filename
                let size = CompatibilityReport.gigabytesText(quant.option.totalBytes)
                let recommended = quant.option.label.flatMap(CoreText.quantHint(for:)).map {
                    String(localized: "Recommended version: \(name) (\($0))", bundle: .module)
                } ?? String(localized: "Recommended version: \(name)", bundle: .module)
                lines = [recommended, String(localized: "Download \(size)", bundle: .module)]
                memory = quant.memory
            } else if let fit = result.weightsFit {
                lines = result.weightsBytes.map {
                    [String(localized: "Download \(CompatibilityReport.gigabytesText($0))", bundle: .module)]
                } ?? []
                memory = fit
            }
            // The caveat that qualifies "works" comes first; licence or layout notes only when there is none.
            let qualifying = result.caveats.first { ["entry", "fit", "artifact"].contains($0.rule) }
            note = qualifying?.detail ?? result.caveats.first.map { String(localized: "Caveat: \($0.title).", bundle: .module) }
        } else if result.status == .unknown {
            title = String(localized: "Could not check this repo", bundle: .module)
            symbol = "questionmark.circle"
            tint = .secondary
            lines = [result.headline]
            note = result.caveats.first?.detail
        } else if blocker?.rule == "fit", let smallest = result.smallestQuant {
            title = String(localized: "Too large for \(device)", bundle: .module)
            symbol = "xmark.octagon.fill"
            tint = .red
            let over = max(smallest.memory.requiredGB - smallest.memory.budgetGB, 0)
            lines = [String(format: String(localized: "Even the smallest version, %@, needs %.1f GB: %.1f GB over the %.1f GB limit.", bundle: .module),
                            smallest.option.label ?? smallest.option.filename, smallest.memory.requiredGB, over,
                            smallest.memory.budgetGB)]
            memory = smallest.memory
        } else if blocker?.rule == "fit", let fit = result.weightsFit {
            title = String(localized: "Too large for \(device)", bundle: .module)
            symbol = "xmark.octagon.fill"
            tint = .red
            memory = fit
            note = blocker?.detail
        } else {
            title = String(localized: "Won't run on \(device)", bundle: .module)
            symbol = "xmark.octagon.fill"
            tint = .red
            lines = blocker.map { [$0.title] } ?? []
            note = blocker?.detail
        }
    }
}

extension HFVerdictAnswer {
    /// "Works" only for a comfortable fit of a file the downloader can fetch.
    static func runnableHeading(quant: QuantFit?, fit: FitEstimate?,
                                device: String) -> (title: String, symbol: String, tint: Color) {
        if let quant, !quant.isTopLevel {
            return (String(localized: "Needs a manual download", bundle: .module), "folder.badge.questionmark", .orange)
        }
        switch fit?.rating {
        case .streamingRequired?:
            return (String(localized: "Runs slowly on \(device)", bundle: .module), "tortoise.fill", .orange)
        case .marginal?:
            return (String(localized: "Tight fit on \(device)", bundle: .module), "exclamationmark.triangle.fill", .orange)
        default: return (String(localized: "Works on \(device)", bundle: .module), "checkmark.circle.fill", .green)
        }
    }
}

/// Shared phrasing for memory and devices.
enum HFFitText {
    /// `this iPhone` for the measured device, the preset's name otherwise.
    static func deviceName(_ target: DevicePreset) -> String {
        let prefix = "This device ("
        guard target.id == DevicePreset.thisDeviceID, target.displayName.hasPrefix(prefix),
              target.displayName.hasSuffix(")") else { return target.displayName }
        let name = String(target.displayName.dropFirst(prefix.count).dropLast())
        return String(localized: "this \(name)", bundle: .module)
    }

    /// `Needs 6.1 GB of memory · limit 8.0 GB`.
    static func needs(_ fit: FitEstimate) -> String {
        String(format: String(localized: "Needs %.1f GB of memory · limit %.1f GB", bundle: .module), fit.requiredGB,
               fit.budgetGB)
    }

    static func tint(_ rating: ModelFitLevel) -> Color {
        switch rating {
        case .excellent, .good: .green
        case .marginal, .streamingRequired: .orange
        case .tooLarge: .red
        }
    }
}

/// A thin bar: memory needed against the device's limit.
struct MemoryBar: View {
    let requiredGB: Double
    let budgetGB: Double
    let rating: ModelFitLevel

    var body: some View {
        GeometryReader { space in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(HFFitText.tint(rating))
                    .frame(width: space.size.width * fraction)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    private var fraction: Double {
        guard budgetGB > 0 else { return 1 }
        return min(max(requiredGB / budgetGB, 0), 1)
    }
}

/// One version (quantization) of a GGUF repo: name, meaning, size and memory against the limit.
struct QuantRow: View {
    let line: QuantFit
    let isRecommended: Bool
    /// Why no version can run here regardless of memory (an unsupported architecture, say); `nil` otherwise.
    var blockedReason: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(line.option.label ?? line.option.filename)
                    .font(.body.monospaced())
                    .fixedSize(horizontal: false, vertical: true)
                if isRecommended {
                    Text("Recommended", bundle: .module)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                }
                Spacer()
                Text(CompatibilityReport.gigabytesText(line.option.totalBytes))
                    .font(.caption.monospacedDigit())
            }
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            MemoryBar(requiredGB: line.memory.requiredGB, budgetGB: line.memory.budgetGB, rating: line.memory.rating)
            Text(status)
                .font(.caption)
                .foregroundStyle(fits ? Color.secondary : HFFitText.tint(.tooLarge))
        }
        .opacity(fits ? 1 : 0.5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var hint: String? { line.option.label.flatMap(CoreText.quantHint(for:)) }

    /// Loadable here: one top-level file that is not too large.
    private var fits: Bool {
        blockedReason == nil && line.isUsable && line.memory.rating != .tooLarge && line.isTopLevel
    }

    private var status: String {
        let need = HFFitText.needs(line.memory)
        if let blockedReason { return String(localized: "Cannot run here: \(blockedReason). \(need)", bundle: .module) }
        if line.option.isSplit {
            return String(localized: "Split into \(line.option.paths.count) parts: Tonamox loads single files only",
                          bundle: .module)
        }
        if !line.isTopLevel {
            return String(localized: "In a subfolder: the downloader fetches top-level files only", bundle: .module)
        }
        switch line.memory.rating {
        case .tooLarge: return String(localized: "Too large. \(need)", bundle: .module)
        case .streamingRequired: return String(localized: "Only by layer streaming, much slower. \(need)", bundle: .module)
        case .marginal: return String(localized: "Tight fit, under 20 % headroom. \(need)", bundle: .module)
        case .good, .excellent: return need
        }
    }

    private var accessibilityText: String {
        let name = line.option.label ?? line.option.filename
        let size = CompatibilityReport.gigabytesText(line.option.totalBytes)
        return [name, isRecommended ? String(localized: "recommended", bundle: .module) : nil, hint,
                String(localized: "\(size) download", bundle: .module), status]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

extension GGUFQuantGroup {
    /// The first part's file name, without folders.
    var filename: String { (firstPath as NSString).lastPathComponent }
}
