import Foundation
import SwiftUI
import TerminalBridgeKit
import UIKit

/// An export written once, when the owner taps it, and shared as a file URL through `ExportShareSheet`. Never as text
/// and never with "Copiar": the pasteboard would carry replies to the Mac by Universal Clipboard, without the expiry
/// the command copies get.
struct ExportFile {
    /// Only the PDF carries charts, so only it takes a chart style.
    enum ReportFormat {
        case pdf(CapabilityChartStyle)
        case markdown
        case json
    }

    enum ComparisonFormat {
        case pdf(CapabilityChartStyle)
        case csv
    }

    enum SelectionFormat {
        case pdf(CapabilityChartStyle)
        case csv
        case markdown
    }

    let build: @MainActor (Date) throws -> (name: String, data: Data)

    /// `tmp/tonamox-export/<uuid>/<name>`, dated now.
    @MainActor
    func write() throws -> SharedExport {
        let file = try build(.now)
        let url = try ExportDirectory.newFileURL(named: file.name)
        try file.data.write(to: url, options: [.atomic, .completeFileProtection])
        return SharedExport(fileURL: url)
    }
}

/// A written export waiting for the share sheet.
struct SharedExport: Identifiable {
    let fileURL: URL
    var id: URL { fileURL }
}

/// `tmp/tonamox-export/<uuid>/<name>`: one folder per file, so two exports in the same minute never collide.
/// Pages that export clear it when they appear and disappear, and the share sheet removes its file when it closes.
nonisolated enum ExportDirectory {
    static var root: URL {
        FileManager.default.temporaryDirectory.appending(path: "tonamox-export", directoryHint: .isDirectory)
    }

    static func newFileURL(named name: String) throws -> URL {
        let folder = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: name, directoryHint: .notDirectory)
    }

    static func remove(_ file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    static func clear() {
        try? FileManager.default.removeItem(at: root)
    }

    static var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}

/// The system share sheet for one export file. `ShareLink` cannot leave out activities, so this wraps
/// `UIActivityViewController` to drop "Copiar" and the reading list.
struct ExportShareSheet: UIViewControllerRepresentable {
    let export: SharedExport

    static let excludedActivities: [UIActivity.ActivityType] = [.copyToPasteboard, .addToReadingList]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [export.fileURL], applicationActivities: nil)
        controller.excludedActivityTypes = Self.excludedActivities
        let url = export.fileURL
        controller.completionWithItemsHandler = { _, _, _, _ in
            ExportDirectory.remove(url)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

extension View {
    /// Presents the share sheet while `export` is set.
    func exportShareSheet(_ export: Binding<SharedExport?>) -> some View {
        sheet(item: export) { item in
            ExportShareSheet(export: item)
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
    }
}

/// The exports of each page. Content is built when the owner taps, with the options the menu shows at that moment.
extension ExportFile {
    /// One model's saved levels as PDF, Markdown or JSON.
    static func report(
        _ levels: [CapabilityReport],
        format: ReportFormat,
        options: CapabilityExportOptions
    ) -> ExportFile {
        ExportFile { date in
            let title = levels.max { $0.date < $1.date }?.modelTitle ?? ""
            switch format {
            case .markdown:
                return (CapabilityExport.fileName(modelTitle: title, exportedAt: date, fileExtension: "md"),
                        Data(CapabilityExport.markdown(levels, options: options, exportedAt: date).utf8))
            case .json:
                return (CapabilityExport.fileName(modelTitle: title, exportedAt: date, fileExtension: "json"),
                        try CapabilityExport.json(levels, options: options, exportedAt: date))
            case .pdf(let style):
                return (CapabilityExport.fileName(modelTitle: title, exportedAt: date, fileExtension: "pdf"),
                        CapabilityPDF.report(levels, options: options, exportedAt: date, chartStyle: style))
            }
        }
    }

    /// Every saved model, as the comparison PDF or CSV.
    static func comparison(_ models: [[CapabilityReport]], format: ComparisonFormat) -> ExportFile {
        ExportFile { date in
            switch format {
            case .pdf(let style):
                return (CapabilityExport.comparisonFileName(exportedAt: date, fileExtension: "pdf"),
                        CapabilityPDF.comparison(models, exportedAt: date, chartStyle: style))
            case .csv:
                return (CapabilityExport.comparisonFileName(exportedAt: date, fileExtension: "csv"),
                        Data(CapabilityComparisonCSV.make(models, exportedAt: date).utf8))
            }
        }
    }

    /// The 2 or 3 models picked in "Comparar modelos": the comparison PDF with the per-probe matrix, the CSV rows of
    /// those models with their letters, or Markdown. None carries replies.
    static func selection(_ models: [[CapabilityReport]], format: SelectionFormat) -> ExportFile {
        ExportFile { date in
            let name = { (fileExtension: String) in
                CapabilityComparison.fileName(models: models.count, exportedAt: date, fileExtension: fileExtension)
            }
            switch format {
            case .pdf(let style):
                return (name("pdf"), CapabilityPDF.comparison(models, exportedAt: date, chartStyle: style,
                                                              includesMatrix: true))
            case .csv:
                return (name("csv"), Data(CapabilityComparisonCSV.make(models, exportedAt: date,
                                                                       includesLetters: true).utf8))
            case .markdown:
                let text = CapabilityComparisonMarkdown.make(models, exportedAt: date,
                                                             appVersion: ExportDirectory.appVersion)
                return (name("md"), Data(text.utf8))
            }
        }
    }

    static func testSession(
        _ session: TestModeSession,
        modelTitle: String,
        options: CapabilityExportOptions
    ) -> ExportFile {
        ExportFile { date in
            let text = TestModeExport.markdown(session: session, modelTitle: modelTitle, exportedAt: date,
                                               options: options) ?? ""
            return (TestModeExport.fileName(modelTitle: modelTitle, exportedAt: date), Data(text.utf8))
        }
    }
}
