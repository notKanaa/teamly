import SwiftUI
import TeamTasksCore

/// A group of the « Groupes » list: colored initials, name and my role, then the last activity.
///
/// The role capsule shares the name's line, so the last activity gets the whole width (two lines at most). At
/// accessibility text sizes the capsule goes under the name.
struct GroupsListRow: View {
    let summary: GroupSummary
    /// « Dernière activité : hier à 18:00 ».
    let activityText: String

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let isLarge = typeSize.isAccessibilitySize
        let titleLayout = isLarge
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        HStack(spacing: 12) {
            GroupsInitialsBadge(
                text: GroupsInitials.make(from: summary.group.name),
                color: GroupsPalette.color(for: summary.id),
                size: 44,
                style: .roundedSquare
            )
            VStack(alignment: .leading, spacing: 3) {
                titleLayout {
                    Text(summary.group.name)
                        .font(.headline)
                        .lineLimit(isLarge ? nil : 2)
                    if !isLarge {
                        Spacer(minLength: 0)
                    }
                    GroupsRoleBadge(role: summary.myRole)
                        .fixedSize()
                }
                Label(activityText, systemImage: "clock")
                    .labelStyle(.inlineIcon)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(isLarge ? nil : 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
