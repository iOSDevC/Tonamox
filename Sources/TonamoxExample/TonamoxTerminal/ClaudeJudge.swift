import Combine
import Foundation
import SwiftUI
import TerminalBridgeKit
import TonamoxCore

/// One reply of a batch. `key` names it for the entry point that built it: a probe id or a Test Mode question.
nonisolated struct ClaudeJudgeItem: Sendable {
    let key: String
    let subject: ClaudeJudgeSubject
    let request: ClaudeJudgeRequest
}

/// What the confirmation shows, and exactly what «Enviar» sends: the first `items` of `totalCount` pending when the
/// session cap leaves room for only part of them.
struct ClaudeJudgeBatch {
    let scope: String
    let model: ClaudeJudgeModel
    let items: [ClaudeJudgeItem]
    let totalCount: Int
    let estimate: ClaudeJudgeEstimate
}

/// Why a request gave no judgment, and the answer it was about: a row shows it only while it still holds that answer.
struct ClaudeJudgeNote: Equatable {
    let line: String
    let answer: String
}

/// Why a batch is not sent, in the words the alert shows.
struct ClaudeJudgeRefusal: Error {
    let message: String
}

/// Sends «Evaluar con Claude» batches, only after the owner confirmed one: one batch at a time in the whole app,
/// at most ``ClaudeJudgeRequest/maxConcurrent`` requests in flight, each attempt recorded in the shared cost ledger
/// at the kit's dated prices.
final class ClaudeJudgeService: ObservableObject {
    static let shared = ClaudeJudgeService()
    static let providerID = ProviderPreset.anthropic.keychainAccount

    /// The entry point whose batch is running; nil when none is.
    @Published private(set) var activeScope: String?
    @Published private(set) var finishedCount = 0
    @Published private(set) var totalCount = 0
    /// Why a request gave no judgment, by scope then key; a new batch of the scope clears its lines.
    @Published private(set) var notes: [String: [String: ClaudeJudgeNote]] = [:]
    /// A refusal from the send-time check, by scope. Shown inline: an alert asked for while the confirmation is
    /// still dismissing is often dropped.
    @Published private(set) var sendRefusals: [String: String] = [:]

    private var work: Task<Void, Never>?
    private var deliver: ((ClaudeJudgeItem, ClaudeJudgment) -> Void)?

    nonisolated private static let session = URLSession(configuration: .ephemeral)

    private init() {}

    var isRunning: Bool { activeScope != nil }

    func note(scope: String, key: String, answer: String?) -> String? {
        guard let note = notes[scope]?[key], note.answer == answer else { return nil }
        return note.line
    }

    func clearSendRefusal(scope: String) {
        if sendRefusals[scope] != nil { sendRefusals[scope] = nil }
    }

    /// A rerun replaces the answers the lines were about.
    func clearNotes(scope: String) {
        if notes[scope] != nil, activeScope != scope { notes[scope] = nil }
    }

    /// Builds the requests and checks mode, key, cloud permission and session cap before anything is shown or sent.
    /// When the cap leaves room for only some of them, the batch is the largest prefix that fits.
    func prepare(
        scope: String,
        subjects: [(key: String, subject: ClaudeJudgeSubject)],
        model: ClaudeJudgeModel
    ) -> Result<ClaudeJudgeBatch, ClaudeJudgeRefusal> {
        clearSendRefusal(scope: scope)
        let all = subjects.map { entry in
            ClaudeJudgeItem(key: entry.key, subject: entry.subject,
                            request: ClaudeJudgeRequest(subject: entry.subject, model: model))
        }
        let full = ClaudeJudgeEstimate(requests: all.map(\.request))
        if let message = refusal(for: full, checksCap: false) { return .failure(ClaudeJudgeRefusal(message: message)) }
        let policy = HybridSettings.shared.policy
        let spent = CostLedger.shared.sessionCostUSD
        let fitting = ClaudeJudgeEstimate.affordableCount(of: all.map(\.request),
                                                          capUSD: policy.costCapUSDPerSession, spentUSD: spent)
        guard fitting > 0 || all.isEmpty else {
            return .failure(ClaudeJudgeRefusal(
                message: ClaudeJudgeText.capExceeded(full, capUSD: policy.costCapUSDPerSession, spentUSD: spent)))
        }
        let items = Array(all.prefix(fitting))
        return .success(ClaudeJudgeBatch(scope: scope, model: model, items: items, totalCount: all.count,
                                         estimate: ClaudeJudgeEstimate(requests: items.map(\.request))))
    }

    /// Checks again at send time: the mode, the permission, the key or the session's spend may have changed while
    /// the confirmation was open. A refusal goes to ``sendRefusals``.
    func start(_ batch: ClaudeJudgeBatch, deliver: @escaping (ClaudeJudgeItem, ClaudeJudgment) -> Void) {
        guard !isRunning, !batch.items.isEmpty else { return }
        if let message = refusal(for: batch.estimate) {
            sendRefusals[batch.scope] = message
            return
        }
        guard let apiKey = KeychainStore.read(for: Self.providerID) else {
            sendRefusals[batch.scope] = ClaudeJudgeText.missingKey
            return
        }
        clearSendRefusal(scope: batch.scope)
        activeScope = batch.scope
        finishedCount = 0
        totalCount = batch.items.count
        notes[batch.scope] = [:]
        self.deliver = deliver
        work = Task { await run(batch.items, scope: batch.scope, apiKey: apiKey) }
    }

