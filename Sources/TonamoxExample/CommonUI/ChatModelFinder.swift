import SwiftUI
import TonamoxCore
import TonamoxUI

/// Hugging Face search for chat models judged against this device: text generation, image + text and any-to-any
/// repos (plus undeclared ones), in MLX or GGUF.
struct ChatModelFinder: View {
    @State private var search = HFModelSearch(query: "", devices: [DevicePreset.thisDevice()],
                                              compatibleOnly: true, pipelineFilter: .chat)
    @State private var selection: String?
    @State private var hasSearched = false

    var body: some View {
        @Bindable var downloads = ModelDownloadCenter.shared
        HFModelSearchList(search: search, selection: $selection)
            .navigationTitle("Hugging Face")
            .navigationDestination(item: $selection) { HFRepoDetailView(repoID: $0, search: search) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu("Options", systemImage: "ellipsis.circle") {
                        Toggle("Keep the screen awake while downloading", isOn: $downloads.keepsScreenAwake)
                    }
                }
            }
            .task {
                // Coming back from a repo's detail must not repeat the search.
                guard !hasSearched else { return }
                hasSearched = true
                search.search()
            }
    }
}
