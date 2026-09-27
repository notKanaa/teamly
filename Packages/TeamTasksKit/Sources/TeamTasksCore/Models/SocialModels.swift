import Foundation

// The v3 social features (docs/CONTRACTS-V3.md): « Relancer », « Échanger mon tour », « Bravo », comments and photos.

// MARK: - Relancer (§1)

/// One nudge (`public.task_nudges`): `fromUserId` asked `toUserId`, an assignee of the task, to do it. A call of
/// `TaskService.nudge(taskId:)` writes one row per assignee nudged.
public struct TaskNudge: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var taskId: UUID
    public var groupId: UUID
    public var fromUserId: UUID
    public var toUserId: UUID
    public var createdAt: Date

    public init(id: UUID, taskId: UUID, groupId: UUID, fromUserId: UUID, toUserId: UUID, createdAt: Date) {
        self.id = id
        self.taskId = taskId
        self.groupId = groupId
        self.fromUserId = fromUserId
        self.toUserId = toUserId
        self.createdAt = createdAt
    }
}

// MARK: - Échanger mon tour (§3)

/// A turn swap (`public.turn_swaps`): the turn holder of a pending rotating occurrence (`fromUserId`) proposes their
/// turn to another member of the rotation (`toUserId`). Accepted, the turn is `toUserId`'s; the favour is paid back
/// at a later spawn of the series, when the turn would go to `toUserId` (`repaidAt`).
public struct TurnSwap: Sendable, Hashable, Identifiable {
    public enum Status: String, Sendable, Hashable, Codable, CaseIterable {
        /// Waiting for `toUserId` (at most one pending swap per task).
        case pending
        /// `toUserId` took the turn.
        case accepted
        /// `toUserId` said no.
        case declined
        /// `fromUserId` withdrew it, or the occurrence became done or changed turn holder another way.
        case cancelled
    }

    public var id: UUID
    /// The occurrence whose turn is proposed.
    public var taskId: UUID
    public var groupId: UUID
    /// The series of the occurrence (its first occurrence's id): the repayment looks for swaps of the same series.
    public var seriesId: UUID
    public var fromUserId: UUID
    public var toUserId: UUID
    public var status: Status
    public var createdAt: Date
    /// When `toUserId` accepted or declined; nil while pending, and for a cancelled swap.
    public var respondedAt: Date?
    /// When the favour was paid back (an accepted swap only); nil before.
    public var repaidAt: Date?

    public init(
        id: UUID,
        taskId: UUID,
        groupId: UUID,
        seriesId: UUID,
        fromUserId: UUID,
        toUserId: UUID,
        status: Status,
        createdAt: Date,
        respondedAt: Date? = nil,
        repaidAt: Date? = nil
    ) {
        self.id = id
        self.taskId = taskId
        self.groupId = groupId
        self.seriesId = seriesId
        self.fromUserId = fromUserId
        self.toUserId = toUserId
        self.status = status
        self.createdAt = createdAt
        self.respondedAt = respondedAt
        self.repaidAt = repaidAt
    }

    public var isPending: Bool { status == .pending }

