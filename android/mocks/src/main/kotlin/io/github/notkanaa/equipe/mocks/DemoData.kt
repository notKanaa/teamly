package io.github.notkanaa.equipe.mocks

import io.github.notkanaa.equipe.core.AppCalendar
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.TaskPriority
import io.github.notkanaa.equipe.core.TaskStatus
import java.time.Instant
import java.time.LocalTime
import java.util.UUID

/** A seeded demo account. */
data class DemoUser(
    val id: UUID,
    val email: String,
    val displayName: String,
)

/**
 * French demo data of docs/CONTRACTS.md §8, identical to `supabase/seed.sql` (canonical) and to the Swift
 * `DemoData`: same ids, creators, assigners, details and dates.
 *
 * Ids are fixed so that previews and UI tests can reference them. Dates are relative to the backend's `now`,
 * computed like the seed: wall-clock times in Europe/Paris for the due dates ("yesterday 18:00" for the overdue
 * rent, "today 20:00", "tomorrow 18:00"…) and the completion of the done task ("yesterday 19:00"), so the screens
 * show round times whatever the seeding time, and exact multiples of 24 hours for everything else
 * (`now() - interval 'N days'` in a UTC session). `last_activity_at` and `memberships_changed_at` are the seed time:
 * the AFTER triggers of the seeded rows bump them to `now()`.
 */
object DemoData {
    const val password: String = "motdepasse123"

    val camille: DemoUser = DemoUser(
        id = UUID.fromString("11111111-1111-4111-8111-111111111111"),
        email = "camille@example.com",
        displayName = "Camille Martin",
    )
    val lucas: DemoUser = DemoUser(
        id = UUID.fromString("22222222-2222-4222-8222-222222222222"),
        email = "lucas@example.com",
        displayName = "Lucas Bernard",
    )
    val ines: DemoUser = DemoUser(
        id = UUID.fromString("33333333-3333-4333-8333-333333333333"),
        email = "ines@example.com",
        displayName = "Inès Dubois",
    )

    /** The three users of §8 (U1, U2, U3). */
    val users: List<DemoUser> = listOf(camille, lucas, ines)

    /** Extra account, member of no group, used only by [MockScenario.EMPTY_GROUPS] (not part of §8 nor of the seed). */
    val newcomer: DemoUser = DemoUser(
        id = UUID.fromString("c0000000-0000-4000-8000-000000000004"),
        email = "alex@example.com",
        displayName = "Alex Moreau",
    )

    val lilasGroupId: UUID = UUID.fromString("a0000000-0000-4000-8000-000000000001")
    const val lilasGroupName: String = "Coloc' rue des Lilas"
    const val lilasInviteCode: String = "LYLAS234"

    val sportGroupId: UUID = UUID.fromString("a0000000-0000-4000-8000-000000000002")
    const val sportGroupName: String = "Projet Asso Sport"
    const val sportInviteCode: String = "SPRT5678"

    /** Ids of the demo tasks (Swift `DemoData.TaskIDs`). */
    object TaskIds {
        val sortirPoubelles: UUID = UUID.fromString("b0000000-0000-4000-8000-000000000001")
        val faireCourses: UUID = UUID.fromString("b0000000-0000-4000-8000-000000000002")
        val payerLoyer: UUID = UUID.fromString("b0000000-0000-4000-8000-000000000003")
        val reparerFuite: UUID = UUID.fromString("b0000000-0000-4000-8000-000000000004")
        val nettoyerCuisine: UUID = UUID.fromString("b0000000-0000-4000-8000-000000000005")
        val reserverGymnase: UUID = UUID.fromString("b0000000-0000-4000-8000-000000000006")
        val creerAffiche: UUID = UUID.fromString("b0000000-0000-4000-8000-000000000007")
    }

    /** Gregorian calendar in Europe/Paris with a French locale. */
    val calendar: AppCalendar = AppCalendar.frenchGregorian(AppCalendar.PARIS)

    private class Seed(
        val id: UUID,
        val groupId: UUID,
        val title: String,
        val details: String?,
        val status: TaskStatus,
        val priority: TaskPriority,
        val dueAt: Instant?,
        val createdBy: DemoUser,
        val createdAt: Instant,
        val completedAt: Instant? = null,
        val assignees: List<DemoUser>,
    )

