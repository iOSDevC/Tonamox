import SwiftUI
import TerminalBridgeKit
import TonamoxCore

@main
struct TonamoxTerminalApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var bridge: BridgeServer
    @StateObject private var chat: TerminalChatViewModel
    @StateObject private var keyboard: BluetoothKeyboard
    @StateObject private var capabilities: CapabilityRunner
    @State private var webServer: WebServerController

    init() {
        // First Tonamox call: any storage access before it fixes this process on its private storage.
        TonamoxSharedStorage.configure(appGroup: TonamoxAppGroup.identifier)
        DownloadRecords.standard.registerDownloaded()
        RemoteTargets.restoreCloudPermission()
        ReasoningSetting.migrate(.standard)
        CapabilityChartStyle.migrate(.standard)
        _bridge = StateObject(wrappedValue: BridgeServer())
        // Never started here: the web server starts only from its screen, in this launch.
        let webServer = WebServerController()
        _webServer = State(initialValue: webServer)
        let chat = TerminalChatViewModel(turnstile: webServer.turnstile)
        _chat = StateObject(wrappedValue: chat)
        let capabilities = CapabilityRunner(turnstile: webServer.turnstile, chat: chat)
        _capabilities = StateObject(wrappedValue: capabilities)
        #if DEBUG
        ExportSmoke.runIfRequested(store: capabilities.archive)
        #endif
        // No CBPeripheralManager yet: the Bluetooth prompt appears on the first "Activar teclado".
        _keyboard = StateObject(wrappedValue: BluetoothKeyboard())
    }

    var body: some Scene {
        WindowGroup {
            TerminalChatView(bridge: bridge, chat: chat, keyboard: keyboard, webServer: webServer,
                             capabilities: capabilities)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // A job never continues while the user cannot see or stop it.
            if phase != .active { keyboard.interruptForInactiveApp() }
            switch phase {
            case .active:
                bridge.start()
                keyboard.resumeIfStarted()
                // The SDK reopens the port by itself; the served model was evicted with the rest.
                webServer.returnedToForeground()
            case .background:
                // The helper sees the connection reset at once instead of waiting for a heartbeat timeout.
                bridge.stop()
                chat.interruptForBackground()
                capabilities.cancel(.background)
                // Nothing leaves the device for a request the user cannot see.
                HybridSettings.shared.consent.declinePending()
                webServer.enteredBackground()
                // Release GPU memory when backgrounded, as the Example does.
                ModelManager.shared.evictAll()
            default:
                break
            }
        }
    }
}
