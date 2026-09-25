import Foundation

// v2 presentation values shared by the view models (docs/CONTRACTS-V2.md): the colors and emojis of people and
// groups, people as badges, checklist progress, and the curated emojis of the pickers.

extension ColorKey {
    /// French name of the color, for the accessibility labels of the pickers.
    public var label: String {
        switch self {
        case .indigo: "Indigo"
        case .violet: "Violet"
        case .blue: "Bleu"
        case .teal: "Turquoise"
        case .green: "Vert"
        case .amber: "Ambre"
        case .orange: "Orange"
        case .coral: "Corail"
        case .pink: "Rose"
        }
    }
}

/// How a person or a group is drawn: its color (resolved: automatic colors already applied), and its emoji or else
/// its initials.
public struct AvatarAppearance: Sendable, Hashable {
    public var color: ColorKey
    /// Drawn instead of the initials when set.
    public var emoji: String?
    /// « CM », « CR », « ? ».
    public var initials: String

    public init(color: ColorKey, emoji: String?, initials: String) {
        self.color = color
        self.emoji = emoji
        self.initials = initials
    }

    /// What to draw on the color: the emoji, else the initials.
    public var symbol: String { emoji ?? initials }

    public var showsEmoji: Bool { emoji != nil }

    /// Someone the app does not know (any more): the automatic color of the id, and « ? ».
    public static func unknown(id: UUID) -> AvatarAppearance {
        AvatarAppearance(color: ColorKey.automatic(for: id), emoji: nil, initials: Initials.unknown)
    }
}

extension UserProfile {
    /// The avatar: `resolvedColor`, and the emoji or the initials of the display name.
    public var appearance: AvatarAppearance {
        AvatarAppearance(color: resolvedColor, emoji: avatarEmoji, initials: Initials.of(displayName))
    }
}

extension TeamGroup {
    /// The group's badge: `resolvedColor`, and the emoji or the initials of the name.
    public var appearance: AvatarAppearance {
        AvatarAppearance(color: resolvedColor, emoji: emoji, initials: Initials.of(name))
    }
}

extension TaskItem {
    /// The badge of the task's group from the fields filled by `TaskService.myTasks` (`groupName`, `groupColor`,
    /// `groupEmoji`); nil when `groupName` is not filled.
    public var groupAppearance: AvatarAppearance? {
        guard let groupName else { return nil }
        return AvatarAppearance(
            color: ColorKey.resolved(groupColor, for: groupId), emoji: groupEmoji, initials: Initials.of(groupName)
        )
    }
}

/// The curated emojis of the pickers. They all pass `InputValidation.emoji(_:)` unchanged (the server's validation
/// is only a safety net, docs/CONTRACTS-V2.md §1).
public enum EmojiChoices {
    /// Avatar symbols, offered after the initials.
    public static let avatars: [String] = [
        "\u{1F98A}", "\u{1F43C}", "\u{1F438}", "\u{1F981}", "\u{1F419}", "\u{1F33B}", "\u{26A1}", "\u{1F431}",
        "\u{1F436}", "\u{1F43B}", "\u{1F428}", "\u{1F42F}", "\u{1F435}", "\u{1F984}", "\u{1F422}", "\u{1F41D}",
        "\u{1F308}", "\u{1F335}", "\u{1F340}", "\u{1F355}", "\u{2B50}", "\u{1F525}", "\u{1F680}",
    ]

    /// Group emojis (« ⚽ » without variation selector, as in the demo data).
    public static let groups: [String] = [
        "\u{1F3E0}", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", "\u{26BD}", "\u{1F393}", "\u{1F4BC}",
        "\u{1F389}", "\u{1F3E1}", "\u{1F373}", "\u{1F9F9}", "\u{1F6D2}", "\u{1F331}", "\u{1F43E}", "\u{1F3B5}",
        "\u{1F3AE}", "\u{2708}\u{FE0F}", "\u{1F3D6}\u{FE0F}", "\u{1F6B2}", "\u{1F4DA}",
    ]
}

