import SwiftUI
import TonamoxCore

/// Hugging Face search results with a verdict for the chosen device on every row. Selecting a row sets
/// `selection` to its repo id; show ``HFRepoDetailView`` for it with a split view's detail column or a stack's
/// `navigationDestination(item:)`. Brings no navigation container of its own.
public struct HFModelSearchList: View {
    @Bindable var search: HFModelSearch
    @Binding var selection: String?
    @State private var showsDetails = false

    public init(search: HFModelSearch, selection: Binding<String?>) {
        self.search = search
        self._selection = selection
    }

    static func title(for status: CompatibilityVerdict?, count: Int) -> String {
        switch status {
        case .runnable: String(localized: "Works here (\(count))", bundle: .module)
        case .runnableWithCaveats: String(localized: "Works with caveats (\(count))", bundle: .module)
        case .notRunnable: String(localized: "Won't run here (\(count))", bundle: .module)
        case .unknown: String(localized: "Could not check (\(count))", bundle: .module)
        case nil: String(localized: "Checking (\(count))", bundle: .module)
        }
    }

    public var body: some View {
        List(selection: $selection) {
            Section {
                HFSearchControls(search: search, showsDetails: $showsDetails)
            }
            if let error = search.searchError {
                Label(error, systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.red)
            }
            if !search.matches.isEmpty {
                Text("\(search.visibleMatches.count) results", bundle: .module)
                    .font(.headline)
                    .listRowBackground(Color.clear)
            }
            let sections = search.sections
            ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                Section {
                    ForEach(section.matches) { match in
                        HFResultRow(match: match, outcome: search.reports[match.id])
                            .tag(match.id)
                            .task(id: match.id) { await search.loadReport(for: match.id) }
                    }
                } header: {
                    Text(Self.title(for: section.status, count: section.matches.count))
                } footer: {
                    if index == sections.count - 1 { HiddenResultsFooter(search: search) }
                }
            }
            if sections.isEmpty {
                Section { EmptyView() } footer: { HiddenResultsFooter(search: search) }
            }
        }
        // On the List, not in a row, which the List may recycle while scrolling.
        .sheet(isPresented: $showsDetails) { HFSearchDetailsSheet(search: search) }
        .searchable(text: $search.query, prompt: Text("Search Hugging Face models", bundle: .module))
        .onSubmit(of: .search) { search.search() }
        .onChange(of: search.formatChoice) { search.search() }
        .onChange(of: search.ordering) { search.search() }
        .overlay {
            if search.isSearching && search.matches.isEmpty {
                ProgressView(String(localized: "Searching…", bundle: .module))
            } else if !search.isSearching && search.matches.isEmpty && search.searchError == nil {
                ContentUnavailableView.search(text: search.query)
            }
        }
    }
}

struct HFSearchControls: View {
    @Bindable var search: HFModelSearch
    @Binding var showsDetails: Bool

    var body: some View {
        Picker(String(localized: "Format", bundle: .module), selection: $search.formatChoice) {
            ForEach(HFWeightFilter.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)

        HStack {
            Picker(String(localized: "Sort", bundle: .module), selection: $search.ordering) {
                ForEach(HuggingFaceSearch.Sort.allCases, id: \.self) { Text($0.localizedLabel).tag($0) }
            }
            Button {
                showsDetails = true
            } label: {
                Image(systemName: "info.circle")
                    .imageScale(.large)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Device and filter", bundle: .module))
            .accessibilityHint(Text("Shows the memory this search judges against and the Compatible only filter",
                                    bundle: .module))
        }
    }
}

/// The device a search is judged against, where its memory figure comes from, and the Compatible only filter.
struct HFSearchDetailsSheet: View {
    @Bindable var search: HFModelSearch
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if search.devices.count > 1 {
                        Picker(String(localized: "Device", bundle: .module), selection: $search.deviceID) {
                            ForEach(search.devices) { target in
                                Text(verbatim: "\(target.displayName) · \(target.localizedBudgetText)").tag(target.id)
                            }
                        }
                        .accessibilityHint(Text("Judges every result against this device's memory budget",
                                                bundle: .module))
                    } else {
                        LabeledContent(search.currentTarget.displayName,
                                       value: search.currentTarget.localizedBudgetText)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(search.currentTarget.source)
                        if let filter = search.pipelineFilter {
                            let tags = filter.pipelineTags.sorted().joined(separator: ", ")
                            Text(filter.admitsUndeclared
                                 ? String(localized: "Shows \(tags) and repos that declare no task.", bundle: .module)
                                 : String(localized: "Shows \(tags).", bundle: .module))
                        }
                        #if targetEnvironment(simulator)
                        Text("Simulator: memory is the Mac's, not an iPhone's.", bundle: .module)
                        #endif
                    }
                }
                Section {
                    Toggle(String(localized: "Compatible only", bundle: .module), isOn: $search.compatibleOnly)
                        .accessibilityHint(Text("Hides results rated Won't run; unchecked results stay visible",
                                                bundle: .module))
                }
            }
            .navigationTitle(Text("Device and filter", bundle: .module))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", bundle: .module)) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Says how many results Compatible only hides, so a repo that would not run here never vanishes silently.
struct HiddenResultsFooter: View {
    @Bindable var search: HFModelSearch

