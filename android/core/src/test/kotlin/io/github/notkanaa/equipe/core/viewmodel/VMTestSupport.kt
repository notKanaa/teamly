package io.github.notkanaa.equipe.core.viewmodel

import io.github.notkanaa.equipe.core.AppCalendar
import io.github.notkanaa.equipe.core.AppServices
import io.github.notkanaa.equipe.core.AssignmentEvent
import io.github.notkanaa.equipe.core.AuthService
import io.github.notkanaa.equipe.core.AuthUser
import io.github.notkanaa.equipe.core.GroupService
import io.github.notkanaa.equipe.core.GroupSummary
import io.github.notkanaa.equipe.core.InMemoryKeyValueStore
import io.github.notkanaa.equipe.core.InviteCode
import io.github.notkanaa.equipe.core.JoinResult
import io.github.notkanaa.equipe.core.LocalNotification
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.Membership
import io.github.notkanaa.equipe.core.NotificationAuthorization
import io.github.notkanaa.equipe.core.NotificationScheduler
import io.github.notkanaa.equipe.core.PlatformServices
import io.github.notkanaa.equipe.core.ProfileService
import io.github.notkanaa.equipe.core.PushService
import io.github.notkanaa.equipe.core.SignUpOutcome
import io.github.notkanaa.equipe.core.TaskDraft
import io.github.notkanaa.equipe.core.TaskItem
import io.github.notkanaa.equipe.core.TaskService
import io.github.notkanaa.equipe.core.TaskStatus
import io.github.notkanaa.equipe.core.TeamGroup
import io.github.notkanaa.equipe.core.UserProfile
import io.github.notkanaa.equipe.core.logic.ReminderPlanner
import io.github.notkanaa.equipe.mocks.DemoData
import io.github.notkanaa.equipe.mocks.DemoUser
import io.github.notkanaa.equipe.mocks.InMemoryBackend
import io.github.notkanaa.equipe.mocks.MockClock
import io.github.notkanaa.equipe.mocks.MockEnvironment
import io.github.notkanaa.equipe.mocks.MockScenario
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import org.junit.Assert.fail
import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime
import java.util.UUID
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

// Test doubles of the view model suites (port of Tests/TeamTasksCoreTests/ViewModels/VMTestSupport.swift). Names are
// prefixed with `VM` so they never clash with helpers of the other suites of this source set.
// Swift waits in real time (VMWait); here everything runs on the virtual time of kotlinx-coroutines-test: long-lived
// work (sessions, realtime, fetch jobs) runs in the test's `backgroundScope`.

// region Fixtures

object VMFixtures {
    val paris: ZoneId = AppCalendar.PARIS
    val calendar: AppCalendar = AppCalendar.frenchGregorian(paris)

    /** Thursday 24 September 2026, 10:00 in Paris. */
    val now: Instant = date(2026, 9, 24, 10)

    fun date(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0): Instant =
        ZonedDateTime.of(year, month, day, hour, minute, 0, 0, paris).toInstant()

    val camille: DemoUser = DemoData.camille
    val lucas: DemoUser = DemoData.lucas
    val ines: DemoUser = DemoData.ines
    val lilas: UUID = DemoData.lilasGroupId
    val sport: UUID = DemoData.sportGroupId
}

// endregion

// region Waiting (virtual time)

/**
 * Lets the scheduled work run until [condition] holds (Swift `VMWait.until`); fails after [timeout] of virtual time.
 */
@OptIn(ExperimentalCoroutinesApi::class)
suspend fun TestScope.waitUntil(description: String, timeout: Duration = 5.seconds, condition: () -> Boolean) {
    runCurrent()
    val deadline = currentTime + timeout.inWholeMilliseconds
    while (!condition()) {
        if (currentTime >= deadline) fail("Timed out waiting for $description")
        delay(1)
    }
}

/** Lets already-scheduled work run (Swift `VMWait.settle`). */
@OptIn(ExperimentalCoroutinesApi::class)
fun TestScope.settle() {
    runCurrent()
    advanceTimeBy(2)
    runCurrent()
}

/** Asserts that [block] throws a cancellation (a service answering `CancellationException` is never shown). */
suspend fun assertCancels(block: suspend () -> Unit) {
    try {
        block()
    } catch (error: kotlin.coroutines.cancellation.CancellationException) {
        return
    }
    fail("expected a CancellationException")
}

// endregion

// region Notification scheduler

