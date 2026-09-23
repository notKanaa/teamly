import Foundation
import TeamTasksCore
import TeamTasksMocks
import Testing

/// `join_group_by_code`: once the caller has 10 failed attempts in the last hour (`attempted_at >= now() - 1 h`),
/// every further attempt → `.rateLimited` (too slow to test on a real server, so it is only covered here).
/// Failed attempts are logged even though `.invalidCode` is thrown.
@Suite struct JoinRateLimitTests {
    let clock = MockClock(Date(timeIntervalSince1970: 1_790_150_400))
    let lilas = InviteCode(DemoData.lilasInviteCode)!
    let unknown = InviteCode("ZZZZ2222")!

    func newcomer(_ backend: InMemoryBackend) throws -> AppServices {
        let user = try backend.createAccount(email: "nouveau@example.com", password: "motdepasse123", displayName: "Nouveau")
        return backend.services(for: user.id)
    }

    @Test func eleventhAttemptAfterTenFailuresIsRateLimited() async throws {
        let backend = InMemoryBackend.demo(now: clock.provider)
        let services = try newcomer(backend)
        for _ in 1...InMemoryBackend.maxFailedJoinsPerHour {
            await #expect(throws: AppError.invalidCode) { try await services.groups.join(code: unknown) }
        }
        // Even a valid code is refused, and refused attempts are not logged.
        await #expect(throws: AppError.rateLimited) { try await services.groups.join(code: lilas) }
        await #expect(throws: AppError.rateLimited) { try await services.groups.join(code: unknown) }
        #expect(try await services.groups.myGroups().isEmpty)

        clock.advance(by: InMemoryBackend.joinRateLimitWindow - 1)
        await #expect(throws: AppError.rateLimited) { try await services.groups.join(code: lilas) }
        // SQL counts `attempted_at >= now() - interval '1 hour'`: failures exactly one hour old still count.
        clock.advance(by: 1)
        await #expect(throws: AppError.rateLimited) { try await services.groups.join(code: lilas) }
        clock.advance(by: 0.001)
        let joined = try await services.groups.join(code: lilas)
        #expect(joined.groupId == DemoData.lilasGroupId)
        #expect(!joined.alreadyMember)
    }

    @Test func onlyFailuresCount() async throws {
        let backend = InMemoryBackend.demo(now: clock.provider)
        let services = try newcomer(backend)
        for _ in 1...9 {
            await #expect(throws: AppError.invalidCode) { try await services.groups.join(code: unknown) }
        }
        #expect(try await services.groups.join(code: lilas).alreadyMember == false)
        #expect(try await services.groups.join(code: lilas).alreadyMember == true)
        #expect(try await services.groups.join(code: lilas).alreadyMember == true)
        await #expect(throws: AppError.invalidCode) { try await services.groups.join(code: unknown) } // 10th failure
        await #expect(throws: AppError.rateLimited) { try await services.groups.join(code: lilas) }
    }

    @Test func limitIsPerUser() async throws {
        let backend = InMemoryBackend.demo(now: clock.provider)
        let services = try newcomer(backend)
        for _ in 1...InMemoryBackend.maxFailedJoinsPerHour {
            await #expect(throws: AppError.invalidCode) { try await services.groups.join(code: unknown) }
        }
        await #expect(throws: AppError.rateLimited) { try await services.groups.join(code: lilas) }
        let ines = backend.services(for: DemoData.ines.id)
        let sport = try #require(InviteCode(DemoData.sportInviteCode))
        #expect(try await ines.groups.join(code: sport).groupId == DemoData.sportGroupId)
    }

    @Test func regeneratedCodeInvalidatesTheOldOne() async throws {
        let backend = InMemoryBackend.demo(now: clock.provider)
        let camille = backend.services(for: DemoData.camille.id)
        let fresh = try await camille.groups.regenerateInviteCode(groupId: DemoData.lilasGroupId)
        #expect(fresh != lilas)
        let services = try newcomer(backend)
        await #expect(throws: AppError.invalidCode) { try await services.groups.join(code: lilas) }
        #expect(try await services.groups.join(code: fresh).groupId == DemoData.lilasGroupId)
    }
}
