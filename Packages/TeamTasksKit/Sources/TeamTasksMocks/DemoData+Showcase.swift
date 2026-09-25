import Foundation
import TeamTasksCore

extension DemoData {
    /// The v2 content of `MockScenario.showcase` (the v2 screenshots), added on top of the demo data of `populated`
    /// in « Coloc' rue des Lilas ». The v1 fields of the demo rows are unchanged: the showcase only sets v2 columns of
    /// existing rows and adds new rows. Dates are relative to the seed time, like the demo data, and consistent with
    /// the server rules (spawn, rotation, activity feed):
    /// - « Sortir les poubelles » is the current occurrence of a weekly series done « à tour de rôle » by Inès, Camille
    ///   and Lucas, and it is Camille's turn. The first occurrence, due a week earlier, was Inès's turn; Camille
    ///   completed it 3 days ago, which spawned the current one (its v1 `createdAt`), her own turn, assigned by
    ///   herself (the completer taking the turn).
    /// - « Faire les courses » has a checklist, half done: « Lait » (checked by Lucas) and « Pâtes » (by Camille), then
    ///   « Lessive » and « Papier toilette ».
    /// - The weekly recap (`WeeklyRecap`, French calendar in Europe/Paris) has Inès first, Camille second and Lucas
    ///   third this week (3, 2 and 1 tasks), and Inès has been the sole leader for 3 weeks (Lucas led the week
    ///   before). Done tasks are added in the current week (in the hours before the seed time, never before Monday
    ///   00:00) and in the 3 weeks before (Monday to Thursday), whatever the weekday of the seed time.
    /// - The activity feed holds the events of the last 3 days: the completion of the previous « Sortir les
    ///   poubelles » and Camille's turn, the creation of « Faire les courses » and its two checked items, and this
    ///   week's completions. Older events are not in the feed (as if it had started then).
    public enum Showcase {
        /// The rotation of « Sortir les poubelles », in turn order.
        public static let poubellesRotation = [DemoData.ines.id, DemoData.camille.id, DemoData.lucas.id]
        /// The rule of the « Sortir les poubelles » series: weekly, on the due date's weekday.
        public static let poubellesRule = RecurrenceRule(frequency: .weekly, timeZoneId: "Europe/Paris")
        /// The first (done) occurrence of the series; its id is the series id.
        public static let previousPoubellesId = DemoData.fixedID("d0000000-0000-4000-8000-000000000001")

        /// The checklist of « Faire les courses », in order; the first two items are done.
        public static let coursesChecklist = ["Lait", "Pâtes", "Lessive", "Papier toilette"]
        public enum ChecklistIDs {
            public static let lait = DemoData.fixedID("e0000000-0000-4000-8000-000000000001")
            public static let pates = DemoData.fixedID("e0000000-0000-4000-8000-000000000002")
            public static let lessive = DemoData.fixedID("e0000000-0000-4000-8000-000000000003")
            public static let papierToilette = DemoData.fixedID("e0000000-0000-4000-8000-000000000004")
        }

        /// This week's podium of « Coloc' rue des Lilas », first place first, with the tasks done this week.
        public static let podium: [(user: DemoUser, count: Int)] = [(DemoData.ines, 3), (DemoData.camille, 2), (DemoData.lucas, 1)]
        /// Inès's streak: the sole leader of the current week and the 2 before it.
        public static let streakWeeks = 3

        /// Id of the n-th done task added for the recap (0-based): `d0000000-0000-4000-8000-000000000101`, `…102`…
        static func doneTaskId(_ index: Int) -> UUID {
            DemoData.fixedID(String(format: "d0000000-0000-4000-8000-%012d", 101 + index))
        }
    }

    // MARK: - Seeding

    /// Adds the showcase content to the demo data seeded by `seed(_:now:calendar:)` with the same `now`.
    static func seedShowcase(_ data: inout BackendData, now: Date, calendar: Calendar) {
        let lilas = lilasGroupId
        let startOfToday = calendar.startOfDay(for: now)
        func wallClock(inDays days: Int, hour: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: days, to: startOfToday) ?? startOfToday
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        }
        func ago(hours: Double) -> Date {
            now.addingTimeInterval(-hours * 3600)
        }