class VMScheduler(
    authorization: NotificationAuthorization = NotificationAuthorization.AUTHORIZED,
    grantOnRequest: Boolean = true,
) : NotificationScheduler {
    private val lock = Any()
    private var authorizationValue = authorization
    private var grantOnRequestValue = grantOnRequest
    private val pendingById = HashMap<String, LocalNotification>()
    private val deliveredLog = ArrayList<LocalNotification>()
    private var requests = 0

    var authorization: NotificationAuthorization
        get() = synchronized(lock) { authorizationValue }
        set(value) = synchronized(lock) { authorizationValue = value }

    var grantOnRequest: Boolean
        get() = synchronized(lock) { grantOnRequestValue }
        set(value) = synchronized(lock) { grantOnRequestValue = value }

    val pending: Map<String, LocalNotification> get() = synchronized(lock) { HashMap(pendingById) }

    /** Pending due-date reminders, sorted. */
    val dueIds: List<String> get() = synchronized(lock) { pendingById.keys.filter { it.startsWith("due-") }.sorted() }

    /** "Deliver now" notifications (assignments, summaries), in order. */
    val delivered: List<LocalNotification> get() = synchronized(lock) { deliveredLog.toList() }

    val requestCount: Int get() = synchronized(lock) { requests }

    fun clearPending() {
        synchronized(lock) { pendingById.clear() }
    }

    override suspend fun authorizationStatus(): NotificationAuthorization = synchronized(lock) { authorizationValue }

    override suspend fun requestAuthorization(): Boolean = synchronized(lock) {
        requests += 1
        if (authorizationValue == NotificationAuthorization.NOT_DETERMINED) {
            authorizationValue = if (grantOnRequestValue) NotificationAuthorization.AUTHORIZED else NotificationAuthorization.DENIED
        }
        authorizationValue == NotificationAuthorization.AUTHORIZED
    }

    override suspend fun pendingIdentifiers(prefix: String): List<String> =
        synchronized(lock) { pendingById.keys.filter { it.startsWith(prefix) }.sorted() }

    override suspend fun add(notification: LocalNotification) {
        synchronized(lock) {
            if (notification.fireDate == null) {
                deliveredLog.add(notification)
            } else {
                pendingById[notification.id] = notification
            }
        }
    }

    override suspend fun removePending(ids: List<String>) {
        synchronized(lock) { for (id in ids) pendingById.remove(id) }
    }

    override suspend fun setBadge(count: Int) {}
}

// endregion

// region Fault injection

/** Counts service calls, makes chosen calls fail, and holds chosen calls until released. */
class VMFaults {
    enum class Op {
        SIGN_UP, SIGN_IN, SIGN_OUT, SEND_PASSWORD_RESET, VERIFY_RECOVERY_CODE, UPDATE_PASSWORD, DELETE_ACCOUNT,
        MY_PROFILE, UPDATE_DISPLAY_NAME,
        MY_GROUPS, CREATE_GROUP, JOIN, RENAME, DELETE_GROUP, MEMBERS, INVITE_CODE, REGENERATE_INVITE_CODE,
        SET_ROLE, REMOVE_MEMBER, LEAVE,
        TASKS, MY_TASKS, TASK, CREATE_TASK, UPDATE_TASK, SET_STATUS, DELETE_TASK, ASSIGNMENTS,
        CURRENT_TOPIC, ENABLE_PUSH, DISABLE_PUSH,
    }

    private val lock = Any()
    private val queued = HashMap<Op, ArrayDeque<Throwable>>()
    private val callCounts = HashMap<Op, Int>()
    private val held = HashSet<Op>()
    private val waiters = HashMap<Op, MutableList<CompletableDeferred<Unit>>>()

    /** The next [times] calls of [op] throw [error] (after being counted). */
    fun fail(op: Op, error: Throwable, times: Int = 1) {
        synchronized(lock) {
            val list = queued.getOrPut(op) { ArrayDeque() }
            repeat(times) { list.addLast(error) }
        }
    }

    fun calls(op: Op): Int = synchronized(lock) { callCounts[op] ?: 0 }

    /** Calls of [op] wait until [release]. */
    fun hold(op: Op) {
        synchronized(lock) { held.add(op) }
    }

    fun release(op: Op) {
        val gates = synchronized(lock) {
            held.remove(op)
            waiters.remove(op).orEmpty()
        }
        for (gate in gates) gate.complete(Unit)
    }

    /** Number of calls of [op] currently held. */
    fun waiting(op: Op): Int = synchronized(lock) { waiters[op]?.count { !it.isCompleted } ?: 0 }

