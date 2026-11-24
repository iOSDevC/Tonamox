import SwiftUI
import TonamoxAppleIntelligence

// MARK: - AgentCrewMainView (Legacy)
//
// Preserved for backward compatibility.
// The primary integration now goes through AgentCrewInlineView in ContentView.
// §Fix #24: Wraps content in AIAvailabilityGate to show clear messaging
// when Apple Intelligence is unavailable.

@available(iOS 27, macOS 27, visionOS 27, *)
struct AgentCrewMainView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        AIAvailabilityGate {
            AgentCrewInlineView()
                .environmentObject(appState)
        }
    }
}
