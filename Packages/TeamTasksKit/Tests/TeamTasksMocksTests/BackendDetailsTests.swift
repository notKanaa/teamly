import Foundation
import TeamTasksCore
import TeamTasksMocks
import Testing

@Suite struct BackendDetailsTests {
    @Test func inviteCodesUseTheAlphabetAndAreUnique() async throws {
        let backend = InMemoryBackend()
        let user = try backend.createAccount(email: "codes@example.com", password: "motdepasse123", displayName: "Codes")
        let services = backend.services(for: user.id)
        var codes: Set<String> = []
        for index in 0..<60 {
            let group = try await services.groups.createGroup(name: "Groupe \(index)")
            let code = try await services.groups.inviteCode(groupId: group.id).value
            #expect(code.count == 8)
            #expect(code.allSatisfy { "ABCDEFGHJKLMNPQRSTUVWXYZ23456789".contains($0) })
            codes.insert(code)
            let regenerated = try await services.groups.regenerateInviteCode(groupId: group.id).value
            #expect(regenerated != code)
            codes.insert(regenerated)
        }
        #expect(codes.count == 120)
    }

    @Test func pushTopicFormat() async throws {
        let backend = InMemoryBackend.demo()
        var topics: Set<String> = []
        for user in DemoData.users {
            let topic = try await backend.services(for: user.id).push.enable()
            #expect(topic.hasPrefix("equipe-"))
            #expect(topic.count == 31)
            #expect(topic.dropFirst(7).allSatisfy { "abcdefghijklmnopqrstuvwxyz0123456789".contains($0) })
            topics.insert(topic)
        }
        #expect(topics.count == 3)
    }

    /// Account deletion promotes the oldest other member: `joined_at`, then `user_id` on ties.
    @Test func promotionTieBreaksOnUserId() async throws {
        let clock = MockClock(Date(timeIntervalSince1970: 1_790_150_400))
        let backend = InMemoryBackend(now: clock.provider)
        let lowId = UUID(uuidString: "10000000-0000-4000-8000-000000000000")!
        let highId = UUID(uuidString: "F0000000-0000-4000-8000-000000000000")!
        let admin = try backend.createAccount(email: "admin@example.com", password: "motdepasse123", displayName: "Admin")
        try backend.createAccount(email: "haut@example.com", password: "motdepasse123", displayName: "Haut", id: highId)
        try backend.createAccount(email: "bas@example.com", password: "motdepasse123", displayName: "Bas", id: lowId)
        let adminServices = backend.services(for: admin.id)
        let group = try await adminServices.groups.createGroup(name: "Égalité")
        let code = try await adminServices.groups.inviteCode(groupId: group.id)
        clock.advance(by: 60)
        // Same joined_at for both (frozen clock); the higher id joins first.
        _ = try await backend.services(for: highId).groups.join(code: code)
        _ = try await backend.services(for: lowId).groups.join(code: code)

        try await adminServices.auth.deleteAccount()
        let members = try await backend.services(for: highId).groups.members(groupId: group.id)
        #expect(members.map(\.user.id) == [lowId, highId])
        #expect(members.map(\.role) == [.admin, .member])
    }

    @Test func membersSortIgnoresCaseAndAccents() async throws {
        let backend = InMemoryBackend()
        let names = ["zoé", "Émile", "eric", "Ana", "Éric"]
        var users: [AuthUser] = []
        for (index, name) in names.enumerated() {
            users.append(try backend.createAccount(email: "u\(index)@example.com", password: "motdepasse123", displayName: name))
        }
        let owner = backend.services(for: users[0].id)
        let group = try await owner.groups.createGroup(name: "Tri")
        let code = try await owner.groups.inviteCode(groupId: group.id)
        for user in users.dropFirst() {
            _ = try await backend.services(for: user.id).groups.join(code: code)
        }
        let members = try await owner.groups.members(groupId: group.id)
        // Admin first, then "ana" < "emile" < "eric" = "eric" (the exact string breaks the tie: "eric" < "Éric").
        #expect(members.map(\.user.displayName) == ["zoé", "Ana", "Émile", "eric", "Éric"])
    }

    @Test func failedWritesCommitNothing() async throws {
        let backend = InMemoryBackend.demo()
        let camille = backend.services(for: DemoData.camille.id)
        let before = try await camille.groups.myGroups()
        await #expect(throws: AppError.assigneeNotMember) {
            try await camille.tasks.create(
                groupId: DemoData.sportGroupId,
                draft: TaskDraft(title: "Refusée", assigneeIds: [DemoData.camille.id, DemoData.ines.id])
            )
        }
        let after = try await camille.groups.myGroups()
        #expect(after == before) // no bump either
        let sport = try await camille.tasks.tasks(groupId: DemoData.sportGroupId, includeOldDone: true)
        #expect(!sport.contains { $0.title == "Refusée" })
    }

    @Test func servicesOfADeletedOrUnknownUserAreSignedOut() async throws {
        let backend = InMemoryBackend.demo()
        let ghost = backend.services(for: UUID())
        #expect(await ghost.auth.currentUser() == nil)
        await #expect(throws: AppError.notAuthenticated) { try await ghost.groups.myGroups() }
    }
}
