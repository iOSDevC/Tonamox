import SwiftUI
import TonamoxCore
import TerminalBridgeKit
import TonamoxUI

/// "Selecciona un modelo": what is on disk plus Apple's model, then the cloud and local-network engines, then search,
/// downloads and shared storage. Downloads start only from the Hugging Face search, on a tap; a remote engine is
/// used only after a tap here.
struct ModelPickerView: View {
    @ObservedObject var chat: TerminalChatViewModel
    @ObservedObject var archive: CapabilityResultStore
    /// Pushes "Pruebas de capacidades" on the root stack; a page inside this sheet would close with it.
    var onTestCapabilities: () -> Void = {}
    /// Root sheets, so a second sheet never stacks on this one.
    var onOpenSettings: () -> Void = {}
    var onOpenSharedStorage: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var cloudRequest: RemoteChoiceRow?
    @State private var cloudModelPreset: ProviderPresetID?
    @State private var providersFormChoice: ProviderFormChoice?
    @State private var showsFinder = false
    /// Model key of the saved reports on screen.
    @State private var openedReportKey: String?
    @AppStorage(ReasoningSetting.defaultsKey) private var reasoning: ReasoningSetting = .medium
    @AppStorage(ReplyLength.defaultsKey) private var length: ReplyLength = .short
    @AppStorage(MeasuredDecodeArchive.defaultsKey) private var measuredDecodes: Data?

