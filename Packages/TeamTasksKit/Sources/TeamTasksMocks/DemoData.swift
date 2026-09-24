import Foundation
import TeamTasksCore

/// A seeded demo account.
public struct DemoUser: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let email: String
    public let displayName: String

    public init(id: UUID, email: String, displayName: String) {
        self.id = id
        self.email = email
        self.displayName = displayName
    }
}

/// French demo data of docs/CONTRACTS.md §8, identical to `supabase/seed.sql` (canonical): same ids, creators,
/// assigners, details and dates.
///
/// Ids are fixed so that previews and UI tests can reference them. Dates are relative to the backend's `now`,
/// computed like the seed: wall-clock times in Europe/Paris for the due dates ("yesterday 18:00" for the overdue
/// rent, "today 20:00", "tomorrow 18:00"…) and the completion of the done task ("yesterday 19:00"), so the screens
/// show round times whatever the seeding time, and exact multiples of 24 hours for everything else
/// (`now() - interval 'N days'` in a UTC session). `last_activity_at` and `memberships_changed_at` are the seed
/// time: the AFTER triggers of the seeded rows bump them to `now()`.
public enum DemoData {
    public static let password = "motdepasse123"

    public static let camille = DemoUser(
        id: fixedID("11111111-1111-4111-8111-111111111111"), email: "camille@example.com", displayName: "Camille Martin"
    )
    public static let lucas = DemoUser(
        id: fixedID("22222222-2222-4222-8222-222222222222"), email: "lucas@example.com", displayName: "Lucas Bernard"
    )
    public static let ines = DemoUser(
        id: fixedID("33333333-3333-4333-8333-333333333333"), email: "ines@example.com", displayName: "Inès Dubois"
    )
    /// The three users of §8 (U1, U2, U3).
    public static let users = [camille, lucas, ines]

    /// Extra account, member of no group, used only by `MockScenario.emptyGroups` (not part of §8 nor of the seed).
    public static let newcomer = DemoUser(
        id: fixedID("c0000000-0000-4000-8000-000000000004"), email: "alex@example.com", displayName: "Alex Moreau"
    )

    public static let lilasGroupId = fixedID("a0000000-0000-4000-8000-000000000001")
    public static let lilasGroupName = "Coloc' rue des Lilas"
    public static let lilasInviteCode = "LYLAS234"

    public static let sportGroupId = fixedID("a0000000-0000-4000-8000-000000000002")
    public static let sportGroupName = "Projet Asso Sport"
    public static let sportInviteCode = "SPRT5678"

    /// Ids of the demo tasks.
    public enum TaskIDs {
        public static let sortirPoubelles = fixedID("b0000000-0000-4000-8000-000000000001")
        public static let faireCourses = fixedID("b0000000-0000-4000-8000-000000000002")
        public static let payerLoyer = fixedID("b0000000-0000-4000-8000-000000000003")
        public static let reparerFuite = fixedID("b0000000-0000-4000-8000-000000000004")
        public static let nettoyerCuisine = fixedID("b0000000-0000-4000-8000-000000000005")
        public static let reserverGymnase = fixedID("b0000000-0000-4000-8000-000000000006")
        public static let creerAffiche = fixedID("b0000000-0000-4000-8000-000000000007")
    }

