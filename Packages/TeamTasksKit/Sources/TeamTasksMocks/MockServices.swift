import Foundation
import TeamTasksCore

// Core service implementations bound to one client session of an `InMemoryBackend`.
// Every call first waits for the backend's artificial latency (zero by default).

struct MockAuthService: AuthService {
    let session: MockSession

    func authStates() -> AsyncStream<AuthState> {
        session.backend.authStates(clientId: session.clientId)
    }

    func currentUser() async -> AuthUser? {
        session.backend.currentUser(clientId: session.clientId)
    }

    func signUp(email: String, password: String, displayName: String) async throws -> SignUpOutcome {
        try await session.backend.simulateLatency()
        return try session.backend.signUp(clientId: session.clientId, email: email, password: password, displayName: displayName)
    }

    func signIn(email: String, password: String) async throws {
        try await session.backend.simulateLatency()
        try session.backend.signIn(clientId: session.clientId, email: email, password: password)
    }

    func signOut() async throws {
        try await session.backend.simulateLatency()
        session.backend.signOut(clientId: session.clientId)
    }

    /// The mock "e-mail" always contains `InMemoryBackend.recoveryCode`.
    func sendPasswordReset(email: String) async throws {
        try await session.backend.simulateLatency()
        try session.backend.sendPasswordReset(email: email)
    }

    func verifyRecoveryCode(email: String, code: String) async throws {
        try await session.backend.simulateLatency()
        try session.backend.verifyRecoveryCode(clientId: session.clientId, email: email, code: code)
    }

    func updatePassword(_ newPassword: String) async throws {
        try await session.backend.simulateLatency()
        try session.backend.updatePassword(clientId: session.clientId, newPassword: newPassword)
    }

    func deleteAccount() async throws {
        try await session.backend.simulateLatency()
        try session.backend.deleteAccount(clientId: session.clientId)
    }
}

struct MockProfileService: ProfileService {
    let session: MockSession

    func myProfile() async throws -> UserProfile {
        try await session.backend.simulateLatency()
        return try session.backend.myProfile(clientId: session.clientId)
    }

    func updateDisplayName(_ name: String) async throws -> UserProfile {
        try await session.backend.simulateLatency()
        return try session.backend.updateDisplayName(clientId: session.clientId, name: name)
    }

    // TODO(v2-mocks): implement (docs/CONTRACTS-V2.md §2, §3; avatar PATCH).
    func updateAvatar(color: ColorKey?, emoji: String?) async throws -> UserProfile {
        throw AppError.unknown("pas encore disponible")
    }

    // TODO(v2-mocks): implement (docs/CONTRACTS-V2.md §5 complete_onboarding, §9).
    func completeOnboarding() async throws {
        throw AppError.unknown("pas encore disponible")
    }
}

struct MockGroupService: GroupService {
    let session: MockSession

    func myGroups() async throws -> [GroupSummary] {
        try await session.backend.simulateLatency()
        return try session.backend.myGroups(clientId: session.clientId)
    }

    func createGroup(name: String) async throws -> GroupSummary {
        try await session.backend.simulateLatency()
        return try session.backend.createGroup(clientId: session.clientId, name: name)
    }

    func join(code: InviteCode) async throws -> JoinResult {
        try await session.backend.simulateLatency()
        return try session.backend.join(clientId: session.clientId, code: code)
    }

    func rename(groupId: UUID, name: String) async throws -> TeamGroup {
        try await session.backend.simulateLatency()
        return try session.backend.rename(clientId: session.clientId, groupId: groupId, name: name)
    }

    func deleteGroup(groupId: UUID) async throws {
        try await session.backend.simulateLatency()
        try session.backend.deleteGroup(clientId: session.clientId, groupId: groupId)
    }

    func members(groupId: UUID) async throws -> [Membership] {
        try await session.backend.simulateLatency()
        return try session.backend.members(clientId: session.clientId, groupId: groupId)
    }

    func inviteCode(groupId: UUID) async throws -> InviteCode {
        try await session.backend.simulateLatency()
        return try session.backend.inviteCode(clientId: session.clientId, groupId: groupId)
    }

    func regenerateInviteCode(groupId: UUID) async throws -> InviteCode {
        try await session.backend.simulateLatency()
        return try session.backend.regenerateInviteCode(clientId: session.clientId, groupId: groupId)
    }

    func setRole(groupId: UUID, userId: UUID, role: MemberRole) async throws {
        try await session.backend.simulateLatency()
        try session.backend.setRole(clientId: session.clientId, groupId: groupId, userId: userId, role: role)
    }

    func removeMember(groupId: UUID, userId: UUID) async throws {
        try await session.backend.simulateLatency()
        try session.backend.removeMember(clientId: session.clientId, groupId: groupId, userId: userId)
    }

