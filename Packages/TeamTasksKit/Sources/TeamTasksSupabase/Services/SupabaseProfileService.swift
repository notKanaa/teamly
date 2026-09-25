import Foundation
import TeamTasksCore

/// `ProfileService` on PostgREST (docs/CONTRACTS.md §4.3; docs/CONTRACTS-V2.md §2, §5, §9).
struct SupabaseProfileService: ProfileService {
    let context: SupabaseContext

    /// No visible profile for the session user means the account no longer exists → `.notAuthenticated`.
    /// v2: with the avatar and the onboarding fields (`onboardedAt`, `createdAt`), which only this read fills.
    func myProfile() async throws -> UserProfile {
        let rows = try await context.rest.fetch([ProfileRow].self) { RestQuery.myProfile(me: $0.userId) }
        guard let row = rows.first else { throw AppError.notAuthenticated }
        return row.profile
    }

    /// `PATCH profiles?id=eq.<me>` with the trimmed name; 0 rows updated → `.forbidden`. v2: the result keeps the
    /// avatar.
    func updateDisplayName(_ name: String) async throws -> UserProfile {
        let name = try InputValidation.displayName(name)
        let rows = try await context.rest.fetch([ProfileRow].self) {
            RestQuery.updateDisplayName(me: $0.userId, name: name)
        }
        guard let row = rows.first else { throw AppError.forbidden }
        return row.profile
    }

    /// v2: `PATCH profiles?id=eq.<me>` of both avatar columns (docs/CONTRACTS-V2.md §2). The emoji is checked and
    /// normalized first (nil or blank = the initials; a typed color is always valid); 0 rows updated → `.forbidden`.
    func updateAvatar(color: ColorKey?, emoji: String?) async throws -> UserProfile {
        let emoji = try InputValidation.emoji(emoji)
        let rows = try await context.rest.fetch([ProfileRow].self) {
            RestQuery.updateAvatar(me: $0.userId, color: color, emoji: emoji)
        }
        guard let row = rows.first else { throw AppError.forbidden }
        return row.profile
    }

    /// v2: `complete_onboarding()` sets `onboarded_at` once; later calls write nothing.
    func completeOnboarding() async throws {
        _ = try await context.rest.send { _ in RestQuery.rpc("complete_onboarding") }
    }
}

/// `PushService` on the `enable_push` / `disable_push` RPCs and `push_subscriptions` (docs/CONTRACTS.md §4, §7).
struct SupabasePushService: PushService {
    let context: SupabaseContext

    func currentTopic() async throws -> String? {
        let rows = try await context.rest.fetch([PushTopicRow].self) { RestQuery.pushTopic(me: $0.userId) }
        return rows.first?.topic
    }

    func enable() async throws -> String {
        try await context.rest.fetch(String.self) { _ in RestQuery.rpc("enable_push") }
    }

    func disable() async throws {
        _ = try await context.rest.send { _ in RestQuery.rpc("disable_push") }
    }
}