/// A person as the screens show them: names and avatar.
public struct PersonBadge: Sendable, Hashable, Identifiable {
    public var id: UUID
    /// Display name; `MemberDirectory.formerMemberName` for someone who is not a member (any more).
    public var name: String
    /// First name, or the display name when another member has the same first name (`MemberDirectory.shortNames`).
    public var shortName: String
    public var appearance: AvatarAppearance
    public var isMe: Bool
    /// False for someone who left the group, or a deleted account.
    public var isMember: Bool

    public init(id: UUID, name: String, shortName: String, appearance: AvatarAppearance, isMe: Bool, isMember: Bool) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.appearance = appearance
        self.isMe = isMe
        self.isMember = isMember
    }
}

/// Progress of a task's checklist.
public struct ChecklistProgress: Sendable, Hashable {
    public var done: Int
    public var total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }

    /// The progress of `items`; nil for an empty checklist.
    public init?(_ items: [ChecklistItem]) {
        guard !items.isEmpty else { return nil }
        self.init(done: items.filter(\.isDone).count, total: items.count)
    }

    /// 0…1.
    public var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }

    public var isComplete: Bool { total > 0 && done == total }

    /// « 2/5 », for rows.
    public var compactText: String { "\(done)/\(total)" }

    /// « 2 sur 5 », for the task screen.
    public var text: String { "\(done) sur \(total)" }
}

extension ActivityEvent.Kind {
    /// SF Symbols name of the event, drawn when no person is shown.
    public var systemImage: String {
        switch self {
        case .taskCreated: "plus.circle"
        case .taskCompleted: "checkmark.circle.fill"
        case .turnStarted: "arrow.triangle.2.circlepath"
        case .checklistItemDone: "checklist.checked"
        case .memberJoined: "person.badge.plus"
        case .memberLeft: "person.badge.minus"
        }
    }
}

extension MemberDirectory {
    /// The short name of every member: the first name (`FrenchText.firstName(of:)`), or the whole display name when
    /// another member has the same first name (compared with `NameOrder.key`).
    public var shortNames: [UUID: String] {
        let people = members.map { member in
            (id: member.user.id, first: FrenchText.firstName(of: member.user.displayName), full: member.user.displayName)
        }
        var counts: [String: Int] = [:]
        for person in people {
            counts[NameOrder.key(person.first), default: 0] += 1
        }
        var names: [UUID: String] = [:]
        for person in people {
            let isShared = counts[NameOrder.key(person.first), default: 0] > 1
            names[person.id] = isShared || person.first.isEmpty ? person.full : person.first
        }
        return names
    }

    /// Short name of a member (`shortNames`), `formerMemberName` when unknown or nil.
    public func shortName(of userId: UUID?) -> String {
        guard let userId, let name = shortNames[userId] else { return Self.formerMemberName }
        return name
    }

    /// The badge of a member, or of someone who is not a member (« Ancien membre », « ? »).
    public func badge(of userId: UUID) -> PersonBadge {
        badge(of: userId, shortNames: shortNames)
    }

    /// The badges of `userIds`: the current user first, then by display name (`NameOrder`), then id.
    public func badges(of userIds: [UUID]) -> [PersonBadge] {
        let shortNames = shortNames
        return Set(userIds).map { badge(of: $0, shortNames: shortNames) }.sorted { lhs, rhs in
            if lhs.isMe != rhs.isMe { return lhs.isMe }
            if let order = NameOrder.precedes(lhs.name, rhs.name) { return order }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// Every member's badge, in the order of `members`.
    public var memberBadges: [PersonBadge] {
        let shortNames = shortNames
        return members.map { badge(of: $0.user.id, shortNames: shortNames) }
    }

    func badge(of userId: UUID, shortNames: [UUID: String]) -> PersonBadge {
        guard let member = members.first(where: { $0.user.id == userId }) else {
            return PersonBadge(
                id: userId,
                name: Self.formerMemberName,
                shortName: Self.formerMemberName,
                appearance: .unknown(id: userId),
                isMe: userId == currentUserId,
                isMember: false
            )
        }
        return PersonBadge(
            id: userId,
            name: member.user.displayName,
            shortName: shortNames[userId] ?? member.user.displayName,
            appearance: member.user.appearance,
            isMe: userId == currentUserId,
            isMember: true
        )
    }
}