        // « Sortir les poubelles »: the first occurrence (done) and the current one (the v1 row, v2 columns only).
        let rule = Showcase.poubellesRule
        let seriesId = Showcase.previousPoubellesId
        let seriesCreatedAt = ago(hours: 8 * 24 - 1) // an hour after Inès joined
        let spawnedAt = ago(hours: 3 * 24) // the v1 createdAt of the current occurrence
        data.tasks[seriesId] = TaskRecord(
            id: seriesId,
            groupId: lilas,
            title: "Sortir les poubelles",
            details: "Poubelle jaune et poubelle verte.",
            status: .done,
            priority: .high,
            dueAt: wallClock(inDays: -7, hour: 20),
            createdBy: camille.id,
            createdAt: seriesCreatedAt,
            updatedAt: spawnedAt,
            completedAt: spawnedAt,
            recurrence: rule,
            seriesId: seriesId,
            nextOccurrenceId: TaskIDs.sortirPoubelles,
            rotation: Showcase.poubellesRotation,
            turnUserId: ines.id,
            completedBy: camille.id
        )
        data.assignees[seriesId] = [ines.id: AssigneeRecord(
            taskId: seriesId, groupId: lilas, userId: ines.id, assignedBy: camille.id, assignedAt: seriesCreatedAt
        )]
        data.tasks[TaskIDs.sortirPoubelles]?.recurrence = rule
        data.tasks[TaskIDs.sortirPoubelles]?.seriesId = seriesId
        data.tasks[TaskIDs.sortirPoubelles]?.rotation = Showcase.poubellesRotation
        data.tasks[TaskIDs.sortirPoubelles]?.turnUserId = camille.id

        // « Faire les courses »: its checklist, created with the task, half done.
        let coursesCreatedAt = data.tasks[TaskIDs.faireCourses]?.createdAt ?? ago(hours: 48)
        let checks: [UUID: (by: DemoUser, at: Date)] = [
            Showcase.ChecklistIDs.lait: (lucas, ago(hours: 26)),
            Showcase.ChecklistIDs.pates: (camille, ago(hours: 5)),
        ]
        let itemIds = [
            Showcase.ChecklistIDs.lait, Showcase.ChecklistIDs.pates, Showcase.ChecklistIDs.lessive,
            Showcase.ChecklistIDs.papierToilette,
        ]
        for (index, itemId) in itemIds.enumerated() {
            let check = checks[itemId]
            data.checklistItems[itemId] = ChecklistItemRecord(
                id: itemId, taskId: TaskIDs.faireCourses, groupId: lilas, title: Showcase.coursesChecklist[index],
                position: index + 1, done: check != nil, doneAt: check?.at, doneBy: check?.by.id, createdAt: coursesCreatedAt
            )
        }

