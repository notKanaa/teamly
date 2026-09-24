package io.github.notkanaa.equipe.supabase

import io.github.notkanaa.equipe.core.AppError
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.time.Instant
import java.util.UUID
import kotlin.coroutines.cancellation.CancellationException

// Strict decoding of PostgREST JSON answers, with the semantics of Swift's `Decodable` rows: a missing or mistyped
// required field fails the row ([MalformedAnswer]), an optional field may be missing or null, timestamps are parsed by
// [PostgresTimestamp] (0 to 6 fractional digits), UUIDs must have the canonical 8-4-4-4-12 form, and an enum column
// holding a value this client does not know throws [UnknownEnumValue] (so that list reads leave only that row out).

/** An answer that does not have the expected shape. */
internal class MalformedAnswer(message: String) : Exception(message)

/** A value of a server enum this client does not know (added by a later migration). */
internal class UnknownEnumValue(val type: String, val value: String) : Exception("unknown $type value $value")

/** Parsing and decoding of answer bodies; every failure becomes `AppError.Unknown(`[UNEXPECTED_ANSWER]`)`. */
internal object RestDecoding {
    /**
     * Decodes [body] with [decode]; any failure (not JSON, missing field, unknown enum value…) is an unexpected
     * answer.
     */
    fun <T> decode(body: ByteArray, decode: (JsonElement) -> T): T = try {
        decode(parse(body))
    } catch (error: CancellationException) {
        throw error
    } catch (error: AppError) {
        throw error
    } catch (error: Exception) { // MalformedAnswer, UnknownEnumValue, SerializationException…
        throw unexpectedAnswer()
    }

    /**
     * Decodes a JSON array, leaving out the rows holding an enum value this client does not know (they can neither be
     * shown nor safely edited: an edit would overwrite the unknown value); any other malformed row fails the whole
     * array.
     */
    fun <T> decodeRows(body: ByteArray, decodeRow: (JsonObject) -> T): List<T> = decode(body) { element ->
        lossyRows(element, decodeRow).rows
    }

    /** The rows of [element] and the number of rows left out (see [decodeRows]). */
    fun <T> lossyRows(element: JsonElement, decodeRow: (JsonObject) -> T): LossyRows<T> {
        val array = element as? JsonArray ?: throw MalformedAnswer("expected an array")
        val rows = ArrayList<T>(array.size)
        var skipped = 0
        for (item in array) {
            try {
                rows.add(decodeRow(item.asObject("row")))
            } catch (error: UnknownEnumValue) {
                skipped += 1
            }
        }
        return LossyRows(rows, skipped)
    }

    class LossyRows<T>(val rows: List<T>, val skipped: Int)

    fun parse(body: ByteArray): JsonElement = Json.parseToJsonElement(body.decodeToString())

    fun unexpectedAnswer(): AppError = AppError.Unknown(SupabaseErrorMapping.UNEXPECTED_ANSWER)
}

private val uuidPattern = Regex("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")

/** A UUID in canonical form (Swift's `UUID(uuidString:)`), or null. `UUID.fromString` alone accepts `1-1-1-1-1`. */
internal fun parseUuidOrNull(text: String): UUID? =
    if (uuidPattern.matches(text)) UUID.fromString(text) else null

internal fun JsonElement.asObject(what: String): JsonObject = this as? JsonObject ?: throw MalformedAnswer("$what is not an object")

/** A JSON string value (not a number, boolean or null), or null. */
internal fun JsonElement?.stringValue(): String? = (this as? JsonPrimitive)?.takeIf { it.isString }?.content

/** Whether the field is absent or JSON null. */
private fun JsonObject.isNull(key: String): Boolean = this[key].let { it == null || it is JsonNull }

internal fun JsonObject.requiredString(key: String): String =
    this[key].stringValue() ?: throw MalformedAnswer("$key is not a string")

internal fun JsonObject.optionalString(key: String): String? =
    if (isNull(key)) null else requiredString(key)

internal fun JsonObject.requiredUuid(key: String): UUID =
    parseUuidOrNull(requiredString(key)) ?: throw MalformedAnswer("$key is not a UUID")

internal fun JsonObject.optionalUuid(key: String): UUID? =
    if (isNull(key)) null else requiredUuid(key)

internal fun JsonObject.requiredInstant(key: String): Instant =
    PostgresTimestamp.parse(requiredString(key)) ?: throw MalformedAnswer("$key is not a timestamp")

internal fun JsonObject.optionalInstant(key: String): Instant? =
    if (isNull(key)) null else requiredInstant(key)

internal fun JsonObject.optionalObject(key: String): JsonObject? =
    if (isNull(key)) null else this.getValue(key).asObject(key)

internal fun <T> JsonObject.optionalArray(key: String, decodeItem: (JsonObject) -> T): List<T>? {
    if (isNull(key)) return null
    val array = this.getValue(key) as? JsonArray ?: throw MalformedAnswer("$key is not an array")
    return array.map { decodeItem(it.asObject(key)) }
}

/**
 * An enum column (`task_status`, `task_priority`, `member_role`): a known value decodes as usual, an unknown one throws
 * [UnknownEnumValue] (a non-string value is malformed).
 */
internal fun <E> JsonObject.known(key: String, type: String, fromRawValue: (String) -> E?): E {
    val raw = requiredString(key)
    return fromRawValue(raw) ?: throw UnknownEnumValue(type, raw)
}