    func cancel() {
        work?.cancel()
    }

    private func refusal(for estimate: ClaudeJudgeEstimate, checksCap: Bool = true) -> String? {
        let policy = HybridSettings.shared.policy
        guard policy.mode != .off else { return ClaudeJudgeText.remoteOff }
        guard KeychainStore.hasKey(for: Self.providerID) else { return ClaudeJudgeText.missingKey }
        guard policy.allowCloud else { return ClaudeJudgeText.cloudNotAllowed }
        guard checksCap else { return nil }
        let spent = CostLedger.shared.sessionCostUSD
        guard !estimate.exceedsCap(policy.costCapUSDPerSession, spentUSD: spent) else {
            return ClaudeJudgeText.capExceeded(estimate, capUSD: policy.costCapUSDPerSession, spentUSD: spent)
        }
        return nil
    }

    // MARK: Sending

    private enum Fetched: Sendable {
        case reply(Data, status: Int)
        case transport(String)
        /// Cancelled while in flight: the API may have billed it.
        case cancelled
        /// Cancelled before the request left.
        case notSent
    }

    private func run(_ items: [ClaudeJudgeItem], scope: String, apiKey: String) async {
        await withTaskGroup(of: Void.self) { group in
            var queue = items[...]
            for item in queue.prefix(ClaudeJudgeRequest.maxConcurrent) {
                group.addTask { await self.send(item, scope: scope, apiKey: apiKey) }
            }
            queue = queue.dropFirst(ClaudeJudgeRequest.maxConcurrent)
            while await group.next() != nil {
                guard !Task.isCancelled, let item = queue.popFirst() else { continue }
                group.addTask { await self.send(item, scope: scope, apiKey: apiKey) }
            }
        }
        activeScope = nil
        deliver = nil
        work = nil
    }

    nonisolated private func send(_ item: ClaudeJudgeItem, scope: String, apiKey: String) async {
        let fetched = await Self.fetch(item.request, apiKey: apiKey)
        await complete(item, fetched, scope: scope)
    }

    nonisolated private static func fetch(_ request: ClaudeJudgeRequest, apiKey: String) async -> Fetched {
        guard !Task.isCancelled, let urlRequest = try? request.urlRequest(apiKey: apiKey) else { return .notSent }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            return .reply(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as URLError where error.code == .cancelled {
            return .cancelled
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .transport(error.localizedDescription)
        }
    }

    private func complete(_ item: ClaudeJudgeItem, _ fetched: Fetched, scope: String) {
        switch fetched {
        case .reply(let data, let status):
            let response = ClaudeJudgeResponse.parse(data, status: status, requested: item.request.model, date: .now)
            if response.attempts.isEmpty, (200..<300).contains(status) {
                recordEstimate(item.request)
            } else {
                record(response.attempts)
            }
            if let judgment = response.judgment {
                deliver?(item, judgment)
            } else {
                setNote(ClaudeJudgeText.outcomeLine(response.outcome), for: item, scope: scope)
            }
        case .transport(let message):
            // The request may have reached the API before the connection failed, so it is charged as sent.
            recordEstimate(item.request)
            setNote(ClaudeJudgeText.outcomeLine(.failed(message)), for: item, scope: scope)
        case .cancelled:
            recordEstimate(item.request)
        case .notSent:
            break
        }
        finishedCount += 1
    }

    private func setNote(_ line: String, for item: ClaudeJudgeItem, scope: String) {
        notes[scope, default: [:]][item.key] = ClaudeJudgeNote(line: line, answer: item.subject.answer)
    }

    // MARK: Ledger

    private func record(_ attempts: [ClaudeJudgeAttempt]) {
        let ledger = CostLedger.shared
        for attempt in attempts {
            Self.setPrice(on: ledger, model: attempt.modelID)
            ledger.record(provider: Self.providerID, model: attempt.modelID, usage: Self.usage(of: attempt),
                          origin: .cloud, compressionRatio: nil)
        }
    }

    /// The ledger's own worst case for a reply it never saw: the largest prompt estimate and `max_tokens`.
    private func recordEstimate(_ request: ClaudeJudgeRequest) {
        let ledger = CostLedger.shared
        Self.setPrice(on: ledger, model: request.model.rawValue)
        ledger.record(
            provider: Self.providerID, model: request.model.rawValue, usage: nil,
            estimatedUsage: TokenUsage(inputTokens: request.estimatedInputTokens.upperBound,
                                       outputTokens: ClaudeJudgeRequest.maxTokens),
            origin: .cloud, compressionRatio: nil)
    }

    private static func setPrice(on ledger: CostLedger, model: String) {
        let price = ClaudeJudgePrices.price(for: model)
        ledger.setPrice(TokenPrice(inputUSDPerMillion: price.inputUSDPerMillion,
                                   outputUSDPerMillion: price.outputUSDPerMillion),
                        provider: providerID, model: model)
    }

    private static func usage(of attempt: ClaudeJudgeAttempt) -> TokenUsage {
        TokenUsage(inputTokens: attempt.inputTokens, outputTokens: attempt.outputTokens)
    }
}

/// «Evaluar con Claude» for one entry point: the button with its count, the confirmation, the refusal alert and,
/// while this entry point's batch runs, its progress and «Cancelar evaluación». `compact` is the Modo Test row.
struct ClaudeJudgeControls: View {
    let scope: String
    /// Read when tapped, so the batch is what is pending at that moment.
    let subjects: () -> [(key: String, subject: ClaudeJudgeSubject)]
    let count: Int
    let identifier: String
    var compact = false
    let deliver: (ClaudeJudgeItem, ClaudeJudgment) -> Void