    /** Writes the §8 data relative to [now], exactly like `supabase/seed.sql`. */
    internal fun seed(data: BackendData, now: Instant, calendar: AppCalendar) {
        val today = calendar.localDate(now)

        /** `(paris.today + days + time 'hour:00') at time zone 'Europe/Paris'`. */
        fun wallClock(days: Long, hour: Int): Instant = calendar.instant(today.plusDays(days), LocalTime.of(hour, 0))

        /** `now() - interval 'N days'` in a UTC session: exactly N × 24 hours. */
        fun ago(days: Long): Instant = now.minusSeconds(days * 86_400L)

        // Accounts (created 30 days ago) and their profiles.
        for (user in users) insert(user, data, ago(30))

        // Groups, invites and memberships. The member inserts bump last_activity_at and memberships_changed_at to
        // the seed time.
        class GroupSeed(val id: UUID, val name: String, val creator: DemoUser, val code: String, val createdAt: Instant)
        val groups = listOf(
            GroupSeed(lilasGroupId, lilasGroupName, camille, lilasInviteCode, ago(10)),
            GroupSeed(sportGroupId, sportGroupName, lucas, sportInviteCode, ago(20)),
        )
        for (group in groups) {
            data.groups[group.id] = GroupRecord(
                id = group.id, name = group.name, createdBy = group.creator.id,
                createdAt = group.createdAt, lastActivityAt = now,
            )
            data.invites[group.id] = InviteRecord(
                groupId = group.id, code = group.code, createdBy = group.creator.id, createdAt = group.createdAt,
            )
        }
        class MemberSeed(val groupId: UUID, val user: DemoUser, val role: MemberRole, val joinedAt: Instant)
        val memberships = listOf(
            MemberSeed(lilasGroupId, camille, MemberRole.ADMIN, ago(10)),
            MemberSeed(lilasGroupId, lucas, MemberRole.MEMBER, ago(9)),
            MemberSeed(lilasGroupId, ines, MemberRole.MEMBER, ago(8)),
            MemberSeed(sportGroupId, lucas, MemberRole.ADMIN, ago(20)),
            MemberSeed(sportGroupId, camille, MemberRole.MEMBER, ago(15)),
        )
        for (membership in memberships) {
            data.members.getOrPut(membership.groupId) { HashMap() }[membership.user.id] = MemberRecord(
                groupId = membership.groupId, userId = membership.user.id,
                role = membership.role, joinedAt = membership.joinedAt,
            )
            data.profiles[membership.user.id]?.let {
                data.profiles[membership.user.id] = it.copy(membershipsChangedAt = now)
            }
        }

        // Tasks (updated_at = created_at) and assignees (assigned by the creator, at the creation date).
        val seeds = listOf(
            Seed(
                id = TaskIds.sortirPoubelles, groupId = lilasGroupId, title = "Sortir les poubelles",
                details = "Poubelle jaune et poubelle verte.", status = TaskStatus.TODO, priority = TaskPriority.HIGH,
                dueAt = wallClock(0, 20), createdBy = camille, createdAt = ago(3), assignees = listOf(camille),
            ),
            Seed(
                id = TaskIds.faireCourses, groupId = lilasGroupId, title = "Faire les courses",
                details = "Lait, pâtes, lessive et papier toilette.", status = TaskStatus.IN_PROGRESS,
                priority = TaskPriority.MEDIUM, dueAt = wallClock(1, 18), createdBy = lucas, createdAt = ago(2),
                assignees = listOf(lucas, camille),
            ),
            Seed(
                // Yesterday 18:00: always overdue, and a round time on screen (not the seeding time).
                id = TaskIds.payerLoyer, groupId = lilasGroupId, title = "Payer le loyer",
                details = null, status = TaskStatus.TODO, priority = TaskPriority.HIGH,
                dueAt = wallClock(-1, 18), createdBy = camille, createdAt = ago(6), assignees = listOf(ines),
            ),
            Seed(
                id = TaskIds.reparerFuite, groupId = lilasGroupId, title = "Réparer la fuite du lavabo",
                details = "Le joint sous le lavabo de la salle de bain goutte.", status = TaskStatus.TODO,
                priority = TaskPriority.LOW, dueAt = null, createdBy = ines, createdAt = ago(5), assignees = emptyList(),
            ),
            Seed(
                id = TaskIds.nettoyerCuisine, groupId = lilasGroupId, title = "Nettoyer la cuisine",
                details = null, status = TaskStatus.DONE, priority = TaskPriority.MEDIUM,
                dueAt = null, createdBy = lucas, createdAt = ago(4), completedAt = wallClock(-1, 19),
                assignees = listOf(camille),
            ),
            Seed(
                id = TaskIds.reserverGymnase, groupId = sportGroupId, title = "Réserver le gymnase",
                details = "Samedi après-midi, pour le tournoi.", status = TaskStatus.TODO, priority = TaskPriority.HIGH,
                dueAt = wallClock(3, 18), createdBy = lucas, createdAt = ago(7), assignees = listOf(camille),
            ),
            Seed(
                id = TaskIds.creerAffiche, groupId = sportGroupId, title = "Créer l'affiche du tournoi",
                details = null, status = TaskStatus.IN_PROGRESS, priority = TaskPriority.LOW,
                dueAt = wallClock(7, 12), createdBy = lucas, createdAt = ago(7), assignees = listOf(lucas),
            ),
        )
        for (seed in seeds) {
            data.tasks[seed.id] = TaskRecord(
                id = seed.id,
                groupId = seed.groupId,
                title = seed.title,
                details = seed.details,
                status = seed.status,
                priority = seed.priority,
                dueAt = seed.dueAt,
                createdBy = seed.createdBy.id,
                createdAt = seed.createdAt,
                updatedAt = seed.createdAt,
                completedAt = seed.completedAt,
            )
            for (assignee in seed.assignees) {
                data.assignees.getOrPut(seed.id) { HashMap() }[assignee.id] = AssigneeRecord(
                    taskId = seed.id, groupId = seed.groupId, userId = assignee.id,
                    assignedBy = seed.createdBy.id, assignedAt = seed.createdAt,
                )
            }
        }
    }

    internal fun insert(user: DemoUser, data: BackendData, createdAt: Instant) {
        data.accounts[user.id] = AccountRecord(id = user.id, email = user.email, password = password, createdAt = createdAt)
        data.profiles[user.id] = ProfileRecord(
            id = user.id, displayName = user.displayName, membershipsChangedAt = createdAt,
            createdAt = createdAt, updatedAt = createdAt,
        )
    }
}
