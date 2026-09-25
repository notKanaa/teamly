package io.github.notkanaa.equipe.config

import io.github.notkanaa.equipe.supabase.SupabaseConfiguration
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

class SupabaseSettingsTest {
    private val publishable = "sb_publishable_" + "a".repeat(20)

    private fun problems(url: String, key: String, withheld: Boolean = false): List<ConfigurationIssue.Problem> =
        when (val resolution = SupabaseSettings.resolve(url, key, withheld)) {
            is SupabaseSettings.Resolution.Configured -> emptyList()
            is SupabaseSettings.Resolution.Misconfigured -> resolution.issue.problems
        }

    @Test
    fun validSettingsAreConfigured() {
        val resolution = SupabaseSettings.resolve("https://abcdefgh.supabase.co/", " $publishable ", false)
        assertEquals(
            SupabaseSettings.Resolution.Configured(SupabaseConfiguration("https://abcdefgh.supabase.co", publishable)),
            resolution,
        )
        assertTrue(problems("http://10.0.2.2:54321", publishable).isEmpty())
    }

    @Test
    fun everyProblemIsReportedAtOnce() {
        assertEquals(
            listOf(ConfigurationIssue.Problem.MissingUrl, ConfigurationIssue.Problem.MissingKey),
            problems("", "  "),
        )
        assertEquals(
            listOf(ConfigurationIssue.Problem.ExampleUrl, ConfigurationIssue.Problem.ExampleKey),
            problems("https://your-project-ref.supabase.co", SupabaseSettings.EXAMPLE_KEY),
        )
    }

    @Test
    fun invalidUrlsAreRefused() {
        for (url in listOf("abcdefgh.supabase.co", "ftp://host", "https://", "https://host/rest/v1", "https://h?x=1")) {
            assertEquals(url, listOf(ConfigurationIssue.Problem.InvalidUrl(url)), problems(url, publishable))
        }
    }

    @Test
    fun secretKeysAreRefused() {
        val secret = "sb_" + "secret_" + "x".repeat(31)
        assertEquals(listOf(ConfigurationIssue.Problem.SecretKey), problems("https://a.supabase.co", secret))
        val serviceRole = jwt("""{"role":"service_""" + """role"}""")
        assertEquals(listOf(ConfigurationIssue.Problem.SecretKey), problems("https://a.supabase.co", serviceRole))
        assertTrue(problems("https://a.supabase.co", jwt("""{"role":"anon"}""")).isEmpty())
        // Withheld by the build (the key is then empty).
        assertEquals(listOf(ConfigurationIssue.Problem.SecretKey), problems("https://a.supabase.co", "", withheld = true))
    }

    @Test
    fun messagesUseFrenchTypography() {
        val all = listOf(
            ConfigurationIssue.Problem.MissingUrl,
            ConfigurationIssue.Problem.ExampleUrl,
            ConfigurationIssue.Problem.InvalidUrl("x"),
            ConfigurationIssue.Problem.MissingKey,
            ConfigurationIssue.Problem.ExampleKey,
            ConfigurationIssue.Problem.SecretKey,
        )
        for (problem in all) {
            val message = problem.message
            assertTrue(message, !message.contains(" :") && !message.contains("« ") && !message.contains(" »"))
            assertTrue(message, !message.contains("'"))
        }
    }

    private fun jwt(payload: String): String {
        val encoder = Base64.getUrlEncoder().withoutPadding()
        val header = encoder.encodeToString("""{"alg":"HS256","typ":"JWT"}""".toByteArray())
        return header + "." + encoder.encodeToString(payload.toByteArray()) + ".signature"
    }
}
