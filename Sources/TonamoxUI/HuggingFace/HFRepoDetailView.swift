import SwiftUI
import TonamoxCore
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// One verdict card (can it run here, and which file), the Download section when it runs, the versions
/// (quantizations) against the device's limit, then the checker's technical findings. Fetches the repo the first time it appears. Brings no navigation container.
public struct HFRepoDetailView: View {
    let repoID: String
    let search: HFModelSearch
    @State private var showsToken = false
    @State private var trial: Model?
    @Environment(\.hfRepoCaution) private var repoCaution

    public init(repoID: String, search: HFModelSearch) {
        self.repoID = repoID
        self.search = search
    }

    public var body: some View {
        Group {
            if let report = search.reports[repoID] {
                let tags = search.matches.first { $0.id == repoID }?.tags ?? []
                HFReportForm(result: report, caution: repoCaution(repoID, tags), showsToken: $showsToken,
                             trial: $trial)
            } else {
                ProgressView(String(localized: "Checking \(repoID)…", bundle: .module))
            }
        }
        .task(id: repoID) { await search.loadReport(for: repoID) }
        .navigationTitle(repoID.split(separator: "/").last.map(String.init) ?? repoID)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "Hugging Face token", bundle: .module), systemImage: "key") { showsToken = true }
            }
        }
        // Sheets live here, not in the Form's rows, which a List may recycle while scrolling.
        .sheet(isPresented: $showsToken) { HFTokenSheet() }
        .sheet(item: $trial) { ModelTrialView(candidate: $0) }
    }
}

/// The checker's report as a form: the answer first, the evidence below.
struct HFReportForm: View {
    let result: CompatibilityReport
    var caution: String?
    @Binding var showsToken: Bool
    @Binding var trial: Model?
    @State private var copied = false
    @State private var showsFindings = false