    /// Gregorian calendar in Europe/Paris with a French locale.
    public static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris") ?? TimeZone(secondsFromGMT: 3600) ?? .gmt
        calendar.locale = Locale(identifier: "fr_FR")
        return calendar
    }()

    static func fixedID(_ string: String) -> UUID {
        UUID(uuidString: string) ?? UUID()
    }

    // MARK: - Seeding

    /// Writes the §8 data relative to `now`, exactly like `supabase/seed.sql`.
    static func seed(_ data: inout BackendData, now: Date, calendar: Calendar) {
        let startOfToday = calendar.startOfDay(for: now)
        /// `(paris.today + days + time 'hour:00') at time zone 'Europe/Paris'`.
        func wallClock(inDays days: Int, hour: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: days, to: startOfToday) ?? startOfToday
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        }
        /// `now() - interval 'N days'` in a UTC session: exactly N × 24 hours.
        func ago(days: Int) -> Date {
            now.addingTimeInterval(-TimeInterval(days) * 86_400)
        }

        // Accounts (created 30 days ago) and their profiles.
        for user in users {
            insert(user, into: &data, createdAt: ago(days: 30))
        }

        // Groups, invites and memberships. The member inserts bump last_activity_at and memberships_changed_at
        // to the seed time.
        let groups: [(id: UUID, name: String, creator: DemoUser, code: String, createdAt: Date)] = [
            (lilasGroupId, lilasGroupName, camille, lilasInviteCode, ago(days: 10)),
            (sportGroupId, sportGroupName, lucas, sportInviteCode, ago(days: 20)),
        ]
        for group in groups {
            data.groups[group.id] = GroupRecord(
                id: group.id, name: group.name, createdBy: group.creator.id, createdAt: group.createdAt, lastActivityAt: now
            )
            data.invites[group.id] = InviteRecord(
                groupId: group.id, code: group.code, createdBy: group.creator.id, createdAt: group.createdAt
            )
        }
        let memberships: [(UUID, DemoUser, MemberRole, Date)] = [
            (lilasGroupId, camille, .admin, ago(days: 10)),
            (lilasGroupId, lucas, .member, ago(days: 9)),
            (lilasGroupId, ines, .member, ago(days: 8)),
            (sportGroupId, lucas, .admin, ago(days: 20)),
            (sportGroupId, camille, .member, ago(days: 15)),
        ]
        for (groupId, user, role, joinedAt) in memberships {
            data.members[groupId, default: [:]][user.id] = MemberRecord(
                groupId: groupId, userId: user.id, role: role, joinedAt: joinedAt
            )
            data.profiles[user.id]?.membershipsChangedAt = now
        }

        // Tasks (updated_at = created_at) and assignees (assigned by the creator, at the creation date).
        struct Seed {
            var id: UUID
            var groupId: UUID
            var title: String
            var details: String?
            var status: TaskStatus
            var priority: TaskPriority
            var dueAt: Date?
            var createdBy: DemoUser
            var createdAt: Date
            var completedAt: Date?
            var assignees: [DemoUser]
        }
        let seeds = [
            Seed(
                id: TaskIDs.sortirPoubelles, groupId: lilasGroupId, title: "Sortir les poubelles",
                details: "Poubelle jaune et poubelle verte.", status: .todo, priority: .high,
                dueAt: wallClock(inDays: 0, hour: 20), createdBy: camille, createdAt: ago(days: 3), assignees: [camille]
            ),
            Seed(
                id: TaskIDs.faireCourses, groupId: lilasGroupId, title: "Faire les courses",
                details: "Lait, pâtes, lessive et papier toilette.", status: .inProgress, priority: .medium,
                dueAt: wallClock(inDays: 1, hour: 18), createdBy: lucas, createdAt: ago(days: 2), assignees: [lucas, camille]
            ),
            Seed(
                // Yesterday 18:00: always overdue, and a round time on screen (not the seeding time).
                id: TaskIDs.payerLoyer, groupId: lilasGroupId, title: "Payer le loyer",
                details: nil, status: .todo, priority: .high,
                dueAt: wallClock(inDays: -1, hour: 18), createdBy: camille, createdAt: ago(days: 6), assignees: [ines]
            ),
            Seed(
                id: TaskIDs.reparerFuite, groupId: lilasGroupId, title: "Réparer la fuite du lavabo",
                details: "Le joint sous le lavabo de la salle de bain goutte.", status: .todo, priority: .low,
                dueAt: nil, createdBy: ines, createdAt: ago(days: 5), assignees: []
            ),
            Seed(
                id: TaskIDs.nettoyerCuisine, groupId: lilasGroupId, title: "Nettoyer la cuisine",
                details: nil, status: .done, priority: .medium,
                dueAt: nil, createdBy: lucas, createdAt: ago(days: 4), completedAt: wallClock(inDays: -1, hour: 19),
                assignees: [camille]
            ),
            Seed(
                id: TaskIDs.reserverGymnase, groupId: sportGroupId, title: "Réserver le gymnase",
                details: "Samedi après-midi, pour le tournoi.", status: .todo, priority: .high,
                dueAt: wallClock(inDays: 3, hour: 18), createdBy: lucas, createdAt: ago(days: 7), assignees: [camille]
            ),
            Seed(
                id: TaskIDs.creerAffiche, groupId: sportGroupId, title: "Créer l'affiche du tournoi",
                details: nil, status: .inProgress, priority: .low,
                dueAt: wallClock(inDays: 7, hour: 12), createdBy: lucas, createdAt: ago(days: 7), assignees: [lucas]
            ),
        ]
        for seed in seeds {
            data.tasks[seed.id] = TaskRecord(
                id: seed.id,
                groupId: seed.groupId,
                title: seed.title,
                details: seed.details,
                status: seed.status,
                priority: seed.priority,
                dueAt: seed.dueAt,
                createdBy: seed.createdBy.id,
                createdAt: seed.createdAt,
                updatedAt: seed.createdAt,
                completedAt: seed.completedAt
            )
            for assignee in seed.assignees {
                data.assignees[seed.id, default: [:]][assignee.id] = AssigneeRecord(
                    taskId: seed.id, groupId: seed.groupId, userId: assignee.id,
                    assignedBy: seed.createdBy.id, assignedAt: seed.createdAt
                )
            }
        }
    }

    static func insert(_ user: DemoUser, into data: inout BackendData, createdAt: Date) {
        data.accounts[user.id] = AccountRecord(id: user.id, email: user.email, password: password, createdAt: createdAt)
        data.profiles[user.id] = ProfileRecord(
            id: user.id, displayName: user.displayName, membershipsChangedAt: createdAt, createdAt: createdAt, updatedAt: createdAt
        )
    }
}

extension InMemoryBackend {
    /// A backend preloaded with the demo data of docs/CONTRACTS.md §8.
    public static func demo(
        now: @escaping NowProvider = { Date() },
        calendar: Calendar = DemoData.calendar,
        latency: Duration = .zero
    ) -> InMemoryBackend {
        let backend = InMemoryBackend(now: now, calendar: calendar, latency: latency)
        backend.loadDemoData()
        return backend
    }

    /// Adds the demo data of docs/CONTRACTS.md §8, with dates relative to the backend's current `now()`.
    public func loadDemoData() {
        let reference = now()
        seed { data in DemoData.seed(&data, now: reference, calendar: calendar) }
    }

    /// Adds `DemoData.newcomer` (an account with no group).
    public func addNewcomerAccount() {
        let reference = now()
        seed { data in DemoData.insert(DemoData.newcomer, into: &data, createdAt: reference) }
    }
}
