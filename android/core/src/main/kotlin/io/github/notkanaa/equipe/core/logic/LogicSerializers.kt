package io.github.notkanaa.equipe.core.logic

import io.github.notkanaa.equipe.core.uuidString
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerializationException
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import java.time.Instant
import java.time.format.DateTimeParseException
import java.util.UUID

// JSON codecs of the state persisted by the logic classes (KeyValueStore). Lossless: an Instant keeps its nanoseconds
// (a server timestamp read back must compare equal to the same timestamp read again from the server).

/** [Instant] as an ISO-8601 string (`2026-09-24T10:00:00.020Z`). */
internal object InstantIsoSerializer : KSerializer<Instant> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("io.github.notkanaa.equipe.core.logic.Instant", PrimitiveKind.STRING)

    override fun serialize(encoder: Encoder, value: Instant) {
        encoder.encodeString(value.toString())
    }

    override fun deserialize(decoder: Decoder): Instant {
        val text = decoder.decodeString()
        return try {
            Instant.parse(text)
        } catch (error: DateTimeParseException) {
            throw SerializationException("Invalid instant: $text", error)
        }
    }
}

/** [UUID] as its upper-case string ([uuidString]). */
internal object UuidStringSerializer : KSerializer<UUID> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("io.github.notkanaa.equipe.core.logic.UUID", PrimitiveKind.STRING)

    override fun serialize(encoder: Encoder, value: UUID) {
        encoder.encodeString(value.uuidString)
    }

    override fun deserialize(decoder: Decoder): UUID {
        val text = decoder.decodeString()
        return try {
            UUID.fromString(text)
        } catch (error: IllegalArgumentException) {
            throw SerializationException("Invalid UUID: $text", error)
        }
    }
}
