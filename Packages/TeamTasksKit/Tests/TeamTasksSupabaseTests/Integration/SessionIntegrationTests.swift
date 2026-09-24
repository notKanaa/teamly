import Foundation
import Supabase
import TeamTasksContract
import TeamTasksCore
import Testing
@testable import TeamTasksSupabase

/// Counts calls (thread-safe, tests only).
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    /// Increments and returns the new count.
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

extension IntegrationTests {
    /// Sessions the server refuses, account deletion on two devices, and the realtime group ids after an offline
    /// launch, against the local stack (reviews ADP-1, ADP-3, VM-2).
    @Suite struct SessionIntegrationTests {
        /// The account is deleted on device A while B (same account) keeps a valid JWT: B's next write is refused,
        /// its refresh fails, and B is signed out instead of failing every call until the token expires.
        @Test(.timeLimit(.minutes(1)))
        func accountDeletedElsewhereSignsThisDeviceOutAtItsNextWrite() async throws {
            let a = try await SupabaseHarness().makeUser(displayName: "Supprimé ailleurs")
            let b = try IntegrationEnvironment.makeServices()
            try await b.auth.signIn(email: a.email, password: a.password)
            let probe = StreamProbe(b.auth.authStates())
            defer { probe.stop() }
            try await probe.waitFor("B signed in") { $0.user?.id == a.id }

            try await a.auth.deleteAccount()
            let mark = probe.mark()
            await #expect(throws: AppError.notAuthenticated) { try await b.groups.createGroup(name: "Encore") }
            try await probe.waitFor(".signedOut on B", after: mark) { $0 == .signedOut }
            #expect(await b.auth.currentUser() == nil)
        }

        /// « Réessayer » of a deletion whose answer was lost: `delete_my_account` finds the account gone, which is
        /// the requested end state. Success, and the device is signed out.
        @Test(.timeLimit(.minutes(1)))
        func deletingAnAlreadyDeletedAccountSucceeds() async throws {
            let a = try await SupabaseHarness().makeUser(displayName: "Suppression répétée")
            let b = try IntegrationEnvironment.makeServices()
            try await b.auth.signIn(email: a.email, password: a.password)
            try await a.auth.deleteAccount() // the first attempt, whose answer B never received
            try await b.auth.deleteAccount()
            #expect(await b.auth.currentUser() == nil)
        }

        /// PostgREST refuses a token the client still considers valid (signing key rotated on the hosted project,
        /// device clock behind): the adapter refreshes once and sends the request again.
        @Test(.timeLimit(.minutes(1)))
        func refusedButUnexpiredTokenIsRefreshedOnce() async throws {
            let configuration = try IntegrationEnvironment.unwrapConfiguration()
            let storage = InMemoryAuthStorage()
            let context = SupabaseContext(configuration: configuration, authStorage: storage, now: { Date() })
            let services = SupabaseBackend.services(for: context)
            let user = try await SupabaseHarness.signUp(displayName: "Jeton refusé", services: services)
            _ = try await services.groups.createGroup(name: "Groupe du jeton")

            let host = configuration.url.host ?? ""
            let key = "sb-\(host.split(separator: ".")[0])-auth-token"
            let stored = try #require(try storage.retrieve(key: key))
            var session = try JSONDecoder().decode(Session.self, from: stored)
            let parts = session.accessToken.split(separator: ".").map(String.init)
            #expect(parts.count == 3)
            // Same claims, signature of another key.
            session.accessToken = parts[0] + "." + parts[1] + "." + String(parts[2].reversed())
            try storage.store(key: key, value: JSONEncoder().encode(session))

            let groups = try await services.groups.myGroups()
            #expect(groups.map(\.group.name) == ["Groupe du jeton"])
            _ = try await services.groups.createGroup(name: "Encore un groupe")
            #expect(await services.auth.currentUser()?.id == user.id)
            try await services.auth.deleteAccount()
        }

        /// Offline launch: the first fetch of the group ids fails. The channel's `.connected` fetches them again
        /// and the group gets live updates (RealtimeCoordinator wired like SessionModel).
        @MainActor
        @Test(.timeLimit(.minutes(1)), .enabled(if: IntegrationEnvironment.realtimeEnabled, "REALTIME_IT=0"))
        func groupActivityAfterAnOfflineLaunch() async throws {
            let user = try await SupabaseHarness().makeUser(displayName: "Démarrage hors ligne")
            let group = try await user.groups.createGroup(name: "Groupe hors ligne")
            let attempts = CallCounter()
            let groups = user.groups
            let feed = ChangeFeed()
            let coordinator = RealtimeCoordinator(
                realtime: user.realtime,
                userId: user.id,
                feed: feed,
                groupIds: {
                    if attempts.next() == 1 { throw AppError.network } // offline at launch
                    return try await groups.myGroups().map(\.id)
                },
                debounce: .zero,
                retryDelay: .seconds(1)
            )
            coordinator.start()
            defer { coordinator.stop() }

            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(20))
            while coordinator.subscribedGroupIds != [group.id], clock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(coordinator.subscribedGroupIds == [group.id])
            #expect(!coordinator.groupIdsAreStale)
            try await Task.sleep(for: .milliseconds(1500)) // the new channel joins

            // Twice, so that a late `.connected` (which bumps everything) cannot pass for the activity.
            for name in ["Renommé hors ligne", "Renommé encore"] {
                let before = feed.groupRevision(group.id)
                _ = try await user.groups.rename(groupId: group.id, name: name)
                let wait = clock.now.advanced(by: .seconds(10))
                while feed.groupRevision(group.id) == before, clock.now < wait {
                    try await Task.sleep(for: .milliseconds(50))
                }
                #expect(feed.groupRevision(group.id) > before, "group activity after an offline launch (\(name))")
            }
        }
    }
}
