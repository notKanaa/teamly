package io.github.notkanaa.equipe.mocks

import io.github.notkanaa.equipe.contract.ContractHarness
import io.github.notkanaa.equipe.contract.ContractUser
import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.AppServices
import io.github.notkanaa.equipe.core.AssignmentEvent
import io.github.notkanaa.equipe.core.GroupService
import io.github.notkanaa.equipe.core.GroupSummary
import io.github.notkanaa.equipe.core.InviteCode
import io.github.notkanaa.equipe.core.JoinResult
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.Membership
import io.github.notkanaa.equipe.core.ProfileService
import io.github.notkanaa.equipe.core.RealtimeEvent
import io.github.notkanaa.equipe.core.RealtimeService
import io.github.notkanaa.equipe.core.TaskDraft
import io.github.notkanaa.equipe.core.TaskItem
import io.github.notkanaa.equipe.core.TaskService
import io.github.notkanaa.equipe.core.TaskStatus
import io.github.notkanaa.equipe.core.TeamGroup
import io.github.notkanaa.equipe.core.UserProfile
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.SendChannel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.launch
import java.time.Instant
import java.util.UUID

// Port of the decorators of ScenarioMutationTests.swift: deliberate misbehaviours injected around the mock services.
// A contract scenario that still passes on a misbehaving backend would not protect the Supabase adapters, so each
// mutation must be detected.

enum class ScenarioMutation {
    /** A non-member renaming an existing group gets `NotFound` (lead decision: `Forbidden`). */
    RENAME_NON_MEMBER_NOT_FOUND,

    /** Renaming an unknown group gives `Forbidden` (lead decision: `NotFound`). */
    RENAME_UNKNOWN_FORBIDDEN,
    DELETE_NON_MEMBER_NOT_FOUND,
    DELETE_UNKNOWN_FORBIDDEN,

    /** Non-members reading members / tasks get an error instead of an empty list. */
    NON_MEMBER_READS_THROW,

    /** `regenerate_invite_code`, `set_member_role`, `remove_member` on an unknown group → `NotFound` (lead: `Forbidden`). */
    UNKNOWN_GROUP_NOT_FOUND,

    /** An RPC called without a session → `Forbidden` (contract: `NotAuthenticated`). */
    SIGNED_OUT_FORBIDDEN,

    /** Every subscriber receives `Assigned` for every new assignment (missing `user_id=eq.<me>` filter). */
    ASSIGNED_TO_EVERYONE,

    /** Every subscriber receives `MembershipsChanged` for everyone's membership changes (missing `id=eq.<me>`). */
    MEMBERSHIPS_CHANGED_TO_EVERYONE,

    /** Subscribers receive `GroupActivity` for groups of their filter they are not a member of (no RLS). */
    ACTIVITY_TO_NON_MEMBERS,

    /**
     * Real-server race: changes committed before the subscription arrive after `Connected` (released on the first
     * write that follows); combined with `create_task` emitting no signal.
     */
    STALE_EVENTS_AND_SILENT_TASK_CREATION,
}

/** [MockHarness] whose users' services are wrapped by decorators applying one mutation (none: transparent). */
class MutationHarness(mutation: ScenarioMutation?) : ContractHarness {
    private val base = MockHarness()
    private val registry = MutationRegistry(mutation)

    override suspend fun makeUser(displayName: String): ContractUser {
        val user = base.makeUser(displayName)
        val plain = user.services
        val services = AppServices(
            auth = plain.auth,
            profiles = MutatedProfileService(plain.profiles, registry),
            groups = MutatedGroupService(plain.groups, registry),
            tasks = MutatedTaskService(plain.tasks, plain.groups, user.id, registry),
            realtime = MutatedRealtimeService(plain.realtime, user.id, registry),
            push = plain.push,
        )
        return ContractUser(user.authUser, user.displayName, user.email, user.password, services)
    }
}

/** Shared state of the decorated services of one harness: known groups and live Realtime subscriptions. */
class MutationRegistry(val mutation: ScenarioMutation?) {
    private class Subscription(
        val owner: UUID,
        val groupIds: List<UUID>,
        val channel: SendChannel<RealtimeEvent>,
        var staleArmed: Boolean,
    ) {
        val suppressed = HashMap<UUID, Int>()
    }

    private val lock = Any()
    private val subscriptions = LinkedHashMap<UUID, Subscription>()
    private val knownGroups = HashSet<UUID>()

    fun rememberGroup(groupId: UUID) {
        synchronized(lock) { knownGroups.add(groupId) }
    }

    fun isKnownGroup(groupId: UUID): Boolean = synchronized(lock) { groupId in knownGroups }

