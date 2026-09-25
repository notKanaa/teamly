import SwiftUI
import TeamTasksCore

/// A task of a list as a card (docs/DESIGN-V2.md §5), drawn from a `TaskRow`:
/// - leading, a `StatusControl` (44 pt target) whose ring takes `tint`;
/// - in the middle, the title (headline, struck through when done) with « Nouveau » when `row.isNew`, then a line of
///   chips that wraps: the group (« Mes tâches »: `row.groupAppearance` and `row.groupShortName`), the due date (red
///   and bold when overdue), « Ton tour » (or « À tour de rôle », or the repetition), the checklist « 2/5 », « En
///   cours », and the priority when it is not « Moyenne »;
/// - trailing, on the group screen (`row.assigneesText != nil`): the assignees (`row.assignees`) or the dashed circle
///   of « Personne ». At accessibility text sizes they move under the chips.
///
/// Wrap it in the screen's `NavigationLink` (with `.buttonStyle(.pressable)` or `.plain` in a scroll view) and put the
/// row's identifier on the link (`AccessibilityID.Tasks.row(row.title)`). VoiceOver reads the card as one sentence
/// starting with the title and the status, with a « Passer à « … » » action; the status button stays a separate element.
///
/// ```swift
/// NavigationLink(value: AppRoute.task(groupId: row.task.groupId, taskId: row.id)) {
///     TaskRowCard(row: row, tint: model.appearance.color.accent, isBusy: model.busyTaskIds.contains(row.id)) {
///         setStatus(row.status.next, for: row)
///     }
/// }
/// .buttonStyle(.pressable)
/// .accessibilityIdentifier(AccessibilityID.Tasks.row(row.title))
/// ```
struct TaskRowCard: View {
    let row: TaskRow
    /// Ring of a task to do: the group's `ColorKey.accent`; nil: the row's group (« Mes tâches »), else the accent.
    var tint: Color?
    var isBusy: Bool
    /// Asks for the next status (`row.status.next`); nil: the status cannot be changed from the row.
    var onToggleStatus: (() -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(row: TaskRow, tint: Color? = nil, isBusy: Bool = false, onToggleStatus: (() -> Void)? = nil) {
        self.row = row
        self.tint = tint
        self.isBusy = isBusy
        self.onToggleStatus = onToggleStatus
    }

    private var canToggle: Bool { row.canChangeStatus && onToggleStatus != nil }
    private var showsAssignees: Bool { row.assigneesText != nil }
    private var ringTint: Color { tint ?? row.groupAppearance?.color.accent ?? Theme.accent }

    var body: some View {
        let isLarge = dynamicTypeSize.isAccessibilitySize
        HStack(alignment: .center, spacing: 6) {
            StatusControl(status: row.status, tint: ringTint, isBusy: isBusy, isEnabled: canToggle) {
                onToggleStatus?()
            }

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    titleLine
                    FlowLayout(spacing: 10, lineSpacing: 6) {
                        metaItems
                    }
                    if showsAssignees && isLarge {
                        assignees
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if showsAssignees && !isLarge {
                    assignees
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityActions {
                if canToggle && !isBusy {
                    Button("Passer à «\u{00A0}\(row.status.next.label)\u{00A0}»") {
                        onToggleStatus?()
                    }
                }
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: Theme.Radius.row)
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
    }

    // MARK: - Parts

    private var titleLine: some View {
        // At accessibility text sizes « Nouveau » goes under the title: beside it, it would leave the title a few
        // letters per line.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return layout {
            Text(row.title)
                .font(.headline)
                .strikethrough(row.isDone)
                .foregroundStyle(row.isDone ? Theme.textSecondary : Theme.textPrimary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if row.isNew {
                NewBadge()
            }
        }
    }

    @ViewBuilder private var metaItems: some View {
        if let group = row.groupAppearance, let name = row.groupShortName {
            Chip(group.emoji.map { "\($0) \(name)" } ?? name, tone: group.color.tone)
        }
        if let dueText = row.dueText {
            Chip(
                dueText,
                systemImage: "clock",
                tone: .ink(row.isOverdue ? Theme.danger : Theme.textSecondary),
                style: .plain,
                weight: row.isOverdue ? .bold : .semibold
            )
        }
        if row.isMyTurn {
            Chip(
                TaskRow.myTurnLabel,
                systemImage: "arrow.triangle.2.circlepath",
                tone: .ink(Theme.accent),
                style: .plain,
                weight: .bold
            )
        } else if row.hasRotation {
            Chip(
                TaskRow.rotationLabel,
                systemImage: "arrow.triangle.2.circlepath",
                tone: .ink(Theme.textSecondary),
                style: .plain
            )
        } else if let recurrence = row.recurrenceText {
            Chip(recurrence, systemImage: "arrow.triangle.2.circlepath", tone: .ink(Theme.textSecondary), style: .plain)
        }
        if let checklist = row.checklistProgress {
            Chip(
                checklist.compactText,
                systemImage: "checklist",
                tone: .ink(checklist.isComplete ? ColorKey.green.accent : ColorKey.teal.accent),
                style: .plain,
                weight: .bold
            )
        }
        if row.status == .inProgress {
            Chip(row.status.label, tone: row.status.tone)
        }
        if row.priority != .medium {
            Chip(row.priority.label, systemImage: "flag.fill", tone: row.priority.tone)
        }
    }

    @ViewBuilder private var assignees: some View {
        if row.assignees.isEmpty {
            UnassignedAvatar(size: 32)
        } else {
            AvatarStack(people: row.assignees, limit: 3, size: 32)
        }
    }

    // MARK: - VoiceOver

    /// « Payer le loyer, En cours, priorité haute, en retard, échéance hier à 18:00, assignée à Inès Dubois »;
    /// « Sortir les poubelles, nouveau, À faire, priorité moyenne, échéance aujourd’hui à 20:00, ton tour, groupe
    /// Coloc' rue des Lilas ».
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
        if row.isMyTurn {
            parts.append(TaskRow.myTurnLabel.lowercased())
        } else if row.hasRotation {
            parts.append(TaskRow.rotationLabel.lowercased())
        } else if let recurrence = row.recurrenceText {
            parts.append(recurrence.lowercased())
        }
        if let checklist = row.checklistProgress {
            parts.append("checklist \(checklist.text)")
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
}
