import Foundation
import TeamTasksCore

/// `ProfileService` on PostgREST (docs/CONTRACTS.md §4.3).
struct SupabaseProfileService: ProfileService {
    let context: SupabaseContext

    /// No visible profile for the session user means the account no longer exists → `.notAuthenticated`.
    func myProfile() async throws -> UserProfile {
        let rows = try await context.rest.fetch([ProfileRow].self) { RestQuery.myProfile(me: $0.userId) }
        guard let row = rows.first else { throw AppError.notAuthenticated }
        return row.profile
    }

    /// `PATCH profiles?id=eq.<me>` with the trimmed name; 0 rows updated → `.forbidden`.
    func updateDisplayName(_ name: String) async throws -> UserProfile {
        let name = try InputValidation.displayName(name)
        let rows = try await context.rest.fetch([ProfileRow].self) {
            RestQuery.updateDisplayName(me: $0.userId, name: name)
        }
        guard let row = rows.first else { throw AppError.forbidden }
        return row.profile
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
