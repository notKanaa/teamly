import Foundation

/// Input limits. Must match the SQL check constraints (docs/CONTRACTS.md § Validation).
public enum Limits {
    public static let displayName = 1...50
    public static let groupName = 1...60
    public static let taskTitle = 1...200
    public static let taskDetailsMax = 5000
    public static let passwordMinLength = 8
    public static let maxAssignees = 20
    /// Done tasks completed more than this many days ago are hidden unless explicitly requested.
    public static let oldDoneTaskDays = 30

    // MARK: - v2 (docs/CONTRACTS-V2.md §3)

    /// Items of one task's checklist.
    public static let checklistItemsMax = 30
    /// Code points of a checklist item title (after trimming; at least 1).
    public static let checklistItemTitleMax = 200
    /// Users of a rotation (« à tour de rôle »).
    public static let rotationMin = 2
    public static let rotationMax = 20
    /// `RecurrenceRule.interval` (at least 1).
    public static let repeatIntervalMax = 52
    /// Code points of a group or avatar emoji (after trimming; at least 1).
    public static let emojiCodePointsMax = 16
    /// Events of one activity feed read, newest first (docs/CONTRACTS-V2.md §7, `limit=50`).
    public static let activityFeedMax = 50
    /// The server deletes a group's events older than this many days when it writes a new one (an event exactly
    /// 90 days old is kept).
    public static let activityRetentionDays = 90
}
