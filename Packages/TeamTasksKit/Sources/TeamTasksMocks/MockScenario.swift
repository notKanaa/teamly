import Foundation

/// Predefined states for previews and UI tests (`-mockScenario <rawValue>` launch argument).
public enum MockScenario: String, Sendable, CaseIterable {
    /// No session: the login screen is shown.
    case signedOut
    /// Signed in as the demo user with French demo groups, members and tasks.
    case populated
    /// Signed in, member of no group (empty states).
    case emptyGroups
}
