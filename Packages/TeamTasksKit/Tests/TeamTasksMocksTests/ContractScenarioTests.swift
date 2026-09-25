import Foundation
import TeamTasksContract
import TeamTasksCore
import TeamTasksMocks
import Testing

/// Runs the backend-agnostic scenarios against a fresh in-memory backend.
/// The clock advances 1 ms per read so successive operations get strictly increasing timestamps, like
/// successive Postgres transactions, while staying deterministic.
struct MockHarness: ContractHarness {
    static let start = Date(timeIntervalSince1970: 1_790_150_400) // 2026-09-23T08:00:00Z
    let backend: InMemoryBackend

    init() {
        backend = InMemoryBackend(now: MockClock(MockHarness.start, autoAdvance: 0.001).provider)
    }

    func makeUser(displayName: String) async throws -> ContractUser {
        let email = "contrat-\(UUID().uuidString.prefix(12).lowercased())@example.com"
        let password = "motdepasse123"
        let services = backend.services(for: nil)
        let outcome = try await services.auth.signUp(email: email, password: password, displayName: displayName)
        guard outcome == .signedIn, let user = await services.auth.currentUser() else {
            throw AppError.notAuthenticated
        }
        return ContractUser(authUser: user, displayName: displayName, email: email, password: password, services: services)
    }
}

@Suite struct ContractScenarioTests {
    @Test(arguments: ContractScenarios.all.map(\.name))
    func scenario(_ name: String) async throws {
        let scenario = try #require(ContractScenarios.named(name))
        try await scenario.run(MockHarness())
    }

    @Test func catalogHasUniqueNamesAndCoversEveryArea() {
        let names = ContractScenarios.all.map(\.name)
        #expect(Set(names).count == names.count)
        let areas = Set(names.compactMap { $0.split(separator: ".").first.map(String.init) })
        #expect(areas == [
            "auth", "profile", "group", "members", "matrix", "task", "reads", "realtime", "push", "account",
            // v2 (docs/CONTRACTS-V2.md)
            "appearance", "onboarding", "recurrence", "rotation", "checklist", "activity", "recap", "compat",
        ])
    }

    /// The v2 scenarios are part of the catalog; those that subscribe to Realtime are named `realtime.v2…`, so the
    /// backends that skip Realtime by prefix skip them too.
    @Test func v2ScenariosArePartOfTheCatalog() {
        let all = Set(ContractScenarios.all.map(\.name))
        let v2 = ContractScenarios.v2.map(\.name)
        #expect(Set(v2).isSubset(of: all))
        #expect(v2.filter { $0.hasPrefix("realtime.") } == ["realtime.v2GroupSignals", "realtime.v2OwnProfileSignals", "realtime.v2RotationTurns"])
    }

    /// A scenario must fail with a descriptive `ContractFailure` (not pass) when the backend misbehaves.
    @Test func scenariosDetectAMisbehavingBackend() async throws {
        let scenario = try #require(ContractScenarios.named("group.joinByCode"))
        let harness = try SameUserHarness()
        let error = await #expect(throws: ContractFailure.self) {
            try await scenario.run(harness)
        }
        #expect(error?.description.contains("join result") == true)
    }
}

/// Returns the same account for every `makeUser` call: "another" user joining a group is already a member.
struct SameUserHarness: ContractHarness {
    let user: ContractUser

    init() throws {
        let backend = InMemoryBackend()
        let email = "partage@example.com"
        let account = try backend.createAccount(email: email, password: "motdepasse123", displayName: "Partagé")
        user = ContractUser(
            authUser: account, displayName: "Partagé", email: email, password: "motdepasse123",
            services: backend.services(for: account.id)
        )
    }

    func makeUser(displayName: String) async throws -> ContractUser {
        user
    }
}
