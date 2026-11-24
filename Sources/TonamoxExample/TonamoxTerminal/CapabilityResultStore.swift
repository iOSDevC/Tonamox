import Combine
import Foundation
import TerminalBridgeKit
import TonamoxCore

/// The last complete capability report per model and level, in this app's own `UserDefaults.standard` (never the
/// App Group): outcomes, reasons and the capped replies of probes that did not pass. Prompt text is never written.
final class CapabilityResultStore: ObservableObject {
    /// `[modelKey: [level.rawValue: report]]`.
    @Published private(set) var reports: [String: CapabilityReportArchive.Levels]
    /// Entries this build cannot read, written back on every save.
    private var unreadable: CapabilityReportArchive.Unreadable
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let current = defaults.data(forKey: CapabilityReportArchive.defaultsKey)
        let legacy = defaults.data(forKey: CapabilityReportArchive.legacyDefaultsKey)
        reports = CapabilityReportArchive.decode(v2: current, legacy: legacy)
        unreadable = CapabilityReportArchive.unreadable(in: current)
        // One-time move to the per-level key; the v1 key is never written again, and it is removed only once
        // every report in it was read.
        if legacy != nil {
            if !reports.isEmpty, let data = CapabilityReportArchive.encode(reports, keeping: unreadable) {
                defaults.set(data, forKey: CapabilityReportArchive.defaultsKey)
            }
            if CapabilityReportArchive.legacyIsFullyRead(legacy) {
                defaults.removeObject(forKey: CapabilityReportArchive.legacyDefaultsKey)
            }
        }
    }

    /// Model keys, newest first, for "Resultados guardados".
    var savedModels: [String] {
        CapabilityReportArchive.modelsByRecency(reports)
    }

    func report(modelKey: String, level: CapabilityLevel) -> CapabilityReport? {
        CapabilityReportArchive.report(modelKey: modelKey, level: level, in: reports)
    }

    /// The model's saved reports in level order.
    func levels(of modelKey: String) -> [CapabilityReport] {
        CapabilityReportArchive.levels(of: modelKey, in: reports)
    }

    /// Does nothing for an incomplete report or one with busy-server rows. Other levels of the model stay.
    func save(_ report: CapabilityReport) {
        store(CapabilityReportArchive.storing(report, in: reports))
    }

    /// Marks or unmarks one probe of a saved report; the automatic state and reason stay as they were.
    func setValidation(_ validated: Bool, probeID: String, modelKey: String, level: CapabilityLevel) {
        guard let saved = report(modelKey: modelKey, level: level) else { return }
        var updated = reports
        updated[modelKey]?[level.rawValue] = saved.validating(probeID, on: validated ? .now : nil)
        store(updated)
    }

    /// Sets Claude's second opinion on one probe of the report saved on `date`; nothing once another run replaced it.
    func setSecondOpinion(
        _ judgment: ClaudeJudgment,
        probeID: String,
        modelKey: String,
        level: CapabilityLevel,
        savedOn date: Date
    ) {
        guard let saved = report(modelKey: modelKey, level: level), saved.date == date,
              let result = saved.result(for: probeID), result.canBeValidatedByHand, result.savedReply != nil
        else { return }
        var updated = reports
        updated[modelKey]?[level.rawValue] = saved.judging(probeID, with: judgment)
        store(updated)
    }

    #if DEBUG
    /// Seed cleanup for `ExportSmoke`; the app itself only ever clears everything.
    func removeModels(where shouldRemove: (String) -> Bool) {
        store(reports.filter { !shouldRemove($0.key) })
    }
    #endif

    func clear() {
        defaults.removeObject(forKey: CapabilityReportArchive.defaultsKey)
        defaults.removeObject(forKey: CapabilityReportArchive.legacyDefaultsKey)
        reports = [:]
        unreadable = CapabilityReportArchive.Unreadable()
    }

    private func store(_ updated: [String: CapabilityReportArchive.Levels]) {
        guard updated != reports, let data = CapabilityReportArchive.encode(updated, keeping: unreadable) else {
            return
        }
        defaults.set(data, forKey: CapabilityReportArchive.defaultsKey)
        reports = updated
    }

    /// The stable key a report is saved under; nil for engines whose runs are never saved (Echo, remote).
    static func modelKey(for choice: ModelChoice) -> String? {
        switch choice.kind {
        case .onDisk(let weights):
            switch weights.format {
            case .mlx:
                return CapabilityModelKey.mlx(modelID: weights.id)
            case .gguf:
                guard let file = weights.resolvedFileURL, let size = fileSize(file) else { return nil }
                return CapabilityModelKey.gguf(fileURL: file, byteSize: size)
            }
        case .appleIntelligence:
            return CapabilityModelKey.apple(osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
        case .remote:
            return nil
        #if DEBUG
        case .echo:
            return nil
        #endif
        }
    }

    private static func fileSize(_ file: URL) -> Int64? {
        // `path(percentEncoded: false)`: the shared storage root contains a space.
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))
        return (attributes?[.size] as? NSNumber)?.int64Value
    }
}
