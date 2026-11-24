import SwiftUI
import TerminalBridgeKit

enum CapabilityDateStyle {
    static let saved: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_ES")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// The PDF's dates: local time with its zone, because file names and Markdown are in UTC.
    static let printed: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_ES")
        formatter.setLocalizedDateFormatFromTemplate("dMMMyyyyHHmmzzz")
        return formatter
    }()
}

/// The battery page's saved reports of one model: it follows the store, so marks made on a detail page show at once.
struct EditableSavedReportView: View {
    @ObservedObject var store: CapabilityResultStore
    let modelKey: String

    var body: some View {
        let levels = store.levels(of: modelKey)
        if !levels.isEmpty {
            SavedReportView(levels: levels, store: store)
        }
    }
}

/// A model's saved reports, one level at a time, group by group: each probe's state, reason and time; the probes that
/// did not pass open their detail page, reply included. With a `store` the owner can mark them as valid there;
/// without one (the model sheet) the page is read-only.
struct SavedReportView: View {
    /// In level order.
    let levels: [CapabilityReport]
    var store: CapabilityResultStore?
    @State private var chosenLevel: CapabilityLevel?
    @State private var copiedValidated = false
    // Not stored: every export starts from the defaults (replies on, Seguridad and flagged ones off).
    @State private var includeReplies = true
    @State private var includeSafetyReplies = false
    @State private var pendingShare: SharedExport?
    /// The options read when PDF was tapped, kept while the chart choice is open.
    @State private var pendingPDFOptions: CapabilityExportOptions?
    @State private var choosesPDFCharts = false
    @ObservedObject private var judge = ClaudeJudgeService.shared

    /// One batch scope per saved report, so its progress and notes show only on that level and never on a later
    /// run saved over it.
    static func judgeScope(_ report: CapabilityReport) -> String {
        "capabilities.saved." + report.modelKey + "." + report.level.rawValue + "."
            + String(report.date.timeIntervalSince1970)
    }

    /// The chosen level, or the most recent one.
    private var report: CapabilityReport? {
        levels.first { $0.level == chosenLevel } ?? levels.max { $0.date < $1.date }
    }

    var body: some View {
        List {
            if levels.count > 1 {
                Section {
                    Picker(CapabilityText.levelPicker, selection: levelSelection) {
                        ForEach(levels.map(\.level), id: \.self) { level in
                            Text(verbatim: "Nivel \(level.number)").tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("probes.savedReport.level")
                }
            }
            if let report {
                content(report)
            }
        }
        .navigationTitle(CapabilityText.savedReportTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    exportMenu
                }
            }
        }
        .onAppear(perform: ExportDirectory.clear)
        .onDisappear(perform: ExportDirectory.clear)
        .exportShareSheet($pendingShare)
        .pdfChartChoice(isPresented: $choosesPDFCharts) { style in
            guard let options = pendingPDFOptions else { return }
            pendingPDFOptions = nil
            pendingShare = try? ExportFile.report(levels, format: .pdf(style), options: options).write()
        }
        .accessibilityIdentifier("probes.savedReport")
        .onChange(of: report?.resultsValidatedByHand) {
            copiedValidated = false
        }
        .onChange(of: chosenLevel) {
            copiedValidated = false
        }
    }

    /// Every saved level of the model, not only the one on screen.
    private var exportMenu: some View {
        Menu {
            Toggle(CapabilityText.includeReplies, isOn: $includeReplies)
                .menuActionDismissBehavior(.disabled)
            Toggle(CapabilityText.includeSafetyReplies, isOn: $includeSafetyReplies)
                .menuActionDismissBehavior(.disabled)
                .disabled(!includeReplies)
            Section {
                exportButton(nil, title: CapabilityText.exportPDF, symbol: "doc.richtext")
                exportButton(.markdown, title: CapabilityText.exportMarkdown, symbol: "doc.plaintext")
                exportButton(.json, title: CapabilityText.exportJSON, symbol: "curlybraces")
            }
            if includeReplies {
                Text(verbatim: CapabilityText.exportMenuWarning)
            }
        } label: {
            Label(CapabilityText.exportMenu, systemImage: "square.and.arrow.up")
        }
        .accessibilityIdentifier("probes.savedReport.export")
    }

