import Foundation
import Observation

/// The avatar picker (onboarding « Choisis ton avatar », Réglages): a color among every `ColorKey`, and the initials
/// or an emoji of `EmojiChoices.avatars`, with a live `preview`. `save()` sends the choice when it changed
/// (`ProfileService.updateAvatar`).
///
/// Views: swatches `colorOptions` (`isSelected(_:)`, `selectColor(_:)`), the initials then `emojiOptions`
/// (`isSelected(emoji:)`, `selectEmoji(_:)`, nil = the initials), and the preview.
@MainActor
@Observable
public final class AvatarEditorViewModel: ErrorPresenting {
    public let session: SessionModel
    /// The edited profile, with the saved avatar.
    public private(set) var profile: UserProfile
    /// The chosen color; nil = automatic (the color of the user id).
    public private(set) var color: ColorKey?
    /// The chosen emoji; nil = the initials.
    public private(set) var emoji: String?
    public private(set) var isSaving = false
    public var error: ErrorState?

    public init(session: SessionModel, profile: UserProfile) {
        self.session = session
        self.profile = profile
        color = profile.avatarColor
        emoji = profile.avatarEmoji
    }

    // MARK: - Choices

    public var colorOptions: [ColorKey] { ColorKey.allCases }
    public var emojiOptions: [String] { EmojiChoices.avatars }

    /// « CM ».
    public var initials: String { Initials.of(profile.displayName) }

    /// The avatar as it will look.
    public var preview: AvatarAppearance {
        AvatarAppearance(color: color ?? ColorKey.automatic(for: profile.id), emoji: emoji, initials: initials)
    }

    public func isSelected(_ option: ColorKey) -> Bool { preview.color == option }

    /// nil: the initials.
    public func isSelected(emoji option: String?) -> Bool { emoji == option }

    /// Picks a color. The automatic color of a user whose saved color is automatic stays automatic.
    public func selectColor(_ option: ColorKey) {
        if profile.avatarColor == nil, option == ColorKey.automatic(for: profile.id) {
            color = nil
        } else {
            color = option
        }
    }

    /// Picks an emoji; nil: the initials.
    public func selectEmoji(_ option: String?) {
        emoji = option
    }

    /// The choice differs from the saved avatar.
    public var hasChanges: Bool { color != profile.avatarColor || emoji != profile.avatarEmoji }

    public var canSave: Bool { hasChanges && !isSaving }

    /// Back to the saved avatar.
    public func reset() {
        color = profile.avatarColor
        emoji = profile.avatarEmoji
    }

    // MARK: - Save

    /// Saves the choice when it changed (true at once otherwise). On success `profile` holds the saved avatar and
    /// every screen reloads (avatars are everywhere); on failure `error` is set and the choice is kept.
    @discardableResult
    public func save() async -> Bool {
        guard !isSaving else { return false }
        guard hasChanges else { return true }
        error = nil
        let checkedEmoji: String?
        do {
            checkedEmoji = try InputValidation.emoji(emoji)
        } catch {
            present(error)
            return false
        }
        isSaving = true
        defer { isSaving = false }
        do {
            var updated = try await session.services.profiles.updateAvatar(color: color, emoji: checkedEmoji)
            // The PATCH returns the public profile: keep what only `myProfile()` reads.
            updated.onboardedAt = updated.onboardedAt ?? profile.onboardedAt
            updated.createdAt = updated.createdAt ?? profile.createdAt
            profile = updated
            color = updated.avatarColor
            emoji = updated.avatarEmoji
            session.feed.bumpAll()
            return true
        } catch {
            present(error)
            return false
        }
    }
}
