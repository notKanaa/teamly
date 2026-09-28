import SwiftUI
import TeamTasksCore

/// The « Activité » tab of a group (docs/DESIGN-V2.md §7.5): the week's recap (`GroupRecapCard`: « Cette semaine », its
/// range, the total done, the podium, the streak), then « Fil d’activité », the events by day. An event about a task
/// the group screen knows opens it. v3: the v3 kinds (nudges, absences, swaps, comments with their excerpt, photos) and
/// the « Bravo » chips under each event (a tap toggles the user's reaction; a long press offers the 5 emojis, also as
/// VoiceOver actions).
///
/// Loads when shown and reloads on the group's change signal (`.task(id: model.refreshKey)`); the group screen owns
/// the pull to refresh and leaves when the model `isGone`.
struct GroupActivityContent: View {
    let model: GroupActivityViewModel
    let groupId: UUID
    /// The tasks the group screen has loaded: an event about one of them opens it (the others may be deleted).
    let openableTaskIds: Set<UUID>

    init(model: GroupActivityViewModel, groupId: UUID, openableTaskIds: Set<UUID>) {
        self.model = model
        self.groupId = groupId
        self.openableTaskIds = openableTaskIds
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .task(id: model.refreshKey) {
                await model.load()
            }
            .shellErrorAlert(model)
    }

    @ViewBuilder private var content: some View {
        if model.loadState.isLoaded {
            VStack(alignment: .leading, spacing: 18) {
                GroupRecapCard(model: model)
                SectionTitle(GroupActivityViewModel.feedTitle, size: .large)
                    .padding(.top, 4)
                feed
            }
        } else {
            GroupsLoadStateView(loadState: model.loadState) {
                Task { await model.reload() }
            }
        }
    }

    @ViewBuilder private var feed: some View {
        if model.isFeedEmpty {
            GroupsStateView(
                systemImage: "bolt.horizontal.circle",
                title: "Aucune activité",
                message: GroupActivityViewModel.emptyFeedMessage
            )
            .cardSurface()
            .accessibilityIdentifier(AccessibilityID.Groups.activityEmpty)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(model.sections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(section.title)
                        feedCard(section.rows)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.Groups.activityFeed)
        }
    }

    /// The events of one day in a card, separated by hairlines.
    private func feedCard(_ rows: [ActivityFeedRow]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Rectangle()
                        .fill(Theme.hairline)
                        .frame(height: 1)
                        .accessibilityHidden(true)
                }
                feedEntry(row)
            }
        }
        .padding(.horizontal, Theme.Spacing.cardPadding)
        .padding(.vertical, 4)
        .cardSurface()
    }

    /// v3: an event with its « Bravo » chips under it; a long press offers the 5 reactions.
    private func feedEntry(_ row: ActivityFeedRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            feedRow(row)
                .accessibilityActions {
                    if model.canReact {
                        ForEach(ReactionEmoji.allCases) { emoji in
                            Button(reactionTitle(emoji, on: row)) {
                                toggle(emoji, on: row)
                            }
                        }
                    }
                }
            if !row.reactions.isEmpty {
                ActivityReactionChips(row: row, canReact: model.canReact) { emoji in
                    toggle(emoji, on: row)
                }
                .padding(.leading, 50)
                .padding(.bottom, 10)
                .padding(.top, -4)
            }
        }
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contextMenu {
            if model.canReact {
                ForEach(ReactionEmoji.allCases) { emoji in
                    Button {
                        toggle(emoji, on: row)
                    } label: {
                        Text(reactionTitle(emoji, on: row))
                    }
                }
            }
        }
    }

    /// « 👏 Bravo », « 👏 Retirer Bravo » when the user already reacted so.
    private func reactionTitle(_ emoji: ReactionEmoji, on row: ActivityFeedRow) -> String {
        model.hasReacted(emoji, to: row.id) ? "\(emoji.rawValue) Retirer «\u{00A0}\(emoji.label)\u{00A0}»" : "\(emoji.rawValue) \(emoji.label)"
    }

    private func toggle(_ emoji: ReactionEmoji, on row: ActivityFeedRow) {
        Task { await model.toggleReaction(emoji, on: row.id) }
    }

    @ViewBuilder private func feedRow(_ row: ActivityFeedRow) -> some View {
        if let taskId = row.taskId, openableTaskIds.contains(taskId) {
            NavigationLink(value: AppRoute.task(groupId: groupId, taskId: taskId)) {
                GroupActivityRow(row: row)
            }
            .buttonStyle(.plain)
        } else {
            GroupActivityRow(row: row)
        }
    }
}