    var body: some View {
        NavigationStack {
            List {
                let local = ModelGroup.bucket(chat.catalog.onDevice + chat.catalog.ggufFiles
                    + chat.catalog.debugChoices) { $0.source }
                let remote = ModelGroup.bucket(chat.catalog.remote) { $0.choice.source }
                ForEach(ModelGroup.allCases, id: \.self) { group in
                    section(group, local: local[group] ?? [], remote: remote[group] ?? [])
                }
                replySection
                moreSection
                testSection
            }
            .navigationTitle(ModelPickerText.sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                        .accessibilityIdentifier("model.done")
                }
            }
            .navigationDestination(item: $cloudModelPreset) { id in
                CloudModelForm(preset: ProviderPreset.preset(id), onChange: chat.refreshCatalog)
            }
            .navigationDestination(item: $providersFormChoice) { initial in
                ProvidersForm(initial: initial, onChange: chat.refreshCatalog)
            }
            .navigationDestination(isPresented: $showsFinder) {
                ChatModelFinder()
                    .environment(\.hfRepoCaution, SafetyFiltersMark.repoCaution)
            }
            // Read-only, so it stays inside the sheet, unlike the battery page.
            .navigationDestination(item: $openedReportKey) { modelKey in
                SavedReportView(levels: archive.levels(of: modelKey))
            }
            .confirmationDialog(
                "¿Usar \(cloudRequest?.choice.title ?? "") en lugar de un modelo local?",
                isPresented: Binding(get: { cloudRequest != nil }, set: { if !$0 { cloudRequest = nil } }),
                titleVisibility: .visible,
                presenting: cloudRequest
            ) { row in
                Button("Permitir y usar") { allowCloud(for: row) }
                Button("Cancelar", role: .cancel) {}
            } message: { _ in
                Text("Tus mensajes saldrán del iPhone hacia ese proveedor y pueden tener coste. "
                    + "Cada mensaje seguirá pidiendo tu aprobación antes de enviarse. "
                    + "El permiso se guarda; puedes quitarlo en «Claves API y envío remoto».")
            }
        }
        .onAppear(perform: chat.refreshCatalog)
        .onChange(of: ModelDownloadCenter.shared.revision) { chat.refreshCatalog() }
    }

    // MARK: Sections

    /// Every row goes in the group of its source, so a row with an unexpected source still shows somewhere.
    @ViewBuilder
    private func section(_ group: ModelGroup, local: [ModelChoice], remote: [RemoteChoiceRow]) -> some View {
        if group == .onDevice || !local.isEmpty || !remote.isEmpty {
            Section {
                if group == .onDevice && local.isEmpty {
                    emptyState
                }
                ForEach(local) { choice in
                    choiceRow(choice)
                }
                if group == .onDevice {
                    appleRow
                }
                ForEach(remote) { row in
                    remoteRow(row)
                }
            } header: {
                Text(verbatim: group.title)
            } footer: {
                sectionFooter(group)
            }
        }
    }

    @ViewBuilder
    private func sectionFooter(_ group: ModelGroup) -> some View {
        switch group {
        case .onDevice:
            if chat.isRunningCapabilityTests {
                Text(verbatim: ModelPickerText.runningTestsFooter)
                    .accessibilityIdentifier("model.runningTestsFooter")
            }
        case .cloud:
            Text(verbatim: ModelPickerText.remoteFooter)
        case .network, .debug:
            EmptyView()
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: ModelPickerText.emptyOnDevice)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("model.empty")
            Button {
                showsFinder = true
            } label: {
                Label(ModelPickerText.findModels, systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            // A download mid-run would evict or swap weights under the battery.
            .disabled(chat.isRunningCapabilityTests)
            .accessibilityIdentifier("model.findModels")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var appleRow: some View {
        switch chat.catalog.apple {
        case .available:
            choiceRow(LocalModelCatalog.appleChoice)
        case .unavailable(let short, let full):
            ModelRowLabel(title: LocalModelCatalog.appleChoice.title, detail: ModelPickerText.appleDetail,
                          note: short, accessory: .lock)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: ModelRowLabel.spokenLabel(
                    title: LocalModelCatalog.appleChoice.title, detail: ModelPickerText.appleDetail,
                    placement: .device, lockReason: short)))
                .accessibilityHint(Text(verbatim: full))
                .accessibilityIdentifier("model.choice.apple")
        }
    }

    /// Read when the next reply starts; a capability run keeps the values it started with.
    private var replySection: some View {
        Section {
            Picker(selection: $length) {
                ForEach(ReplyLength.allCases, id: \.self) { option in
                    Text(verbatim: option.title).tag(option)
                }
            } label: {
                Text(verbatim: ReplyLength.sectionTitle)
            }
            .disabled(chat.isRunningCapabilityTests)
            .accessibilityIdentifier("model.replyLength")
            Picker(selection: $reasoning) {
                ForEach(ReasoningSetting.allCases, id: \.self) { setting in
                    Text(verbatim: setting.title).tag(setting)
                }
            } label: {
                Text(verbatim: ReasoningSetting.sectionTitle)
            }
            .disabled(chat.isRunningCapabilityTests)
            .accessibilityIdentifier("model.reasoning")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let cost = costLine {
                    Text(verbatim: cost)
                        .accessibilityIdentifier("model.replyCost")
                }
                Text(verbatim: ReplyLength.footer)
                Text(verbatim: ReasoningSetting.footer)
            }
        }
    }

    /// Only a model this device has decoded with gets a time; nothing is guessed for the others.
    private var costLine: String? {
        guard let id = chat.selectedChoiceID else { return nil }
        return MeasuredDecodeArchive.decode(measuredDecodes)[id]?.costLine(length: length, reasoning: reasoning)
    }

    /// Search, downloads and shared storage, each one tap from the sheet.
    private var moreSection: some View {
        Section {
            NavigationLink {
                ChatModelFinder()
                    .environment(\.hfRepoCaution, SafetyFiltersMark.repoCaution)
            } label: {
                Label(ModelPickerText.searchHuggingFace, systemImage: "magnifyingglass")
            }
            // A download, delete or "Try it" mid-run would evict, load or swap weights under the battery.
            .disabled(chat.isRunningCapabilityTests)
            .accessibilityIdentifier("model.huggingFace")
            NavigationLink {
                DownloadedModelsList()
                    .onDisappear(perform: chat.refreshCatalog)
            } label: {
                Label(ModelPickerText.downloadedModels, systemImage: "internaldrive")
            }
            .disabled(chat.isRunningCapabilityTests)
            .accessibilityIdentifier("model.downloads")
            Button {
                onOpenSharedStorage()
            } label: {
                Label {
                    // Explicit colour: inside a List button the title would take the tint, unlike its neighbours.
                    Text(verbatim: ModelPickerText.sharedStorage).foregroundStyle(Color.primary)
                } icon: {
                    Image(systemName: "externaldrive.connected.to.line.below")
                }
            }
            .disabled(chat.isRunningCapabilityTests)
            .accessibilityIdentifier("model.sharedStorage")
        } header: {
            Text(verbatim: ModelPickerText.moreModels)
        } footer: {
            Text(verbatim: ModelPickerText.filesFooter)
        }
    }

    private var testSection: some View {
        Section {
            Button {
                dismiss()
                onTestCapabilities()
            } label: {
                ModelRowLabel(title: ModelPickerText.testThisModel,
                              detail: chat.selectedChoice?.title ?? ModelChipText.noSelectionName,
                              symbol: "checklist", accessory: .chevron)
            }
            .accessibilityIdentifier("model.capabilityTests")
        }
    }

    // MARK: Rows

    private func remoteRow(_ row: RemoteChoiceRow) -> some View {
        RemoteModelRow(
            row: row,
            isSelected: row.choice.id == chat.selectedChoiceID,
            isRunningCapabilityTests: chat.isRunningCapabilityTests,
            onTap: { tap(row) },
            onDetail: { openDetail(for: row) }
        )
    }

    @ViewBuilder
    private func choiceRow(_ choice: ModelChoice) -> some View {
        let modelKey = CapabilityResultStore.modelKey(for: choice)
        let primary = modelKey.flatMap { CapabilityReportArchive.primaryReport(of: $0, in: archive.reports) }
        if let modelKey, let primary {
            HStack(spacing: 4) {
                selectButton(choice, summary: CapabilitySummary(primary: primary, levels: archive.levels(of: modelKey)))
                    .buttonStyle(.borderless)
                    .tint(.primary)
                Button {
                    openedReportKey = modelKey
                } label: {
                    Image(systemName: "list.bullet.clipboard")
                        .imageScale(.large)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(verbatim: CapabilityText.openSavedReportLabel(model: choice.title)))
                .accessibilityIdentifier("model.capabilityReport." + choice.id)
            }
        } else {
            selectButton(choice, summary: nil)
        }
    }

    private func selectButton(_ choice: ModelChoice, summary: CapabilitySummary?) -> some View {
        let isSelected = choice.id == chat.selectedChoiceID
        return Button {
            chat.selectedChoiceID = choice.id
            dismiss()
        } label: {
            ModelRowLabel(title: choice.title, detail: choice.detail, summary: summary,
                          safetyFiltersRemoved: choice.safetyFiltersRemoved,
                          accessory: isSelected ? .checkmark : .none)
        }
        // The battery keeps its engine; switching models mid-run would load a second set of weights.
        .disabled(chat.isRunningCapabilityTests)
        .accessibilityLabel(Text(verbatim: ModelRowLabel.spokenLabel(
            title: choice.title, detail: choice.detail, placement: choice.source.placement, summary: summary,
            safetyFiltersRemoved: choice.safetyFiltersRemoved)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("model.choice." + choice.id)
    }

    private func tap(_ row: RemoteChoiceRow) {
        if let lock = row.lock {
            resolve(row, lock: lock)
        } else {
            chat.selectedChoiceID = row.choice.id
            dismiss()
        }
    }

    private func openDetail(for row: RemoteChoiceRow) {
        guard case .remote(let kind) = row.choice.kind else { return }
        switch kind {
        case .compatibleServer: providersFormChoice = .other
        case .preset(let id): cloudModelPreset = id
        }
    }

    /// A locked remote row leads to what unlocks it instead of sitting there greyed out.
    private func resolve(_ row: RemoteChoiceRow, lock: RemoteLock) {
        let preset: ProviderPresetID? = if case .remote(.preset(let id)) = row.choice.kind { id } else { nil }
        switch lock {
        case .cloudNotAllowed:
            cloudRequest = row
        case .serverNotConfigured:
            providersFormChoice = .other
        case .missingKey:
            providersFormChoice = preset.map { .preset($0) } ?? .other
        case .modelNotChosen:
            cloudModelPreset = preset
        case .remoteOff:
            onOpenSettings()
        }
    }

    /// The permission is kept even mid-run; only the switch waits, since the battery keeps its engine.
    private func allowCloud(for row: RemoteChoiceRow) {
        HybridSettings.shared.policy.allowCloud = true
        chat.refreshCatalog()
        guard !chat.isRunningCapabilityTests else { return }
        chat.selectedChoiceID = row.choice.id
        dismiss()
    }
}
