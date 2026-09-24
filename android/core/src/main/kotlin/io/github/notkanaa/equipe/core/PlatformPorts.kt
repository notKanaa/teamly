package io.github.notkanaa.equipe.core

import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.serializer
import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.temporal.WeekFields
import java.util.Locale

// Port of TeamTasksCore/Services/PlatformPorts.swift: platform abstractions implemented by the Android app
// (NotificationManager/WorkManager, DataStore…) and by simple fakes in tests, so all the logic stays testable on the JVM.

enum class NotificationAuthorization {
    NOT_DETERMINED,
    DENIED,
    AUTHORIZED,
}

/** A local notification request. */
data class LocalNotification(
    /** Stable identifier. Prefixes: `due-` (due-date reminders), `assigned-` (new assignment), `summary-`. */
    val id: String,
    val title: String,
    val body: String,
    /** Delivery date; null means "deliver now". */
    val fireDate: Instant? = null,
    /** Routing info for taps: keys `taskId`, `groupId` (UUID strings). */
    val userInfo: Map<String, String> = emptyMap(),
    val threadId: String? = null,
)

interface NotificationScheduler {
    suspend fun authorizationStatus(): NotificationAuthorization

    /** Returns true if granted. */
    suspend fun requestAuthorization(): Boolean

    /** Identifiers of pending (not yet delivered) requests starting with [prefix]. */
    suspend fun pendingIdentifiers(prefix: String): List<String>

    suspend fun add(notification: LocalNotification)

    suspend fun removePending(ids: List<String>)

    suspend fun setBadge(count: Int)
}

/** Small persistent key-value storage (UserDefaults on iOS; DataStore/SharedPreferences on Android). */
interface KeyValueStore {
    /** The bytes stored under [key], or null. */
    fun data(key: String): ByteArray?

    /** Stores [data] under [key]; null removes the key. */
    fun set(key: String, data: ByteArray?)
}

/** JSON codec of [value] / [setValue] (unknown keys ignored, like Swift's `JSONDecoder`). */
val KeyValueStoreJson: Json = Json { ignoreUnknownKeys = true }

/** The JSON value stored under [key] (kotlinx.serialization), or null when absent or undecodable. */
inline fun <reified T> KeyValueStore.value(key: String, json: Json = KeyValueStoreJson): T? {
    val bytes = data(key) ?: return null
    return try {
        json.decodeFromString(serializer<T>(), bytes.decodeToString())
    } catch (error: IllegalArgumentException) { // SerializationException included
        null
    }
}

/** Stores [value] as JSON under [key]; null (or a value that cannot be encoded) removes the key. */
inline fun <reified T> KeyValueStore.setValue(key: String, value: T?, json: Json = KeyValueStoreJson) {
    if (value == null) {
        set(key, null)
        return
    }
    val encoded = try {
        json.encodeToString(serializer<T>(), value).encodeToByteArray()
    } catch (error: SerializationException) {
        null
    }
    set(key, encoded)
}

/** In-memory [KeyValueStore] (tests, previews, UI tests). Thread-safe; stores copies (value semantics). */
class InMemoryKeyValueStore : KeyValueStore {
    private val storage = HashMap<String, ByteArray>()

    override fun data(key: String): ByteArray? = synchronized(storage) { storage[key]?.copyOf() }

    override fun set(key: String, data: ByteArray?) {
        synchronized(storage) {
            if (data == null) storage.remove(key) else storage[key] = data.copyOf()
        }
    }
}

/** Current-date provider (injectable for tests). */
typealias NowProvider = () -> Instant

/**
 * The app's calendar (Swift `Calendar.frenchGregorian(timeZone:)`): Gregorian (ISO chronology of java.time), weeks
 * starting on Monday with at least 4 days in the first week (ISO 8601), `fr_FR` locale, injected time zone.
 *
 * Only java.time APIs available on Android 26 are used (e.g. no `LocalDate.ofInstant`, which is Java 9).
 */
data class AppCalendar(
    val zone: ZoneId,
    val locale: Locale = FRENCH,
) {
    /** Monday first, minimal days in the first week: 4. */
    val weekFields: WeekFields get() = WeekFields.of(DayOfWeek.MONDAY, 4)

    fun zonedDateTime(instant: Instant): ZonedDateTime = instant.atZone(zone)

    /** The calendar day of [instant] in [zone]. */
    fun localDate(instant: Instant): LocalDate = instant.atZone(zone).toLocalDate()

    /** Start of the day of [instant] in [zone] (DST-aware: not always midnight). */
    fun startOfDay(instant: Instant): Instant = startOfDay(localDate(instant))

    fun startOfDay(date: LocalDate): Instant = date.atStartOfDay(zone).toInstant()

    /** The instant of a wall-clock [time] on [date] in [zone] (gaps resolved forward, overlaps to the earlier offset). */
    fun instant(date: LocalDate, time: LocalTime): Instant = ZonedDateTime.of(date, time, zone).toInstant()

    fun isSameDay(lhs: Instant, rhs: Instant): Boolean = localDate(lhs) == localDate(rhs)

    companion object {
        /** `fr_FR`. */
        val FRENCH: Locale = Locale.FRANCE

        val PARIS: ZoneId = ZoneId.of("Europe/Paris")

        /** French Gregorian rules in [zone] (Swift `Calendar.frenchGregorian(timeZone:)`). */
        fun frenchGregorian(zone: ZoneId): AppCalendar = AppCalendar(zone, FRENCH)

        /** French Gregorian rules in the device's current time zone. */
        fun systemDefault(): AppCalendar = frenchGregorian(ZoneId.systemDefault())
    }
}

/** Platform services injected into view models. */
data class PlatformServices(
    val notifications: NotificationScheduler,
    val store: KeyValueStore,
    val now: NowProvider = { Instant.now() },
    val calendar: AppCalendar = AppCalendar.systemDefault(),
)
