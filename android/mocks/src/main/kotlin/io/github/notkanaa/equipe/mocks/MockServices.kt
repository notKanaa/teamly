package io.github.notkanaa.equipe.mocks

import io.github.notkanaa.equipe.core.AssignmentEvent
import io.github.notkanaa.equipe.core.AuthService
import io.github.notkanaa.equipe.core.AuthState
import io.github.notkanaa.equipe.core.AuthUser
import io.github.notkanaa.equipe.core.GroupService
import io.github.notkanaa.equipe.core.GroupSummary
import io.github.notkanaa.equipe.core.InviteCode
import io.github.notkanaa.equipe.core.JoinResult
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.Membership
import io.github.notkanaa.equipe.core.ProfileService
import io.github.notkanaa.equipe.core.PushService
import io.github.notkanaa.equipe.core.RealtimeEvent
import io.github.notkanaa.equipe.core.RealtimeService
import io.github.notkanaa.equipe.core.SignUpOutcome
import io.github.notkanaa.equipe.core.TaskDraft
import io.github.notkanaa.equipe.core.TaskItem
import io.github.notkanaa.equipe.core.TaskService
import io.github.notkanaa.equipe.core.TaskStatus
import io.github.notkanaa.equipe.core.TeamGroup
import io.github.notkanaa.equipe.core.UserProfile
import kotlinx.coroutines.flow.Flow
import java.time.Instant
import java.util.UUID

// Core service implementations bound to one client session of an `InMemoryBackend`.
// Every call first waits for the backend's artificial latency (zero by default).

internal class MockAuthService(private val session: MockSession) : AuthService {
    private val backend get() = session.backend

    override fun authStates(): Flow<AuthState> = backend.authStates(session.clientId)

    override suspend fun currentUser(): AuthUser? = backend.currentUser(session.clientId)

    override suspend fun signUp(email: String, password: String, displayName: String): SignUpOutcome {
        backend.simulateLatency()
        return backend.signUp(session.clientId, email, password, displayName)
    }

    override suspend fun signIn(email: String, password: String) {
        backend.simulateLatency()
        backend.signIn(session.clientId, email, password)
    }

    override suspend fun signOut() {
        backend.simulateLatency()
        backend.signOut(session.clientId)
    }

    /** The mock "e-mail" always contains [InMemoryBackend.recoveryCode]. */
    override suspend fun sendPasswordReset(email: String) {
        backend.simulateLatency()
        backend.sendPasswordReset(email)
    }

    override suspend fun verifyRecoveryCode(email: String, code: String) {
        backend.simulateLatency()
        backend.verifyRecoveryCode(session.clientId, email, code)
    }

    override suspend fun updatePassword(newPassword: String) {
        backend.simulateLatency()
        backend.updatePassword(session.clientId, newPassword)
    }

    override suspend fun deleteAccount() {
        backend.simulateLatency()
        backend.deleteAccount(session.clientId)
    }
}

internal class MockProfileService(private val session: MockSession) : ProfileService {
    private val backend get() = session.backend

    override suspend fun myProfile(): UserProfile {
        backend.simulateLatency()
        return backend.myProfile(session.clientId)
    }

    override suspend fun updateDisplayName(name: String): UserProfile {
        backend.simulateLatency()
        return backend.updateDisplayName(session.clientId, name)
    }
}

internal class MockGroupService(private val session: MockSession) : GroupService {
    private val backend get() = session.backend

    override suspend fun myGroups(): List<GroupSummary> {
        backend.simulateLatency()
        return backend.myGroups(session.clientId)
    }

    override suspend fun createGroup(name: String): GroupSummary {
        backend.simulateLatency()
        return backend.createGroup(session.clientId, name)
    }

    override suspend fun join(code: InviteCode): JoinResult {
        backend.simulateLatency()
        return backend.join(session.clientId, code)
    }

    override suspend fun rename(groupId: UUID, name: String): TeamGroup {
        backend.simulateLatency()
        return backend.rename(session.clientId, groupId, name)
    }

    override suspend fun deleteGroup(groupId: UUID) {
        backend.simulateLatency()
        backend.deleteGroup(session.clientId, groupId)
    }

    override suspend fun members(groupId: UUID): List<Membership> {
        backend.simulateLatency()
        return backend.members(session.clientId, groupId)
    }

    override suspend fun inviteCode(groupId: UUID): InviteCode {
        backend.simulateLatency()
        return backend.inviteCode(session.clientId, groupId)
    }

    override suspend fun regenerateInviteCode(groupId: UUID): InviteCode {
        backend.simulateLatency()
        return backend.regenerateInviteCode(session.clientId, groupId)
    }

    override suspend fun setRole(groupId: UUID, userId: UUID, role: MemberRole) {
        backend.simulateLatency()
        backend.setRole(session.clientId, groupId, userId, role)
    }

    override suspend fun removeMember(groupId: UUID, userId: UUID) {
        backend.simulateLatency()
        backend.removeMember(session.clientId, groupId, userId)
    }

    override suspend fun leave(groupId: UUID) {
        backend.simulateLatency()
        backend.leave(session.clientId, groupId)
    }
}

internal class MockTaskService(private val session: MockSession) : TaskService {
    private val backend get() = session.backend

    override suspend fun tasks(groupId: UUID, includeOldDone: Boolean): List<TaskItem> {
        backend.simulateLatency()
        return backend.tasks(session.clientId, groupId, includeOldDone)
    }

    override suspend fun myTasks(includeDone: Boolean): List<TaskItem> {
        backend.simulateLatency()
        return backend.myTasks(session.clientId, includeDone)
    }

    override suspend fun task(id: UUID): TaskItem {
        backend.simulateLatency()
        return backend.task(session.clientId, id)
    }

    override suspend fun create(groupId: UUID, draft: TaskDraft): TaskItem {
        backend.simulateLatency()
        return backend.createTask(session.clientId, groupId, draft)
    }

    override suspend fun update(taskId: UUID, draft: TaskDraft): TaskItem {
        backend.simulateLatency()
        return backend.updateTask(session.clientId, taskId, draft)
    }

    override suspend fun setStatus(taskId: UUID, status: TaskStatus): TaskItem {
        backend.simulateLatency()
        return backend.setStatus(session.clientId, taskId, status)
    }

    override suspend fun delete(taskId: UUID) {
        backend.simulateLatency()
        backend.deleteTask(session.clientId, taskId)
    }

    override suspend fun assignments(since: Instant): List<AssignmentEvent> {
        backend.simulateLatency()
        return backend.assignments(session.clientId, since)
    }
}

internal class MockRealtimeService(private val session: MockSession) : RealtimeService {
    /**
     * Emits [RealtimeEvent.Connected] as soon as it is collected, then the change signals of docs/CONTRACTS.md §6
     * for [userId], as far as this client's session may see them (nothing while signed out).
     */
    override fun events(userId: UUID, groupIds: List<UUID>): Flow<RealtimeEvent> =
        session.backend.subscribe(session.clientId, userId, groupIds)
}

internal class MockPushService(private val session: MockSession) : PushService {
    private val backend get() = session.backend

    override suspend fun currentTopic(): String? {
        backend.simulateLatency()
        return backend.currentPushTopic(session.clientId)
    }

    override suspend fun enable(): String {
        backend.simulateLatency()
        return backend.enablePush(session.clientId)
    }

    override suspend fun disable() {
        backend.simulateLatency()
        backend.disablePush(session.clientId)
    }
}