/// v3 « Bravo » (docs/CONTRACTS-V3.md §4): the reactions of an event as chips (« 👏 2 »), the user's own on the soft
/// accent; a tap adds or removes the user's reaction. Each chip is a 44 pt button whose value says the count
/// (« 2 réactions, dont la tienne »).
struct ActivityReactionChips: View {
    let row: ActivityFeedRow
    let canReact: Bool
    let onToggle: (ReactionEmoji) -> Void

    init(row: ActivityFeedRow, canReact: Bool, onToggle: @escaping (ReactionEmoji) -> Void) {
        self.row = row
        self.canReact = canReact
        self.onToggle = onToggle
    }

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 0) {
            ForEach(row.reactions) { summary in
                Button {
                    onToggle(summary.emoji)
                } label: {
                    HStack(spacing: 4) {
                        Text(summary.emoji.rawValue)
                        Text("\(summary.count)")
                            .font(Font.footnote.weight(.heavy))
                            .monospacedDigit()
                    }
                    .foregroundStyle(summary.includesMe ? Theme.accentSoftText : Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 30)
                    .background(
                        summary.includesMe ? Theme.accentSoft : Theme.background,
                        in: Capsule()
                    )
                    .overlay {
                        if summary.includesMe {
                            Capsule()
                                .strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1)
                        }
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .disabled(!canReact)
                .accessibilityLabel("\(summary.emoji.rawValue) \(summary.emoji.label)")
                .accessibilityValue(summary.accessibilityValue)
                .accessibilityHint(summary.includesMe ? "Retire ta réaction" : "Ajoute ta réaction")
                .accessibilityAddTraits(summary.includesMe ? .isSelected : [])
                .accessibilityIdentifier(
                    AccessibilityID.Social.reactionChip(row.event.taskTitle ?? "\(row.id)", summary.emoji.label)
                )
            }
        }
    }
}

/// « Cette semaine » (docs/DESIGN-V2.md §7.5): the week's range and the total done, then the podium (2nd, 1st, 3rd) or,
/// when nothing was done yet, a message, and the streak of the leader (a flame on the amber soft color).
struct GroupRecapCard: View {
    let model: GroupActivityViewModel

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(model: GroupActivityViewModel) {
        self.model = model
    }

    var body: some View {
        Card(padding: 18, spacing: 16) {
            header
            if model.isRecapEmpty {
                HStack(alignment: .center, spacing: 12) {
                    IconTile(systemImage: "trophy.fill", tone: ColorKey.amber.tone, size: 36)
                    Text(RecapText.emptyMessage)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                PodiumView(entries: model.podiumStageOrder)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(AccessibilityID.Groups.activityPodium)
            }
            if let streak = model.streakText {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "flame.fill")
                        .foregroundStyle(ColorKey.orange.accent)
                        .accessibilityHidden(true)
                    Text(GroupActivityText.attributed(streak))
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    ColorKey.amber.tone.background,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityID.Groups.activityStreak)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Groups.activityRecap)
    }

