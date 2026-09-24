package io.github.notkanaa.equipe.contract

import io.github.notkanaa.equipe.core.GroupSummary
import io.github.notkanaa.equipe.core.InviteCode
import io.github.notkanaa.equipe.core.JoinResult
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.RealtimeEvent
import io.github.notkanaa.equipe.core.TaskDraft
import io.github.notkanaa.equipe.core.TaskItem
import io.github.notkanaa.equipe.core.TaskPriority
import io.github.notkanaa.equipe.core.uuidString
import java.time.Instant
import java.util.UUID
import kotlin.random.Random

/** Unique values so that scenarios never collide with each other or with existing data on a real server. */
internal object Unique {
    private const val ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

    fun token(length: Int = 6): String {
        val builder = StringBuilder(length)
        repeat(length) { builder.append(ALPHABET[Random.nextInt(ALPHABET.length)]) }
        return builder.toString()
    }

    /** `"<base> <token>"`, e.g. `"Alice K7Q2ZP"`. Bases starting with distinct letters sort predictably. */
    fun name(base: String): String = "$base ${token()}"

    /** A random, well-formed invite code (practically never an existing one). */
    fun inviteCode(): InviteCode = InviteCode.parse(token(InviteCode.length)) ?: InviteCode.parse("ZZZZZZZZ")!!

    /** A fresh e-mail on the same domain as [reference]. */
    fun email(reference: String): String {
        val domain = reference.split("@").lastOrNull()?.takeIf { it.isNotEmpty() } ?: "example.com"
        return "contrat-${token(10).lowercase()}@$domain"
    }
}

/** Deterministic values (whole seconds, so they round-trip exactly through any backend). */
internal object Fixed {
    /** 2031-01-01T00:00:00Z. */
    val dueA: Instant = Instant.ofEpochSecond(1_924_992_000L)

    /** 2031-03-01T12:30:00Z. */
    val dueB: Instant = Instant.ofEpochSecond(1_930_091_400L)

    /** Earlier than any server timestamp. */
    val longAgo: Instant = Instant.EPOCH

    fun text(count: Int): String = "x".repeat(count)
}

/** A group created by a scenario. */
internal class GroupFixture(val id: UUID, val name: String, val code: InviteCode)

internal fun sortedIds(users: List<ContractUser>): List<UUID> = users.map { it.id }.sortedBy { it.uuidString }

internal fun isPushTopic(topic: String): Boolean {
    val prefix = "equipe-"
    if (!topic.startsWith(prefix)) return false
    val suffix = topic.substring(prefix.length)
    return suffix.length == 24 && suffix.all { it in 'a'..'z' || it in '0'..'9' }
}

internal fun isWellFormedCode(code: InviteCode): Boolean =
    code.value.length == InviteCode.length && code.value.all { it in InviteCode.alphabet }

/** Swift's `String.debugDescription`: quoted, with control characters escaped (e.g. U+0000 → `\0`). */
internal fun debugDescription(value: String): String {
    val builder = StringBuilder("\"")
    for (char in value) {
        when {
            char == '\u0000' -> builder.append("\\0")
            char == '\n' -> builder.append("\\n")
            char == '\t' -> builder.append("\\t")
            char == '"' -> builder.append("\\\"")
            char == '\\' -> builder.append("\\\\")
            char.code < 0x20 -> builder.append("\\u{").append(Integer.toHexString(char.code)).append('}')
            else -> builder.append(char)
        }
    }
    return builder.append('"').toString()
}

/** The task without the `myTasks`-only fields, to compare with `task(id)`. */
internal val TaskItem.withoutPersonalFields: TaskItem
    get() = copy(myAssignedAt = null, myAssignedBy = null, groupName = null)

/** A fresh user named `"<base> <token>"`. */
internal suspend fun ContractHarness.user(base: String): ContractUser =
    Verify.step("makeUser($base)") { makeUser(Unique.name(base)) }

/** Creates a group administered by this user; [joinedBy] members then join it, in order. */
internal suspend fun ContractUser.makeGroup(
    base: String = "Groupe",
    joinedBy: List<ContractUser> = emptyList(),
): GroupFixture {
    val name = Unique.name(base)
    val summary = Verify.step("$displayName creates group $name") { groups.createGroup(name) }
    val code = Verify.step("$displayName reads the invite code") { groups.inviteCode(summary.id) }
    val fixture = GroupFixture(summary.id, name, code)
    for (member in joinedBy) {
        val result = member.join(fixture)
        Verify.that(!result.alreadyMember, "${member.displayName} should be a new member of $name")
    }
    return fixture
}

internal suspend fun ContractUser.join(group: GroupFixture): JoinResult =
    Verify.step("$displayName joins ${group.name}") { groups.join(group.code) }

