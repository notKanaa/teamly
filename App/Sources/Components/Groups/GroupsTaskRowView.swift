import SwiftUI
import TeamTasksCore

/// One task of the group screen: status button, title, priority, due date (red when overdue) and assignee
/// initials. Put it inside a `NavigationLink`; the status button stays tappable on its own.
struct GroupsTaskRowView: View {
    let row: TaskRow
    let assignees: [GroupsAvatarStack.Person]
    let isBusy: Bool
    /// Tap on the status symbol (à faire → en cours → terminée → à faire).
    let onToggleStatus: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            statusControl
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title)
                        .font(.body)
                        .strikethrough(row.isDone)
                        .foregroundStyle(row.isDone ? Color.secondary : Color.primary)
                        .lineLimit(2)
                    HStack(spacing: 10) {
                        GroupsPriorityLabel(priority: row.priority)
                        if let dueText = row.dueText {
                            Label(dueText, systemImage: row.isOverdue ? "exclamationmark.circle" : "calendar")
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(row.isOverdue ? Color.red : Color.secondary)
                                .fontWeight(row.isOverdue ? Font.Weight.semibold : Font.Weight.regular)
                        }
                    }
                    .font(.caption)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                GroupsAvatarStack(people: assignees)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusControl: some View {
        if isBusy {
            ProgressView()
                .frame(width: 30, height: 30)
                .accessibilityLabel("Mise à jour du statut")
        } else if row.canChangeStatus {
            Button {
                onToggleStatus()
            } label: {
                statusSymbol
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Statut : \(row.status.label)")
            .accessibilityHint("Passe la tâche à « \(row.status.next.label) »")
            .accessibilityIdentifier(AccessibilityID.Groups.taskStatusButton(row.title))
        } else {
            statusSymbol
                .opacity(0.6)
                .accessibilityLabel("Statut : \(row.status.label)")
        }
    }

    private var statusSymbol: some View {
        Image(systemName: row.status.systemImage)
            .font(.title2)
            .foregroundStyle(GroupsStyle.statusColor(row.status))
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
    }

    /// « Payer le loyer, À faire, priorité haute, en retard, échéance hier à 20:00, assignée à Inès Dubois ».
    private var accessibilityText: String {
        var parts = [row.title, row.status.label, "priorité \(row.priority.label.lowercased())"]
        if let dueText = row.dueText {
            let due = "échéance \(dueText.lowercased())"
            parts.append(row.isOverdue ? "en retard, \(due)" : due)
        }
        if let assigneesText = row.assigneesText {
            parts.append(
                assigneesText == MemberDirectory.unassignedText ? assigneesText.lowercased() : "assignée à \(assigneesText)"
            )
        }
        return parts.joined(separator: ", ")
    }
}
