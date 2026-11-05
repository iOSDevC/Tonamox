import SwiftUI
import TonamoxCore

@main
struct TonamoxTerminalApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // First Tonamox call: any storage access before it fixes this process on its private storage.
        TonamoxSharedStorage.configure(appGroup: TonamoxAppGroup.identifier)
    }

    var body: some Scene {
        WindowGroup {
            SharedModelsView()
        }
        .onChange(of: scenePhase) { _, phase in
            // Release GPU memory when backgrounded, as the Example does.
            if phase == .background {
                Task { @MainActor in ModelManager.shared.evictAll() }
            }
        }
    }
}
