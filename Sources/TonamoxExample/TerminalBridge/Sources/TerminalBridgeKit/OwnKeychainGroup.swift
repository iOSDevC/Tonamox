import Foundation

/// Decides whether the keychain's default access group belongs to this app alone.
public enum OwnKeychainGroup {
    /// False for an App Group (`group.` prefix or one of `sharedGroups`): a build without the application-identifier
    /// entitlement can default to one, and every sibling app can read and write it.
    public static func isOwn(_ group: String, sharedGroups: Set<String>) -> Bool {
        !group.isEmpty && !group.hasPrefix("group.") && !sharedGroups.contains(group)
    }
}