    /// « Cette semaine » and the range, with the big total on the trailing side (under them at accessibility sizes).
    @ViewBuilder private var header: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                titles
                total(alignment: .leading)
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                titles
                    .frame(maxWidth: .infinity, alignment: .leading)
                total(alignment: .trailing)
            }
        }
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(GroupActivityViewModel.recapTitle)
                .font(.rounded(.title2))
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            if let range = model.recapRangeText {
                Text(range)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func total(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            Text("\(model.recapTotal)")
                .font(.roundedNumber(.largeTitle))
                .foregroundStyle(Theme.accent)
            Text(model.recapTotalLabel)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One event of the feed (docs/DESIGN-V2.md §7.5): the member's avatar with the event's badge (a 20 pt circle in the
/// kind's color, with its symbol) — or the event's tile when the person is not a member —, the sentence with the
/// names in bold, and the time. One VoiceOver element. At accessibility text sizes the time goes under the sentence.
struct GroupActivityRow: View {
    let row: ActivityFeedRow

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(row: ActivityFeedRow) {
        self.row = row
    }

    var body: some View {
        let isLarge = dynamicTypeSize.isAccessibilitySize
        HStack(alignment: isLarge ? .top : .center, spacing: 12) {
            leading
            if isLarge {
                VStack(alignment: .leading, spacing: 4) {
                    sentence
                    time
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                sentence
                    .frame(maxWidth: .infinity, alignment: .leading)
                time
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// The sentence, then (v3) the excerpt of a comment.
    private var sentence: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(GroupActivityText.attributed(row.text))
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = row.detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// VoiceOver: the sentence, the excerpt, the time.
    private var accessibilityText: String {
        [row.text.plainText, row.detail, row.timeText].compactMap { $0 }.joined(separator: ", ")
    }

    private var time: some View {
        Text(row.timeText)
            .font(.footnote)
            .foregroundStyle(Theme.textSecondary)
            .monospacedDigit()
    }

    @ViewBuilder private var leading: some View {
        if let person = row.person {
            AvatarView(person.appearance, size: 38)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: row.activityKind.feedBadgeSymbol)
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Theme.onFill)
                        .frame(width: 20, height: 20)
                        .background(row.activityKind.feedBadgeFill, in: Circle())
                        .background {
                            Circle()
                                .fill(Theme.card)
                                .padding(-2)
                        }
                        .offset(x: 5, y: 5)
                        .accessibilityHidden(true)
                }
                .padding(.trailing, 5)
                .padding(.bottom, 5)
        } else {
            IconTile(systemImage: row.systemImage, tone: row.activityKind.feedTone, size: 38)
        }
    }
}

/// Drawing an `EmphasizedText` of the core (the feed, the streak).
enum GroupActivityText {
    /// `text` with its emphasized runs (the people) in bold.
    static func attributed(_ text: EmphasizedText) -> AttributedString {
        var result = AttributedString()
        for run in text.runs {
            var part = AttributedString(run.text)
            if run.isEmphasized {
                part.inlinePresentationIntent = .stronglyEmphasized
            }
            result.append(part)
        }
        return result
    }
}

/// The v2 and v3 kinds of the feed (docs/CONTRACTS-V3.md §7): a relaunch is red, an absence blue, a swap teal, a
/// comment violet, a photo green.
extension ActivityKind {
    /// The glyph of the event's badge on a member's avatar.
    var feedBadgeSymbol: String {
        switch self {
        case .taskCreated: "plus"
        case .taskCompleted: "checkmark"
        case .turnStarted: "arrow.triangle.2.circlepath"
        case .checklistItemDone: "checklist"
        case .memberJoined: "person.fill.badge.plus"
        case .memberLeft: "person.fill.badge.minus"
        case .taskNudged: "bell.fill"
        case .memberAway: "airplane"
        case .turnSwapped: "arrow.left.arrow.right"
        case .commentAdded: "text.bubble.fill"
        case .photoAdded: "camera.fill"
        }
    }

    /// The badge's fill (a white glyph on it).
    var feedBadgeFill: Color {
        switch self {
        case .taskCreated: Theme.accentFill
        case .taskCompleted: ColorKey.green.fill
        case .turnStarted: ColorKey.coral.fill
        case .checklistItemDone: ColorKey.teal.fill
        case .memberJoined: ColorKey.blue.fill
        case .memberLeft: SoftTone.neutral.fill
        case .taskNudged: SoftTone.danger.fill
        case .memberAway: ColorKey.blue.fill
        case .turnSwapped: ColorKey.teal.fill
        case .commentAdded: ColorKey.violet.fill
        case .photoAdded: ColorKey.green.fill
        }
    }

    /// The soft pair of the event's tile, when the person is not a member.
    var feedTone: SoftTone {
        switch self {
        case .taskCreated: SoftTone.accent
        case .taskCompleted: SoftTone.done
        case .turnStarted: ColorKey.coral.tone
        case .checklistItemDone: ColorKey.teal.tone
        case .memberJoined: ColorKey.blue.tone
        case .memberLeft: SoftTone.neutral
        case .taskNudged: SoftTone.danger
        case .memberAway: ColorKey.blue.tone
        case .turnSwapped: ColorKey.teal.tone
        case .commentAdded: ColorKey.violet.tone
        case .photoAdded: ColorKey.green.tone
        }
    }
}
