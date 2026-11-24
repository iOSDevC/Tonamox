import SwiftUI
import TonamoxCore
import TonamoxUI
import TonamoxDocs

/// The document library; DocsTab offers its own model downloads and refreshes its index on document changes.
struct LibraryAppRoot: View {
    var body: some View {
        content
            .onSharedStorageChange([.models]) {
                ModelDownloadCenter.shared.reloadSharedState()
            }
    }

    @ViewBuilder private var content: some View {
        #if os(iOS)
        TabView {
            Tab("Library", systemImage: "doc.text.magnifyingglass") {
                DocsTab()
            }
            Tab("Settings", systemImage: "gearshape") {
                HybridSettingsView(isEmbedded: true)
            }
            Tab("Licencias", systemImage: "doc.text") {
                OpenSourceNoticesTab()
            }
        }
        .background(KeyboardDismissOnTap())
        #else
        DocsTab()
        #endif
    }
}