    func leave(groupId: UUID) async throws {
        try await session.backend.simulateLatency()
        try session.backend.leave(clientId: session.clientId, groupId: groupId)
    }

    // TODO(v2-mocks): implement (docs/CONTRACTS-V2.md §5 create_group with appearance).
    func createGroup(name: String, color: ColorKey?, emoji: String?) async throws -> GroupSummary {
        throw AppError.unknown("pas encore disponible")
    }

    // TODO(v2-mocks): implement (docs/CONTRACTS-V2.md §5 set_group_appearance).
    func setAppearance(groupId: UUID, color: ColorKey?, emoji: String?) async throws -> TeamGroup {
        throw AppError.unknown("pas encore disponible")
    }

    // TODO(v2-mocks): implement (docs/CONTRACTS-V2.md §7 activity feed).
    func activity(groupId: UUID) async throws -> [ActivityEvent] {
        throw AppError.unknown("pas encore disponible")
    }
}

struct MockTaskService: TaskService {
    let session: MockSession

    func tasks(groupId: UUID, includeOldDone: Bool) async throws -> [TaskItem] {
        try await session.backend.simulateLatency()
        return try session.backend.tasks(clientId: session.clientId, groupId: groupId, includeOldDone: includeOldDone)
    }

    func myTasks(includeDone: Bool) async throws -> [TaskItem] {
        try await session.backend.simulateLatency()
        return try session.backend.myTasks(clientId: session.clientId, includeDone: includeDone)
    }

    func task(id: UUID) async throws -> TaskItem {
        try await session.backend.simulateLatency()
        return try session.backend.task(clientId: session.clientId, taskId: id)
    }

    func create(groupId: UUID, draft: TaskDraft) async throws -> TaskItem {
        try await session.backend.simulateLatency()
        return try session.backend.createTask(clientId: session.clientId, groupId: groupId, draft: draft)
    }

    func update(taskId: UUID, draft: TaskDraft) async throws -> TaskItem {
        try await session.backend.simulateLatency()
        return try session.backend.updateTask(clientId: session.clientId, taskId: taskId, draft: draft)
    }

    func setStatus(taskId: UUID, status: TaskStatus) async throws -> TaskItem {
        try await session.backend.simulateLatency()
        return try session.backend.setStatus(clientId: session.clientId, taskId: taskId, status: status)
    }

    func delete(taskId: UUID) async throws {
        try await session.backend.simulateLatency()
        try session.backend.deleteTask(clientId: session.clientId, taskId: taskId)
    }

    func assignments(since: Date) async throws -> [AssignmentEvent] {
        try await session.backend.simulateLatency()
        return try session.backend.assignments(clientId: session.clientId, since: since)
    }

    // TODO(v2-mocks): implement (docs/CONTRACTS-V2.md §5 add_checklist_item).
    func addChecklistItem(taskId: UUID, title: String) async throws -> ChecklistItem {
        throw AppError.unknown("pas encore disponible")
    }

    // TODO(v2-mocks): implement (docs/CONTRACTS-V2.md §5 rename_checklist_item).
    func renameChecklistItem(itemId: UUID, title: String) async throws -> ChecklistItem {
        throw AppError.unknown("pas encore disponible")
    }

    // TODO(v2-mocks): implement (docs/CONTRACTS-V2.md §5 set_checklist_item_done).
    func setChecklistItemDone(itemId: UUID, done: Bool) async throws -> ChecklistItem {
        throw AppError.unknown("pas encore disponible")
    }

    // TODO(v2-mocks): implement (docs/CONTRACTS-V2.md §5 delete_checklist_item).
    func deleteChecklistItem(itemId: UUID) async throws {
        throw AppError.unknown("pas encore disponible")
    }

    // TODO(v2-mocks): implement (docs/CONTRACTS-V2.md §8 weekly recap read).
    func completions(groupId: UUID, since: Date) async throws -> [TaskCompletion] {
        throw AppError.unknown("pas encore disponible")
    }
}

struct MockRealtimeService: RealtimeService {
    let session: MockSession

    /// Emits `.connected` immediately, then the change signals of docs/CONTRACTS.md §6 for `userId`, as far as
    /// this client's session may see them (nothing while signed out).
    func events(userId: UUID, groupIds: [UUID]) -> AsyncStream<RealtimeEvent> {
        session.backend.subscribe(clientId: session.clientId, userId: userId, groupIds: groupIds)
    }
}

struct MockPushService: PushService {
    let session: MockSession

    func currentTopic() async throws -> String? {
        try await session.backend.simulateLatency()
        return try session.backend.currentPushTopic(clientId: session.clientId)
    }

    func enable() async throws -> String {
        try await session.backend.simulateLatency()
        return try session.backend.enablePush(clientId: session.clientId)
    }

    func disable() async throws {
        try await session.backend.simulateLatency()
        try session.backend.disablePush(clientId: session.clientId)
    }
}
