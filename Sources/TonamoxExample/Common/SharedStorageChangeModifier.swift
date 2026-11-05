import Combine
import Foundation
import SwiftUI
import TonamoxCore

/// Runs an action when shared data changes in this or another app of the group, and whenever the scene becomes
/// active again: change signals are not delivered while an app is suspended.
struct SharedStorageChangeModifier: ViewModifier {
    let kinds: Set<SharedStorageChange>
    let action: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: TonamoxSharedStorage.didChangeNotification)) { note in
                // A signal without a recognisable kind still refreshes.
                if let change = TonamoxSharedStorage.change(of: note), !kinds.contains(change) { return }
                action()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { action() }
            }
    }
}

extension View {
    /// Refreshes after `kinds` of shared data change, and when the scene becomes active.
    func onSharedStorageChange(_ kinds: Set<SharedStorageChange> = Set(SharedStorageChange.allCases),
                               perform action: @escaping () -> Void) -> some View {
        modifier(SharedStorageChangeModifier(kinds: kinds, action: action))
    }
}
