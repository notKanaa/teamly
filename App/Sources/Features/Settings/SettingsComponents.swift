import SwiftUI
import TeamTasksCore

// The building blocks of « Réglages » (docs/DESIGN-V2.md §7.8, the SettingsMain mockup): titled sections of rows on a
// card, rows led by an icon tile, the quick tiles and the figures of the profile card.

/// A titled block of « Réglages »: the small section title, then its rows on one card (padding 4 × 16). Put a
/// `SettingsDivider` between two rows.
struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title)
            VStack(spacing: 0) {
                content
            }
            .padding(.horizontal, Theme.Spacing.cardPadding)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
    }
}

/// The hairline between two rows of a card.
struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// A row of a « Réglages » card: an icon tile, the title (and an optional subtitle), then an optional trailing text
/// and a chevron. At least 56 pt tall; the texts wrap. Put it in a `Button` or a `NavigationLink`.
struct SettingsRowLabel: View {
    let title: String
    var subtitle: String?
    let systemImage: String
    var tone: SoftTone
    var titleColor: Color
    var trailing: String?
    var trailingColor: Color
    var trailingWeight: Font.Weight
    var showsChevron: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String,
        tone: SoftTone,
        titleColor: Color = Theme.textPrimary,
        trailing: String? = nil,
        trailingColor: Color = Theme.textSecondary,
        trailingWeight: Font.Weight = .regular,
        showsChevron: Bool = false
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tone = tone
        self.titleColor = titleColor
        self.trailing = trailing
        self.trailingColor = trailingColor
        self.trailingWeight = trailingWeight
        self.showsChevron = showsChevron
    }

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemImage: systemImage, tone: tone, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Font.body.weight(.bold))
                    .foregroundStyle(titleColor)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
                // At accessibility sizes the trailing text goes under the title.
                if let trailing, dynamicTypeSize.isAccessibilitySize {
                    trailingText(trailing)
                }
            }
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let trailing, !dynamicTypeSize.isAccessibilitySize {
                trailingText(trailing)
                    .multilineTextAlignment(.trailing)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(Font.footnote.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }

    private func trailingText(_ text: String) -> some View {
        Text(text)
            .font(Font.subheadline.weight(trailingWeight))
            .foregroundStyle(trailingColor)
    }
}

/// A quick tile of « Réglages » (Notifications, Rappels, Récap du lundi, Heures calmes): a 36 pt icon tile (and an
/// optional accessory at its right, such as a switch), then the title and its status. It fills the height of its grid
/// row. Put it in a `Button`, a `Menu`, or use it as is with a switch accessory.
struct SettingsQuickTile<Accessory: View>: View {
    let title: String
    let status: String
    var statusColor: Color
    let systemImage: String
    var tone: SoftTone
    let accessory: Accessory

    init(
        _ title: String,
        status: String,
        statusColor: Color = Theme.textSecondary,
        systemImage: String,
        tone: SoftTone,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.status = status
        self.statusColor = statusColor
        self.systemImage = systemImage
        self.tone = tone
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                IconTile(systemImage: systemImage, tone: tone, size: 36)
                Spacer(minLength: 0)
                accessory
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Font.subheadline.weight(.heavy))
                    .foregroundStyle(Theme.textPrimary)
                Text(status)
                    .font(Font.footnote.weight(.semibold))
                    .foregroundStyle(statusColor)
            }
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardSurface()
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

extension SettingsQuickTile where Accessory == EmptyView {
    init(
        _ title: String,
        status: String,
        statusColor: Color = Theme.textSecondary,
        systemImage: String,
        tone: SoftTone
    ) {
        self.init(title, status: status, statusColor: statusColor, systemImage: systemImage, tone: tone) {
            EmptyView()
        }
    }
}

/// A figure of the profile card (« 23 tâches ce mois »): the number in rounded heavy type, an optional leading symbol,
/// and its label, on a soft tone. One VoiceOver element.
struct SettingsStatTile: View {
    let value: String
    let label: String
    var systemImage: String?
    var tone: SoftTone

    init(value: String, label: String, systemImage: String? = nil, tone: SoftTone) {
        self.value = value
        self.label = label
        self.systemImage = systemImage
        self.tone = tone
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(Font.headline.weight(.bold))
                        .accessibilityHidden(true)
                }
                Text(value)
                    .font(.roundedNumber(.title2))
            }
            Text(label)
                .font(Font.caption.weight(.bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(tone.foreground)
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tone.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(label)")
    }
}

/// A small capsule badge (« v2 » of « Nouveautés »): white bold text on the accent fill.
struct SettingsBadge: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(Font.caption.weight(.heavy))
            .foregroundStyle(Theme.onFill)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.accentFill, in: Capsule())
    }
}
