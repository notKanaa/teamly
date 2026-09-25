import Foundation
import Observation

/// « Apparence » sheet of a group, for its admins (`GroupDetailViewModel.makeAppearanceEditor()`): the group's color
/// (every `ColorKey`) and emoji (`EmojiChoices.groups`, or none: the initials), with a live `preview`. `save()` sets
/// both (`GroupService.setAppearance`); on success `savedGroup` is set: dismiss and hand it to
/// `GroupDetailViewModel.apply(group:)`.
@MainActor
@Observable
public final class GroupAppearanceViewModel: ErrorPresenting {
    public static let title = "Apparence"
    /// The group was deleted, or the user left it, meanwhile.
    public static let goneMessage = GroupDetailViewModel.goneMessage

    public let session: SessionModel
    /// The group with its saved appearance.
    public private(set) var group: TeamGroup
    /// The chosen color; nil = automatic (the color of the group id), as long as the saved color is automatic.
    public private(set) var color: ColorKey?
    /// The chosen emoji; nil = none (the initials).
    public private(set) var emoji: String?
    public private(set) var isSaving = false
    public private(set) var savedGroup: TeamGroup?
    /// The group is gone (deleted, or the user is no longer a member): dismiss.
    public private(set) var isGone = false
    public var error: ErrorState?

    public init(session: SessionModel, group: TeamGroup) {
        self.session = session
        self.group = group
        color = group.color
        emoji = group.emoji
    }

    public var colorOptions: [ColorKey] { ColorKey.allCases }
    public var emojiOptions: [String] { EmojiChoices.groups }

    /// The group as it will look.
    public var preview: AvatarAppearance {
        AvatarAppearance(color: color ?? ColorKey.automatic(for: group.id), emoji: emoji, initials: Initials.of(group.name))
    }

    public func isSelected(_ option: ColorKey) -> Bool { preview.color == option }

    /// nil: no emoji.
    public func isSelected(emoji option: String?) -> Bool { emoji == option }

    /// Picks a color. The automatic color of a group whose saved color is automatic stays automatic.
    public func selectColor(_ option: ColorKey) {
        if group.color == nil, option == ColorKey.automatic(for: group.id) {
            color = nil
        } else {
            color = option
        }
    }

    /// Picks an emoji; nil: none.
    public func selectEmoji(_ option: String?) {
        emoji = option
    }

    public var hasChanges: Bool { color != group.color || emoji != group.emoji }

    public var canSave: Bool { hasChanges && !isSaving && !isGone }

    /// Saves the color and the emoji (admins). Returns the group on success (`savedGroup`), nil otherwise: `error`
    /// set; `isGone` when the group no longer exists or the user left it.
    @discardableResult
    public func save() async -> TeamGroup? {
        guard !isSaving, !isGone else { return nil }
        error = nil
        let checkedEmoji: String?
        do {
            checkedEmoji = try InputValidation.emoji(emoji)
        } catch {
            present(error)
            return nil
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = try await session.services.groups.setAppearance(groupId: group.id, color: color, emoji: checkedEmoji)
            group = updated
            color = updated.color
            emoji = updated.emoji
            savedGroup = updated
            session.feed.bump(groupId: updated.id)
            session.feed.bumpMemberships()
            session.feed.bumpMyTasks()
            return updated
        } catch {
            guard let appError = ErrorState(from: error)?.error else { return nil }
            if appError == .notFound {
                isGone = true
                present(message: Self.goneMessage, error: .notFound)
            } else {
                present(appError)
            }
            return nil
        }
    }
}
