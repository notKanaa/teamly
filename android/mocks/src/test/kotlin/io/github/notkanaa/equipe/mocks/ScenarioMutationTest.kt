package io.github.notkanaa.equipe.mocks

import io.github.notkanaa.equipe.contract.ContractScenario
import io.github.notkanaa.equipe.contract.ContractScenarios
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized

/** Port of ScenarioMutationTests.swift (decorators in MutationHarness.kt). Real time: the scenarios wait on the wall clock. */
object ScenarioMutations {
    /** Failing scenarios (name → failure) of [scenarios] run on a harness applying [mutation]. */
    suspend fun failingScenarios(
        mutation: ScenarioMutation?,
        scenarios: List<ContractScenario> = ContractScenarios.all,
    ): Map<String, String> {
        val failures = LinkedHashMap<String, String>()
        for (scenario in scenarios) {
            try {
                scenario.run(MutationHarness(mutation))
            } catch (error: Exception) {
                failures[scenario.name] = error.toString()
            }
        }
        return failures
    }

    /** Scenarios that must catch each mutation (lead decisions and docs/CONTRACTS.md §6). */
    val detectors: Map<ScenarioMutation, List<String>> = mapOf(
        ScenarioMutation.RENAME_NON_MEMBER_NOT_FOUND to listOf("group.rename", "matrix.groupAdminActions"),
        ScenarioMutation.RENAME_UNKNOWN_FORBIDDEN to listOf("group.rename"),
        ScenarioMutation.DELETE_NON_MEMBER_NOT_FOUND to listOf("group.delete", "matrix.groupAdminActions"),
        ScenarioMutation.DELETE_UNKNOWN_FORBIDDEN to listOf("group.delete"),
        ScenarioMutation.NON_MEMBER_READS_THROW to
            listOf("group.nonMemberSeesNothing", "matrix.seeGroupMembersAndTasks", "group.delete"),
        ScenarioMutation.UNKNOWN_GROUP_NOT_FOUND to listOf("matrix.groupAdminActions"),
        ScenarioMutation.SIGNED_OUT_FORBIDDEN to listOf("auth.signOutAndSignIn"),
        ScenarioMutation.ASSIGNED_TO_EVERYONE to listOf("realtime.assignedOnlyToMe"),
        ScenarioMutation.MEMBERSHIPS_CHANGED_TO_EVERYONE to listOf("realtime.membershipsChangedOnlyForMe"),
        ScenarioMutation.ACTIVITY_TO_NON_MEMBERS to listOf("realtime.groupActivityOnlyForMembers"),
    )
}

class ScenarioMutationTest {
    @Test
    fun decoratorsAloneBreakNothing() = runBlocking {
        val failures = ScenarioMutations.failingScenarios(null)
        assertTrue("$failures", failures.isEmpty())
    }

    /**
     * On a real server, a change committed before the subscription can arrive after `Connected`: it must not stand in
     * for the signal under test (here `create_task` emits none, which must be detected, after the 10 s bound).
     */
    @Test
    fun staleEventCannotStandInForAMissingSignal() = runBlocking {
        val scenario = ContractScenarios.named("realtime.groupActivity")!!
        val failures = ScenarioMutations.failingScenarios(
            ScenarioMutation.STALE_EVENTS_AND_SILENT_TASK_CREATION, listOf(scenario),
        )
        assertTrue("a stale event satisfied the wait for the create_task signal", failures[scenario.name] != null)
    }
}

/** Every mutation (except the stale-event race, tested alone above) is caught by its detector scenarios. */
@RunWith(Parameterized::class)
class ScenarioMutationCatalogTest(private val mutation: ScenarioMutation) {
    @Test
    fun catalogDetects() = runBlocking {
        val detectors = ScenarioMutations.detectors[mutation] ?: throw AssertionError("no detector for $mutation")
        val failures = ScenarioMutations.failingScenarios(mutation)
        println("$mutation is detected by ${failures.keys.sorted()}")
        for (name in detectors) {
            assertTrue("$name does not detect $mutation; failing: ${failures.keys.sorted()}", failures[name] != null)
        }
        // A mutation is caught by the scenarios about that rule, not by a harness that breaks everything.
        assertTrue("$mutation breaks every scenario", failures.size < ContractScenarios.all.size / 2)
    }

    companion object {
        @JvmStatic
        @Parameterized.Parameters(name = "{0}")
        fun mutations(): List<ScenarioMutation> =
            ScenarioMutation.entries.filter { it != ScenarioMutation.STALE_EVENTS_AND_SILENT_TASK_CREATION }
    }
}
