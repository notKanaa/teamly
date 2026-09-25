package io.github.notkanaa.equipe.config

import io.github.notkanaa.equipe.BuildConfig
import io.github.notkanaa.equipe.supabase.SupabaseBackend
import io.github.notkanaa.equipe.supabase.SupabaseConfiguration
import java.net.URI
import java.net.URISyntaxException
import java.util.Locale

/** Why the app cannot reach its backend: every problem found, shown by the « Configuration manquante » screen. */
data class ConfigurationIssue(val problems: List<Problem>) {
    sealed interface Problem {
        /** French explanation of the problem. */
        val message: String

        data object MissingUrl : Problem {
            override val message: String =
                "SUPABASE_URL est vide : indiquez l’adresse de votre projet, par exemple " +
                    "« https://abcdefgh.supabase.co »."
        }

        data object ExampleUrl : Problem {
            override val message: String =
                "SUPABASE_URL contient encore la valeur d’exemple « https://${SupabaseSettings.EXAMPLE_HOST} »."
        }

        data class InvalidUrl(val url: String) : Problem {
            override val message: String =
                "SUPABASE_URL « $url » n’est pas une adresse valide : indiquez « https:// » " +
                    "suivi de l’hôte du projet (ou « http:// » pour un Supabase local), sans chemin."
        }

        data object MissingKey : Problem {
            override val message: String =
                "SUPABASE_PUBLISHABLE_KEY est vide : copiez la clé publique « sb_publishable_… » de " +
                    "votre projet."
        }

        data object ExampleKey : Problem {
            override val message: String = "SUPABASE_PUBLISHABLE_KEY contient encore la valeur d’exemple."
        }

        /** A secret (`sb_secret_…`) or `service_role` key instead of the publishable one. */
        data object SecretKey : Problem {
            override val message: String =
                "SUPABASE_PUBLISHABLE_KEY contient une clé secrète, qui donnerait accès à toutes les données à " +
                    "quiconque l’extrait de l’app : utilisez la clé publique « sb_publishable_… » de " +
                    "votre projet, et régénérez la clé secrète si elle a été partagée."
        }
    }
}

/**
 * The Supabase project the app was built for: BuildConfig.SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY, set at build time
 * from the Gradle properties `equipe.supabaseUrl` / `equipe.supabaseKey` or the environment variables SUPABASE_URL /
 * SUPABASE_PUBLISHABLE_KEY (port of the iOS `SupabaseSettings`).
 */
object SupabaseSettings {
    /** Values of the iOS Config/Secrets.example.xcconfig: copying an example is not a configuration. */
    const val EXAMPLE_HOST: String = "your-project-ref.supabase.co"
    const val EXAMPLE_KEY: String = "sb_publishable_xxxxxxxxxxxxxxxx"

    sealed interface Resolution {
        data class Configured(val configuration: SupabaseConfiguration) : Resolution

        data class Misconfigured(val issue: ConfigurationIssue) : Resolution
    }

    /**
     * The configuration, or every problem found (all at once, so that a single rebuild fixes everything).
     *
     * @param keyWithheld the build refused to embed the key because it is a secret key.
     */
    fun resolve(
        url: String = BuildConfig.SUPABASE_URL,
        publishableKey: String = BuildConfig.SUPABASE_PUBLISHABLE_KEY,
        keyWithheld: Boolean = BuildConfig.SUPABASE_KEY_IS_SECRET,
    ): Resolution {
        val problems = ArrayList<ConfigurationIssue.Problem>()

        val trimmedUrl = url.trim()
        var projectUrl: String? = null
        when {
            trimmedUrl.isEmpty() -> problems.add(ConfigurationIssue.Problem.MissingUrl)
            trimmedUrl.lowercase(Locale.ROOT).contains(EXAMPLE_HOST) ->
                problems.add(ConfigurationIssue.Problem.ExampleUrl)
            else -> {
                projectUrl = projectUrl(trimmedUrl)
                if (projectUrl == null) problems.add(ConfigurationIssue.Problem.InvalidUrl(trimmedUrl))
            }
        }

        val key = publishableKey.trim()
        when {
            keyWithheld -> problems.add(ConfigurationIssue.Problem.SecretKey)
            key.isEmpty() -> problems.add(ConfigurationIssue.Problem.MissingKey)
            key == EXAMPLE_KEY -> problems.add(ConfigurationIssue.Problem.ExampleKey)
            // Shipped in the app, a secret key would give everyone who extracts it access to every row (it bypasses
            // RLS): refuse to run with it rather than use it.
            SupabaseBackend.isSecretKey(key) -> problems.add(ConfigurationIssue.Problem.SecretKey)
        }

        if (problems.isNotEmpty() || projectUrl == null) {
            return Resolution.Misconfigured(ConfigurationIssue(problems))
        }
        return Resolution.Configured(SupabaseConfiguration(url = projectUrl, publishableKey = key))
    }

    /**
     * `scheme://host[:port]` of an `http(s)` URL with a host and no path, query, fragment or user info (trailing
     * slashes ignored), else null: the URLs `SupabaseBackend.makeServices` accepts (it throws for the others).
     */
    fun projectUrl(url: String): String? {
        val trimmed = url.trim().trimEnd('/')
        val uri = try {
            URI(trimmed)
        } catch (error: URISyntaxException) {
            return null
        }
        val scheme = uri.scheme ?: return null
        val valid = (scheme == "https" || scheme == "http") && !uri.host.isNullOrEmpty() &&
            uri.rawPath.isNullOrEmpty() && uri.rawQuery == null && uri.rawFragment == null && uri.rawUserInfo == null
        return if (valid) trimmed else null
    }
}
