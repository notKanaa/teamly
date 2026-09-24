import Foundation
@testable import RealtimeV2
import Supabase
import TeamTasksCore
import Testing
@testable import TeamTasksSupabase

/// §6 bindings: ≤ 60 group ids, payload → `RealtimeEvent`, `system` status → `.connected` / failure.
@Suite struct RealtimeBindingsTests {
    /// The filters as sent in the join payload (`RealtimePostgresFilter.value` is internal to supabase-swift).
    @Test func filtersAreThoseOfTheContract() {
        let bindings = RealtimeBindings(userId: Seed.camille, groupIds: [Seed.lilas, Seed.sport])
        #expect(bindings.groupsFilter.value
            == "id=in.(a0000000-0000-4000-8000-000000000001,a0000000-0000-4000-8000-000000000002)")
        #expect(bindings.profilesFilter.value == "id=eq.11111111-1111-4111-8111-111111111111")
        #expect(bindings.assigneesFilter.value == "user_id=eq.11111111-1111-4111-8111-111111111111")
        #expect(RealtimeBindings(userId: Seed.camille, groupIds: []).groupsFilter.value == "id=in.()")
    }

    @Test func groupIdsAreCappedAtSixtyLowercaseAndUnique() {
        let ids = (0..<70).map { _ in UUID() }
        let bindings = RealtimeBindings(userId: Seed.camille, groupIds: [ids[0]] + ids)
        #expect(bindings.groupIds.count == 59, "the first 60 given ids, one of them twice")
        #expect(bindings.groupIds == ids.prefix(59).map { $0.uuidString.lowercased() })
        #expect(bindings.me == "11111111-1111-4111-8111-111111111111")
        #expect(RealtimeBindings(userId: Seed.camille, groupIds: ids).groupIds.count == 60)
        #expect(RealtimeBindings(userId: Seed.camille, groupIds: []).groupIds.isEmpty)
    }

    @Test func groupsUpdateIsGroupActivity() {
        let record: [String: AnyJSON] = [
            "id": .string("a0000000-0000-4000-8000-000000000001"), "name": .string("Coloc' rue des Lilas"),
            "last_activity_at": .string("2026-09-24T00:24:04.385321+00:00"),
        ]
        #expect(RealtimeBindings.groupActivity(record: record) == .groupActivity(groupId: Seed.lilas))
        #expect(RealtimeBindings.groupActivity(record: [:]) == nil)
    }

    @Test func taskAssigneesInsertIsAssigned() {
        var record: [String: AnyJSON] = [
            "task_id": .string("b0000000-0000-4000-8000-000000000002"), "group_id": .string("a0000000-0000-4000-8000-000000000001"),
            "user_id": .string("11111111-1111-4111-8111-111111111111"), "assigned_by": .string("22222222-2222-4222-8222-222222222222"),
            "assigned_at": .string("2026-09-21T23:52:26.878215+00:00"),
        ]
        #expect(RealtimeBindings.assigned(record: record)
            == .assigned(taskId: Seed.courses, groupId: Seed.lilas, assignedBy: Seed.lucas))
        record["assigned_by"] = .null
        #expect(RealtimeBindings.assigned(record: record) == .assigned(taskId: Seed.courses, groupId: Seed.lilas, assignedBy: nil))
        record["task_id"] = nil
        #expect(RealtimeBindings.assigned(record: record) == nil)
    }

    /// Only the Postgres subscription confirmation is `.connected` (not the join reply); errors are failures.
    @Test func systemMessages() {
        let subscribed: [String: AnyJSON] = [
            "channel": "equipe:x", "extension": "postgres_changes", "message": "Subscribed to PostgreSQL", "status": "ok",
        ]
        #expect(RealtimeBindings.systemStatus(payload: subscribed) == .subscribed)
        let failed: [String: AnyJSON] = [
            "channel": "equipe:x", "extension": "postgres_changes",
            "message": "{:error, \"Unable to subscribe to changes with given parameters.\"}", "status": "error",
        ]
        #expect(RealtimeBindings.systemStatus(payload: failed) == .failed)
        #expect(RealtimeBindings.systemStatus(payload: ["extension": "system", "status": "error", "message": "Token has expired"]) == .failed)
        #expect(RealtimeBindings.systemStatus(payload: ["extension": "presence", "status": "ok"]) == .other)
        #expect(RealtimeBindings.systemStatus(payload: [:]) == .other)
    }
}