    var body: some View {
        let hidden = search.hiddenCount
        if hidden > 0 {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(hidden) hidden: they would not run here", bundle: .module)
                Button(String(localized: "Show all", bundle: .module)) { search.compatibleOnly = false }
                    .accessibilityHint(Text("Turns off Compatible only", bundle: .module))
            }
        }
    }
}

struct HFResultRow: View {
    let match: HFModelHit
    let outcome: CompatibilityReport?
    @Environment(\.hfRepoCaution) private var repoCaution

    var body: some View {
        let caution = repoCaution(match.id, match.tags)
        VStack(alignment: .leading, spacing: 4) {
            Text(match.id)
                .font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            if let caution {
                HFRepoCautionLabel(text: caution)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VerdictBadge(status: outcome?.status)
                Text(outcome?.headline ?? String(localized: "Checking…", bundle: .module))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 12) {
                if let outcome { Text(outcome.weightFormat.localizedLabel) }
                if let artifact = outcome?.artifact, artifact.kind.isAdapter || artifact.isSuspectedAdapter {
                    Label(artifact.kind.isAdapter && artifact.isCertain ? String(localized: "Adapter, not a model", bundle: .module)
                            : String(localized: "Maybe an adapter", bundle: .module),
                          systemImage: "puzzlepiece.extension")
                }
                Label("\(match.downloads)", systemImage: "arrow.down.circle")
                Label("\(match.likes)", systemImage: "heart")
                if match.gated { Label(String(localized: "Gated", bundle: .module), systemImage: "lock.fill") }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caution.map { accessibilityText + " " + $0 } ?? accessibilityText)
    }

    private var accessibilityText: String {
        guard let outcome else { return String(localized: "\(match.id). Checking compatibility.", bundle: .module) }
        let verdict = outcome.status.localizedLabel
        return match.gated
            ? String(localized: "\(match.id). \(verdict). \(outcome.headline). Gated repository.", bundle: .module)
            : "\(match.id). \(verdict). \(outcome.headline)."
    }
}

// MARK: - Badge

/// A caution the host app wants on a Hugging Face repo, under its search row and atop its detail page. Gets the
/// repo id and its tags; nil shows nothing. TonamoxUI applies no rule of its own here.
public struct HFRepoCaution: Sendable, Equatable {
    /// Equality is by `id`: closures cannot be compared, and an incomparable environment value would invalidate
    /// every dependent view on each update.
    public let id: String
    private let caution: @Sendable (_ repoID: String, _ tags: [String]) -> String?

    public init(id: String, _ caution: @escaping @Sendable (_ repoID: String, _ tags: [String]) -> String?) {
        self.id = id
        self.caution = caution
    }

    /// The default: no caution on any repo.
    public static let none = HFRepoCaution(id: "none") { _, _ in nil }

    public func callAsFunction(_ repoID: String, _ tags: [String]) -> String? { caution(repoID, tags) }

    public static func == (lhs: HFRepoCaution, rhs: HFRepoCaution) -> Bool { lhs.id == rhs.id }
}

extension EnvironmentValues {
    /// See ``HFRepoCaution``; ``HFRepoCaution/none`` by default.
    @Entry public var hfRepoCaution: HFRepoCaution = .none
}

struct HFRepoCautionLabel: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.shield")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct VerdictBadge: View {
    let status: CompatibilityVerdict?

    var body: some View {
        if let status {
            Label(status.localizedLabel, systemImage: status.systemImage)
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint(status))
                .accessibilityLabel(Text("Verdict: \(status.localizedLabel)", bundle: .module))
        } else {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(Text("Checking", bundle: .module))
        }
    }

    private func tint(_ value: CompatibilityVerdict) -> Color {
        switch value {
        case .runnable: .green
        case .runnableWithCaveats: .orange
        case .notRunnable: .red
        case .unknown: .secondary
        }
    }
}