        // Done tasks for the weekly recap. `weekStarts[k]` is Monday 00:00 of the week k weeks before the current one.
        var weekStarts = [WeeklyRecap.weekStart(of: now, calendar: calendar)]
        for _ in 1..<WeeklyRecap.weeksRead {
            let dayOfTheWeekBefore = calendar.date(byAdding: .day, value: -7, to: weekStarts[weekStarts.count - 1])
                ?? weekStarts[weekStarts.count - 1].addingTimeInterval(-7 * 86_400)
            weekStarts.append(WeeklyRecap.weekStart(of: dayOfTheWeekBefore, calendar: calendar))
        }
        let previousInCurrentWeek = spawnedAt >= weekStarts[0]
        func thisWeek(_ hoursAgo: Double) -> Date {
            max(weekStarts[0], ago(hours: hoursAgo))
        }
        func earlier(_ weeks: Int, days: Double, hours: Double) -> Date {
            weekStarts[weeks].addingTimeInterval((days * 24 + hours) * 3600)
        }
        var done: [(user: DemoUser, title: String, at: Date)] = [
            (ines, "Arroser les plantes", thisWeek(1)),
            (lucas, "Descendre le verre", thisWeek(4)),
            (ines, "Passer l’aspirateur", thisWeek(7)),
            (camille, "Nettoyer le frigo", thisWeek(10)),
            (ines, "Faire la vaisselle", thisWeek(13)),
        ]
        if !previousInCurrentWeek {
            // Camille's second task of the week, when the previous « Sortir les poubelles » belongs to the week before.
            done.append((camille, "Laver le linge", thisWeek(16)))
        }
        done += [
            (ines, "Nettoyer la salle de bain", earlier(1, days: 1, hours: 10)),
            (ines, "Changer les draps", earlier(1, days: 2, hours: 18)),
            (ines, "Détartrer la bouilloire", earlier(2, days: 0, hours: 19)),
            (lucas, "Ranger la cave", earlier(2, days: 1, hours: 20)),
            (ines, "Trier le courrier", earlier(2, days: 3, hours: 9)),
            (lucas, "Acheter des ampoules", earlier(3, days: 2, hours: 11)),
        ]
        for (index, task) in done.enumerated() {
            let id = Showcase.doneTaskId(index)
            let createdAt = task.at.addingTimeInterval(-5 * 86_400)
            data.tasks[id] = TaskRecord(
                id: id, groupId: lilas, title: task.title, details: nil, status: .done, priority: .medium, dueAt: nil,
                createdBy: task.user.id, createdAt: createdAt, updatedAt: task.at, completedAt: task.at,
                completedBy: task.user.id
            )
            data.assignees[id] = [task.user.id: AssigneeRecord(
                taskId: id, groupId: lilas, userId: task.user.id, assignedBy: task.user.id, assignedAt: createdAt
            )]
        }

        // The activity feed of the last 3 days, oldest first (ids increase with time).
        var events: [(kind: ActivityEvent.Kind, actor: UUID?, subject: UUID?, task: UUID, taskTitle: String, item: String?, at: Date)] = [
            (.taskCompleted, camille.id, nil, seriesId, "Sortir les poubelles", nil, spawnedAt),
            (.turnStarted, nil, camille.id, TaskIDs.sortirPoubelles, "Sortir les poubelles", nil, spawnedAt),
            (.taskCreated, lucas.id, nil, TaskIDs.faireCourses, "Faire les courses", nil, coursesCreatedAt),
        ]
        for itemId in [Showcase.ChecklistIDs.lait, Showcase.ChecklistIDs.pates] {
            guard let item = data.checklistItems[itemId], let doneAt = item.doneAt else { continue }
            events.append((.checklistItemDone, item.doneBy, nil, TaskIDs.faireCourses, "Faire les courses", item.title, doneAt))
        }
        for (index, task) in done.enumerated() where task.at >= weekStarts[0] {
            events.append((.taskCompleted, task.user.id, nil, Showcase.doneTaskId(index), task.title, nil, task.at))
        }
        let ordered = events.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }
        for (_, event) in ordered {
            data.lastActivityId += 1
            data.activity.append(ActivityRecord(
                id: data.lastActivityId, groupId: lilas, kind: event.kind, actorId: event.actor, subjectId: event.subject,
                taskId: event.task, taskTitle: event.taskTitle, itemTitle: event.item, createdAt: event.at
            ))
        }
    }
}

extension InMemoryBackend {
    /// A backend preloaded with the demo data and the v2 content of `MockScenario.showcase`.
    public static func showcase(
        now: @escaping NowProvider = { Date() },
        calendar: Calendar = DemoData.calendar,
        latency: Duration = .zero
    ) -> InMemoryBackend {
        let backend = InMemoryBackend(now: now, calendar: calendar, latency: latency)
        backend.loadShowcaseData()
        return backend
    }

    /// Adds the demo data of docs/CONTRACTS.md §8 and the v2 content of `MockScenario.showcase`
    /// (`DemoData.Showcase`), with dates relative to the backend's current `now()` (one seed time for both). Call it
    /// instead of `loadDemoData()`.
    public func loadShowcaseData() {
        let reference = now()
        seed { data in
            DemoData.seed(&data, now: reference, calendar: calendar)
            DemoData.seedShowcase(&data, now: reference, calendar: calendar)
        }
    }
}
