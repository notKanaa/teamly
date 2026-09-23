import Foundation
import TeamTasksCore
import TeamTasksMocks
import Testing

/// SQL `tasks_due_at_range` / `invalid_due_at`: due dates must lie in [1970-01-01, 10000-01-01) UTC.
@Suite struct DueDateRangeTests {
    let clock = MockClock(Date(timeIntervalSince1970: 1_790_150_400))
    let lilas = DemoData.lilasGroupId
    /// Note: `Date.distantFuture` is 4001-01-01, inside the accepted range.
    static let year10001 = Date(timeIntervalSince1970: 253_402_300_800 + 366 * 86_400)

    @Test func sharedRuleBoundaries() throws {
        #expect(try InputValidation.dueDate(nil) == nil)
        #expect(try InputValidation.dueDate(Date(timeIntervalSince1970: 0)) == Date(timeIntervalSince1970: 0))
        #expect(throws: AppError.invalidInput) { try InputValidation.dueDate(Date(timeIntervalSince1970: -1)) }
        let lastSecond = Date(timeIntervalSince1970: 253_402_300_799) // 9999-12-31T23:59:59Z
        #expect(try InputValidation.dueDate(lastSecond) == lastSecond)
        #expect(throws: AppError.invalidInput) { try InputValidation.dueDate(Date(timeIntervalSince1970: 253_402_300_800)) }
        #expect(throws: AppError.invalidInput) { try InputValidation.dueDate(Self.year10001) }
        #expect(throws: AppError.invalidInput) { try InputValidation.dueDate(.distantPast) }
    }

    @Test func mockRejectsOutOfRangeDueDatesLikeSQL() async throws {
        let backend = InMemoryBackend.demo(now: clock.provider)
        let camille = backend.services(for: DemoData.camille.id)
        await #expect(throws: AppError.invalidInput) {
            _ = try await camille.tasks.create(groupId: lilas, draft: TaskDraft(title: "Trop loin", dueAt: Self.year10001))
        }
        // Title and details are validated first, like the SQL trigger.
        await #expect(throws: AppError.invalidTitle) {
            _ = try await camille.tasks.create(groupId: lilas, draft: TaskDraft(title: " ", dueAt: .distantPast))
        }
        let task = try await camille.tasks.create(groupId: lilas, draft: TaskDraft(title: "Dans les temps", dueAt: clock.now()))
        var draft = TaskDraft(task: task)
        draft.dueAt = Date(timeIntervalSince1970: -86_400)
        await #expect(throws: AppError.invalidInput) {
            _ = try await camille.tasks.update(taskId: task.id, draft: draft)
        }
        #expect(try await camille.tasks.task(id: task.id).dueAt == task.dueAt, "a rejected edit changes nothing")
    }
}
