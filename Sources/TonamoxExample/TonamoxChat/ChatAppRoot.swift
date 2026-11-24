import SwiftUI
import TonamoxCore
import TonamoxUI

/// Chat and Voice over the models the group shares; models are found and downloaded from Chat's model sheet.
struct ChatAppRoot: View {
    var body: some View {
        TabView {
            Tab("Chat", systemImage: "bubble.left.and.text.bubble.right") {
                ChatTab()
            }
            Tab("Voice", systemImage: "mic.fill") {
                VoiceTab()
            }
            #if os(iOS)
            Tab("Settings", systemImage: "gearshape") {
                HybridSettingsView(isEmbedded: true)
            }
            Tab("Licencias", systemImage: "doc.text") {
                OpenSourceNoticesTab()
            }
            #endif
        }
        #if os(iOS)
        .background(KeyboardDismissOnTap())
        #endif
        .onSharedStorageChange([.models]) {
            ModelDownloadCenter.shared.reloadSharedState()
        }
    }
}
