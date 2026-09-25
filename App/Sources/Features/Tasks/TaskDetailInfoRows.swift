import SwiftUI
import TeamTasksCore

/// Row insets of the task screen's cards (its `List` sections): tighter than the system's, as on the mockups.
enum TaskDetailInsets {
    /// An info row: 52 pt for one line.
    static var infoRow: EdgeInsets { EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16) }
    /// The title of the checklist and its progress.
    static var checklistHeader: EdgeInsets { EdgeInsets(top: 14, leading: 16, bottom: 6, trailing: 16) }
    /// A checklist item or « Ajouter un élément »: 44 pt.
    static var checklistItem: EdgeInsets { EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16) }
    /// The last row of the checklist.
    static var checklistLast: EdgeInsets { EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16) }
}

/// A row of the task screen's info card (docs/DESIGN-V2.md §7.6): an icon tile, the title (« Échéance ») and its value
/// on the same line when they fit, the value under the title otherwise (long values, large text sizes), then an
/// optional detail under them (the next dates of a repetition, the turn order). VoiceOver reads the row as one element.
struct TaskInfoRow<Value: View, Detail: View>: View {
    let title: String
    let systemImage: String
    let tone: SoftTone
    let value: Value
    let detail: Detail

    /// The scale of `IconTile` (its side grows with Dynamic Type, ×1.5 at most): the first line is centered on it.
    @ScaledMetric(relativeTo: .body) private var tileScale: CGFloat = 1

    init(
        _ title: String,
        systemImage: String,
        tone: SoftTone,
        @ViewBuilder value: () -> Value,
        @ViewBuilder detail: () -> Detail
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tone = tone
        self.value = value()
        self.detail = detail()
    }

    private static var tileSize: CGFloat { 32 }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(systemImage: systemImage, tone: tone, size: Self.tileSize)
            VStack(alignment: .leading, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 12) {
                        titleText
                        Spacer(minLength: 8)
                        value
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        titleText
                        value
                    }
                }
                .frame(minHeight: Self.tileSize * min(max(tileScale, 1), 1.5))
                detail
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var titleText: some View {
        Text(title)
            .font(.body)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension TaskInfoRow where Detail == EmptyView {
    init(_ title: String, systemImage: String, tone: SoftTone, @ViewBuilder value: () -> Value) {
        self.init(title, systemImage: systemImage, tone: tone, value: value) {
            EmptyView()
        }
    }
}

/// The value of an info row: body semibold in `textPrimary` (or `color`), wrapping.
struct TaskInfoValue: View {
    let text: String
    var color: Color

    init(_ text: String, color: Color = Theme.textPrimary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(Font.body.weight(.semibold))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The turn order of a rotation (« À tour de rôle »): the avatars from the current turn on, the current one larger and
/// ringed in the accent, with a chevron between two. Wraps when the rotation is long. Decorative (the row's text says
/// the same: `TaskDetailViewModel.rotationText`).
struct TaskRotationChain: View {
    let entries: [RotationEntry]

    init(entries: [RotationEntry]) {
        self.entries = entries
    }

    var body: some View {
        FlowLayout(spacing: 4, lineSpacing: 6) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(Font.caption.weight(.heavy))
                        .foregroundStyle(Theme.textSecondary)
                }
                if entry.isCurrentTurn {
                    AvatarView(entry.person.appearance, size: 30, ring: Theme.card, highlight: Theme.accent)
                        .padding(2 * AvatarView.ringWidth)
                } else {
                    AvatarView(entry.person.appearance, size: 26)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The people a task is assigned to, one per line with their avatar: « Camille Martin (toi) », « Lucas Bernard »;
/// « Non assignée » with the dashed circle when nobody is.
struct TaskAssigneesList: View {
    let people: [PersonBadge]

    init(people: [PersonBadge]) {
        self.people = people
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if people.isEmpty {
                HStack(spacing: 8) {
                    UnassignedAvatar(size: 26)
                    TaskInfoValue(MemberDirectory.unassignedText, color: Theme.textSecondary)
                }
            } else {
                ForEach(people) { person in
                    HStack(spacing: 8) {
                        AvatarView(person.appearance, size: 26)
                        TaskInfoValue(Self.displayName(of: person))
                    }
                }
            }
        }
    }

    /// « Camille Martin (toi) » for the current user, as in « Membres » (« Toi » until the members are loaded).
    static func displayName(of person: PersonBadge) -> String {
        guard person.isMe else { return person.name }
        return person.isMember ? "\(person.name) (toi)" : MemberDirectory.meName
    }
}