    /// Oldest first, then by id (the order of the swap reads).
    public static func sorted(_ swaps: [TurnSwap]) -> [TurnSwap] {
        swaps.sorted { lhs, rhs in
            lhs.createdAt != rhs.createdAt ? lhs.createdAt < rhs.createdAt : lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

// MARK: - Bravo (§4)

/// The emojis of a « Bravo » reaction, in display order (the SQL check of `activity_reactions.emoji`).
public enum ReactionEmoji: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case clap = "\u{1F44F}"
    case fire = "\u{1F525}"
    case muscle = "\u{1F4AA}"
    /// U+2764 U+FE0F: the heart with its emoji variation selector.
    case heart = "\u{2764}\u{FE0F}"
    case joy = "\u{1F602}"

    public var id: String { rawValue }

    /// French name, for the accessibility labels.
    public var label: String {
        switch self {
        case .clap: "Bravo"
        case .fire: "Au top"
        case .muscle: "Costaud"
        case .heart: "Merci"
        case .joy: "Trop drôle"
        }
    }
}

/// One reaction to an activity event (`reactions:activity_reactions(user_id,emoji)`).
public struct ActivityReaction: Sendable, Hashable {
    public var userId: UUID
    public var emoji: ReactionEmoji

    public init(userId: UUID, emoji: ReactionEmoji) {
        self.userId = userId
        self.emoji = emoji
    }

    /// Display order: the emoji's order in `ReactionEmoji.allCases`, then `userId.uuidString`.
    public static func sorted(_ reactions: [ActivityReaction]) -> [ActivityReaction] {
        let order = Dictionary(uniqueKeysWithValues: ReactionEmoji.allCases.enumerated().map { ($1, $0) })
        return reactions.sorted { lhs, rhs in
            let left = order[lhs.emoji] ?? 0
            let right = order[rhs.emoji] ?? 0
            return left != right ? left < right : lhs.userId.uuidString < rhs.userId.uuidString
        }
    }
}

/// The reactions of one emoji on one event: « 👏 2 », highlighted when the current user is among them.
public struct ReactionSummary: Sendable, Hashable, Identifiable {
    public var emoji: ReactionEmoji
    public var count: Int
    public var includesMe: Bool
    /// Who reacted, sorted by `uuidString`.
    public var userIds: [UUID]

    public init(emoji: ReactionEmoji, count: Int, includesMe: Bool, userIds: [UUID]) {
        self.emoji = emoji
        self.count = count
        self.includesMe = includesMe
        self.userIds = userIds
    }

    public var id: String { emoji.rawValue }

    /// « 👏 2 ».
    public var text: String { "\(emoji.rawValue) \(count)" }

    /// One summary per emoji used, in the order of `ReactionEmoji.allCases`.
    public static func summaries(of reactions: [ActivityReaction], currentUserId: UUID) -> [ReactionSummary] {
        ReactionEmoji.allCases.compactMap { emoji in
            let users = Set(reactions.filter { $0.emoji == emoji }.map(\.userId)).sorted { $0.uuidString < $1.uuidString }
            guard !users.isEmpty else { return nil }
            return ReactionSummary(emoji: emoji, count: users.count, includesMe: users.contains(currentUserId), userIds: users)
        }
    }
}

// MARK: - Commentaires (§5)

/// A comment on a task (`public.task_comments`). Every member of the group may comment; the author or an admin may
/// delete it.
public struct TaskComment: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var taskId: UUID
    public var groupId: UUID
    /// nil once the author's account is deleted.
    public var authorId: UUID?
    /// Trimmed, 1–`Limits.commentBodyMax` code points.
    public var body: String
    /// The members mentioned, distinct, at most `Limits.mentionsMax`, in the order sent.
    public var mentions: [UUID]
    public var createdAt: Date

    public init(
        id: UUID,
        taskId: UUID,
        groupId: UUID,
        authorId: UUID?,
        body: String,
        mentions: [UUID] = [],
        createdAt: Date
    ) {
        self.id = id
        self.taskId = taskId
        self.groupId = groupId
        self.authorId = authorId
        self.body = body
        self.mentions = mentions
        self.createdAt = createdAt
    }

    /// Oldest first, then by id (the order of `TaskService.comments(taskId:)`).
    public static func sorted(_ comments: [TaskComment]) -> [TaskComment] {
        comments.sorted { lhs, rhs in
            lhs.createdAt != rhs.createdAt ? lhs.createdAt < rhs.createdAt : lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

// MARK: - Photo preuve (§6)

/// A photo attached to a task (`public.task_photos`), stored in the private bucket `task-photos` at `path`
/// (`<group_id>/<task_id>/<uuid>.<ext>`). Displayed through a signed URL (`TaskService.photoURL(_:)`, 1 hour).
public struct TaskPhoto: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var taskId: UUID
    public var groupId: UUID
    /// The object's path in the bucket.
    public var path: String
    /// nil once the uploader's account is deleted.
    public var uploadedBy: UUID?
    public var createdAt: Date

    public init(id: UUID, taskId: UUID, groupId: UUID, path: String, uploadedBy: UUID?, createdAt: Date) {
        self.id = id
        self.taskId = taskId
        self.groupId = groupId
        self.path = path
        self.uploadedBy = uploadedBy
        self.createdAt = createdAt
    }

    /// Oldest first, then by id (the display order of `TaskItem.photos`).
    public static func sorted(_ photos: [TaskPhoto]) -> [TaskPhoto] {
        photos.sorted { lhs, rhs in
            lhs.createdAt != rhs.createdAt ? lhs.createdAt < rhs.createdAt : lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// The bucket of the task photos.
    public static let bucket = "task-photos"

    /// The folder of a task's photos: `<group_id>/<task_id>/`, lowercase ids.
    public static func folder(groupId: UUID, taskId: UUID) -> String {
        "\(groupId.uuidString.lowercased())/\(taskId.uuidString.lowercased())/"
    }

    /// A new object path for a JPEG photo of a task: `<group_id>/<task_id>/<uuid>.jpg`, lowercase ids.
    public static func newPath(groupId: UUID, taskId: UUID, objectId: UUID = UUID()) -> String {
        folder(groupId: groupId, taskId: taskId) + objectId.uuidString.lowercased() + ".jpg"
    }
}
