import Foundation
import Testing
@testable import TeamTasksCore

@Suite struct TaskFilterTests {
    typealias F = LogicFixtures
    let now = LogicFixtures.date(2026, 9, 24, 12, 0)

    var tasks: [TaskItem] {
        [
            F.task(1, status: .todo, due: F.date(2026, 9, 23), assignees: [F.me]), // overdue, mine
            F.task(2, status: .inProgress, due: F.date(2026, 9, 25), assignees: [F.other]),
            F.task(3, status: .done, due: F.date(2026, 9, 20), assignees: [F.me]), // done: never overdue
            F.task(4, status: .todo, due: nil, assignees: []),
            F.task(5, status: .inProgress, due: F.date(2026, 9, 24, 11, 59), assignees: [F.me, F.other]), // overdue
        ]
    }

    private func ids(_ filter: TaskFilter, userId: UUID? = LogicFixtures.me) -> [Int] {
        filter.apply(to: tasks, userId: userId, now: now).map { task in
            tasks.firstIndex(of: task)! + 1
        }
    }

    @Test func defaultFilterKeepsEverythingInOrder() {
        #expect(ids(.all) == [1, 2, 3, 4, 5])
        #expect(!TaskFilter.all.isActive)
        #expect(TaskFilter.all.activeCriteriaCount == 0)
    }

    @Test func statusFilters() {
        #expect(ids(TaskFilter(status: .todo)) == [1, 4])
        #expect(ids(TaskFilter(status: .inProgress)) == [2, 5])
        #expect(ids(TaskFilter(status: .done)) == [3])
        #expect(ids(TaskFilter(status: .notDone)) == [1, 2, 4, 5])
    }

    @Test func assignedToMe() {
        #expect(ids(TaskFilter(onlyAssignedToMe: true)) == [1, 3, 5])
        #expect(ids(TaskFilter(onlyAssignedToMe: true), userId: nil) == [])
    }

    @Test func overdue() {
        #expect(ids(TaskFilter(onlyOverdue: true)) == [1, 5])
    }

    @Test func overdueBoundaryIsStrict() {
        let dueNow = F.task(9, due: now)
        #expect(!dueNow.isOverdue(at: now))
        #expect(dueNow.isOverdue(at: now.addingTimeInterval(0.001)))
        #expect(!F.task(10, due: nil).isOverdue(at: now))
        #expect(!F.task(11, status: .done, due: F.date(2020, 1, 1)).isOverdue(at: now))
    }

    @Test func criteriaCombine() {
        let filter = TaskFilter(status: .inProgress, onlyAssignedToMe: true, onlyOverdue: true)
        #expect(ids(filter) == [5])
        #expect(filter.activeCriteriaCount == 3)
        #expect(filter.isActive)
    }

    @Test func frenchLabels() {
        #expect(TaskStatusFilter.allCases.map(\.label) == ["Toutes", "À faire", "En cours", "Terminées", "Non terminées"])
    }

    @Test func codableRoundTrip() throws {
        let filter = TaskFilter(status: .notDone, onlyAssignedToMe: true, onlyOverdue: false)
        let data = try JSONEncoder().encode(filter)
        #expect(try JSONDecoder().decode(TaskFilter.self, from: data) == filter)
    }
}

@Suite struct TaskSortTests {
    typealias F = LogicFixtures

    private func titles(_ tasks: [TaskItem]) -> [String] { tasks.map(\.title) }

    @Test func dueDateThenPriorityThenTitleWithNilLast() {
        let day = F.date(2026, 9, 25, 10, 0)
        let tasks = [
            F.task(1, title: "Sans date", priority: .high, due: nil),
            F.task(2, title: "Zèbre", priority: .low, due: day),
            F.task(3, title: "banane", priority: .high, due: day),
            F.task(4, title: "Abricot", priority: .high, due: day),
            F.task(5, title: "Tôt", priority: .low, due: day.addingTimeInterval(-60)),
            F.task(6, title: "Autre sans date", priority: .low, due: nil),
        ]
        #expect(titles(TaskSort.dueDate.sorted(tasks)) == ["Tôt", "Abricot", "banane", "Zèbre", "Sans date", "Autre sans date"])
    }

    @Test func priorityThenDueDate() {
        let tasks = [
            F.task(1, title: "Moyenne", priority: .medium, due: F.date(2026, 9, 25)),
            F.task(2, title: "Haute sans date", priority: .high, due: nil),
            F.task(3, title: "Haute tôt", priority: .high, due: F.date(2026, 9, 24)),
            F.task(4, title: "Basse", priority: .low, due: F.date(2026, 9, 1)),
        ]
        #expect(titles(TaskSort.priority.sorted(tasks)) == ["Haute tôt", "Haute sans date", "Moyenne", "Basse"])
    }

    @Test func recentlyCreatedFirst() {
        let tasks = [
            F.task(1, title: "Ancienne", createdAt: F.date(2026, 1, 1)),
            F.task(2, title: "Récente", createdAt: F.date(2026, 9, 1)),
            F.task(3, title: "Moyenne", createdAt: F.date(2026, 5, 1)),
        ]
        #expect(titles(TaskSort.recentlyCreated.sorted(tasks)) == ["Récente", "Moyenne", "Ancienne"])
    }

    @Test func titlesCompareIgnoringCaseAndAccents() {
        let tasks = ["fenêtre", "Éclairage", "eau", "Zinc", "arrosage"].enumerated().map { index, title in
            F.task(index + 1, title: title)
        }
        #expect(titles(TaskSort.dueDate.sorted(tasks)) == ["arrosage", "eau", "Éclairage", "fenêtre", "Zinc"])
    }

    @Test func stableForFullyEqualTasks() {
        let due = F.date(2026, 9, 25)
        let tasks = (1...20).map { F.task($0, title: "Même titre", due: due) }
        for sort in TaskSort.allCases {
            #expect(sort.sorted(tasks).map(\.id) == tasks.map(\.id))
            #expect(sort.sorted(tasks.reversed()).map(\.id) == tasks.reversed().map(\.id))
        }
    }

    @Test func deterministicWhateverTheInputOrder() {
        let tasks = [
            F.task(1, title: "b", priority: .low, due: F.date(2026, 9, 25)),
            F.task(2, title: "a", priority: .low, due: F.date(2026, 9, 25)),
            F.task(3, title: "c", priority: .high, due: nil),
            F.task(4, title: "d", priority: .medium, due: F.date(2026, 9, 26)),
        ]
        for sort in TaskSort.allCases {
            let expected = sort.sorted(tasks).map(\.id)
            #expect(sort.sorted(tasks.reversed()).map(\.id) == expected)
            #expect(sort.sorted([tasks[2], tasks[0], tasks[3], tasks[1]]).map(\.id) == expected)
        }
    }

    @Test func predicateMatchesSortedOrder() {
        let tasks = [
            F.task(1, title: "b", priority: .low, due: F.date(2026, 9, 25)),
            F.task(2, title: "a", priority: .high, due: F.date(2026, 9, 25)),
            F.task(3, title: "c", priority: .high, due: nil),
        ]
        for sort in TaskSort.allCases {
            #expect(tasks.sorted(by: sort.areInIncreasingOrder).map(\.id) == sort.sorted(tasks).map(\.id))
        }
        #expect(!TaskSort.dueDate.areInIncreasingOrder(tasks[0], tasks[0]))
    }

    @Test func frenchLabels() {
        #expect(TaskSort.allCases.map(\.label) == ["Échéance", "Priorité", "Plus récentes"])
    }
}
