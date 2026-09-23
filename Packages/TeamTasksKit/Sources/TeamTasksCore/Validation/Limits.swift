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
}
