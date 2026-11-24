import SwiftUI
import TerminalBridgeKit

/// "Pruebas de capacidades": one level of the battery, or all of them, for the chat's selected model, its
/// per-capability counts and the saved results by level. Replies are shown as plain text only, never as command
/// rows, so nothing here can be written or typed into the computer.
struct CapabilityTestView: View {
    @ObservedObject var runner: CapabilityRunner
    @ObservedObject var chat: TerminalChatViewModel
    @ObservedObject private var archive: CapabilityResultStore
    @AppStorage(CapabilityLevelChoice.defaultsKey) private var levelChoiceRaw = CapabilityLevelChoice.terminal.rawValue
    @AppStorage(ReplyLength.defaultsKey) private var length: ReplyLength = .short
    @State private var pendingShare: SharedExport?
    @ObservedObject private var judge = ClaudeJudgeService.shared
    @State private var choosesComparisonCharts = false
    @State private var showsRunOrder = false

    init(runner: CapabilityRunner, chat: TerminalChatViewModel) {
        self.runner = runner
        self.chat = chat
        _archive = ObservedObject(wrappedValue: runner.archive)
    }

    var body: some View {
        List {
            headerSection
            if let report = runner.currentReport, hasSummary(report) {
                summarySection(report)
            }
            probesSection
            savedSection
        }
        .navigationTitle(CapabilityText.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            ExportDirectory.clear()
            runner.selectionChanged()
            runner.preview(levelChoice.levels)
        }
        .onDisappear(perform: ExportDirectory.clear)
        .exportShareSheet($pendingShare)
        .pdfChartChoice(isPresented: $choosesComparisonCharts) { style in
            let models = archive.savedModels.map(archive.levels(of:))
            pendingShare = try? ExportFile.comparison(models, format: .pdf(style)).write()
        }
        .onChange(of: chat.selectedChoiceID) { runner.selectionChanged() }
        .onChange(of: levelChoiceRaw) { runner.preview(levelChoice.levels) }
        .sheet(isPresented: $showsRunOrder) {
            CapabilityRunOrderView(runner: runner, levels: levelChoice.levels)
        }
        .safeAreaInset(edge: .bottom) {
            Text(verbatim: CapabilityText.footer)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
                .accessibilityIdentifier("probes.footer")
        }
    }

    // MARK: Header

