import Foundation
import TeamTasksContract
import TeamTasksCore
import Testing

extension IntegrationTests {
    /// Every contract scenario (docs/CONTRACTS.md) against the Supabase adapters and the local stack.
    @Suite struct SupabaseScenarioTests {
        /// Scenarios that subscribe to Realtime (skipped when `REALTIME_IT=0`).
        static let realtimeScenarios: Set<String> = Set(
            ContractScenarios.all.map(\.name).filter { $0.hasPrefix("realtime.") }
        ).union(["members.noOpRoleChange", "account.deleteAccount"])

        static var scenarioNames: [String] {
            ContractScenarios.all.map(\.name).filter { name in
                IntegrationEnvironment.realtimeEnabled || !realtimeScenarios.contains(name)
            }
        }

        @Test(.timeLimit(.minutes(3)), arguments: scenarioNames)
        func scenario(_ name: String) async throws {
            let scenario = try #require(ContractScenarios.named(name))
            try await scenario.run(SupabaseHarness())
        }

        /// The Realtime skip list names existing scenarios (a renamed one would silently stop being skipped).
        @Test func realtimeSkipListIsUpToDate() {
            #expect(Set(ContractScenarios.all.map(\.name)).isSuperset(of: Self.realtimeScenarios))
        }
    }
}
