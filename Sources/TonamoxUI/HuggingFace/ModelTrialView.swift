import SwiftUI
import TonamoxCore
#if canImport(UIKit)
import UIKit
#endif

/// Why a downloaded model can't be loaded right now, shared by the pickers and Try it.
enum RunBlocker {
    case simulatorMLX
    case tooLarge
    case unsized

    /// Short label for a picker row.
    var label: String {
        switch self {
        case .simulatorMLX: String(localized: "device only", bundle: .module)
        case .tooLarge: String(localized: "too large now", bundle: .module)
        case .unsized: String(localized: "size unknown", bundle: .module)
        }
    }

    /// Full sentence for Try it.
    var explanation: String {
        switch self {
        case .simulatorMLX: String(localized: "MLX can't run on the Simulator; Try it needs a device.", bundle: .module)
        case .tooLarge: String(localized: "Too large for this device's free memory right now.", bundle: .module)
        case .unsized:
            String(localized: "Try it needs the size from a search result; download it from Search.", bundle: .module)
        }
    }

    /// `nil` when `model` may load now. Size 0 is only rejected when `requiresSize`: the load-time memory guard
    /// can't judge an unsized model.
    static func check(_ model: Model, requiresSize: Bool = false) -> RunBlocker? {
        if requiresSize && model.approximateSizeMB <= 0 { return .unsized }
        #if targetEnvironment(simulator)
        if model.format == .mlx { return .simulatorMLX }
        #endif
        let fit = HardwareAnalyzer.assess(model).fitLevel
        if fit == .tooLarge || (model.format == .mlx && fit == .streamingRequired) { return .tooLarge }
        return nil
    }
}

/// Loads a downloaded model, asks one short question and unloads it again.
struct ModelTrialView: View {
    let candidate: Model
    @Environment(\.dismiss) private var dismiss

    @State private var reply = ""
    @State private var stage = String(localized: "Loading…", bundle: .module)
    @State private var failure: String?
    @State private var run: Task<Void, Never>?
    @State private var isFinished = false
    @State private var stopReason: String?

    private static let prompt = "Reply with one short sentence: what are you?"

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Prompt", bundle: .module)) { Text(Self.prompt) }
                Section(String(localized: "Reply", bundle: .module)) {
                    if let failure {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    } else if reply.isEmpty {
                        ProgressView(stage)
                    } else {
                        Text(reply).textSelection(.enabled)
                    }
                }
                Section {
                    Text(stage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(candidate.resolvedFileURL?.path ?? candidate.repoID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(candidate.displayName)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done", bundle: .module)) {
                        stop(reason: nil)
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 360)
        #endif
        .onAppear { start() }
        .onDisappear { stop(reason: nil) }
        #if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            stop(reason: String(localized: "Stopped: the system reported low memory.", bundle: .module))
        }
        #endif
    }

    private func start() {
        guard run == nil else { return }
        if let blocker = RunBlocker.check(candidate, requiresSize: true) {
            failure = blocker.explanation
            isFinished = true
            stage = String(localized: "Not loaded.", bundle: .module)
            return
        }
        let target = candidate
        run = Task {
            var outcome = ""
            do {
                let started = ContinuousClock.now
                let session = try await ModelManager.shared.load(target)
                // A cancelled load can still finish; don't generate with it.
                try Task.checkCancellation()
                let loaded = ContinuousClock.now
                stage = String(localized: "Loaded in \(Self.seconds(loaded - started)). Generating…", bundle: .module)
                let text = try await session.chat(Self.prompt, maxTokens: 32)
                try Task.checkCancellation()
                reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let replied = Self.seconds(ContinuousClock.now - loaded)
                outcome = String(localized: "Loaded in \(Self.seconds(loaded - started)), replied in \(replied).",
                                 bundle: .module)
            } catch is CancellationError {
                outcome = String(localized: "Cancelled.", bundle: .module)
            } catch {
                failure = error.localizedDescription
            }
            // Unload whatever happens, so a test never keeps gigabytes resident; report it only once done.
            ModelManager.shared.evict(target)
            isFinished = true
            if let stopReason { failure = String(localized: "\(stopReason) The model was unloaded.", bundle: .module) }
            stage = outcome.isEmpty ? String(localized: "Unloaded.", bundle: .module)
                : String(localized: "\(outcome) Unloaded.", bundle: .module)
        }
    }

    /// Cancelling `run` alone does not stop the load: `ModelManager.load` awaits its own unstructured task.
    private func stop(reason: String?) {
        guard run != nil, !isFinished else { return }
        if let reason { stopReason = reason }
        ModelManager.shared.cancelLoad(candidate)
        run?.cancel()
    }

    private static func seconds(_ elapsed: Duration) -> String {
        elapsed.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow, maximumUnitCount: 2))
    }
}
