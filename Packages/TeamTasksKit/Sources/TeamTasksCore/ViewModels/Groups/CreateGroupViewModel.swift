import Foundation
import Observation

/// « Nouveau groupe » sheet (also the « Créer » side of the onboarding's first group). On success `createdGroup` is
/// set: dismiss and show it (`router.showGroup(group.id)`). The creator is the group's admin.
///
/// v2: the group's color (every `ColorKey`) and emoji (`EmojiChoices.groups`, or none: the initials), with a live
/// `preview`. The color starts on a palette color picked at random (like an automatic color) and is always sent, so
/// that the group looks as previewed.
@MainActor
@Observable
public final class CreateGroupViewModel: ErrorPresenting {
    public static let maxNameLength = Limits.groupName.upperBound
    /// Example names, for the field's placeholder.
    public static let namePlaceholder = "Coloc’, famille, asso…"

    public var name: String {
        get { nameValue }
        set {
            nameValue = newValue
            if nameError != nil { nameError = Self.nameMessage(newValue) }
        }
    }

    /// v2: the group's color.
    public var color: ColorKey
    /// v2: the group's emoji; nil = none (the initials are shown).
    public var emoji: String?

    public private(set) var nameError: String?
    public private(set) var isSubmitting = false
    public private(set) var createdGroup: GroupSummary?
    public var error: ErrorState?

    public let session: SessionModel
    private var nameValue = ""

    /// - Parameters:
    ///   - color: the initial color; nil: a palette color picked at random.
    ///   - emoji: the initial emoji; nil: none.
    public init(session: SessionModel, color: ColorKey? = nil, emoji: String? = nil) {
        self.session = session
        self.color = color ?? ColorKey.automatic(for: UUID())
        self.emoji = emoji
    }

    public var canSubmit: Bool { !InputValidation.trimmed(nameValue).isEmpty && !isSubmitting }

    // MARK: - Appearance (v2)

    public var colorOptions: [ColorKey] { ColorKey.allCases }
    public var emojiOptions: [String] { EmojiChoices.groups }

    /// The group as it will look (initials of the name typed so far).
    public var preview: AvatarAppearance {
        AvatarAppearance(color: color, emoji: emoji, initials: Initials.of(nameValue))
    }

    public func selectColor(_ option: ColorKey) {
        color = option
    }

    /// Picks an emoji; picking the selected one again removes it (nil: none).
    public func selectEmoji(_ option: String?) {
        emoji = option == emoji ? nil : option
    }

    // MARK: - Create

    /// Creates the group with its appearance. Returns it on success, nil otherwise (`nameError` or `error` set).
    @discardableResult
    public func create() async -> GroupSummary? {
        guard !isSubmitting else { return nil }
        error = nil
        nameError = Self.nameMessage(nameValue)
        guard nameError == nil else { return nil }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let group = try await session.services.groups.createGroup(name: nameValue, color: color, emoji: emoji)
            createdGroup = group
            session.feed.bumpMemberships()
            return group
        } catch {
            guard let appError = ErrorState(from: error)?.error else { return nil }
            if appError == .invalidName {
                nameError = appError.messageFR
            } else {
                present(appError)
            }
            return nil
        }
    }

    public static func nameMessage(_ name: String) -> String? {
        do {
            _ = try InputValidation.groupName(name)
            return nil
        } catch {
            return AppError.invalidName.messageFR
        }
    }
}
