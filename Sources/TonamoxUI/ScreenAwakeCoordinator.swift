import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// One reason to keep the screen on. Apps declare their own in an extension, for example
/// `static let upload = ScreenAwakeReason("upload")`.
public struct ScreenAwakeReason: Hashable, Sendable {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }

    /// ``ModelDownloadCenter`` while a download runs with ``ModelDownloadCenter/keepsScreenAwake`` on.
    public static let download = ScreenAwakeReason("download")
}

/// The only writer of `UIApplication.isIdleTimerDisabled` in apps that use it: Auto-Lock stays off while any reason
/// is held. Writing the flag directly would undo another feature's hold. Tracks reasons on every platform and changes
/// nothing where there is no idle timer.
@MainActor
public final class ScreenAwakeCoordinator {
    public static let shared = ScreenAwakeCoordinator()

    public private(set) var heldReasons: Set<ScreenAwakeReason> = []

    public var keepsScreenAwake: Bool { !heldReasons.isEmpty }

    private init() {}

    public func setHeld(_ held: Bool, for reason: ScreenAwakeReason) {
        if held {
            heldReasons.insert(reason)
        } else {
            heldReasons.remove(reason)
        }
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = keepsScreenAwake
        #endif
    }
}