    var body: some View {
        Form {
            // The inline navigation title truncates long repository ids.
            Section {
                Text(result.repoID)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                if let caution {
                    HFRepoCautionLabel(text: caution)
                }
            }
            HFVerdictCard(result: result)
            if let suggestion = result.suggestedEntry, result.status.isRunnable, !result.artifact.kind.isAdapter {
                HFDownloadSection(result: result, suggestion: suggestion, showsToken: $showsToken, trial: $trial)
                    .id(result.repoID)
            }
            versionsSection
            otherFilesSection
            findingsSection
            deviceSection
            modelSection
            memorySection
            licenseSection
            actions
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var versionsSection: some View {
        if !result.quantFits.isEmpty {
            let recommended = result.recommendedQuant?.id
            // A blocker other than memory (architecture, adapter) rules out every row, whatever its size.
            let blocker = result.blockers.first { $0.rule != "fit" }?.title
            Section {
                ForEach(result.quantFits.sorted { $0.option.totalBytes < $1.option.totalBytes }) { line in
                    QuantRow(line: line, isRecommended: line.id == recommended, blockedReason: blocker)
                }
            } header: {
                Text("Versions (quantizations) on \(result.target.displayName)", bundle: .module)
            } footer: {
                Text("Smaller versions need less memory and lose some quality. Dimmed versions cannot load here.", bundle: .module)
            }
        }
    }

    @ViewBuilder private var otherFilesSection: some View {
        if !result.artifact.excludedFiles.isEmpty {
            Section(String(localized: "Other files, not versions of the model", bundle: .module)) {
                ForEach(result.artifact.excludedFiles) { file in
                    LabeledContent {
                        Text(file.sizeBytes.map(CompatibilityReport.gigabytesText) ?? "")
                            .monospacedDigit()
                    } label: {
                        Text(file.path).font(.caption.monospaced())
                        Text(file.kind.localizedLabel)
                    }
                }
            }
        }
    }

    private var findingsSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showsFindings) {
                ForEach(result.findings) { FindingRow(item: $0) }
            } label: {
                Text("Technical details (\(result.findings.count) findings)", bundle: .module)
            }
        } footer: {
            Text("Architecture, header read, licence and the evidence behind the answer above.", bundle: .module)
        }
    }

    private var deviceSection: some View {
        Section(String(localized: "Device", bundle: .module)) {
            LabeledContent(String(localized: "Device", bundle: .module), value: result.target.displayName)
            LabeledContent(String(localized: "Memory limit", bundle: .module), value: result.target.localizedBudgetText)
            Text(result.target.source)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var modelSection: some View {
        Section(String(localized: "Model", bundle: .module)) {
            LabeledContent(String(localized: "Format", bundle: .module), value: result.weightFormat.localizedLabel)
            if let category = result.modelCategory {
                LabeledContent(String(localized: "Loads as", bundle: .module),
                               value: category == .vision ? String(localized: "Vision (image + text)", bundle: .module) : String(localized: "Text", bundle: .module))
            }
            if let family = result.overview.family { LabeledContent(String(localized: "Architecture", bundle: .module), value: family) }
            if let layers = result.overview.layers { LabeledContent(String(localized: "Layers", bundle: .module), value: "\(layers)") }
            if let context = result.overview.trainedContext { LabeledContent(String(localized: "Trained context", bundle: .module),
                               value: String(localized: "\(context) tokens", bundle: .module)) }
            if let heads = result.overview.kvHeads { LabeledContent(String(localized: "KV heads", bundle: .module), value: "\(heads)") }
            if let dim = result.overview.headDim { LabeledContent(String(localized: "Head dim", bundle: .module), value: "\(dim)") }
            LabeledContent(String(localized: "Vision weights", bundle: .module), value: result.overview.hasVision ? String(localized: "Yes", bundle: .module) : String(localized: "No", bundle: .module))
            if let quantization = result.overview.quantization { LabeledContent(String(localized: "Quantization", bundle: .module), value: quantization) }
        }
    }

    @ViewBuilder private var memorySection: some View {
        if let fit = result.weightsFit {
            Section(String(localized: "Memory on \(result.target.displayName)", bundle: .module)) {
                if let bytes = result.weightsBytes { LabeledContent(String(localized: "Weights", bundle: .module), value: CompatibilityReport.gigabytesText(bytes)) }
                LabeledContent(String(localized: "Fit", bundle: .module), value: fit.localizedSummary)
                if let speed = fit.localizedDecodeText {
                    LabeledContent(String(localized: "Decode estimate", bundle: .module), value: speed)
                }
            }
        }
    }

    private var licenseSection: some View {
        Section(String(localized: "License", bundle: .module)) {
            LabeledContent(String(localized: "License", bundle: .module), value: result.licenseID ?? String(localized: "Not declared", bundle: .module))
            if let name = result.licenseName { LabeledContent(String(localized: "Name", bundle: .module), value: name) }
            LabeledContent(String(localized: "Gated", bundle: .module),
                           value: result.gatedMode.map { String(localized: "Yes (\($0))", bundle: .module) } ?? String(localized: "No", bundle: .module))
        }
    }

    private var actions: some View {
        Section {
            if let entry = result.suggestedEntry {
                Button(copied ? String(localized: "Copied", bundle: .module) : String(localized: "Copy catalog entry", bundle: .module), systemImage: "doc.on.doc") {
                    Self.copy(entry.jsonText())
                    copied = true
                }
                DisclosureGroup(String(localized: "models.json entry", bundle: .module)) {
                    Text(entry.jsonText())
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            } else {
                Label(String(localized: "No catalog entry: the model can't run here.", bundle: .module), systemImage: "doc.badge.ellipsis")
                    .foregroundStyle(.secondary)
            }
            if let url = result.huggingFaceURL {
                Link(destination: url) {
                    Label(String(localized: "Open on Hugging Face", bundle: .module), systemImage: "safari")
                }
            }
        }
    }

    private static func copy(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}

struct FindingRow: View {
    let item: CompatibilityFinding

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(item.title, systemImage: item.level.systemImage)
                .foregroundStyle(tint)
                .font(.body.weight(item.level == .blocker ? .semibold : .regular))
            Text(item.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(item.level.localizedLabel): \(item.title). \(item.detail)"))
    }

    private var tint: Color {
        switch item.level {
        case .blocker: .red
        case .caveat: .orange
        case .info: .primary
        }
    }
}
