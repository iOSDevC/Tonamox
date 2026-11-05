import Foundation
import notify

// MARK: - SharedStorageSignal

/// Darwin notifications between the processes of a group, re-posted as
/// ``TonamoxSharedStorage/didChangeNotification``.
///
/// Darwin names are system-wide and carry no payload, so the name only says what kind of data changed and every
/// receiver re-reads it. A suspended app misses posts; apps also refresh when they become active.
package enum SharedStorageSignal {

    /// `<prefix>.models`, `<prefix>.conversations`, `<prefix>.documents`.
    package static func name(of change: SharedStorageChange, prefix: String) -> String {
        "\(prefix).\(change.rawValue)"
    }

    /// Reaches every observer of `prefix`, including this process's.
    package static func post(_ change: SharedStorageChange, prefix: String) {
        let status = notify_post(name(of: change, prefix: prefix))
        if status != NOTIFY_STATUS_OK {
            TonamoxSharedStorage.log.error("notify_post \(change.rawValue, privacy: .public) failed: \(status)")
        }
    }

    /// Posts on the main queue, so observers see one delivery path with and without a group.
    package static func postLocally(_ change: SharedStorageChange, center: NotificationCenter) {
        DispatchQueue.main.async {
            center.post(notification(for: change))
        }
    }

    /// Registers one observer per change kind; each delivery re-posts on `center` from `queue`. Returns the tokens
    /// for ``cancel(_:)``.
    package static func observe(prefix: String, center: NotificationCenter,
                                queue: DispatchQueue = .main) -> [Int32] {
        SharedStorageChange.allCases.compactMap { register(change: $0, prefix: prefix, center: center, queue: queue) }
    }

    package static func cancel(_ tokens: [Int32]) {
        for token in tokens {
            notify_cancel(token)
        }
    }

    static func notification(for change: SharedStorageChange) -> Notification {
        Notification(name: TonamoxSharedStorage.didChangeNotification, object: nil,
                     userInfo: [TonamoxSharedStorage.changeKey: change.rawValue])
    }

    private static func register(change: SharedStorageChange, prefix: String, center: NotificationCenter,
                                 queue: DispatchQueue) -> Int32? {
        var token: Int32 = NOTIFY_TOKEN_INVALID
        let status = notify_register_dispatch(name(of: change, prefix: prefix), &token, queue) { _ in
            center.post(notification(for: change))
        }
        guard status == NOTIFY_STATUS_OK else {
            TonamoxSharedStorage.log.error("notify_register_dispatch \(change.rawValue, privacy: .public) failed: \(status)")
            return nil
        }
        return token
    }
}