    /**
     * Wraps a Realtime flow: events are forwarded in order into one channel, where mutations may also inject events
     * (synchronously, before the caller goes on) or drop some.
     */
    fun subscribe(base: Flow<RealtimeEvent>, owner: UUID, groupIds: List<UUID>): Flow<RealtimeEvent> = flow {
        val channel = Channel<RealtimeEvent>(Channel.UNLIMITED)
        val id = UUID.randomUUID()
        synchronized(lock) {
            subscriptions[id] = Subscription(
                owner, groupIds, channel, staleArmed = mutation == ScenarioMutation.STALE_EVENTS_AND_SILENT_TASK_CREATION,
            )
        }
        try {
            coroutineScope {
                val forwarder = launch(start = CoroutineStart.UNDISPATCHED) {
                    base.collect { event ->
                        if (event is RealtimeEvent.GroupActivity && consumeSuppression(id, event.groupId)) return@collect
                        channel.trySend(event)
                    }
                }
                try {
                    for (event in channel) emit(event)
                } finally {
                    forwarder.cancel()
                }
            }
        } finally {
            synchronized(lock) { subscriptions.remove(id) }
        }
    }

    private fun consumeSuppression(id: UUID, groupId: UUID): Boolean = synchronized(lock) {
        val subscription = subscriptions[id] ?: return@synchronized false
        val count = subscription.suppressed[groupId] ?: 0
        if (count <= 0) return@synchronized false
        subscription.suppressed[groupId] = count - 1
        true
    }

    /** Sends [event] into every subscription matching [condition]. */
    private fun inject(event: RealtimeEvent, condition: (Subscription) -> Boolean = { true }) {
        synchronized(lock) {
            for (subscription in subscriptions.values) {
                if (condition(subscription)) subscription.channel.trySend(event)
            }
        }
    }

    /** Called before every write: releases the stale events of the subscriptions made since the last write. */
    fun beforeWrite() {
        if (mutation != ScenarioMutation.STALE_EVENTS_AND_SILENT_TASK_CREATION) return
        synchronized(lock) {
            for (subscription in subscriptions.values) {
                if (!subscription.staleArmed) continue
                for (groupId in subscription.groupIds) subscription.channel.trySend(RealtimeEvent.GroupActivity(groupId))
                subscription.channel.trySend(RealtimeEvent.MembershipsChanged)
                subscription.staleArmed = false
            }
        }
    }

    /** Drops the next `GroupActivity(groupId)` of every subscription watching the group. */
    fun suppressNextActivity(groupId: UUID) {
        synchronized(lock) {
            for (subscription in subscriptions.values) {
                if (groupId in subscription.groupIds) {
                    subscription.suppressed[groupId] = (subscription.suppressed[groupId] ?: 0) + 1
                }
            }
        }
    }

    /** After a write that bumps [groupId]. */
    fun groupChanged(groupId: UUID) {
        if (mutation != ScenarioMutation.ACTIVITY_TO_NON_MEMBERS) return
        inject(RealtimeEvent.GroupActivity(groupId)) { groupId in it.groupIds }
    }

    /** After a write that changes someone's membership. */
    fun membershipChanged() {
        if (mutation != ScenarioMutation.MEMBERSHIPS_CHANGED_TO_EVERYONE) return
        inject(RealtimeEvent.MembershipsChanged)
    }

    /** After new assignment rows of [userIds]. */
    fun assigned(userIds: Set<UUID>, taskId: UUID, groupId: UUID, assigner: UUID) {
        if (mutation != ScenarioMutation.ASSIGNED_TO_EVERYONE) return
        for (userId in userIds) {
            inject(RealtimeEvent.Assigned(taskId, groupId, assigner)) { it.owner != userId }
        }
    }
}

class MutatedRealtimeService(
    private val base: RealtimeService,
    private val owner: UUID,
    private val registry: MutationRegistry,
) : RealtimeService {
    override fun events(userId: UUID, groupIds: List<UUID>): Flow<RealtimeEvent> =
        registry.subscribe(base.events(userId, groupIds), owner, groupIds)
}

class MutatedProfileService(
    private val base: ProfileService,
    private val registry: MutationRegistry,
) : ProfileService {
    override suspend fun myProfile(): UserProfile = base.myProfile()

    override suspend fun updateDisplayName(name: String): UserProfile {
        registry.beforeWrite()
        return base.updateDisplayName(name)
    }
}

