package io.github.notkanaa.equipe.mocks

import io.github.notkanaa.equipe.contract.ContractFailure
import io.github.notkanaa.equipe.contract.ContractScenarios
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized
import java.io.File

/**
 * Runs every backend-agnostic contract scenario against a fresh in-memory backend (port of ContractScenarioTests.swift).
 * Real time (`runBlocking`): the Realtime waits of the scenarios use the wall clock.
 */
@RunWith(Parameterized::class)
class ContractScenarioTest(private val name: String) {
    @Test
    fun scenario() = runBlocking {
        val scenario = ContractScenarios.named(name) ?: throw AssertionError("unknown scenario $name")
        scenario.run(MockHarness())
    }

    companion object {
        @JvmStatic
        @Parameterized.Parameters(name = "{0}")
        fun names(): List<String> = ContractScenarios.all.map { it.name }
    }
}

class ContractCatalogTest {
    @Test
    fun catalogHasUniqueNamesAndCoversEveryArea() {
        val names = ContractScenarios.all.map { it.name }
        assertEquals(names.size, names.toSet().size)
        val areas = names.map { it.substringBefore('.') }.toSet()
        assertEquals(
            setOf("auth", "profile", "group", "members", "matrix", "task", "reads", "realtime", "push", "account"),
            areas,
        )
    }

    /**
     * Same scenarios, same names, same order as the Swift catalog: `ContractScenarios.all` of ContractHarness.swift
     * concatenates the `static let xxxScenarios` lists of the Swift files in TeamTasksContract/Scenarios.
     */
    @Test
    fun catalogMatchesTheSwiftScenarios() {
        val harness = repositoryFile("Packages/TeamTasksKit/Sources/TeamTasksContract/ContractHarness.swift")
        val listOrder = Regex("""\b(\w+Scenarios)\b""")
            .findAll(harness.readText().substringAfter("static let all").substringBefore("static func named"))
            .map { it.groupValues[1] }
            .toList()
        val declaration = Regex("""static let (\w+Scenarios)\s*:""")
        val scenarioName = Regex("""ContractScenario\("([^"]+)"\)""")
        val lists = HashMap<String, List<String>>()
        File(harness.parentFile, "Scenarios").listFiles { file -> file.name.endsWith(".swift") }!!.forEach { file ->
            val text = file.readText()
            val declarations = declaration.findAll(text).toList()
            declarations.forEachIndexed { index, match ->
                val end = if (index + 1 < declarations.size) declarations[index + 1].range.first else text.length
                lists[match.groupValues[1]] =
                    scenarioName.findAll(text.substring(match.range.last, end)).map { it.groupValues[1] }.toList()
            }
        }
        val swiftNames = listOrder.flatMap { lists[it] ?: throw AssertionError("no Swift list $it in $lists") }
        assertEquals(56, swiftNames.size)
        assertEquals(swiftNames, ContractScenarios.all.map { it.name })
    }

    /** A scenario must fail with a descriptive [ContractFailure] (not pass) when the backend misbehaves. */
    @Test
    fun scenariosDetectAMisbehavingBackend() = runBlocking {
        val scenario = ContractScenarios.named("group.joinByCode")!!
        val failure = try {
            scenario.run(SameUserHarness())
            null
        } catch (error: ContractFailure) {
            error
        }
        assertNotNull("the scenario must fail", failure)
        assertTrue(failure!!.description, failure.description.contains("join result"))
    }
}