    suspend fun check(op: Op) {
        var gate: CompletableDeferred<Unit>? = null
        val error = synchronized(lock) {
            callCounts[op] = (callCounts[op] ?: 0) + 1
            val error = queued[op]?.removeFirstOrNull()
            if (op in held) {
                val waiting = CompletableDeferred<Unit>()
                waiters.getOrPut(op) { ArrayList() }.add(waiting)
                gate = waiting
            }
            error
        }
        gate?.await()
        if (error != null) throw error
    }
}

class VMAuthService(
    private val base: AuthService,
    private val faults: VMFaults,
    private val signUpOutcome: SignUpOutcome?,
) : AuthService by base {
    override suspend fun signUp(email: String, password: String, displayName: String): SignUpOutcome {
        faults.check(VMFaults.Op.SIGN_UP)
        val outcome = base.signUp(email, password, displayName)
        return signUpOutcome ?: outcome
    }

    override suspend fun signIn(email: String, password: String) {
        faults.check(VMFaults.Op.SIGN_IN)
        base.signIn(email, password)
    }

    override suspend fun signOut() {
        faults.check(VMFaults.Op.SIGN_OUT)
        base.signOut()
    }

    override suspend fun sendPasswordReset(email: String) {
        faults.check(VMFaults.Op.SEND_PASSWORD_RESET)
        base.sendPasswordReset(email)
    }

    override suspend fun verifyRecoveryCode(email: String, code: String) {
        faults.check(VMFaults.Op.VERIFY_RECOVERY_CODE)
        base.verifyRecoveryCode(email, code)
    }

    override suspend fun updatePassword(newPassword: String) {
        faults.check(VMFaults.Op.UPDATE_PASSWORD)
        base.updatePassword(newPassword)
    }

    override suspend fun deleteAccount() {
        faults.check(VMFaults.Op.DELETE_ACCOUNT)
        base.deleteAccount()
    }
}

class VMProfileService(private val base: ProfileService, private val faults: VMFaults) : ProfileService {
    override suspend fun myProfile(): UserProfile {
        faults.check(VMFaults.Op.MY_PROFILE)
        return base.myProfile()
    }

    override suspend fun updateDisplayName(name: String): UserProfile {
        faults.check(VMFaults.Op.UPDATE_DISPLAY_NAME)
        return base.updateDisplayName(name)
    }
}

class VMGroupService(private val base: GroupService, private val faults: VMFaults) : GroupService {
    override suspend fun myGroups(): List<GroupSummary> {
        faults.check(VMFaults.Op.MY_GROUPS)
        return base.myGroups()
    }

    override suspend fun createGroup(name: String): GroupSummary {
        faults.check(VMFaults.Op.CREATE_GROUP)
        return base.createGroup(name)
    }

    override suspend fun join(code: InviteCode): JoinResult {
        faults.check(VMFaults.Op.JOIN)
        return base.join(code)
    }

    override suspend fun rename(groupId: UUID, name: String): TeamGroup {
        faults.check(VMFaults.Op.RENAME)
        return base.rename(groupId, name)
    }

    override suspend fun deleteGroup(groupId: UUID) {
        faults.check(VMFaults.Op.DELETE_GROUP)
        base.deleteGroup(groupId)
    }

    override suspend fun members(groupId: UUID): List<Membership> {
        faults.check(VMFaults.Op.MEMBERS)
        return base.members(groupId)
    }

    override suspend fun inviteCode(groupId: UUID): InviteCode {
        faults.check(VMFaults.Op.INVITE_CODE)
        return base.inviteCode(groupId)
    }

    override suspend fun regenerateInviteCode(groupId: UUID): InviteCode {
        faults.check(VMFaults.Op.REGENERATE_INVITE_CODE)
        return base.regenerateInviteCode(groupId)
    }

    override suspend fun setRole(groupId: UUID, userId: UUID, role: MemberRole) {
        faults.check(VMFaults.Op.SET_ROLE)
        base.setRole(groupId, userId, role)
    }

    override suspend fun removeMember(groupId: UUID, userId: UUID) {
        faults.check(VMFaults.Op.REMOVE_MEMBER)
        base.removeMember(groupId, userId)
    }

    override suspend fun leave(groupId: UUID) {
        faults.check(VMFaults.Op.LEAVE)
        base.leave(groupId)
    }
}

class VMTaskService(private val base: TaskService, private val faults: VMFaults) : TaskService {
    override suspend fun tasks(groupId: UUID, includeOldDone: Boolean): List<TaskItem> {
        faults.check(VMFaults.Op.TASKS)
        return base.tasks(groupId, includeOldDone)
    }

    override suspend fun myTasks(includeDone: Boolean): List<TaskItem> {
        faults.check(VMFaults.Op.MY_TASKS)
        return base.myTasks(includeDone)
    }

