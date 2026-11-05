import SwiftUI
import TonamoxCore

/// On-device image generation; image models are found, downloaded and deleted from the Image tab.
struct ImageAppRoot: View {
    @State private var imageState = ImageGenState()

    var body: some View {
        content
            .onSharedStorageChange([.models]) {
                imageState.reloadModels()
            }
    }

    @ViewBuilder private var content: some View {
        #if os(iOS)
        TabView {
            Tab("Image", systemImage: "photo.on.rectangle.angled") {
                ImageGenTab(state: imageState)
            }
            Tab("Settings", systemImage: "gearshape") {
                HybridSettingsView(isEmbedded: true)
            }
        }
        .background(KeyboardDismissOnTap())
        #else
        ImageGenTab(state: imageState)
        #endif
    }
}