/** Creates a task titled `"<base> <token>"`. */
internal suspend fun ContractUser.makeTask(
    groupId: UUID,
    base: String = "Tâche",
    assignees: List<ContractUser> = emptyList(),
    priority: TaskPriority = TaskPriority.MEDIUM,
    dueAt: Instant? = null,
): TaskItem {
    val draft = TaskDraft(
        title = Unique.name(base), priority = priority, dueAt = dueAt, assigneeIds = assignees.map { it.id }.toSet(),
    )
    return Verify.step("$displayName creates task ${draft.title}") { tasks.create(groupId, draft) }
}

/** Full edit keeping the current fields, only replacing the assignees. */
internal suspend fun ContractUser.reassign(task: TaskItem, users: List<ContractUser>): TaskItem {
    val draft = TaskDraft(task).copy(assigneeIds = users.map { it.id }.toSet())
    return tasks.update(task.id, draft)
}

internal suspend fun ContractUser.summary(groupId: UUID): GroupSummary? = groups.myGroups().firstOrNull { it.id == groupId }

internal suspend fun ContractUser.lastActivity(groupId: UUID): Instant =
    Verify.unwrap(summary(groupId), "group $groupId in $displayName's groups").group.lastActivityAt

/** Checks that the group's `lastActivityAt` moved strictly after [previous]; returns the new value. */
internal suspend fun ContractUser.checkBumped(groupId: UUID, previous: Instant, action: String): Instant {
    val current = lastActivity(groupId)
    Verify.that(current > previous, "$action must bump lastActivityAt ($previous → $current)")
    return current
}

/** Member ids in the order returned by `members(groupId)`. */
internal suspend fun ContractUser.memberIds(groupId: UUID): List<UUID> = groups.members(groupId).map { it.user.id }

internal suspend fun ContractUser.role(groupId: UUID): MemberRole? = summary(groupId)?.myRole

/**
 * Subscribes to Realtime for [groupIds] plus a private barrier group, waits for `Connected`, then flushes (see
 * [RealtimeProbe]): changes committed before the subscription, which a real server may still deliver after
 * `Connected`, are then behind any later `mark()`.
 */
internal suspend fun ContractUser.subscribe(groupIds: List<UUID>): RealtimeProbe {
    val barrier = Verify.step("$displayName creates a barrier group") { groups.createGroup(Unique.name("Barriere")) }
    val probe = RealtimeProbe(StreamProbe(realtime.events(id, groupIds + barrier.id)), this, barrier.id)
    try {
        probe.waitFor("$displayName: .connected") { it == RealtimeEvent.Connected }
        probe.flush("the subscription")
    } catch (error: Throwable) {
        probe.stop()
        throw error
    }
    return probe
}

/**
 * A scenario user's Realtime subscription whose filter also contains a barrier group of that user.
 *
 * [flush] bumps the barrier group and waits for its `GroupActivity`: Realtime delivers changes in commit order, so
 * every change committed before the flush has then been received. Positive checks wait for an event after a
 * [mark]; absence checks look at the events between a mark and a flush.
 */
internal class RealtimeProbe(
    val stream: StreamProbe<RealtimeEvent>,
    val owner: ContractUser,
    val barrier: UUID,
) {
    val events: List<RealtimeEvent> get() = stream.events

    fun mark(): Int = stream.mark()

    fun stop() {
        stream.stop()
    }

    suspend fun waitFor(
        description: String,
        after: Int = 0,
        predicate: (RealtimeEvent) -> Boolean,
    ): IndexedValue<RealtimeEvent> = stream.waitFor(description, after, predicate = predicate)

    /** Bumps the barrier group and waits for its event; returns that event's index. */
    suspend fun flush(label: String): Int {
        val start = mark()
        Verify.step("${owner.displayName} bumps the barrier after $label") {
            owner.groups.rename(barrier, Unique.name("Barriere"))
        }
        val barrierEvent = RealtimeEvent.GroupActivity(barrier)
        return waitFor("${owner.displayName}: barrier after $label", after = start) { it == barrierEvent }.index
    }

    /** Flushes, then checks that no event matching [predicate] arrived since [start]. */
    suspend fun expectNone(start: Int, description: String, predicate: (RealtimeEvent) -> Boolean) {
        val end = flush(description)
        val window = events.subList(start, end)
        Verify.that(window.none(predicate), "$description: unexpected event in $window")
    }
}

/** Runs [body] with [probe], then stops it (Swift `defer { probe.stop() }`). */
internal inline fun <T> RealtimeProbe.use(body: (RealtimeProbe) -> T): T = try {
    body(this)
} finally {
    stop()
}

/** Runs [body] with [probe], then stops it (Swift `defer { probe.stop() }`). */
internal inline fun <E, T> StreamProbe<E>.use(body: (StreamProbe<E>) -> T): T = try {
    body(this)
} finally {
    stop()
}
