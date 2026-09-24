package io.github.notkanaa.equipe.supabase.integration

import io.github.notkanaa.equipe.contract.ContractScenarios
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized
import kotlin.time.Duration.Companion.minutes

/**
 * Every contract scenario (docs/CONTRACTS.md) against the Supabase adapters and the local stack (port of
 * SupabaseContractTests.swift). Skipped without `SUPABASE_URL` / `SUPABASE_KEY`. Real time: the Realtime waits of the
 * scenarios use the wall clock (10 s bound).
 */
@RunWith(Parameterized::class)
class SupabaseScenarioTest(private val name: String) {
    @Test
    fun scenario() = IntegrationEnvironment.run(3.minutes) { devices ->
        val scenario = ContractScenarios.named(name) ?: throw AssertionError("unknown scenario $name")
        scenario.run(SupabaseHarness(devices))
    }

    companion object {
        @JvmStatic
        @Parameterized.Parameters(name = "{0}")
        fun names(): List<String> = ContractScenarios.all.map { it.name }
    }
}

class ScenarioCatalogTest {
    /** Every scenario of the catalog runs against Supabase (none is left out). */
    @Test
    fun everyScenarioIsRun() {
        assertEquals(56, SupabaseScenarioTest.names().size)
        assertEquals(SupabaseScenarioTest.names().toSet().size, SupabaseScenarioTest.names().size)
    }
}