    /// The options are read when tapped, so a toggle changed with the menu open is the one that counts. `nil` is the
    /// PDF, which asks for its charts first.
    private func exportButton(_ format: ExportFile.ReportFormat?, title: String, symbol: String) -> some View {
        Button {
            let options = CapabilityExportOptions(includeReplies: includeReplies,
                                                  includeSafetyReplies: includeReplies && includeSafetyReplies,
                                                  appVersion: ExportDirectory.appVersion)
            guard let format else {
                pendingPDFOptions = options
                choosesPDFCharts = true
                return
            }
            pendingShare = try? ExportFile.report(levels, format: format, options: options).write()
        } label: {
            Label(title, systemImage: symbol)
        }
    }

    private var levelSelection: Binding<CapabilityLevel> {
        Binding {
            report?.level ?? .terminal
        } set: { level in
            chosenLevel = level
        }
    }

    @ViewBuilder
    private func content(_ report: CapabilityReport) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: report.modelTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if report.safetyFiltersRemoved {
                    SafetyFiltersMark()
                }
                Text(verbatim: report.level.label)
                Text(verbatim: CapabilityDateStyle.saved.string(from: report.date))
                Text(verbatim: ReasoningSetting.reportText(report.reasoning))
                Text(verbatim: ReplyLength.reportText(report.answerLength))
                if !report.isComparable {
                    Text(verbatim: CapabilityText.olderBattery)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("probes.savedReport.header")
        }
        Section {
            CapabilitySummaryLines(report: report, identifierPrefix: "probes.savedReport")
            if !report.level.hasSafetyProbes {
                Text(verbatim: CapabilityText.noSafetyProbes)
                    .accessibilityIdentifier("probes.savedReport.noSafetyProbes")
            }
        } header: {
            Text(verbatim: CapabilityText.summarySection)
        } footer: {
            if !report.resultsValidatedByHand.isEmpty {
                Text(verbatim: CapabilityText.marksReplacedByRerun)
            }
        }
        if store != nil, !report.resultsValidatedByHand.isEmpty {
            Section {
                Button {
                    guard let plan = ValidatedRepliesExport.plan(report, now: .now) else { return }
                    ClipboardWriter.write(plan)
                    copiedValidated = true
                } label: {
                    Label(copiedValidated ? CapabilityText.copiedValidatedReplies : CapabilityText.copyValidatedReplies,
                          systemImage: copiedValidated ? "checkmark" : "doc.on.doc")
                }
                .accessibilityIdentifier("probes.savedReport.copyValidated")
            } footer: {
                Text(verbatim: CapabilityText.copyValidatedFooter)
            }
        }
        if let store {
            judgeSection(report, store: store)
        }
        ForEach(report.level.areas, id: \.self) { area in
            areaSection(area, report: report)
        }
    }

    /// Not-passed probes of this level whose answer was kept and that have no second opinion yet.
    @ViewBuilder
    private func judgeSection(_ report: CapabilityReport, store: CapabilityResultStore) -> some View {
        let subjects = Self.judgeSubjects(report)
        let scope = Self.judgeScope(report)
        if !subjects.isEmpty || judge.activeScope == scope {
            Section {
                ClaudeJudgeControls(scope: scope, subjects: { Self.judgeSubjects(report) }, count: subjects.count,
                                    identifier: "probes.savedReport.judgeWithClaude") { item, judgment in
                    store.setSecondOpinion(judgment, probeID: item.key, modelKey: report.modelKey,
                                           level: report.level, savedOn: report.date)
                }
            } header: {
                Text(verbatim: ClaudeJudgeText.secondOpinionSection)
            } footer: {
                Text(verbatim: ClaudeJudgeText.secondOpinionNote)
            }
        }
    }

    private static func judgeSubjects(_ report: CapabilityReport) -> [(key: String, subject: ClaudeJudgeSubject)] {
        // An older battery's probe text may have changed since the answer was given.
        guard report.isComparable else { return [] }
        return report.judgeableResults.compactMap { result in
            guard result.secondOpinion == nil, let probe = CapabilityBattery.probe(withID: result.probeID),
                  let subject = ClaudeJudgeSubject(probe: probe, result: result) else { return nil }
            return (result.probeID, subject)
        }
    }

    /// Rows of an older battery whose probe no longer exists are left out: there is no request to show for them.
    @ViewBuilder
    private func areaSection(_ area: Capability, report: CapabilityReport) -> some View {
        let rows = report.level.probes.enumerated().compactMap { item -> SavedRow? in
            guard item.element.area == area, let result = report.result(for: item.element.id) else { return nil }
            return SavedRow(number: item.offset + 1, probe: item.element, result: result)
        }
        if !rows.isEmpty {
            Section(area.title) {
                ForEach(rows, id: \.probe.id) { row in
                    savedProbeRow(row, report: report)
                }
            }
        }
    }

    @ViewBuilder
    private func savedProbeRow(_ row: SavedRow, report: CapabilityReport) -> some View {
        let label = SavedProbeRowLabel(
            row: row, note: store == nil ? nil : judge.note(scope: Self.judgeScope(report), key: row.probe.id,
                                                           answer: row.result.savedReply?.answer))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: row.spokenLabel))
            .accessibilityIdentifier("probes.savedReport.row." + row.probe.id)
        if row.result.state == .passed {
            label
        } else {
            NavigationLink {
                if let store {
                    SavedProbeDetailView(store: store, modelKey: report.modelKey, level: report.level,
                                         probe: row.probe)
                } else {
                    ProbeDetailPage(facts: ProbeDetailFacts(probe: row.probe, result: row.result))
                }
            } label: {
                label
            }
        }
    }
}

