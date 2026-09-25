import SwiftUI
import TeamTasksCore

/// A person as a circle in their color, with their emoji or their initials (docs/DESIGN-V2.md §5). Recommended sizes:
/// 26, 32, 40, 48, and 116 for the avatar editor. Below 60 pt the initials are shortened to their first letter.
/// Decorative: hidden from VoiceOver (the text next to it says who it is).
///
/// `ring`: a 2 pt ring the color of the surface behind, drawn outside the frame (overlapping stacks, a hero).
/// `highlight`: one more 2 pt ring outside it (the current turn of a rotation in `Theme.accent`, the podium's first).
struct AvatarView: View {
    /// Width of each ring, drawn outside the frame.
    static let ringWidth: CGFloat = 2

    let appearance: AvatarAppearance
    var size: CGFloat
    var ring: Color?
    var highlight: Color?

    init(_ appearance: AvatarAppearance, size: CGFloat = 32, ring: Color? = nil, highlight: Color? = nil) {
        self.appearance = appearance
        self.size = size
        self.ring = ring
        self.highlight = highlight
    }

    var body: some View {
        Circle()
            .fill(appearance.color.fill)
            .overlay {
                symbol
            }
            .frame(width: size, height: size)
            .background {
                rings
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder private var symbol: some View {
        if let emoji = appearance.emoji {
            Text(emoji)
                .font(.system(size: size * 0.5))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        } else {
            let initials = size < 60 ? String(appearance.initials.prefix(1)) : appearance.initials
            Text(initials)
                .font(.system(size: size * (initials.count > 1 ? 0.36 : 0.44), weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.onFill)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(size * 0.08)
        }
    }

    @ViewBuilder private var rings: some View {
        if highlight != nil || ring != nil {
            ZStack {
                if let highlight {
                    Circle()
                        .fill(highlight)
                        .padding(-2 * Self.ringWidth)
                }
                Circle()
                    .fill(ring ?? Theme.card)
                    .padding(-Self.ringWidth)
            }
        }
    }
}

/// Up to three overlapping avatars, each ringed in the color of the surface behind them, then « +N »
/// (docs/DESIGN-V2.md §5). Decorative: hidden from VoiceOver.
///
/// ```swift
/// AvatarStack(avatars: overview.memberAvatars, overflowText: overview.moreMembersText)   // a group card
/// AvatarStack(people: row.assignees, size: 32)                                            // a task row
/// AvatarStack(avatars: model.memberBadges.map(\.appearance), size: 26, surface: groupFill) // on the hero
/// ```
struct AvatarStack: View {
    let avatars: [AvatarAppearance]
    var overflowText: String?
    var size: CGFloat
    var surface: Color

    /// - Parameters:
    ///   - avatars: the circles to draw, in order (the view shows them all).
    ///   - overflowText: « +2 », drawn last in a neutral circle; nil for none.
    ///   - surface: the color behind the stack (the rings).
    init(avatars: [AvatarAppearance], overflowText: String? = nil, size: CGFloat = 30, surface: Color = Theme.card) {
        self.avatars = avatars
        self.overflowText = overflowText
        self.size = size
        self.surface = surface
    }

    /// People (`TaskRow.assignees`, `memberBadges`): all of them when they fit in `limit` circles, else the first
    /// `limit - 1` and « +N ».
    init(people: [PersonBadge], limit: Int = 3, size: CGFloat = 30, surface: Color = Theme.card) {
        let shown = people.count <= limit ? people.count : max(limit - 1, 0)
        let hidden = people.count - shown
        self.init(
            avatars: people.prefix(shown).map(\.appearance),
            overflowText: hidden > 0 ? "+\(hidden)" : nil,
            size: size,
            surface: surface
        )
    }

    var body: some View {
        HStack(spacing: -size * 0.27) {
            ForEach(Array(avatars.enumerated()), id: \.offset) { _, avatar in
                AvatarView(avatar, size: size, ring: surface)
            }
            if let overflowText {
                Text(overflowText)
                    .font(.system(size: size * 0.38, weight: .heavy, design: .rounded))
                    .foregroundStyle(SoftTone.neutral.foreground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(size * 0.06)
                    .frame(width: size, height: size)
                    .background(SoftTone.neutral.background, in: Circle())
                    .background {
                        Circle()
                            .fill(surface)
                            .padding(-AvatarView.ringWidth)
                    }
            }
        }
        .padding(.horizontal, AvatarView.ringWidth)
        .accessibilityHidden(true)
    }
}

/// The dashed circle of a task nobody is assigned to (« Personne »). Decorative.
struct UnassignedAvatar: View {
    var size: CGFloat = 32

    var body: some View {
        Circle()
            .strokeBorder(Theme.textTertiary, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A group's badge (docs/DESIGN-V2.md §5): its emoji centered on its fill, in a rounded square; without an emoji, the
/// initials of its name in white (a group symbol while the name has no letter yet: the create preview). Sizes 56 (group
/// cards), 60 (the create preview), 64 (the hero), 40 (small). `.onColor` draws a white tile (the group hero, on the
/// group's fill). Decorative: hidden from VoiceOver.
struct GroupTile: View {
    enum Style {
        /// The group's fill.
        case filled
        /// A white tile, for the hero drawn in the group's fill (initials in the fill).
        case onColor
    }

    let appearance: AvatarAppearance
    var size: CGFloat
    var style: Style

    init(_ appearance: AvatarAppearance, size: CGFloat = 56, style: Style = .filled) {
        self.appearance = appearance
        self.size = size
        self.style = style
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.33, style: .continuous)
            .fill(style == .filled ? appearance.color.fill : Color.white)
            .frame(width: size, height: size)
            .overlay {
                symbol
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder private var symbol: some View {
        if let emoji = appearance.emoji {
            Text(emoji)
                .font(.system(size: size * 0.5))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        } else if appearance.initials == Initials.unknown {
            Image(systemName: "person.2.fill")
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundStyle(style == .filled ? Theme.onFill : appearance.color.fill)
        } else {
            Text(appearance.initials)
                .font(.system(size: size * 0.36, weight: .heavy, design: .rounded))
                .foregroundStyle(style == .filled ? Theme.onFill : appearance.color.fill)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(size * 0.08)
        }
    }
}
