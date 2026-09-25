import SwiftUI
import TeamTasksCore

/// A group of the « Groupes » list (docs/DESIGN-V2.md §7.2): its tile, its name, « 3 membres · 4 à faire » and the
/// members' avatars, then the week's progress in the group's color (« Cette semaine », « 9 faites sur 13 »).
/// Without figures (`overview` nil: not read yet, or the read failed) the card shows the user's role instead.
/// One VoiceOver element (the caller's `NavigationLink` makes it a button). At accessibility text sizes the tile and
/// the avatars share a line above the name.
struct GroupCard: View {
    let summary: GroupSummary
    let overview: GroupOverview?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(summary: GroupSummary, overview: GroupOverview?) {
        self.summary = summary
        self.overview = overview
    }

    var body: some View {
        let appearance = summary.group.appearance
        let isLarge = dynamicTypeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: 14) {
            if isLarge {
                HStack(alignment: .center, spacing: 12) {
                    GroupTile(appearance, size: 56)
                    Spacer(minLength: 8)
                    avatars
                }
                titles
            } else {
                HStack(alignment: .center, spacing: 14) {
                    GroupTile(appearance, size: 56)
                    titles
                        .frame(maxWidth: .infinity, alignment: .leading)
                    avatars
                }
            }
            if let overview {
                week(overview, tint: appearance.color.fill, isLarge: isLarge)
            }
        }
        .padding(Theme.Spacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(summary.group.name)
                .font(.rounded(.headline, weight: .heavy))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var avatars: some View {
        if let overview, !overview.memberAvatars.isEmpty {
            AvatarStack(avatars: overview.memberAvatars, overflowText: overview.moreMembersText)
        }
    }

    /// « 3 membres · 4 à faire », or the role when the figures are missing.
    private var subtitle: String {
        if let overview {
            return overview.summaryText
        }
        return summary.myRole == .admin ? "Tu es admin" : "Tu es membre"
    }

    private func week(_ overview: GroupOverview, tint: Color, isLarge: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if isLarge {
                Text(GroupOverview.weekTitle)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                Text(overview.weekProgressText)
                    .font(Font.footnote.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(GroupOverview.weekTitle)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 8)
                    Text(overview.weekProgressText)
                        .font(Font.footnote.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            ProgressBar(value: overview.weekProgress, tint: tint, track: Theme.hairline)
        }
    }
}

/// The dashed « Rejoindre un groupe » card at the end of the groups list (docs/DESIGN-V2.md §7.2): a key tile, the
/// title and « Avec un code d’invitation ». A button; the caller puts its identifier on it.
struct JoinGroupCard: View {
    let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                IconTile(systemImage: "key.fill", tone: .accent, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rejoindre un groupe")
                        .font(Font.body.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Avec un code d’invitation")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(Font.footnote.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Theme.Spacing.cardPadding)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.trackStrong, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("Rejoindre un groupe")
        .accessibilityHint("Avec un code d’invitation")
    }
}