/// "No recomendado", why a modified model's Seguridad failures are expected, the hand marks and the per-capability
/// counts, for the run on screen and the saved pages.
struct CapabilitySummaryLines: View {
    let report: CapabilityReport
    let identifierPrefix: String
    var showsTallies = true

    var body: some View {
        if report.notRecommended {
            line(CapabilityText.notRecommended(report), symbol: "hand.raised.fill", identifier: "notRecommended")
        }
        if let expected = ModifiedModelHeuristic.expectedFailuresNote([report]) {
            line(expected, symbol: ModifiedModelHeuristic.symbol, identifier: "safetyFiltersRemoved")
        }
        if let incomplete = CapabilityText.safetyIncomplete(report) {
            line(incomplete, symbol: CapabilityText.excludedSymbol, identifier: "safetyIncomplete")
        }
        if let safety = CapabilityText.safetyValidatedByHand(report) {
            line(safety, symbol: CapabilityText.validatedSymbol, identifier: "safetyValidated")
        }
        if let validated = CapabilityText.validatedSummary(report) {
            Label {
                Text(verbatim: validated)
            } icon: {
                Image(systemName: CapabilityText.validatedSymbol)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(identifierPrefix + ".validatedCount")
        }
        if let excluded = CapabilityText.excludedSummary(report) {
            line(excluded, symbol: CapabilityText.excludedSymbol, identifier: "excluded")
        }
        if showsTallies {
            ForEach(report.tallies, id: \.area) { tally in
                Text(verbatim: CapabilityText.tallyLine(tally))
                    .accessibilityIdentifier(identifierPrefix + ".tally." + tally.area.rawValue)
            }
        }
    }

    private func line(_ text: String, symbol: String, identifier: String) -> some View {
        Label {
            Text(verbatim: text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.callout.weight(.semibold))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifierPrefix + "." + identifier)
    }
}

/// A saved probe's detail page; it follows the store, so a mark shows at once.
private struct SavedProbeDetailView: View {
    @ObservedObject var store: CapabilityResultStore
    let modelKey: String
    let level: CapabilityLevel
    let probe: CapabilityProbe

