import SwiftUI
import TeamTasksCore

/// One task of a list (« Mes tâches », group screen): status button, title (struck through when done),
/// « Nouveau » badge, group name (« Mes tâches ») or assignees (group screen), priority and due date.
///
/// Put it inside a `NavigationLink` row: the status button is borderless and keeps its own tap. The status button is
/// enabled when `row.canChangeStatus` and `onToggleStatus` is given; `onToggleStatus` should ask for
/// `row.status.next`. VoiceOver users get the same change as a custom action on the row.
struct TasksRowView: View {
    let row: TaskRow
    let isBusy: Bool
    let onToggleStatus: (() -> Void)?

    init(row: TaskRow, isBusy: Bool = false, onToggleStatus: (() -> Void)? = nil) {
        self.row = row
        self.isBusy = isBusy
        self.onToggleStatus = onToggleStatus
    }

    private var canToggle: Bool { row.canChangeStatus && onToggleStatus != nil }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TasksStatusButton(status: row.status, isBusy: isBusy, isEnabled: canToggle) {
                onToggleStatus?()
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.title)
                        .font(.body.weight(.medium))
                        .strikethrough(row.isDone)
                        .foregroundStyle(row.isDone ? Color.secondary : Color.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    if row.isNew {
                        TasksNewBadge()
                    }
                }

                if let groupName = row.groupName {
                    Label(groupName, systemImage: "person.3")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    TasksPriorityBadge(priority: row.priority)
                    TasksDueDateLabel(text: row.dueText, isOverdue: row.isOverdue)
                        .font(.caption)
                        .lineLimit(1)
                }

                if let assigneesText = row.assigneesText {
                    Label(assigneesText, systemImage: "person")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
            }
            .opacity(row.isDone ? 0.75 : 1)
            .accessibilityElement(children: .combine)
        }
        .padding(.vertical, 4)
        .accessibilityActions {
            if canToggle && !isBusy {
                Button(nextStatusActionTitle) {
                    onToggleStatus?()
                }
            }
        }
    }

    private var nextStatusActionTitle: String {
        "Passer à « \(row.status.next.label) »"
    }
}
