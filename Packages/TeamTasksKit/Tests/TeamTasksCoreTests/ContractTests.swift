import Foundation
import Testing
@testable import TeamTasksCore

@Suite struct InviteCodeTests {
    @Test(arguments: ["ABCDEFGH", "abcd-efgh", " AbCd EfGh ", "abcd_efgh"])
    func acceptsAndNormalizes(input: String) throws {
        let code = try #require(InviteCode(input))
        #expect(code.value == "ABCDEFGH")
        #expect(code.formatted == "ABCD-EFGH")
    }

    @Test(arguments: ["", "ABCDEFG", "ABCDEFGHJ", "ABCDEFG0", "ABCDEFGO", "ABCDEFG1", "ABCDEFGI", "ÀBCDEFGH"])
    func rejectsInvalid(input: String) {
        #expect(InviteCode(input) == nil)
    }

    /// CODE-1: SQL drops non-`[A-Z0-9]` code points one by one (`L` + U+0301 keeps the `L`), so must `normalize`.
    @Test func normalizationDropsCodePointsLikeSQL() {
        #expect(InviteCode.normalize("L\u{301}YLAS234") == "LYLAS234")
        #expect(InviteCode("l\u{301}ylas-234")?.value == "LYLAS234")
        #expect(InviteCode.normalize("straße") == "STRASSE") // full case mapping, like SQL upper()
    }

    @Test func alphabetHas32UnambiguousCharacters() {
        #expect(InviteCode.alphabet.count == 32)
        for ambiguous in "01IO" {
            #expect(!InviteCode.alphabet.contains(ambiguous))
        }
    }
}

@Suite struct BackendErrorMapperTests {
    @Test func mapsBusinessMessagesFirst() {
        #expect(BackendErrorMapper.map(code: "P0001", message: "last_admin") == .lastAdmin)
        #expect(BackendErrorMapper.map(code: "42501", message: "forbidden_fields") == .forbiddenFields)
        #expect(BackendErrorMapper.map(code: "P0001", message: "task_not_found") == .notFound)
    }

    @Test func fallsBackToSQLState() {
        #expect(BackendErrorMapper.map(code: "42501", message: "new row violates row-level security policy") == .forbidden)
        #expect(BackendErrorMapper.map(code: "23505", message: "duplicate key") == .conflict)
        #expect(BackendErrorMapper.map(code: "23514", message: "check constraint") == .invalidInput)
        #expect(BackendErrorMapper.map(code: "PGRST116", message: "0 rows") == .notFound)
    }

    @Test func fallsBackToHTTPStatus() {
        #expect(BackendErrorMapper.map(code: nil, message: nil, httpStatus: 401) == .notAuthenticated)
        #expect(BackendErrorMapper.map(code: nil, message: "boom", httpStatus: 500) == .unknown("boom"))
    }

    /// CORE-401: PostgREST answers a call without a user JWT with HTTP 401
    /// `{"code":"42501","message":"permission denied for …"}`.
    @Test func signedOutPermissionErrorMapsToNotAuthenticated() {
        #expect(BackendErrorMapper.map(code: "42501", message: "permission denied for table group_members", httpStatus: 401) == .notAuthenticated)
        #expect(BackendErrorMapper.map(code: "42501", message: "permission denied for function create_group", httpStatus: 401) == .notAuthenticated)
        // Our own permission errors keep their meaning.
        #expect(BackendErrorMapper.map(code: "42501", message: "forbidden", httpStatus: 403) == .forbidden)
        #expect(BackendErrorMapper.map(code: "42501", message: "forbidden_fields", httpStatus: 403) == .forbiddenFields)
    }

    @Test func mapsValidationErrorsAddedByTheReview() {
        #expect(BackendErrorMapper.map(code: "P0001", message: "invalid_due_at", httpStatus: 400) == .invalidInput)
        #expect(BackendErrorMapper.map(code: "23502", message: "invalid_input", httpStatus: 400) == .invalidInput)
        #expect(BackendErrorMapper.map(code: "22P05", message: "unsupported Unicode escape sequence", httpStatus: 400) == .invalidInput)
    }

    @Test func everyCaseHasAFrenchMessage() {
        for error in BackendErrorMapper.messageCodes.values {
            #expect(!error.messageFR.isEmpty)
        }
    }
}

@Suite struct PermissionsTests {
    let admin = UUID()
    let creator = UUID()
    let assignee = UUID()
    let other = UUID()

    var task: TaskItem {
        TaskItem(
            id: UUID(), groupId: UUID(), title: "Acheter le pain",
            createdBy: creator, createdAt: .now, updatedAt: .now, assigneeIds: [assignee]
        )
    }

    @Test func matrix() {
        // (user, role) -> (edit, status, delete)
        let cases: [(UUID, MemberRole?, Bool, Bool, Bool)] = [
            (admin, .admin, true, true, true),
            (creator, .member, true, true, true),
            (assignee, .member, false, true, false),
            (other, .member, false, false, false),
            (creator, nil, false, false, false), // creator who left the group
            (assignee, nil, false, false, false),
        ]
        for (user, role, edit, status, delete) in cases {
            #expect(TaskPermissions.canEdit(task, userId: user, role: role) == edit)
            #expect(TaskPermissions.canChangeStatus(task, userId: user, role: role) == status)
            #expect(TaskPermissions.canDelete(task, userId: user, role: role) == delete)
        }
    }

    @Test func groupAdminOnlyActions() {
        #expect(GroupPermissions.canManageMembers(role: .admin))
        #expect(!GroupPermissions.canManageMembers(role: .member))
        #expect(!GroupPermissions.canSeeInviteCode(role: .member))
        #expect(GroupPermissions.canLeave(role: .member))
        #expect(!GroupPermissions.canLeave(role: nil))
    }
}
