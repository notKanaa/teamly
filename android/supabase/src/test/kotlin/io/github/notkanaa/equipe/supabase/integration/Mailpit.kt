package io.github.notkanaa.equipe.supabase.integration

import io.github.notkanaa.equipe.contract.ContractFailure
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlin.time.TimeSource

/** Reads the e-mails caught by the local Mailpit (`MAILPIT_URL`, API v1). Port of Mailpit.swift. */
internal object Mailpit {
    /** Waits (bounded) for the newest message sent to [email] and returns the 6-digit code it contains. */
    suspend fun recoveryCode(email: String, timeout: Duration = 20.seconds): String {
        val base = IntegrationEnvironment.mailpitUrl ?: throw ContractFailure("MAILPIT_URL is not set")
        val deadline = TimeSource.Monotonic.markNow() + timeout
        while (deadline.hasNotPassedNow()) {
            val id = latestMessageId(email, base)
            if (id != null) {
                val message = get("$base/api/v1/message/$id") as? JsonObject ?: throw ContractFailure("unexpected Mailpit message")
                val body = listOfNotNull(message["Text"].string(), message["HTML"].string()).joinToString("\n")
                return sixDigitCode(body) ?: throw ContractFailure("no 6-digit code in the recovery e-mail: $body")
            }
            delay(250.milliseconds)
        }
        throw ContractFailure("no e-mail for $email in Mailpit after $timeout")
    }

    private suspend fun latestMessageId(email: String, base: String): String? {
        val query = URLEncoder.encode("to:\"$email\"", "UTF-8")
        val listing = get("$base/api/v1/search?query=$query&limit=5") as? JsonObject ?: return null
        val messages = listing["messages"] as? JsonArray ?: return null
        // Newest first; the search is a full-text one, so check the recipient exactly.
        return messages.filterIsInstance<JsonObject>().firstOrNull { message ->
            (message["To"] as? JsonArray).orEmpty().filterIsInstance<JsonObject>().any {
                it["Address"].string()?.lowercase() == email.lowercase()
            }
        }?.get("ID").string()
    }

    fun sixDigitCode(text: String): String? = Regex("(?<![0-9])[0-9]{6}(?![0-9])").find(text)?.value

    private fun JsonElement?.string(): String? = (this as? JsonPrimitive)?.takeIf { it.isString }?.content

    private suspend fun get(url: String): JsonElement = withContext(Dispatchers.IO) {
        val connection = URL(url).openConnection() as HttpURLConnection
        try {
            connection.connectTimeout = 5_000
            connection.readTimeout = 5_000
            if (connection.responseCode != 200) throw ContractFailure("Mailpit answered ${connection.responseCode} for $url")
            Json.parseToJsonElement(connection.inputStream.use { it.readBytes().toString(Charsets.UTF_8) })
        } finally {
            connection.disconnect()
        }
    }
}
