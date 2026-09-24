package io.github.notkanaa.equipe.supabase

import io.github.notkanaa.equipe.core.InputValidation
import io.github.notkanaa.equipe.core.Limits
import io.github.notkanaa.equipe.core.TaskDraft
import io.github.notkanaa.equipe.core.TaskPriority
import io.github.notkanaa.equipe.core.UuidStringOrder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.time.Instant
import java.util.UUID

/**
 * One PostgREST request, described verbatim (path and ordered query parameters, as written in docs/CONTRACTS.md §4.3)
 * before percent-encoding and authentication. Port of RestRequest.swift.
 */
internal data class RestRequest(
    val method: Method = Method.GET,
    /** Relative to `/rest/v1/`, e.g. `group_members` or `rpc/create_group`. */
    val path: String,
    val query: List<QueryItem> = emptyList(),
    val body: JsonElement? = null,
    /** `Prefer` header (e.g. `return=representation`). */
    val prefer: String? = null,
) {
    enum class Method {
        GET,
        POST,
        PATCH,
    }

    data class QueryItem(val name: String, val value: String)

    /** `name=value&…` without percent-encoding: the form used in docs/CONTRACTS.md. */
    val readableQuery: String get() = query.joinToString("&") { "${it.name}=${it.value}" }

    /**
     * `path?query` with every character outside [QUERY_ALLOWED] percent-encoded (a `+` in a timestamp would otherwise
     * read as a space).
     */
    val encodedPathAndQuery: String
        get() = if (query.isEmpty()) {
            path
        } else {
            path + "?" + query.joinToString("&") { percentEncoded(it.name) + "=" + percentEncoded(it.value) }
        }

    /** The full URL of the request under [restUrl] (`<project>/rest/v1`). */
    fun url(restUrl: String): String = restUrl.trimEnd('/') + "/" + encodedPathAndQuery

    /** The body as compact JSON (keys in the order given: the builders sort them). */
    fun encodedBody(): String? = body?.let { Json.encodeToString(JsonElement.serializer(), it) }

    companion object {
        /**
         * Characters left as is in query names and values: RFC 3986 unreserved characters plus the PostgREST syntax
         * characters `* , : ( ) !`. Everything else (`+`, space, `&`, `=`, `#`, `%`, non-ASCII…) is encoded.
         */
        const val QUERY_ALLOWED: String = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~*,:()!"

        private const val HEX = "0123456789ABCDEF"

        /** UTF-8 percent-encoding of every character outside [QUERY_ALLOWED] (upper-case hex, like Foundation). */
        fun percentEncoded(value: String): String {
            val builder = StringBuilder(value.length)
            for (byte in value.toByteArray(Charsets.UTF_8)) {
                val code = byte.toInt() and 0xFF
                if (code < 0x80 && QUERY_ALLOWED.indexOf(code.toChar()) >= 0) {
                    builder.append(code.toChar())
                } else {
                    builder.append('%').append(HEX[code shr 4]).append(HEX[code and 0x0F])
                }
            }
            return builder.toString()
        }
    }
}

/** Builders of every PostgREST request the adapters make (docs/CONTRACTS.md §4.1, §4.3). */
internal object RestQuery {
    /** Lower-case canonical form, as Postgres prints UUIDs. */
    fun uuid(value: UUID): String = value.toString().lowercase()

    private fun item(name: String, value: String) = RestRequest.QueryItem(name, value)

    // region Reads

    fun myGroups(me: UUID) = RestRequest(
        path = "group_members",
        query = listOf(item("select", "role,group:groups(*)"), item("user_id", "eq.${uuid(me)}")),
    )

    fun members(groupId: UUID) = RestRequest(
        path = "group_members",
        query = listOf(
            item("select", "user_id,role,joined_at,profile:profiles(id,display_name)"),
            item("group_id", "eq.${uuid(groupId)}"),
        ),
    )

    fun inviteCode(groupId: UUID) = RestRequest(
        path = "group_invites",
        query = listOf(item("select", "code"), item("group_id", "eq.${uuid(groupId)}")),
    )

    const val TASK_SELECT = "*,assignees:task_assignees(user_id)"

    /** Old done tasks: cutoff = `now − 30 × 86 400 s` (not calendar days), inclusive. */
    fun oldDoneCutoff(now: Instant): Instant = now.minusSeconds(Limits.oldDoneTaskDays * 86_400L)

    /** Unless [includeOldDone], done tasks completed before `now − 30 days` are left out. */
    fun groupTasks(groupId: UUID, includeOldDone: Boolean, now: Instant): RestRequest {
        val query = mutableListOf(item("select", TASK_SELECT), item("group_id", "eq.${uuid(groupId)}"))
        if (!includeOldDone) {
            val cutoff = PostgresTimestamp.format(oldDoneCutoff(now))
            query.add(item("or", "(status.neq.done,completed_at.gte.$cutoff)"))
        }
        return RestRequest(path = "tasks", query = query)
    }