class MutatedGroupService(
    private val base: GroupService,
    private val registry: MutationRegistry,
) : GroupService {
    private val mutation: ScenarioMutation? get() = registry.mutation

    private suspend fun isMember(groupId: UUID): Boolean {
        val groups = try {
            base.myGroups()
        } catch (error: AppError) {
            emptyList()
        }
        return groups.any { it.id == groupId }
    }

    override suspend fun myGroups(): List<GroupSummary> = base.myGroups()

    override suspend fun createGroup(name: String): GroupSummary {
        registry.beforeWrite()
        try {
            val summary = base.createGroup(name)
            registry.rememberGroup(summary.id)
            registry.membershipChanged()
            return summary
        } catch (error: AppError.NotAuthenticated) {
            if (mutation == ScenarioMutation.SIGNED_OUT_FORBIDDEN) throw AppError.Forbidden
            throw error
        }
    }

    override suspend fun join(code: InviteCode): JoinResult {
        registry.beforeWrite()
        val result = base.join(code)
        if (!result.alreadyMember) {
            registry.membershipChanged()
            registry.groupChanged(result.groupId)
        }
        return result
    }

    override suspend fun rename(groupId: UUID, name: String): TeamGroup {
        registry.beforeWrite()
        try {
            val group = base.rename(groupId, name)
            registry.groupChanged(groupId)
            return group
        } catch (error: AppError.Forbidden) {
            if (mutation == ScenarioMutation.RENAME_NON_MEMBER_NOT_FOUND && !isMember(groupId)) throw AppError.NotFound
            throw error
        } catch (error: AppError.NotFound) {
            if (mutation == ScenarioMutation.RENAME_UNKNOWN_FORBIDDEN) throw AppError.Forbidden
            throw error
        }
    }

    override suspend fun deleteGroup(groupId: UUID) {
        registry.beforeWrite()
        try {
            base.deleteGroup(groupId)
            registry.membershipChanged()
        } catch (error: AppError.Forbidden) {
            if (mutation == ScenarioMutation.DELETE_NON_MEMBER_NOT_FOUND && !isMember(groupId)) throw AppError.NotFound
            throw error
        } catch (error: AppError.NotFound) {
            if (mutation == ScenarioMutation.DELETE_UNKNOWN_FORBIDDEN) throw AppError.Forbidden
            throw error
        }
    }

    override suspend fun members(groupId: UUID): List<Membership> {
        if (mutation == ScenarioMutation.NON_MEMBER_READS_THROW && !isMember(groupId)) throw AppError.Forbidden
        return base.members(groupId)
    }

    override suspend fun inviteCode(groupId: UUID): InviteCode = base.inviteCode(groupId)

    override suspend fun regenerateInviteCode(groupId: UUID): InviteCode {
        registry.beforeWrite()
        try {
            return base.regenerateInviteCode(groupId)
        } catch (error: AppError.Forbidden) {
            throw unknownGroupError(groupId, error)
        }
    }

    override suspend fun setRole(groupId: UUID, userId: UUID, role: MemberRole) {
        registry.beforeWrite()
        try {
            base.setRole(groupId, userId, role)
            registry.membershipChanged()
            registry.groupChanged(groupId)
        } catch (error: AppError.Forbidden) {
            throw unknownGroupError(groupId, error)
        }
    }

    override suspend fun removeMember(groupId: UUID, userId: UUID) {
        registry.beforeWrite()
        try {
            base.removeMember(groupId, userId)
            registry.membershipChanged()
            registry.groupChanged(groupId)
        } catch (error: AppError.Forbidden) {
            throw unknownGroupError(groupId, error)
        }
    }

    override suspend fun leave(groupId: UUID) {
        registry.beforeWrite()
        base.leave(groupId)
        registry.membershipChanged()
        registry.groupChanged(groupId)
    }

    private fun unknownGroupError(groupId: UUID, error: AppError): AppError =
        if (mutation == ScenarioMutation.UNKNOWN_GROUP_NOT_FOUND && !registry.isKnownGroup(groupId)) AppError.NotFound else error
}

class MutatedTaskService(
    private val base: TaskService,
    private val groups: GroupService,
    private val owner: UUID,
    private val registry: MutationRegistry,
) : TaskService {
    private val mutation: ScenarioMutation? get() = registry.mutation

    private suspend fun isMember(groupId: UUID): Boolean {
        val summaries = try {
            groups.myGroups()
        } catch (error: AppError) {
            emptyList()
        }
        return summaries.any { it.id == groupId }
    }

    override suspend fun tasks(groupId: UUID, includeOldDone: Boolean): List<TaskItem> {
        if (mutation == ScenarioMutation.NON_MEMBER_READS_THROW && !isMember(groupId)) throw AppError.NotFound
        return base.tasks(groupId, includeOldDone)
    }

    override suspend fun myTasks(includeDone: Boolean): List<TaskItem> = base.myTasks(includeDone)

    override suspend fun task(id: UUID): TaskItem = base.task(id)

    override suspend fun create(groupId: UUID, draft: TaskDraft): TaskItem {
        registry.beforeWrite()
        if (mutation == ScenarioMutation.STALE_EVENTS_AND_SILENT_TASK_CREATION) registry.suppressNextActivity(groupId)
        val task = base.create(groupId, draft)
        registry.assigned(task.assigneeIds.toSet(), task.id, task.groupId, owner)
        registry.groupChanged(task.groupId)
        return task
    }

    override suspend fun update(taskId: UUID, draft: TaskDraft): TaskItem {
        registry.beforeWrite()
        val before = try {
            base.task(taskId).assigneeIds.toSet()
        } catch (error: AppError) {
            emptySet()
        }
        val task = base.update(taskId, draft)
        registry.assigned(task.assigneeIds.toSet() - before, task.id, task.groupId, owner)
        registry.groupChanged(task.groupId)
        return task
    }

    override suspend fun setStatus(taskId: UUID, status: TaskStatus): TaskItem {
        registry.beforeWrite()
        val task = base.setStatus(taskId, status)
        registry.groupChanged(task.groupId)
        return task
    }

    override suspend fun delete(taskId: UUID) {
        registry.beforeWrite()
        base.delete(taskId)
    }

    override suspend fun assignments(since: Instant): List<AssignmentEvent> = base.assignments(since)
}
