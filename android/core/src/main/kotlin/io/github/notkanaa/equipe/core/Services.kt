package io.github.notkanaa.equipe.core

import kotlinx.coroutines.flow.Flow
import java.time.Instant
import java.util.UUID

// Port of TeamTasksCore/Services/Services.swift.
// Every `suspend` method throws `AppError` only (implementations map backend errors with `BackendErrorMapper`),
// except coroutine cancellation, which propagates as `CancellationException`.
// Semantics are specified in docs/CONTRACTS.md; the mocks (:mocks) and the Supabase adapters (:supabase) must behave
// identically.

interface AuthService {
    /** Emits the current state first (possibly [AuthState.Unknown] until the stored session is restored), then every change. */
    fun authStates(): Flow<AuthState>

    suspend fun currentUser(): AuthUser?

    suspend fun signUp(email: String, password: String, displayName: String): SignUpOutcome

    suspend fun signIn(email: String, password: String)

    suspend fun signOut()

    /** Sends a 6-digit recovery code by e-mail. */
    suspend fun sendPasswordReset(email: String)

    /** Verifies the recovery code. On success the user is signed in (recovery session). */
    suspend fun verifyRecoveryCode(email: String, code: String)

    /** Sets a new password for the signed-in user. */
    suspend fun updatePassword(newPassword: String)

    /** Deletes the account and all personal data (RPC `delete_my_account`), then signs out locally. */
    suspend fun deleteAccount()
}

interface ProfileService {
    suspend fun myProfile(): UserProfile

    suspend fun updateDisplayName(name: String): UserProfile
}

interface GroupService {
    /** Groups the current user belongs to, most recently active first ([NameOrder.sortedGroups]). */
    suspend fun myGroups(): List<GroupSummary>

    suspend fun createGroup(name: String): GroupSummary

    /** Throws [AppError.InvalidCode] or [AppError.RateLimited]. */
    suspend fun join(code: InviteCode): JoinResult

    suspend fun rename(groupId: UUID, name: String): TeamGroup

    suspend fun deleteGroup(groupId: UUID)

    /** Members sorted by role (admins first) then display name ([NameOrder.sortedMembers]). */
    suspend fun members(groupId: UUID): List<Membership>

    /** Admins only. */
    suspend fun inviteCode(groupId: UUID): InviteCode

    /** Admins only. The previous code stops working. */
    suspend fun regenerateInviteCode(groupId: UUID): InviteCode

    suspend fun setRole(groupId: UUID, userId: UUID, role: MemberRole)

    suspend fun removeMember(groupId: UUID, userId: UUID)

    suspend fun leave(groupId: UUID)
}

interface TaskService {
    /** Tasks of a group. Done tasks completed more than [Limits.oldDoneTaskDays] ago are omitted unless [includeOldDone]. */
    suspend fun tasks(groupId: UUID, includeOldDone: Boolean): List<TaskItem>

    /** Tasks assigned to the current user across all groups (with `myAssignedAt`, `myAssignedBy` and `groupName` filled). */
    suspend fun myTasks(includeDone: Boolean): List<TaskItem>

    suspend fun task(id: UUID): TaskItem

    suspend fun create(groupId: UUID, draft: TaskDraft): TaskItem

    /** Full edit (fields + assignees), atomic. Admin or creator only. */
    suspend fun update(taskId: UUID, draft: TaskDraft): TaskItem

    /** Admin, creator or assignee. */
    suspend fun setStatus(taskId: UUID, status: TaskStatus): TaskItem

    /** Admin or creator only. */
    suspend fun delete(taskId: UUID)

    /** Assignments to the current user made by someone else after [since] (exclusive), oldest first. */
    suspend fun assignments(since: Instant): List<AssignmentEvent>
}

interface RealtimeService {
    /**
     * Live change signals for the current user. The flow is cold: collecting subscribes, cancelling the collector
     * unsubscribes. Emits [RealtimeEvent.Connected] on every (re)subscription.
     */
    fun events(userId: UUID, groupIds: List<UUID>): Flow<RealtimeEvent>
}

/** Optional "real push" through the free ntfy app (docs/NOTIFICATIONS.md). */
interface PushService {
    /** The current user's private ntfy topic, if enabled. */
    suspend fun currentTopic(): String?

    /** Enables push and returns the (new or existing) topic. */
    suspend fun enable(): String

    suspend fun disable()
}

/** All backend services, injected into view models. */
data class AppServices(
    val auth: AuthService,
    val profiles: ProfileService,
    val groups: GroupService,
    val tasks: TaskService,
    val realtime: RealtimeService,
    val push: PushService,
)