    override suspend fun task(id: UUID): TaskItem {
        faults.check(VMFaults.Op.TASK)
        return base.task(id)
    }

    override suspend fun create(groupId: UUID, draft: TaskDraft): TaskItem {
        faults.check(VMFaults.Op.CREATE_TASK)
        return base.create(groupId, draft)
    }

    override suspend fun update(taskId: UUID, draft: TaskDraft): TaskItem {
        faults.check(VMFaults.Op.UPDATE_TASK)
        return base.update(taskId, draft)
    }

    override suspend fun setStatus(taskId: UUID, status: TaskStatus): TaskItem {
        faults.check(VMFaults.Op.SET_STATUS)
        return base.setStatus(taskId, status)
    }

    override suspend fun delete(taskId: UUID) {
        faults.check(VMFaults.Op.DELETE_TASK)
        base.delete(taskId)
    }

    override suspend fun assignments(since: Instant): List<AssignmentEvent> {
        faults.check(VMFaults.Op.ASSIGNMENTS)
        return base.assignments(since)
    }
}

class VMPushService(private val base: PushService, private val faults: VMFaults) : PushService {
    override suspend fun currentTopic(): String? {
        faults.check(VMFaults.Op.CURRENT_TOPIC)
        return base.currentTopic()
    }

    override suspend fun enable(): String {
        faults.check(VMFaults.Op.ENABLE_PUSH)
        return base.enable()
    }

    override suspend fun disable() {
        faults.check(VMFaults.Op.DISABLE_PUSH)
        base.disable()
    }
}

/** The same services, counted and failing on demand through [faults]. */
fun AppServices.instrumented(faults: VMFaults, signUpOutcome: SignUpOutcome? = null): AppServices = AppServices(
    auth = VMAuthService(auth, faults, signUpOutcome),
    profiles = VMProfileService(profiles, faults),
    groups = VMGroupService(groups, faults),
    tasks = VMTaskService(tasks, faults),
    realtime = realtime,
    push = VMPushService(push, faults),
)

// endregion

// region Harness

/**
 * A mock backend with demo data (docs/CONTRACTS.md §8) seen from one device, with instrumented services and fake
 * platform services. The backend clock advances by 1 s at every read (strictly increasing server timestamps); the
 * device clock reads it without advancing it.
 *
 * @param scope where sessions, apps and view models run: the test's `backgroundScope`.
 */
class VMHarness(
    val scope: CoroutineScope,
    scenario: MockScenario = MockScenario.POPULATED,
    authorization: NotificationAuthorization = NotificationAuthorization.AUTHORIZED,
    signUpOutcome: SignUpOutcome? = null,
) {
    val clock: MockClock = MockClock(VMFixtures.now, autoAdvance = 1.seconds)
    val environment: MockEnvironment = MockEnvironment.make(scenario, now = clock.provider)
    val faults: VMFaults = VMFaults()
    val services: AppServices = environment.services.instrumented(faults, signUpOutcome)
    val scheduler: VMScheduler = VMScheduler(authorization)
    val store: InMemoryKeyValueStore = InMemoryKeyValueStore()
    val platform: PlatformServices = PlatformServices(
        notifications = scheduler,
        store = store,
        now = { clock.peek() },
        calendar = VMFixtures.calendar,
    )

    val backend: InMemoryBackend get() = environment.backend

    /** A session of the scenario's signed-in user (not started). */
    fun makeSession(user: DemoUser? = null): SessionModel {
        val demoUser = user ?: environment.signedInUser ?: VMFixtures.camille
        return SessionModel(AuthUser(demoUser.id, demoUser.email), services, platform, scope, testConfiguration)
    }

    fun makeApp(): AppModel = AppModel(services, platform, scope, sessionConfiguration = testConfiguration)

    /** Services of another device signed in as [user] (not instrumented). */
    fun device(user: DemoUser): AppServices = backend.services(user.id)

    /** Reminder ids expected for these tasks (lead time 1 h). */
    suspend fun reminderIds(taskIds: List<UUID>): List<String> {
        val lucas = device(VMFixtures.lucas)
        return taskIds.map { taskId ->
            val task = lucas.tasks.task(taskId)
            ReminderPlanner.identifier(taskId, task.dueAt ?: error("no due date"))
        }.sorted()
    }

    companion object {
        val testConfiguration: SessionModel.Configuration =
            SessionModel.Configuration(realtimeDebounce = Duration.ZERO, realtimeRetryDelay = 20.milliseconds)
    }
}

/** `state.value` of a view model (shorter assertions). */
val <S : ErrorHolder> ScreenModel<S>.ui: S get() = state.value

// endregion
