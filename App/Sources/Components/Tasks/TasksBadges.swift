import SwiftUI
import TeamTasksCore

// Small capsules describing a task: priority, status, « Nouveau ». Shared by the task screen, « Mes tâches » and
// the group screen.

extension TaskStatus {
    /// Accent color of the status (icons, capsules): readable as small text (`ShellPalette`).
    var tasksTint: Color {
        switch self {
        case .todo: ShellPalette.gray
        case .inProgress: ShellPalette.blue
        case .done: ShellPalette.green
        }
    }
}

extension TeamTasksCore.TaskPriority {
    /// Accent color of the priority (capsules): readable as small text (`ShellPalette`).
    var tasksTint: Color {
        switch self {
        case .low: ShellPalette.gray
        case .medium: ShellPalette.orange
        case .high: ShellPalette.red
        }
    }
}

extension DueBucket {
    /// SF Symbol of a « Mes tâches » section header.
    var tasksSystemImage: String {
        switch self {
        case .overdue: "exclamationmark.circle"
        case .today: "sun.max"
        case .thisWeek: "calendar"
        case .later: "calendar.badge.clock"
        case .noDueDate: "tray"
        case .done: "checkmark.circle"
        }
    }
}

/// Capsule « Haute » / « Moyenne » / « Basse » with the priority icon.
struct TasksPriorityBadge: View {
    let priority: TeamTasksCore.TaskPriority
    let showsLabel: Bool

    init(priority: TeamTasksCore.TaskPriority, showsLabel: Bool = true) {
        self.priority = priority
        self.showsLabel = showsLabel
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: priority.systemImage)
                .font(.caption2.weight(.bold))
            if showsLabel {
                Text(priority.label)
            }
        }
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(priority.tasksTint)
        .background(priority.tasksTint.opacity(0.15), in: Capsule())
        // A short tag: capped so that it leaves room to the due date at the largest text sizes.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        "Priorité \(priority.label.lowercased())"
    }
}

/// Capsule « À faire » / « En cours » / « Terminée » with the status icon.
struct TasksStatusBadge: View {
    let status: TaskStatus

    init(status: TaskStatus) {
        self.status = status
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.systemImage)
            Text(status.label)
        }
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(status.tasksTint)
        .background(status.tasksTint.opacity(0.15), in: Capsule())
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        "Statut\u{00A0}: \(status.label)"
    }
}

/// « Nouveau » capsule of a task assigned by someone else since the user last looked (« Mes tâches »).
struct TasksNewBadge: View {
    init() {}

    var body: some View {
        Text(MyTasksViewModel.newBadgeText)
            .font(.caption2.weight(.bold))
            .lineLimit(1)
            .foregroundStyle(Color.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            // Not the accent itself: white on the dark-mode accent is only 2.9:1.
            .background(ShellPalette.accentFill, in: Capsule())
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .fixedSize()
    }
}
