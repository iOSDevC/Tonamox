import SwiftUI
import TonamoxCore

@main
struct TonamoxChatApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // First Tonamox call: any storage access before it fixes this process on its private storage.
        TonamoxSharedStorage.configure(appGroup: TonamoxAppGroup.identifier)
        DownloadRecords.standard.registerDownloaded()
    }

    var body: some Scene {
        WindowGroup {
            ChatAppRoot()
        }
        .defaultSize(width: 900, height: 700)
        .onChange(of: scenePhase) { _, phase in
            // Release GPU memory when backgrounded, as the Example does.
            if phase == .background {
                Task { @MainActor in ModelManager.shared.evictAll() }
            }
        }

#if os(macOS)
        Settings {
            HybridSettingsView(isEmbedded: true)
        }
#endif
    }
}
