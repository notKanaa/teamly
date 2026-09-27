import Foundation

/// Who takes the turn of a rotating task (« à tour de rôle », docs/CONTRACTS-V2.md §6), decided exactly like the
/// server: the mocks mirror the server with it, and the UI can preview the next turn. Pure. Two server rules use it:
/// - **Spawn**, when an occurrence becomes done: `RotationHandover(after: rotation, turnUserId: turnUserId, …)`; the
///   next occurrence takes `rotation` (cleaned), `turnUserId` and `assigneeId`.
/// - **Turn handover**, when the turn holder of a pending occurrence stops being a member (leave, removal, account
///   deletion): `RotationHandover(after: rotation, turnUserId: departedUserId, …)`; the occurrence takes `turnUserId`
///   and `assigneeId` but keeps its stored rotation (the next spawn cleans it), unless `rotation` is empty: then its
///   rotation and turn are dropped. A `turn_started` event is written only when `turnUserId` is not nil.
public struct RotationHandover: Sendable, Hashable {
    /// The next occurrence's rotation: the listed users who are still members, in order; empty when fewer than
    /// `Limits.rotationMin` remain (the rotation is dropped, the task keeps repeating).
    public var rotation: [UUID]
    /// Whose turn the next occurrence is; nil when the rotation is dropped.
    public var turnUserId: UUID?
    /// The only assignee: the turn holder, or the single member left of a dropped rotation; nil when nobody listed is
    /// still a member. The server assigns it with `assigned_by` NULL (for a turn: notified « C’est ton tour »),
    /// except at a spawn when the completer is that assignee (`assigned_by` = the completer, not notified).
    public var assigneeId: UUID?

    public init(rotation: [UUID], turnUserId: UUID?, assigneeId: UUID?) {
        self.rotation = rotation
        self.turnUserId = turnUserId
        self.assigneeId = assigneeId
    }

    /// The handover after `turnUserId`'s turn: the next turn holder is the first member found cyclically after
    /// `turnUserId`'s position in `rotation` (someone who left still has a position); when `turnUserId` is not listed
    /// (or nil: a deleted account), the first member listed.
    ///
    /// - Parameters:
    ///   - rotation: the occurrence's stored rotation, which may list people who left the group.
    ///   - turnUserId: the previous turn holder: the occurrence's turn holder (spawn) or the departed user (handover).
    ///   - isMember: whether a user is (still) a member of the task's group.
    public init(after rotation: [UUID], turnUserId: UUID?, isMember: (UUID) -> Bool) {
        self.init(after: rotation, turnUserId: turnUserId, isMember: isMember, isAway: { _ in false })
    }

    /// v3 (docs/CONTRACTS-V3.md §2, absence skip): the same handover, skipping the members who are away on the
    /// occurrence's local due date: the next turn holder is the first candidate (the members in the order above) who
    /// is not away; when every candidate is away, the first candidate (the choice without the skip). A dropped rotation
    /// (fewer than `Limits.rotationMin` members) is not changed by the skip.
    ///
    /// - Parameter isAway: whether a member is away on the local due date of the occurrence that gets the turn (the new
    ///   occurrence at a spawn, the pending one at a handover).
    public init(after rotation: [UUID], turnUserId: UUID?, isMember: (UUID) -> Bool, isAway: (UUID) -> Bool) {
        let members = rotation.filter { isMember($0) }
        var candidates: [UUID] = []
        if let turnUserId, let position = rotation.firstIndex(of: turnUserId) {
            for offset in 1...rotation.count {
                let candidate = rotation[(position + offset) % rotation.count]
                if members.contains(candidate), !candidates.contains(candidate) {
                    candidates.append(candidate)
                }
            }
        } else {
            candidates = members
        }
        let turn = candidates.first { !isAway($0) } ?? candidates.first
        if members.count >= Limits.rotationMin {
            self.init(rotation: members, turnUserId: turn, assigneeId: turn)
        } else {
            self.init(rotation: [], turnUserId: nil, assigneeId: members.first)
        }
    }

    /// v3: the first turn of a new rotation (`create_task`, docs/CONTRACTS-V3.md §2): the first listed user who is not
    /// away on the occurrence's local due date; `rotation.first` when every one of them is away. nil for an empty
    /// rotation.
    public static func firstTurn(of rotation: [UUID], isAway: (UUID) -> Bool) -> UUID? {
        rotation.first { !isAway($0) } ?? rotation.first
    }
}
