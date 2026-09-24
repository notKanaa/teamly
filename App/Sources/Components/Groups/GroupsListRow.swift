import SwiftUI
import TeamTasksCore

/// A group of the « Groupes » list: colored initials, name, last activity and my role.
struct GroupsListRow: View {
    let summary: GroupSummary
    /// « Dernière activité : hier à 18:00 ».
    let activityText: String

    var body: some View {
        HStack(spacing: 12) {
            GroupsInitialsBadge(
                text: GroupsInitials.make(from: summary.group.name),
                color: GroupsPalette.color(for: summary.id),
                size: 44,
                style: .roundedSquare
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.group.name)
                    .font(.headline)
                    .lineLimit(2)
                Label(activityText, systemImage: "clock")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            GroupsRoleBadge(role: summary.myRole)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
