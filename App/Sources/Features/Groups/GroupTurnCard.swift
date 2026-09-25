import SwiftUI
import TeamTasksCore

/// A card of « À qui le tour ? » (docs/DESIGN-V2.md §7.4): the rotating task with its due date (red when overdue),
/// whose turn it is — « Toi » in the accent, ringed, when it is the user's — and who comes next (« puis Lucas »).
/// About 236 pt wide, growing with Dynamic Type up to 320 pt. One VoiceOver element; the caller's `NavigationLink`
/// opens the task.
struct GroupTurnCardView: View {
    let card: TurnCard
    /// The group's soft pair, for the rotation tile.
    let tone: SoftTone

    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 236

    init(card: TurnCard, tone: SoftTone) {
        self.card = card
        self.tone = tone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                IconTile(systemImage: "arrow.triangle.2.circlepath", tone: tone, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.title)
                        .font(Font.subheadline.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let due = card.dueText {
                        Text(due)
                            .font(Font.footnote.weight(card.isOverdue ? .bold : .regular))
                            .foregroundStyle(card.isOverdue ? Theme.danger : Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            FlowLayout(spacing: 8, lineSpacing: 4) {
                turnHolder
                if let next = card.nextText {
                    Text(next)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(14)
        .frame(width: min(width, 320), alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .cardSurface(radius: Theme.Radius.row)
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// The avatar and the name of whose turn it is.
    @ViewBuilder private var turnHolder: some View {
        if let current = card.current {
            HStack(spacing: 8) {
                AvatarView(
                    current.appearance,
                    size: 28,
                    ring: card.isMyTurn ? Theme.card : nil,
                    highlight: card.isMyTurn ? Theme.accent : nil
                )
                .padding(card.isMyTurn ? 2 * AvatarView.ringWidth : 0)
                Text(current.isMe ? MemberDirectory.meName : current.shortName)
                    .font(Font.subheadline.weight(.heavy))
                    .foregroundStyle(card.isMyTurn ? Theme.accent : Theme.textPrimary)
            }
        } else {
            HStack(spacing: 8) {
                UnassignedAvatar(size: 28)
                Text("Personne")
                    .font(Font.subheadline.weight(.heavy))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    /// « Sortir les poubelles, échéance aujourd’hui à 20:00, c’est ton tour, puis Lucas ».
    private var accessibilityText: String {
        var parts = [card.title]
        if let due = card.dueText {
            let dueText = "échéance \(due.lowercased())"
            parts.append(card.isOverdue ? "en retard, \(dueText)" : dueText)
        }
        if let current = card.current {
            if current.isMe {
                parts.append("c’est ton tour")
            } else {
                parts.append("au tour \(FrenchText.de(current.shortName))")
            }
        } else {
            parts.append("personne n’a le tour")
        }
        if let next = card.nextText {
            parts.append(next)
        }
        return parts.joined(separator: ", ")
    }
}