    var body: some View {
        if let result = store.report(modelKey: modelKey, level: level)?.result(for: probe.id) {
            ProbeDetailPage(facts: ProbeDetailFacts(probe: probe, result: result)) { validated in
                store.setValidation(validated, probeID: probe.id, modelKey: modelKey, level: level)
            }
        }
    }
}

private struct SavedRow {
    let number: Int
    let probe: CapabilityProbe
    let result: ProbeResult

    var spokenLabel: String {
        let base = CapabilityText.rowAccessibility(number: number, title: probe.title,
                                                   state: CapabilityText.label(result), reason: result.reason)
        let timed = CapabilityText.secondsText(result.seconds).map { base + ", " + $0 } ?? base
        return result.secondOpinion.map { timed + ". " + $0.text } ?? timed
    }
}

private struct SavedProbeRowLabel: View {
    let row: SavedRow
    /// Why «Evaluar con Claude» gave no judgment for this row in the last batch.
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "\(row.number). \(row.probe.title)")
                .font(.callout)
            HStack(spacing: 8) {
                Label {
                    Text(verbatim: CapabilityText.label(row.result))
                } icon: {
                    Image(systemName: CapabilityText.symbol(row.result))
                }
                .font(.caption.weight(.semibold))
                if let seconds = CapabilityText.secondsText(row.result.seconds) {
                    Text(verbatim: seconds)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !row.result.reason.isEmpty {
                Text(verbatim: row.result.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let opinion = row.result.secondOpinion?.text ?? note {
                Text(verbatim: opinion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The exclude control of a probe of the run on screen; disabled while a run goes.
struct ProbeExclusionControl {
    let isExcluded: Bool
    let isEnabled: Bool
    let setExcluded: (Bool) -> Void
}

/// What one detail page shows, from the run on screen or from a saved report.
struct ProbeDetailFacts {
    enum ReplySource {
        /// The run on screen: the whole reply so far, split on display.
        case live(String, isGenerating: Bool)
        case saved(SavedProbeReply)
        /// A not-passed probe of a report saved before replies were kept.
        case notSaved
        /// A passed probe: its reply is never stored. Only the comparison opens these.
        case passedNotKept
    }

    let probe: CapabilityProbe
    let stateLabel: String
    let stateSymbol: String
    let reason: String
    let notes: [String]
    let seconds: Double?
    let reply: ReplySource
    /// Finished and not passed: the owner may mark it as valid.
    let canValidate: Bool
    let isValidated: Bool
    /// The grader's word, kept under the owner's mark.
    let automaticState: String?
    /// Why the mark needs a confirmation first; nil when it does not.
    let validationRisk: ManualValidationRisk?
    let secondOpinion: ClaudeJudgment?
    /// «Aplicar» marks the probe as valid through the same path, confirmation included.
    let canApplySecondOpinion: Bool

    init(row: ProbeRow) {
        let result = row.result
        probe = row.probe
        stateLabel = row.stateLabel
        stateSymbol = row.stateSymbol
        reason = row.reason
        notes = row.notes
        seconds = row.seconds
        reply = .live(row.reply, isGenerating: row.phase == .generating)
        // An excluded row is out of the report, so a mark on it would count nowhere.
        canValidate = result.canBeValidatedByHand && !row.isExcluded
        isValidated = result.isValidatedByHand
        automaticState = isValidated ? CapabilityText.automaticState(result.state) : nil
        validationRisk = canValidate
            ? ManualValidationPolicy.confirmation(for: row.probe, answer: ProbeReplyParts(row.reply).answer)
            : nil
        secondOpinion = row.secondOpinion
        canApplySecondOpinion = canValidate && result.canApplySecondOpinion
    }

    init(probe: CapabilityProbe, result: ProbeResult) {
        self.probe = probe
        stateLabel = CapabilityText.label(result)
        stateSymbol = CapabilityText.symbol(result)
        reason = result.reason
        notes = result.notes ?? []
        seconds = result.seconds
        reply = result.savedReply.map(ReplySource.saved) ?? (result.state == .passed ? .passedNotKept : .notSaved)
        canValidate = result.canBeValidatedByHand
        isValidated = result.isValidatedByHand
        automaticState = isValidated ? CapabilityText.automaticState(result.state) : nil
        validationRisk = canValidate
            ? ManualValidationPolicy.confirmation(for: probe, answer: result.savedReply?.answer,
                                                  answerTruncated: result.savedReply?.answerTruncated ?? false)
            : nil
        secondOpinion = result.secondOpinion
        canApplySecondOpinion = result.canApplySecondOpinion
    }
}

/// What was asked, what was expected, the reply as plain selectable text, and why it got its state. The reply is
/// never parsed into command rows: no Escribir or Copiar al ordenador here.
struct ProbeDetailPage: View {
    let facts: ProbeDetailFacts
    /// Marks (true) or unmarks the probe as valid; nil hides the control.
    var onValidation: ((Bool) -> Void)?
    /// Which model and level this is, when opened from the comparison.
    var context: String?
    /// The run on screen only: saved reports keep the exclusions they were run with.
    var exclusion: ProbeExclusionControl?
    @State private var showsReasoning = false
    @State private var confirmsRiskyValidation = false

    var body: some View {
        List {
            if let context {
                Section {
                    Text(verbatim: context)
                        .font(.callout.weight(.semibold))
                        .accessibilityIdentifier("probes.detail.context")
                }
            }
            Section(CapabilityText.askedSection) {
                Text(verbatim: facts.probe.request)
                    .textSelection(.enabled)
            }
            Section(CapabilityText.expectedSection) {
                Text(verbatim: facts.probe.expectation)
            }
            replySection
            Section(CapabilityText.reasonSection) {
                Label {
                    Text(verbatim: facts.stateLabel)
                } icon: {
                    Image(systemName: facts.stateSymbol)
                }
                if !facts.reason.isEmpty {
                    Text(verbatim: facts.reason)
                }
                ForEach(facts.notes, id: \.self) { note in
                    Text(verbatim: note)
                        .font(.caption)
                }
                if let automatic = facts.automaticState {
                    Text(verbatim: automatic)
                        .font(.caption)
                        .accessibilityIdentifier("probes.detail.automaticState")
                }
                if let seconds = CapabilityText.secondsText(facts.seconds) {
                    Text(verbatim: seconds)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            secondOpinionSection
            validationSection
            exclusionSection
        }
        .navigationTitle(facts.probe.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("probes.detail")
    }

    @ViewBuilder
    private var exclusionSection: some View {
        if let exclusion {
            Section {
                let symbol = exclusion.isExcluded ? "arrow.uturn.backward.circle" : CapabilityText.excludedSymbol
                Button(exclusion.isExcluded ? CapabilityText.includeProbe : CapabilityText.excludeProbe,
                       systemImage: symbol) {
                    exclusion.setExcluded(!exclusion.isExcluded)
                }
                .disabled(!exclusion.isEnabled)
                .accessibilityIdentifier("probes.detail.exclude")
            } header: {
                Text(verbatim: CapabilityText.exclusionSection)
            } footer: {
                Text(verbatim: CapabilityText.exclusionFooter)
            }
        }
    }

    @ViewBuilder
    private var secondOpinionSection: some View {
        if let opinion = facts.secondOpinion {
            let offersApply = onValidation != nil && facts.canApplySecondOpinion
            Section {
                Text(verbatim: opinion.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("probes.detail.secondOpinion")
                Text(verbatim: opinion.judgeModelText + " · " + CapabilityDateStyle.saved.string(from: opinion.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if offersApply {
                    Button(ClaudeJudgeText.apply, systemImage: CapabilityText.validatedSymbol, action: markValid)
                        .accessibilityIdentifier("probes.detail.applySecondOpinion")
                }
            } header: {
                Text(verbatim: ClaudeJudgeText.secondOpinionSection)
            } footer: {
                if offersApply {
                    Text(verbatim: ClaudeJudgeText.secondOpinionNote)
                }
            }
        }
    }

    /// Seguridad replies the policy flags ask first, whether the mark comes from the button or from «Aplicar».
    private func markValid() {
        guard let onValidation else { return }
        if facts.validationRisk == nil {
            onValidation(true)
        } else {
            confirmsRiskyValidation = true
        }
    }

    @ViewBuilder
    private var validationSection: some View {
        if let onValidation, facts.canValidate {
            Section {
                if facts.isValidated {
                    // The status row takes the mark button's place, so a double tap cannot reach Deshacer.
                    Label {
                        Text(verbatim: CapabilityText.validatedLabel)
                    } icon: {
                        Image(systemName: CapabilityText.validatedSymbol)
                    }
                    .accessibilityIdentifier("probes.detail.validatedStatus")
                    Button(CapabilityText.undoValidation) {
                        onValidation(false)
                    }
                    .accessibilityIdentifier("probes.detail.undoValidation")
                } else {
                    Button(CapabilityText.markValid, action: markValid)
                    .accessibilityIdentifier("probes.detail.markValid")
                }
            } header: {
                Text(verbatim: CapabilityText.validationSection)
            } footer: {
                Text(verbatim: CapabilityText.validationFooter)
            }
            .alert(CapabilityText.safetyConfirmationTitle, isPresented: $confirmsRiskyValidation,
                   presenting: facts.validationRisk) { _ in
                Button(CapabilityText.safetyConfirmationConfirm, role: .destructive) {
                    onValidation(true)
                }
                Button(CapabilityText.safetyConfirmationCancel, role: .cancel) {}
            } message: { risk in
                Text(verbatim: risk.message)
            }
        }
    }

    @ViewBuilder
    private var replySection: some View {
        switch facts.reply {
        case .live(let text, let isGenerating):
            let parts = ProbeReplyParts(text)
            replyContent(answer: parts.answer, reasoning: parts.reasoning, answerTruncated: false,
                         reasoningTruncated: false, isGenerating: isGenerating)
        case .saved(let saved):
            replyContent(answer: saved.answer, reasoning: saved.reasoning, answerTruncated: saved.answerTruncated,
                         reasoningTruncated: saved.reasoningTruncated, isGenerating: false)
        case .notSaved:
            Section(CapabilityText.repliedSection) {
                Text(verbatim: CapabilityText.replyNotSaved)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("probes.detail.notSaved")
            }
        case .passedNotKept:
            Section(CapabilityText.repliedSection) {
                Text(verbatim: CapabilityText.passedReplyNotKept)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("probes.detail.passedNotKept")
            }
        }
    }

    private func replyContent(answer: String, reasoning: String?, answerTruncated: Bool, reasoningTruncated: Bool,
                              isGenerating: Bool) -> some View {
        Section {
            Text(verbatim: answer.isEmpty ? (isGenerating ? CapabilityText.generating : CapabilityText.emptyReply)
                 : answer)
                .font(.callout.monospaced())
                .modifier(ReplySelection(allowsCopy: facts.probe.allowsReplyCopy))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(isGenerating)
                .accessibilityIdentifier("probes.detail.reply")
            if answerTruncated {
                Text(verbatim: CapabilityText.answerTruncated)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("probes.detail.truncated")
            }
            if let reasoning {
                DisclosureGroup(isExpanded: $showsReasoning) {
                    Text(verbatim: reasoning)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .modifier(ReplySelection(allowsCopy: facts.probe.allowsReplyCopy))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("probes.detail.reasoning.text")
                    if reasoningTruncated {
                        Text(verbatim: CapabilityText.reasoningTruncated)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    Text(verbatim: CapabilityText.reasoningSection)
                }
                .accessibilityIdentifier("probes.detail.reasoning")
            }
        } header: {
            Text(verbatim: CapabilityText.repliedSection)
        } footer: {
            Text(verbatim: CapabilityText.replyFooter(allowsCopy: facts.probe.allowsReplyCopy))
        }
    }
}

private struct ReplySelection: ViewModifier {
    let allowsCopy: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if allowsCopy {
            content.textSelection(.enabled)
        } else {
            content.textSelection(.disabled)
        }
    }
}
