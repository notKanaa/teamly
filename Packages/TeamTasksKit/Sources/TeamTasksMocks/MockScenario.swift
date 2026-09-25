import Foundation

/// Predefined states for previews and UI tests (`-mockScenario <rawValue>` launch argument).
public enum MockScenario: String, Sendable, CaseIterable {
    /// No session: the login screen is shown.
    case signedOut
    /// Signed in as the demo user with French demo groups, members and tasks.
    case populated
    /// Signed in, member of no group (empty states).
    case emptyGroups
    /// `populated` plus v2 content for the v2 screenshots (`DemoData.Showcase`): a weekly rotating task whose turn is
    /// the demo user's, a half-done checklist, an activity feed and a weekly podium with a streak.
    case showcase
}
