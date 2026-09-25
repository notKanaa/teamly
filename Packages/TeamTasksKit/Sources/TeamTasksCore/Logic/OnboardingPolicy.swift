import Foundation

/// A step of the onboarding, in display order (docs/CONTRACTS-V2.md §9).
public enum OnboardingStep: String, Sendable, Hashable, CaseIterable {
    /// « Bienvenue ».
    case welcome
    /// Avatar: a color, and the initials or an emoji (optional).
    case avatar
    /// « Premier groupe »: create one (name, emoji, color) or join one with a code.
    case firstGroup
    /// Ask for the notification permission.
    case notifications
}

/// When the onboarding is shown, and which steps it has (docs/CONTRACTS-V2.md §9). Finishing it, or « Passer »,
/// calls `ProfileService.completeOnboarding()`. Pure.
public enum OnboardingPolicy {
    /// Accounts at least this old never see the onboarding (it covers the accounts created with a v1 app).
    public static let maxAccountAge: TimeInterval = 7 * 86_400

    /// After sign-in: true iff the onboarding was never completed (`onboardedAt` nil) and the account is less than
    /// `maxAccountAge` old at `now`. False when `createdAt` is unknown (a profile not read by
    /// `ProfileService.myProfile()`).
    public static func shouldShow(profile: UserProfile, now: Date) -> Bool {
        guard profile.onboardedAt == nil, let createdAt = profile.createdAt else { return false }
        return now.timeIntervalSince(createdAt) < maxAccountAge
    }

    /// The steps to show, in order: « Premier groupe » is skipped when the user already has a group, and the
    /// notifications step when the permission was already decided (anything but `.notDetermined`).
    public static func steps(hasGroups: Bool, notifications: NotificationAuthorization) -> [OnboardingStep] {
        var steps: [OnboardingStep] = [.welcome, .avatar]
        if !hasGroups { steps.append(.firstGroup) }
        if notifications == .notDetermined { steps.append(.notifications) }
        return steps
    }
}
