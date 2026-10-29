import SwiftUI
import TonamoxCore
import TonamoxUI
#if os(iOS)
import UIKit
#endif

// MARK: - EngineCompareView
//
// "Which engine runs my model fastest here?" Runs TonamoxCore's EngineBenchmark over downloaded models (llama.cpp or
// MLX, in this process) and the models of local servers (llama-server, Ollama, Magnitude), then shows one table per
// workload. Only models already on disk are offered, so nothing downloads.

struct EngineCompareView: View {
    @State private var comparison = EngineComparison()

    var body: some View {
        // Read so the list follows downloads and deletions.
        let _ = ModelDownloadCenter.shared.revision
        let models = ChatModels.downloaded(requiring: .text)
        let runnable = models.filter { ModelBlocker.check($0) == nil }.map { EngineOption.inProcess($0) }
            + comparison.serverOptions
        let chosen = runnable.filter { comparison.selection.contains($0.id) }
        Form {
            inProcessSection(models)
            serverSection
            workloadSection
            runSection(chosen)
            if let report = comparison.report {
                resultSections(report)
                aboutSection
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Compare engines")
        .task { if !comparison.hasProbed { await comparison.refreshServers() } }
        .onDisappear { if comparison.isRunning { comparison.cancel() } }
        .interactiveDismissDisabled(comparison.isRunning)
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 640)
        #endif
    }

    // MARK: - Engines

    private func inProcessSection(_ models: [Model]) -> some View {
        Section {
            ForEach(models) { model in
                optionRow(.inProcess(model), blocker: ModelBlocker.check(model))
            }
            if models.isEmpty {
                Text("No chat model downloaded yet. Get one from Browse the catalog.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("In this app")
        } footer: {
            Text("Downloaded models that take text, run by Tonamox's llama.cpp (GGUF) or MLX engine. Nothing is "
                 + "downloaded here.")
        }
    }

    private var serverSection: some View {
        let reachable = comparison.servers.filter(\.reachable)
        let stopped = comparison.servers.filter { !$0.reachable }.map(\.kind.displayName)
        return Section {
            ForEach(reachable) { status in
                let local = status.models.filter(\.runsLocally)
                ForEach(local) { served in
                    optionRow(.server(status, served), blocker: nil)
                }
                if local.isEmpty {
                    Text("\(status.kind.displayName) lists no model that runs on this device.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !stopped.isEmpty {
                Text("Not running: \(stopped.joined(separator: ", ")).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button { Task { await comparison.refreshServers() } } label: {
                if comparison.isProbing {
                    HStack { ProgressView(); Text("Probing…") }
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(comparison.isProbing || comparison.isRunning)
        } header: {
            Text("Local servers")
        } footer: {
            Text("Probes llama-server (:8080), Ollama (:11434) and Magnitude (:10100) at their default addresses on "
                 + "this machine. Ollama cloud models are left out.")
        }
    }

    private func optionRow(_ option: EngineOption, blocker: ModelBlocker?) -> some View {
        let isOn = comparison.selection.contains(option.id)
        return Button { comparison.toggle(option.id) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.modelName)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(blocker.map { "\(option.engineName) · \($0.explanation)" } ?? option.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: isOn && blocker == nil ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn && blocker == nil ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(blocker != nil || comparison.isRunning)
        .accessibilityAddTraits(isOn && blocker == nil ? .isSelected : [])
    }

    // MARK: - Workloads and settings

    private var workloadSection: some View {
        Section {
            ForEach(BenchmarkWorkload.all) { workload in
                Toggle(isOn: comparison.binding(for: workload)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workload.title)
                        Text(Self.workloadDetail(workload)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Stepper("Measured runs: \(comparison.measuredRuns)", value: $comparison.measuredRuns, in: 1...10)
            // A segmented picker hides its own label on iOS.
            LabeledContent("Temperature") {
                Picker("Temperature", selection: $comparison.temperature) {
                    Text("0").tag(Float(0))
                    Text("0.7").tag(Float(0.7))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        } header: {
            Text("Workloads")
        } footer: {
            Text("Each workload gets one warm-up run that is not counted, then the measured runs. At temperature 0 "
                 + "each output is compared with the first engine that produced one; at 0.7 outputs are not compared.")
        }
        .disabled(comparison.isRunning)
    }

    /// The prompt size is UTF-8 bytes ÷ 4, the estimate TonamoxCore uses when a runtime reports no count.
    private static func workloadDetail(_ workload: BenchmarkWorkload) -> String {
        let promptTokens = (workload.systemPrompt.utf8.count + workload.userPrompt.utf8.count) / 4
        return "≈\(promptTokens.formatted())-token prompt · up to \(workload.maxTokens) tokens out"
    }

    // MARK: - Run

    private func runSection(_ chosen: [EngineOption]) -> some View {
        Section {
            if comparison.isRunning {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: comparison.fractionDone)
                    Text(comparison.progressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(role: .cancel) { comparison.cancel() } label: {
                    Label(comparison.isCancelling ? "Cancelling…" : "Cancel", systemImage: "stop.circle")
                }
                .disabled(comparison.isCancelling)
            } else {
                Button { comparison.run(chosen) } label: {
                    Label("Run (\(chosen.count) engine\(chosen.count == 1 ? "" : "s"))",
                          systemImage: "gauge.with.dots.needle.67percent")
                }
                .disabled(chosen.isEmpty || comparison.selectedWorkloads.isEmpty)
            }
        } footer: {
            Text("Engines run one at a time. A model in this app is loaded for its turn and released after it, and "
                 + "the app's other loaded models are unloaded before the run. Every prompt starts with a fresh run "
                 + "marker, so a prompt cache can't reuse an earlier run. Cancel stops the run in progress and keeps "
                 + "what finished; a model that is loading finishes loading first.")
        }
    }

    // MARK: - Results

    @ViewBuilder
    private func resultSections(_ report: BenchmarkReport) -> some View {
        if report.wasCancelled {
            Section {
                Label("Cancelled: these results are partial.", systemImage: "stop.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        let unloaded = report.candidates.filter { $0.loadError != nil }
        if !unloaded.isEmpty {
            Section("Did not load") {
                ForEach(unloaded) { candidate in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.label).font(.subheadline.weight(.semibold))
                        Text(candidate.loadError ?? "").font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
        ForEach(report.workloads) { workload in
            workloadResults(workload, in: report)
        }
    }

    private func workloadResults(_ workload: BenchmarkWorkload, in report: BenchmarkReport) -> some View {
        let ran = report.candidates.filter { $0.result(for: workload.id) != nil }
        let measuredCount = ran.filter { $0.result(for: workload.id)?.runs.isEmpty == false }.count
        // A lone engine is trivially the fastest; only rank two or more.
        let fastestDecode = measuredCount > 1 ? report.fastestDecode(in: workload.id)?.id : nil
        let fastestFirstToken = measuredCount > 1 ? report.fastestTimeToFirstToken(in: workload.id)?.id : nil
        let truncated = report.promptTruncationSuspects(in: workload.id)
            .map { id in report.candidates.first { $0.id == id }?.label ?? id }
        let settings = report.settings
        let runs = "\(settings.measuredRuns) measured run\(settings.measuredRuns == 1 ? "" : "s")"
        return Section {
            ForEach(ran) { candidate in
                if let result = candidate.result(for: workload.id) {
                    resultRow(candidate, result, isFastestDecode: candidate.id == fastestDecode,
                              isFastestFirstToken: candidate.id == fastestFirstToken)
                }
            }
            if ran.isEmpty {
                Text("No engine ran this workload.").font(.caption).foregroundStyle(.secondary)
            }
            if report.modelsDiffer(in: workload.id) {
                Label("The engines ran different models or quantizations, or Tonamox could not confirm they match: "
                      + "speed and output match compare more than the engine.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !truncated.isEmpty {
                Label("\(truncated.joined(separator: ", ")) reported far fewer prompt tokens than the others: the "
                      + "server may have cut the prompt to fit its context (Ollama: num_ctx).",
                      systemImage: "scissors")
                    .font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text(workload.title)
        } footer: {
            Text("Up to \(settings.maxTokensOverride ?? workload.maxTokens) tokens · \(runs) · temperature "
                 + "\(String(format: "%.1f", settings.temperature)) · medians; TTFT and decode show the min–max below "
                 + "when runs differ.")
        }
    }

    private func resultRow(
        _ candidate: BenchmarkCandidateResult, _ result: BenchmarkWorkloadResult,
        isFastestDecode: Bool, isFastestFirstToken: Bool
    ) -> some View {
        let provenance = result.provenance
        // Decode counts are exact unless estimated; prompt counts only when the runtime reports them.
        let approxOutput = provenance == .estimated ? "≈" : ""
        let approxPrompt = provenance == .runtime ? "" : "≈"
        return VStack(alignment: .leading, spacing: 6) {
            Text(candidate.label).font(.subheadline.weight(.semibold))
            if let weights = Self.weightsText(candidate) {
                Text(weights)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if isFastestDecode || isFastestFirstToken {
                HStack(spacing: 10) {
                    if isFastestDecode { Label("Fastest decode", systemImage: "hare.fill") }
                    if isFastestFirstToken { Label("Fastest first token", systemImage: "bolt.fill") }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.green)
            }
            if !result.runs.isEmpty {
                LazyVGrid(columns: Self.metricColumns, alignment: .leading, spacing: 6) {
                    metric("TTFT", Self.medianText(result.timeToFirstToken, format: "%.2f s"),
                           detail: Self.range(result.timeToFirstToken, format: "%.2f"),
                           highlighted: isFastestFirstToken)
                    metric("Prefill",
                           Self.medianText(result.prefillTokensPerSecond, format: "\(approxPrompt)%.0f tok/s"))
                    metric("Decode",
                           Self.medianText(result.decodeTokensPerSecond, format: "\(approxOutput)%.1f tok/s"),
                           detail: Self.range(result.decodeTokensPerSecond, format: "%.1f"),
                           highlighted: isFastestDecode)
                    metric("Tokens", Self.tokensText(result, approx: approxPrompt))
                    metric("Peak memory", Self.memoryText(result.peakMemoryBytes),
                           detail: Self.memoryDetail(candidate, peak: result.peakMemoryBytes))
                    // The footer names the temperature; the full label wraps badly in a grid cell.
                    metric("Output match", result.agreement == .notApplicable ? "n/a" : result.agreement.label)
                }
                Text(Self.provenanceText(candidate, provenance))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let failure = result.failure {
                Label(result.runs.isEmpty ? failure : "Stopped early: \(failure)", systemImage: "xmark.octagon")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    private func metric(
        _ name: String, _ value: String, detail: String? = nil, highlighted: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).font(.caption2).foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .fontWeight(highlighted ? .semibold : nil)
                .foregroundStyle(highlighted ? Color.green : Color.primary)
            if let detail {
                Text(detail).font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    private static let metricColumns = [GridItem(.adaptive(minimum: 104), alignment: .topLeading)]

    // MARK: - About

    private var aboutSection: some View {
        Section("About these numbers") {
            Text("They hold for this device, what else it is running and these prompts; run again before reading "
                 + "much into small gaps. Servers are timed from this app, so their time to first token includes "
                 + "the HTTP round trip and any queueing, and their prefill speed is prompt tokens ÷ that time. "
                 + "≈ marks estimated token counts (text length ÷ 4), which are approximate. Peak memory is this "
                 + "app's footprint, so a server, which runs in its own process, is not measured.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Formatting

    private static func medianText(_ metric: BenchmarkMetric?, format: String) -> String {
        metric.map { String(format: format, $0.median) } ?? "—"
    }

    /// `min–max` when the runs differ at the shown precision.
    private static func range(_ metric: BenchmarkMetric?, format: String) -> String? {
        guard let metric else { return nil }
        let low = String(format: format, metric.minimum)
        let high = String(format: format, metric.maximum)
        return low == high ? nil : "\(low)–\(high)"
    }

    private static func tokensText(_ result: BenchmarkWorkloadResult, approx: String) -> String {
        guard let prompt = result.promptTokens?.median, let generated = result.generatedTokens?.median else {
            return "—"
        }
        return "\(approx)\(Int(prompt.rounded())) → \(Int(generated.rounded()))"
    }

    private static func memoryText(_ bytes: Int?) -> String {
        bytes.map { String(format: "%.1f GB", Double($0) / 1_073_741_824) } ?? "—"
    }

    /// What the model added over the app's footprint before it loaded; a server's memory is not this app's.
    private static func memoryDetail(_ candidate: BenchmarkCandidateResult, peak: Int?) -> String? {
        guard candidate.timing == .inProcess else { return "server process" }
        guard let peak, let before = candidate.memoryBeforeLoadBytes else { return nil }
        return String(format: "+%.1f GB", Double(peak - before) / 1_073_741_824)
    }

    /// The weights' name when the label doesn't already show it (a server's model id), quantization and load time.
    private static func weightsText(_ candidate: BenchmarkCandidateResult) -> String? {
        let weights = candidate.weights
        var parts = candidate.label.contains(weights.name) ? [] : [weights.name]
        if let quantization = weights.quantization, !weights.name.lowercased().contains(quantization.lowercased()) {
            parts.append(quantization)
        }
        if let seconds = candidate.loadSeconds {
            parts.append(String(format: "loaded in %.1f s", seconds))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func provenanceText(
        _ candidate: BenchmarkCandidateResult, _ provenance: GenerationStats.Provenance?
    ) -> String {
        guard candidate.timing == .clientSide else { return provenance?.label ?? "" }
        let counts = provenance == .runtime ? "token counts from the server" : "token counts estimated from text"
        return "\(counts) · timed by this app"
    }
}

// MARK: - EngineOption

/// One engine the comparison can run: a downloaded model in this app, or a model a local server lists.
struct EngineOption: Identifiable {
    enum Origin {
        case inProcess(Model)
        case server(LocalProviderStatus, LocalProviderModel)
    }

    let id: String
    let source: Origin

    static func inProcess(_ model: Model) -> EngineOption {
        EngineOption(id: "app:\(model.id)", source: .inProcess(model))
    }

    static func server(_ status: LocalProviderStatus, _ served: LocalProviderModel) -> EngineOption {
        EngineOption(id: "\(status.kind.rawValue):\(served.name)", source: .server(status, served))
    }

    /// The names `BenchmarkCandidate.inProcess` and `.server` use as their default label.
    var engineName: String {
        switch source {
        case .inProcess(let model): model.format == .mlx ? "Tonamox MLX" : "Tonamox llama.cpp"
        case .server(let status, _): status.kind.displayName
        }
    }

    var modelName: String {
        switch source {
        case .inProcess(let model): model.displayName
        case .server(_, let served): served.name
        }
    }

    var detail: String {
        let weights = switch source {
        case .inProcess(let model): BenchmarkModelIdentity(model: model)
        case .server(let status, let served): BenchmarkModelIdentity(served: served, by: status.kind)
        }
        return ([engineName] + [weights.quantization].compactMap { $0 }).joined(separator: " · ")
    }

    /// `false` once an in-process model's files are gone: loading it would download them again.
    var isOnDisk: Bool {
        switch source {
        case .inProcess(let model): model.isDownloaded
        case .server: true
        }
    }

    var isInProcess: Bool {
        if case .inProcess = source { return true }
        return false
    }

    /// Labelled with the model too, so progress and results tell two llama.cpp models apart.
    var candidate: BenchmarkCandidate {
        let label = "\(engineName) · \(modelName)"
        switch source {
        case .inProcess(let model): return .inProcess(model, label: label)
        case .server(let status, let served): return .server(status, model: served, label: label)
        }
    }
}

// MARK: - EngineComparison

/// The selection, settings, progress and report of ``EngineCompareView``.
@MainActor
@Observable
final class EngineComparison {
    var selection: Set<String> = []
    var workloadIDs: Set<String> = Set(BenchmarkWorkload.all.map(\.id))
    var measuredRuns = 3
    var temperature: Float = 0

    private(set) var servers: [LocalProviderStatus] = []
    private(set) var isProbing = false
    private(set) var hasProbed = false
    private(set) var isRunning = false
    private(set) var isCancelling = false
    private(set) var progressText = ""
    private(set) var fractionDone = 0.0
    private(set) var report: BenchmarkReport?
    @ObservationIgnored private var work: Task<Void, Never>?

    var selectedWorkloads: [BenchmarkWorkload] {
        BenchmarkWorkload.all.filter { workloadIDs.contains($0.id) }
    }

    var serverOptions: [EngineOption] {
        servers.filter(\.reachable).flatMap { status in
            status.models.filter(\.runsLocally).map { EngineOption.server(status, $0) }
        }
    }

    func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    func binding(for workload: BenchmarkWorkload) -> Binding<Bool> {
        Binding(
            get: { self.workloadIDs.contains(workload.id) },
            set: { isOn in
                if isOn { self.workloadIDs.insert(workload.id) } else { self.workloadIDs.remove(workload.id) }
            })
    }

    func refreshServers() async {
        isProbing = true
        defer { isProbing = false; hasProbed = true }
        servers = await LocalProviderDetector.detectAll()
    }

    func run(_ chosen: [EngineOption]) {
        let runnable = chosen.filter(\.isOnDisk)
        let workloads = selectedWorkloads
        guard !isRunning, !runnable.isEmpty, !workloads.isEmpty else { return }
        let settings = BenchmarkSettings(measuredRuns: measuredRuns, temperature: temperature)
        let benchmark = EngineBenchmark(candidates: runnable.map(\.candidate), workloads: workloads,
                                        settings: settings)
        if runnable.contains(where: \.isInProcess) {
            // A model loaded elsewhere would compete for memory and inflate the footprint readings.
            ModelManager.shared.evictAll()
        }
        report = nil
        isRunning = true
        isCancelling = false
        fractionDone = 0
        progressText = "Starting…"
        keepScreenAwake(true)
        work = Task {
            let finished = await benchmark.run { event in self.handle(event, settings: settings) }
            report = finished
            isRunning = false
            isCancelling = false
            progressText = ""
            keepScreenAwake(false)
        }
    }

    func cancel() {
        isCancelling = true
        progressText = "Cancelling…"
        work?.cancel()
    }

    private func handle(_ event: BenchmarkEvent, settings: BenchmarkSettings) {
        guard !isCancelling else { return }
        switch event {
        case .loading(_, let label):
            progressText = "Loading \(label)…"
        case .running(let progress):
            progressText = progress.summary
            fractionDone = Self.fraction(at: progress, settings: settings)
        case .workloadFinished, .candidateFinished:
            break
        }
    }

    /// The share of all runs, warm-ups included, done before `progress`'s run starts.
    private static func fraction(at progress: BenchmarkProgress, settings: BenchmarkSettings) -> Double {
        let perWorkload = settings.warmUpRuns + settings.measuredRuns
        let slot = progress.isWarmUp ? progress.run - 1 : settings.warmUpRuns + progress.run - 1
        let done = (progress.candidateIndex * progress.workloadCount + progress.workloadIndex) * perWorkload + slot
        let total = progress.candidateCount * progress.workloadCount * perWorkload
        return total > 0 ? Double(done) / Double(total) : 0
    }

    /// The app unloads every model when it goes to the background, which would fail the run in progress.
    private func keepScreenAwake(_ awake: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = awake
        #endif
    }
}