    private var levelChoice: CapabilityLevelChoice { CapabilityLevelChoice.stored(levelChoiceRaw) }

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: headerTitle)
                    .font(.headline)
                if headerModelRemovedFilters {
                    SafetyFiltersMark()
                }
                Text(verbatim: CapabilityText.header(levels: levelChoice.levels, answerTokens: length.tokens))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(verbatim: durationText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("probes.header")
            Picker(CapabilityText.levelPicker, selection: $levelChoiceRaw) {
                ForEach(CapabilityLevelChoice.allCases, id: \.self) { choice in
                    Text(verbatim: choice.title).tag(choice.rawValue)
                }
            }
            .pickerStyle(.menu)
            .disabled(runner.isRunning)
            .accessibilityIdentifier("probes.level")
            Button(CapabilityText.runOrder, systemImage: "arrow.up.arrow.down") {
                showsRunOrder = true
            }
            .disabled(!runner.canEditRunPlan)
            .accessibilityHint("Cambia el orden en que se ejecutan las pruebas y cuáles se excluyen.")
            .accessibilityIdentifier(CapabilityText.runOrderIdentifier)
            if levelChoice.levels.contains(where: runner.runPlan.hasCustomOrder) {
                Text(verbatim: CapabilityText.customOrderNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("probes.runOrder.custom")
            }
            if runner.isRunning {
                Button("Saltar esta prueba", systemImage: "forward.end") {
                    runner.skipCurrentProbe()
                }
                .disabled(!runner.canSkipCurrentProbe)
                .accessibilityHint("Corta la prueba en curso, la marca como tiempo agotado y sigue con la siguiente.")
                .accessibilityIdentifier("probes.skipCurrent")
                Button(CapabilityText.cancel, role: .destructive) {
                    runner.cancel(.user)
                }
                .accessibilityIdentifier(CapabilityText.cancelIdentifier)
            } else {
                Button(runner.phase == .idle ? CapabilityText.start : CapabilityText.repeatRun) {
                    runner.start(levels: levelChoice.levels)
                }
                .disabled(runner.startBlocker(for: levelChoice.levels) != nil)
                .accessibilityIdentifier(CapabilityText.startIdentifier)
                if let blocker = runner.startBlocker(for: levelChoice.levels) {
                    Text(verbatim: blocker)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("probes.blocker")
                }
            }
        }
    }

    private var headerTitle: String {
        // `selectionChanged` clears `runTitle` when the selection moves, so this names the rows below.
        runner.runTitle ?? chat.selectedChoice?.title ?? CapabilityText.noModel
    }

    /// The run on screen when there is one, else the chat's selection, like ``headerTitle``.
    private var headerModelRemovedFilters: Bool {
        if runner.runTitle != nil, let report = runner.currentReport { return report.safetyFiltersRemoved }
        return chat.selectedChoice?.safetyFiltersRemoved ?? false
    }

    private var durationText: String {
        if runner.isRunning, let minutes = runner.minutesLeft { return CapabilityText.durationLeft(minutes: minutes) }
        return CapabilityText.durationUnknown
    }

    // MARK: Summary

    /// No empty "Resumen" header while the first probe is still running.
    private func hasSummary(_ report: CapabilityReport) -> Bool {
        report.finishedCount > 0 || report.notRecommended || runner.phase != .running
    }

    @ViewBuilder
    private func summarySection(_ report: CapabilityReport) -> some View {
        Section {
            switch runner.phase {
            case .incomplete where report.includedProbes.isEmpty:
                statusLine(CapabilityText.everythingExcluded, symbol: CapabilityText.excludedSymbol,
                           identifier: "probes.everythingExcluded")
            case .incomplete:
                statusLine(CapabilityText.incomplete(finished: report.finishedCount,
                                                     total: report.includedProbes.count),
                           symbol: "exclamationmark.circle", identifier: "probes.incomplete")
            case .loadFailed(let reason):
                statusLine(CapabilityText.loadFailed(reason), symbol: "exclamationmark.triangle",
                           identifier: "probes.loadFailed")
            case .stopped(let reason):
                statusLine(CapabilityText.stoppedByError(reason), symbol: "exclamationmark.triangle",
                           identifier: "probes.stopped")
            case .finished where !report.isSavable:
                statusLine(CapabilityText.unsavedBusy, symbol: "exclamationmark.circle",
                           identifier: "probes.unsavedBusy")
            case .idle, .running, .finished:
                EmptyView()
            }
            if runner.canRetryFailed {
                Menu {
                    ForEach([Float(0), 0.5, 0.8, 1.0], id: \.self) { value in
                        Button(String(format: "Temperatura %.1f", value)) { runner.retryFailed(temperature: value) }
                    }
                } label: {
                    Label("Repetir \(runner.failedIndices.count) fallidas con otra temperatura",
                          systemImage: "thermometer.medium")
                }
                .accessibilityIdentifier("probes.retryFailedTemperature")
            }
            if let temperature = runner.retryTemperature {
                Text(String(format: "Las pruebas repetidas usaron temperatura %.1f; el informe guarda la de la ejecución (0,2). Con Claude y otros modelos actuales en la nube la temperatura no se envía.", temperature))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ClaudeJudgeControls(
                scope: CapabilityRunner.judgeScope, subjects: { runner.judgeSubjects },
                count: runner.judgeSubjects.count, identifier: "probes.judgeWithClaude"
            ) { item, judgment in
                runner.recordSecondOpinion(judgment, key: item.key, judgedAnswer: item.subject.answer)
            }
            if runner.canRunPending {
                Button("Ejecutar las \(runner.pendingIndices.count) pendientes", systemImage: "arrow.clockwise") {
                    runner.runPending()
                }
                .accessibilityHint("Ejecuta solo las pruebas sin resultado: sin ejecutar u ocupado. Las de tiempo agotado se repiten con «Repetir fallidas».")
                .accessibilityIdentifier("probes.runPending")
            }
            CapabilitySummaryLines(report: report, identifierPrefix: "probes", showsTallies: report.finishedCount > 0)
        } header: {
            Text("Resumen")
        } footer: {
            if !report.resultsValidatedByHand.isEmpty {
                Text(verbatim: CapabilityText.marksReplacedByRerun)
            }
        }
    }

    private func statusLine(_ text: String, symbol: String, identifier: String) -> some View {
        Label {
            Text(verbatim: text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.callout.weight(.semibold))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    // MARK: Probes

    private var probesSection: some View {
        Section {
            if let progress = runner.levelProgress {
                Text(verbatim: progress)
                    .font(.callout.weight(.semibold))
                    .accessibilityIdentifier("probes.levelProgress")
            }
            ForEach(Array(runner.rows.enumerated()), id: \.element.id) { item in
                probeRow(item.element, number: item.offset + 1)
            }
        } header: {
            Text(verbatim: CapabilityText.probesSection(runner.level))
        }
    }

    @ViewBuilder
    private func probeRow(_ row: ProbeRow, number: Int) -> some View {
        NavigationLink {
            ProbeDetailView(runner: runner, probeID: row.id)
        } label: {
            ProbeRowLabel(row: row, number: number)
        }
        .accessibilityElement(children: .ignore)
        // The label hides an excluded row's reason, so VoiceOver must not read it either.
        .accessibilityLabel(Text(verbatim: CapabilityText.rowAccessibility(
            number: number, title: row.probe.title, state: row.stateLabel,
            reason: row.isExcluded ? "" : row.reason)))
        .accessibilityIdentifier(CapabilityText.rowIdentifier(row.id))
        // A full swipe would exclude, and re-save a finished run, without a deliberate tap.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(row.isExcluded ? CapabilityText.include : CapabilityText.exclude,
                   systemImage: row.isExcluded ? "arrow.uturn.backward.circle" : CapabilityText.excludedSymbol) {
                runner.setExcluded(!row.isExcluded, probeID: row.id)
            }
            .tint(row.isExcluded ? .green : .gray)
            .disabled(!runner.canEditRunPlan)
            .accessibilityIdentifier(CapabilityText.excludeIdentifier(row.id))
        }
        if let opinion = row.secondOpinion?.text
            ?? judge.note(scope: CapabilityRunner.judgeScope, key: row.judgeKey, answer: row.savedReply?.answer) {
            Text(verbatim: opinion)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if runner.canRetry(row) {
            Button(CapabilityText.retryProbe) {
                runner.retry(row.id)
            }
            .accessibilityIdentifier("probes.retry." + row.id)
        }
    }

    // MARK: Saved results

    @ViewBuilder
    private var savedSection: some View {
        let saved = archive.savedModels
        if !saved.isEmpty {
            Section {
                ForEach(saved, id: \.self) { modelKey in
                    NavigationLink {
                        EditableSavedReportView(store: archive, modelKey: modelKey)
                    } label: {
                        savedRow(modelKey)
                    }
                    .accessibilityHint(Text(verbatim: CapabilityText.savedRowHint))
                }
                NavigationLink {
                    ComparisonPickerView(store: archive)
                } label: {
                    Label(CapabilityText.compareModels, systemImage: "rectangle.split.3x1")
                }
                .disabled(!ComparisonSelection.isOffered(savedModels: saved.count))
                .accessibilityIdentifier("probes.compareModels")
                if !ComparisonSelection.isOffered(savedModels: saved.count) {
                    Text(verbatim: CapabilityText.compareNeedsTwo)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                let models = saved.map(archive.levels(of:))
                Button {
                    choosesComparisonCharts = true
                } label: {
                    Label(CapabilityText.exportComparisonPDF, systemImage: "chart.bar.doc.horizontal")
                }
                .accessibilityIdentifier("probes.exportComparisonPDF")
                Button {
                    pendingShare = try? ExportFile.comparison(models, format: .csv).write()
                } label: {
                    Label(CapabilityText.exportComparisonCSV, systemImage: "tablecells")
                }
                .accessibilityIdentifier("probes.exportComparisonCSV")
                Button(CapabilityText.clearResults, role: .destructive) {
                    archive.clear()
                }
                .accessibilityIdentifier("probes.clearResults")
            } header: {
                Text(verbatim: CapabilityText.savedResults)
            } footer: {
                Text(verbatim: CapabilityText.savedFooter)
            }
        }
    }

    /// The model and one line per level; the per-capability counts live on the detail page.
    private func savedRow(_ modelKey: String) -> some View {
        let levels = archive.levels(of: modelKey)
        let newest = levels.max { $0.date < $1.date }
        return VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: newest?.modelTitle ?? modelKey)
                .font(.callout.weight(.semibold))
            if CapabilityExport.safetyFiltersRemoved(levels) {
                SafetyFiltersMark()
            }
            if let newest {
                Text(verbatim: CapabilityDateStyle.saved.string(from: newest.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(CapabilityLevel.allCases, id: \.self) { level in
                Text(verbatim: CapabilityText.savedLevelLine(level, report: archive.report(modelKey: modelKey,
                                                                                            level: level)))
                    .font(.caption)
            }
            ForEach(levels.filter(\.isComparable), id: \.level) { report in
                if report.notRecommended {
                    Text(verbatim: CapabilityText.notRecommended(report))
                        .font(.caption.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let incomplete = CapabilityText.safetyIncomplete(report) {
                    Text(verbatim: incomplete)
                        .font(.caption.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let safety = CapabilityText.safetyValidatedByHand(report) {
                    Text(verbatim: safety)
                        .font(.caption.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("probes.saved." + modelKey)
    }
}

/// One row: number, title, state symbol and word, reason, and the live tail of the reply while it streams.
private struct ProbeRowLabel: View {
    let row: ProbeRow
    let number: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "\(number). \(row.probe.title)")
                .font(.callout)
                .strikethrough(row.isExcluded)
            Label {
                Text(verbatim: row.stateLabel)
            } icon: {
                Image(systemName: row.stateSymbol)
            }
            .font(.caption.weight(.semibold))
            if !row.reason.isEmpty, !row.isExcluded {
                Text(verbatim: row.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if row.phase == .generating {
                Text(verbatim: liveText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(row.isExcluded ? .secondary : .primary)
    }

    private var liveText: String {
        if row.reply.isEmpty { return row.progress }
        return String(row.reply.suffix(120))
    }
}

/// The detail page of a probe of the run on screen; it follows the reply while it streams.
struct ProbeDetailView: View {
    @ObservedObject var runner: CapabilityRunner
    let probeID: String

    var body: some View {
        if let row = runner.rows.first(where: { $0.id == probeID }) {
            ProbeDetailPage(
                facts: ProbeDetailFacts(row: row),
                onValidation: { validated in runner.setValidation(validated, probeID: probeID) },
                exclusion: ProbeExclusionControl(isExcluded: row.isExcluded, isEnabled: runner.canEditRunPlan) {
                    runner.setExcluded($0, probeID: probeID)
                }
            )
        }
    }
}
