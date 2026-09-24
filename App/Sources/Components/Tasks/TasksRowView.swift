import SwiftUI
import TeamTasksCore

/// One task of a list (« Mes tâches », group screen): status button, title (struck through when done),
/// « Nouveau » badge, group name (« Mes tâches »), priority and due date, and the assignees: their initials on the
/// trailing side when `assignees` is given (group screen), otherwise `row.assigneesText` as a line when set.
///
/// Put it inside a `NavigationLink` row: the status button is borderless and keeps its own tap. The status button is
/// enabled when `row.canChangeStatus` and `onToggleStatus` is given; `onToggleStatus` should ask for
/// `row.status.next`. VoiceOver reads the row as one sentence (title, status, priority, due date, group, assignees)
/// and gets the same status change as a custom action.
///
/// At accessibility text sizes the priority and the due date, then the initials, go under each other instead of
/// being cut.
struct TasksRowView: View {
    let row: TaskRow
    /// Assignees shown as initials on the trailing side (group screen); nil: no initials.
    let assignees: [GroupsAvatarStack.Person]?
    let isBusy: Bool
    let onToggleStatus: (() -> Void)?

    @Environment(\.dynamicTypeSize) private var typeSize

    init(
        row: TaskRow,
        assignees: [GroupsAvatarStack.Person]? = nil,
        isBusy: Bool = false,
        onToggleStatus: (() -> Void)? = nil
    ) {
        self.row = row
        self.assignees = assignees
        self.isBusy = isBusy
        self.onToggleStatus = onToggleStatus
    }

    private var canToggle: Bool { row.canChangeStatus && onToggleStatus != nil }

    var body: some View {
        let isLarge = typeSize.isAccessibilitySize
        let layout = isLarge
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
        HStack(alignment: .top, spacing: 8) {
            TasksStatusButton(status: row.status, isBusy: isBusy, isEnabled: canToggle) {
                onToggleStatus?()
            }

            layout {
                details(isLarge: isLarge)
                if let assignees {
                    GroupsAvatarStack(people: assignees)
                }
            }
            .opacity(row.isDone ? 0.75 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityActions {
                if canToggle && !isBusy {
                    Button(nextStatusActionTitle) {
                        onToggleStatus?()
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func details(isLarge: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.title)
                    .font(.body.weight(.medium))
                    .strikethrough(row.isDone)
                    .foregroundStyle(row.isDone ? Color.secondary : Color.primary)
                    .lineLimit(isLarge ? nil : 2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if row.isNew {
                    TasksNewBadge()
                }
            }

            if let groupName = row.groupName {
                Label(groupName, systemImage: "person.3")
                    .labelStyle(.inlineIcon)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(isLarge ? nil : 1)
            }

            // Side by side while they fit; the due date under the priority otherwise (« Dimanche 27 septembre à
            // 18:00 » next to « Moyenne » on a small iPhone, any date at large text sizes).
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    priorityBadge
                    dueLabel
                }
                VStack(alignment: .leading, spacing: 4) {
                    priorityBadge
                    dueLabel
                }
            }

            if assignees == nil, let assigneesText = row.assigneesText {
                Label(assigneesText, systemImage: "person")
                    .labelStyle(.inlineIcon)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(isLarge ? nil : 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var priorityBadge: some View {
        TasksPriorityBadge(priority: row.priority)
    }

    private var dueLabel: some View {
        TasksDueDateLabel(text: row.dueText, isOverdue: row.isOverdue)
            .font(.caption)
            .fontWeight(row.isOverdue ? Font.Weight.semibold : Font.Weight.regular)
            .lineLimit(2)
    }

    /// « Payer le loyer, À faire, priorité haute, en retard, échéance hier à 20:00, assignée à Inès Dubois »;
    /// « Faire les courses, nouveau, En cours, priorité moyenne, échéance demain à 18:00, groupe Coloc' rue des
    /// Lilas » on « Mes tâches ».
    private var accessibilityText: String {
        var parts = [row.title]
        if row.isNew {
            parts.append(MyTasksViewModel.newBadgeText.lowercased())
        }
        parts.append(row.status.label)
        parts.append("priorité \(row.priority.label.lowercased())")
        if let dueText = row.dueText {
            let due = "échéance \(dueText.lowercased())"
            parts.append(row.isOverdue ? "en retard, \(due)" : due)
        }
        if let groupName = row.groupName {
            parts.append("groupe \(groupName)")
        }
        if let assigneesText = row.assigneesText {
            parts.append(
                assigneesText == MemberDirectory.unassignedText ? assigneesText.lowercased() : "assignée à \(assigneesText)"
            )
        }
        return parts.joined(separator: ", ")
    }

    private var nextStatusActionTitle: String {
        "Passer à «\u{00A0}\(row.status.next.label)\u{00A0}»"
    }
}
