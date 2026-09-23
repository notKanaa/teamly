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

/// French demo data of docs/CONTRACTS.md §8 (same content as `supabase/seed.sql`).
///
/// Ids are fixed so that previews and UI tests can reference them. Dates are relative to the backend's `now`
/// in Europe/Paris: "today 20:00" is a wall-clock time; the other relative dates add calendar days to `now`
/// (keeping its time of day), e.g. "tomorrow" = now + 1 day, "overdue by 1 day" = now − 1 day.
public enum DemoData {
    public static let password = "motdepasse123"

    public static let camille = DemoUser(
        id: fixedID("c0000000-0000-4000-8000-000000000001"), email: "camille@example.com", displayName: "Camille Martin"
    )
    public static let lucas = DemoUser(
        id: fixedID("c0000000-0000-4000-8000-000000000002"), email: "lucas@example.com", displayName: "Lucas Bernard"
    )
    public static let ines = DemoUser(
        id: fixedID("c0000000-0000-4000-8000-000000000003"), email: "ines@example.com", displayName: "Inès Dubois"
    )
    /// The three users of §8 (U1, U2, U3).
    public static let users = [camille, lucas, ines]

    /// Extra account, member of no group, used only by `MockScenario.emptyGroups` (not part of §8).
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

    /// Writes the §8 data relative to `now`.
    static func seed(_ data: inout BackendData, now: Date, calendar: Calendar) {
        let startOfToday = calendar.startOfDay(for: now)
        func today(hour: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: 0, second: 0, of: startOfToday) ?? startOfToday
        }
        func days(_ count: Int) -> Date {
            calendar.date(byAdding: .day, value: count, to: now) ?? now.addingTimeInterval(TimeInterval(count) * 86_400)
        }
        func ago(days: Double = 0, hours: Double = 0) -> Date {
            now.addingTimeInterval(-(days * 86_400 + hours * 3_600))
        }

        // Accounts and profiles.
        for user in users {
            insert(user, into: &data, createdAt: ago(days: 30))
        }

        // Groups, invites and memberships.
        let lilasCreated = ago(days: 14)
        let sportCreated = ago(days: 10)
        data.groups[lilasGroupId] = GroupRecord(
            id: lilasGroupId, name: lilasGroupName, createdBy: camille.id, createdAt: lilasCreated, lastActivityAt: lilasCreated
        )
        data.groups[sportGroupId] = GroupRecord(
            id: sportGroupId, name: sportGroupName, createdBy: lucas.id, createdAt: sportCreated, lastActivityAt: sportCreated
        )
        data.invites[lilasGroupId] = InviteRecord(
            groupId: lilasGroupId, code: lilasInviteCode, createdBy: camille.id, createdAt: lilasCreated
        )
        data.invites[sportGroupId] = InviteRecord(
            groupId: sportGroupId, code: sportInviteCode, createdBy: lucas.id, createdAt: sportCreated
        )
        let memberships: [(UUID, DemoUser, MemberRole, Date)] = [
            (lilasGroupId, camille, .admin, lilasCreated),
            (lilasGroupId, lucas, .member, ago(days: 13)),
            (lilasGroupId, ines, .member, ago(days: 12)),
            (sportGroupId, lucas, .admin, sportCreated),
            (sportGroupId, camille, .member, ago(days: 9)),
        ]
        for (groupId, user, role, joinedAt) in memberships {
            data.members[groupId, default: [:]][user.id] = MemberRecord(
                groupId: groupId, userId: user.id, role: role, joinedAt: joinedAt
            )
        }

        // Tasks and assignees.
        struct Seed {
            var id: UUID
            var groupId: UUID
            var title: String
            var priority: TaskPriority
            var status: TaskStatus
            var dueAt: Date?
            var createdBy: DemoUser
            var createdAt: Date
            var updatedAt: Date?
            var completedAt: Date?
            var assignees: [DemoUser]
        }
        let seeds = [
            Seed(
                id: TaskIDs.sortirPoubelles, groupId: lilasGroupId, title: "Sortir les poubelles",
                priority: .high, status: .todo, dueAt: today(hour: 20),
                createdBy: camille, createdAt: ago(days: 2), assignees: [camille]
            ),
            Seed(
                id: TaskIDs.faireCourses, groupId: lilasGroupId, title: "Faire les courses",
                priority: .medium, status: .inProgress, dueAt: days(1),
                createdBy: lucas, createdAt: ago(days: 1, hours: 2), updatedAt: ago(hours: 3), assignees: [lucas, camille]
            ),
            Seed(
                id: TaskIDs.payerLoyer, groupId: lilasGroupId, title: "Payer le loyer",
                priority: .high, status: .todo, dueAt: days(-1),
                createdBy: camille, createdAt: ago(days: 5), assignees: [ines]
            ),
            Seed(
                id: TaskIDs.reparerFuite, groupId: lilasGroupId, title: "Réparer la fuite du lavabo",
                priority: .low, status: .todo, dueAt: nil,
                createdBy: ines, createdAt: ago(days: 3), assignees: []
            ),
            Seed(
                id: TaskIDs.nettoyerCuisine, groupId: lilasGroupId, title: "Nettoyer la cuisine",
                priority: .medium, status: .done, dueAt: nil,
                createdBy: camille, createdAt: ago(days: 4), updatedAt: days(-1), completedAt: days(-1), assignees: [camille]
            ),
            Seed(
                id: TaskIDs.reserverGymnase, groupId: sportGroupId, title: "Réserver le gymnase",
                priority: .high, status: .todo, dueAt: days(3),
                createdBy: lucas, createdAt: ago(days: 2, hours: 1), assignees: [camille]
            ),
            Seed(
                id: TaskIDs.creerAffiche, groupId: sportGroupId, title: "Créer l'affiche du tournoi",
                priority: .low, status: .inProgress, dueAt: days(7),
                createdBy: lucas, createdAt: ago(days: 1, hours: 5), updatedAt: ago(hours: 20), assignees: [lucas]
            ),
        ]
        for seed in seeds {
            data.tasks[seed.id] = TaskRecord(
                id: seed.id,
                groupId: seed.groupId,
                title: seed.title,
                details: nil,
                status: seed.status,
                priority: seed.priority,
                dueAt: seed.dueAt,
                createdBy: seed.createdBy.id,
                createdAt: seed.createdAt,
                updatedAt: seed.updatedAt ?? seed.createdAt,
                completedAt: seed.completedAt
            )
            for assignee in seed.assignees {
                data.assignees[seed.id, default: [:]][assignee.id] = AssigneeRecord(
                    taskId: seed.id, groupId: seed.groupId, userId: assignee.id,
                    assignedBy: seed.createdBy.id, assignedAt: seed.createdAt
                )
            }
        }

        // Signal columns consistent with the seeded rows.
        for groupId in [lilasGroupId, sportGroupId] {
            var latest = data.groups[groupId]?.createdAt ?? now
            for member in (data.members[groupId] ?? [:]).values { latest = max(latest, member.joinedAt) }
            for taskId in data.taskIds(in: groupId) {
                if let task = data.tasks[taskId] { latest = max(latest, task.updatedAt) }
                for row in (data.assignees[taskId] ?? [:]).values { latest = max(latest, row.assignedAt) }
            }
            data.groups[groupId]?.lastActivityAt = latest
        }
        for user in users {
            let joined = data.members.values.compactMap { $0[user.id]?.joinedAt }
            data.profiles[user.id]?.membershipsChangedAt = joined.max() ?? ago(days: 30)
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