    fun task(id: UUID) = RestRequest(
        path = "tasks",
        query = listOf(item("select", TASK_SELECT), item("id", "eq.${uuid(id)}")),
    )

    fun myTasks(me: UUID, includeDone: Boolean): RestRequest {
        val query = mutableListOf(
            item("select", "$TASK_SELECT,mine:task_assignees!inner(assigned_at,assigned_by,user_id),group:groups(name)"),
            item("mine.user_id", "eq.${uuid(me)}"),
        )
        if (!includeDone) {
            query.add(item("status", "neq.done"))
        }
        return RestRequest(path = "tasks", query = query)
    }

    /** Assignments to [me] made by someone else (or by a deleted account) strictly after [since], oldest first. */
    fun assignments(me: UUID, since: Instant) = RestRequest(
        path = "task_assignees",
        query = listOf(
            item("select", "task_id,group_id,assigned_by,assigned_at,task:tasks(title,due_at,group:groups(name))"),
            item("user_id", "eq.${uuid(me)}"),
            item("assigned_at", "gt.${PostgresTimestamp.format(since)}"),
            item("or", "(assigned_by.is.null,assigned_by.neq.${uuid(me)})"),
            item("order", "assigned_at.asc"),
        ),
    )

    fun myProfile(me: UUID) = RestRequest(
        path = "profiles",
        query = listOf(item("select", "id,display_name"), item("id", "eq.${uuid(me)}")),
    )

    fun pushTopic(me: UUID) = RestRequest(
        path = "push_subscriptions",
        query = listOf(item("select", "topic"), item("user_id", "eq.${uuid(me)}")),
    )

    // endregion

    // region Writes

    /**
     * `PATCH profiles?select=id,display_name&id=eq.<me>` with `Prefer: return=representation` (0 rows → `Forbidden`).
     * The explicit `select` keeps the representation to the columns the client reads, so that a later column-level
     * grant on `profiles` does not break renaming.
     */
    fun updateDisplayName(me: UUID, name: String) = RestRequest(
        method = RestRequest.Method.PATCH,
        path = "profiles",
        query = listOf(item("select", "id,display_name"), item("id", "eq.${uuid(me)}")),
        body = JsonValues.obj("display_name" to JsonPrimitive(name)),
        prefer = "return=representation",
    )

    /** `POST /rest/v1/rpc/<name>` with named `p_…` parameters (keys sorted: deterministic bodies). */
    fun rpc(name: String, params: Map<String, JsonElement> = emptyMap()) = RestRequest(
        method = RestRequest.Method.POST,
        path = "rpc/$name",
        body = JsonValues.obj(params),
    )

    // endregion
}

/**
 * JSON values of request bodies. Unlike default serialization, a null is written as an explicit `null`: PostgREST
 * resolves functions by their named parameters, so `update_task` needs `"p_details": null` rather than a missing key.
 */
internal object JsonValues {
    fun obj(vararg entries: Pair<String, JsonElement>): JsonObject = obj(entries.toMap())

    /** An object with sorted keys. */
    fun obj(entries: Map<String, JsonElement>): JsonObject = JsonObject(entries.toSortedMap())

    fun uuid(value: UUID): JsonElement = JsonPrimitive(RestQuery.uuid(value))

    fun string(value: String): JsonElement = JsonPrimitive(value)

    fun optionalString(value: String?): JsonElement = value?.let(::JsonPrimitive) ?: JsonNull

    /** UTC, 6 fractional digits ([PostgresTimestamp.format]), or `null`. */
    fun timestamp(value: Instant?): JsonElement = value?.let { JsonPrimitive(PostgresTimestamp.format(it)) } ?: JsonNull

    /** Sorted (by `uuidString`) array of lower-case UUID strings: deterministic request bodies. */
    fun uuids(values: Collection<UUID>): JsonElement = JsonArray(values.sortedWith(UuidStringOrder).map(::uuid))
}

/**
 * The editable fields of a draft, validated with [InputValidation] in the server's order (title, details, due date);
 * the assignee rules are checked by the server.
 */
internal class TaskFields(draft: TaskDraft) {
    val title: String = InputValidation.taskTitle(draft.title)
    val details: String? = InputValidation.taskDetails(draft.details)
    val dueAt: Instant? = InputValidation.dueDate(draft.dueAt)
    val priority: TaskPriority = draft.priority
    val assigneeIds: Set<UUID> = draft.assigneeIds

    /** Every `p_…` parameter, explicit `null`s included (`update_task` has no defaults). */
    fun params(vararg extra: Pair<String, JsonElement>): Map<String, JsonElement> = mapOf(
        "p_title" to JsonValues.string(title),
        "p_details" to JsonValues.optionalString(details),
        "p_priority" to JsonValues.string(priority.rawValue),
        "p_due_at" to JsonValues.timestamp(dueAt),
        "p_assignee_ids" to JsonValues.uuids(assigneeIds),
    ) + extra
}
