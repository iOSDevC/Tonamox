import SwiftUI
import TonamoxCore

@main
struct TonamoxTerminalApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var bridge: BridgeServer
    @StateObject private var chat: TerminalChatViewModel

    init() {
        // First Tonamox call: any storage access before it fixes this process on its private storage.
        TonamoxSharedStorage.configure(appGroup: TonamoxAppGroup.identifier)
        _bridge = StateObject(wrappedValue: BridgeServer())
        _chat = StateObject(wrappedValue: TerminalChatViewModel())
    }

    var body: some Scene {
        WindowGroup {
            TerminalChatView(bridge: bridge, chat: chat)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                bridge.start()
            case .background:
                // The helper sees the connection reset at once instead of waiting for a heartbeat timeout.
                bridge.stop()
                chat.interruptForBackground()
                // Release GPU memory when backgrounded, as the Example does.
                ModelManager.shared.evictAll()
            default:
                break
            }
        }
    }
}