    @ObservedObject private var service = ClaudeJudgeService.shared
    @AppStorage(ClaudeJudgeModel.defaultsKey) private var model: ClaudeJudgeModel = .standard
    @State private var pendingBatch: ClaudeJudgeBatch?
    @State private var refusal: String?

    private static let refusalTitle = "Evaluar con Claude"

    var body: some View {
        if service.activeScope == scope {
            runningControls
        } else if count > 0 {
            if !compact {
                ClaudeJudgeModelPicker(model: $model)
                    .disabled(service.isRunning)
            }
            startButton
            if !compact {
                ClaudeJudgeSendRefusal(scope: scope, identifier: identifier)
            }
        }
    }

    private var progressText: String {
        ClaudeJudgeText.running + " \(service.finishedCount) de \(service.totalCount)"
    }

    @ViewBuilder
    private var runningControls: some View {
        if compact {
            Button(role: .destructive, action: service.cancel) {
                Label("\(service.finishedCount)/\(service.totalCount)", systemImage: "stop.circle")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(verbatim: ClaudeJudgeText.cancel + ". " + progressText))
            .accessibilityIdentifier(identifier + ".cancel")
        } else {
            Label {
                Text(verbatim: progressText)
            } icon: {
                ProgressView()
            }
            .accessibilityIdentifier(identifier + ".progress")
            Button(ClaudeJudgeText.cancel, role: .destructive, action: service.cancel)
                .accessibilityIdentifier(identifier + ".cancel")
        }
    }

    private var startButton: some View {
        Button(action: prepare) {
            if compact {
                Label {
                    Text(verbatim: "\(count)")
                } icon: {
                    Image(systemName: "checkmark.bubble")
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            } else {
                Label(ClaudeJudgeText.button(count: count), systemImage: "checkmark.bubble")
            }
        }
        .buttonStyle(.borderless)
        .disabled(service.isRunning)
        .accessibilityLabel(Text(verbatim: ClaudeJudgeText.button(count: count)))
        .accessibilityIdentifier(identifier)
        .confirmationDialog(
            ClaudeJudgeText.confirmationTitle,
            isPresented: Binding(get: { pendingBatch != nil }, set: { if !$0 { pendingBatch = nil } }),
            titleVisibility: .visible,
            presenting: pendingBatch
        ) { batch in
            Button(ClaudeJudgeText.sendButton(count: batch.items.count, of: batch.totalCount)) {
                service.start(batch, deliver: deliver)
            }
            Button("Cancelar", role: .cancel) {}
        } message: { batch in
            Text(verbatim: ClaudeJudgeText.confirmationMessage(model: batch.model, estimate: batch.estimate,
                                                               totalCount: batch.totalCount))
        }
        .alert(
            Self.refusalTitle,
            isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } }),
            presenting: refusal
        ) { _ in
            Button("Aceptar", role: .cancel) {}
        } message: { message in
            Text(verbatim: message)
        }
    }

    private func prepare() {
        switch service.prepare(scope: scope, subjects: subjects(), model: model) {
        case .success(let batch) where !batch.items.isEmpty:
            pendingBatch = batch
        case .success:
            break
        case .failure(let failure):
            refusal = failure.message
        }
    }
}

/// The send-time refusal of one entry point, under its button; the compact Modo Test row puts it below its header.
struct ClaudeJudgeSendRefusal: View {
    let scope: String
    let identifier: String

    @ObservedObject private var service = ClaudeJudgeService.shared

    var body: some View {
        if let message = service.sendRefusals[scope] {
            Label {
                Text(verbatim: message)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(identifier + ".refusal")
        }
    }
}

/// «Modelo juez», kept under ``ClaudeJudgeModel/defaultsKey``.
struct ClaudeJudgeModelPicker: View {
    @Binding var model: ClaudeJudgeModel

    var body: some View {
        Picker(ClaudeJudgeText.modelSetting, selection: $model) {
            ForEach(ClaudeJudgeModel.allCases) { option in
                Text(verbatim: option.title).tag(option)
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("claudeJudge.model")
    }
}
