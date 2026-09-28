import Foundation

/// Turns the v3 Realtime events (docs/CONTRACTS-V3.md §11) into local notifications worded by `SocialNotificationText`:
/// a nudge, a turn proposed to the user, the answer to a turn they proposed, a reaction to their activity, a comment
/// that mentions them or is on a task they are assigned to. `RealtimeCoordinator` forwards the events in order
/// (`SessionModel` wires it).
///
/// The names (first names, `FrenchText.firstName(of:)`) and the titles are read when the event comes: the members of
/// the event's group, the task (`TaskService.task(id:)`), the feed of the group for a reaction, the comments of the task
/// for a comment. A read that fails leaves « Quelqu’un » or no title. Nothing is posted while notifications are not
/// authorized, nor for the user's own reactions and comments, nor for a comment that `SocialNotificationText.shouldNotify`
/// refuses, nor for the repayment or the cancellation of a swap. Every notification carries the task (or the group, for
/// a reaction to an event without task): a tap opens it. Quiet hours are the platform scheduler's business (it plays no
/// sound during them).
public actor SocialNotifier {
    private let userId: UUID
    private let groups: any GroupService
    private let tasks: any TaskService
    private let scheduler: any NotificationScheduler

    public init(userId: UUID, groups: any GroupService, tasks: any TaskService, scheduler: any NotificationScheduler) {
        self.userId = userId
        self.groups = groups
        self.tasks = tasks
        self.scheduler = scheduler
    }

    /// Posts the notification of `event` (see the type's rules); returns it, nil when nothing is posted.
    @discardableResult
    public func handle(_ event: RealtimeEvent) async -> LocalNotification? {
        guard event.socialGroupId != nil, await scheduler.authorizationStatus() == .authorized else { return nil }
        guard let notification = await notification(for: event) else { return nil }
        do {
            try await scheduler.add(notification)
            return notification
        } catch {
            return nil
        }
    }

    /// The notification of `event`, nil when there is none to post.
    func notification(for event: RealtimeEvent) async -> LocalNotification? {
        switch event {
        case .connected, .groupActivity, .membershipsChanged, .assigned:
            return nil
        case let .nudged(nudgeId, taskId, groupId, fromUserId):
            async let name = firstName(of: fromUserId, in: groupId)
            async let title = taskTitle(taskId)
            return SocialNotificationText.nudge(
                nudgeId: nudgeId, taskId: taskId, groupId: groupId, fromName: await name, taskTitle: await title
            )
        case let .turnSwapProposed(swapId, taskId, groupId, fromUserId):
            async let name = firstName(of: fromUserId, in: groupId)
            async let title = taskTitle(taskId)
            return SocialNotificationText.swapProposed(
                swapId: swapId, taskId: taskId, groupId: groupId, fromName: await name, taskTitle: await title
            )
        case let .turnSwapUpdated(swapId, taskId, groupId, toUserId, status, isRepaid):
            // Only an answer is news: not a repayment, a pending or a cancelled swap.
            guard status == .declined || (status == .accepted && !isRepaid) else { return nil }
            async let name = firstName(of: toUserId, in: groupId)
            async let title = taskTitle(taskId)
            return SocialNotificationText.swapUpdated(
                swapId: swapId, taskId: taskId, groupId: groupId, status: status, isRepaid: isRepaid,
                toName: await name, taskTitle: await title
            )
        case let .reactionAdded(activityId, groupId, reactorId, emoji):
            guard reactorId != userId else { return nil }
            async let name = firstName(of: reactorId, in: groupId)
            let reacted = try? await groups.activity(groupId: groupId).first { $0.id == activityId }
            return SocialNotificationText.reaction(
                activityId: activityId, groupId: groupId, taskId: reacted?.taskId, reactorId: reactorId,
                currentUserId: userId, fromName: await name, emoji: emoji, taskTitle: reacted?.taskTitle
            )
        case let .commentAdded(commentId, taskId, groupId, authorId, mentions):
            guard authorId != userId else { return nil }
            let task = try? await tasks.task(id: taskId)
            let isAssignee = task?.assigneeIds.contains(userId) ?? false
            guard SocialNotificationText.shouldNotify(
                authorId: authorId, mentions: mentions, currentUserId: userId, isAssignee: isAssignee
            ) else { return nil }
            async let name = firstName(of: authorId, in: groupId)
            let body = (try? await tasks.comments(taskId: taskId))?.first { $0.id == commentId }?.body ?? ""
            return SocialNotificationText.comment(
                commentId: commentId, taskId: taskId, groupId: groupId, authorId: authorId, mentions: mentions,
                currentUserId: userId, isAssignee: isAssignee, authorName: await name, taskTitle: task?.title, body: body
            )
        }
    }

    /// The first name of a member of `groupId`, nil when unknown (or unreadable).
    private func firstName(of userId: UUID?, in groupId: UUID) async -> String? {
        guard let userId,
              let member = (try? await groups.members(groupId: groupId))?.first(where: { $0.user.id == userId })
        else { return nil }
        let name = FrenchText.firstName(of: member.user.displayName)
        return name.isEmpty ? nil : name
    }

    private func taskTitle(_ taskId: UUID) async -> String? {
        try? await tasks.task(id: taskId).title
    }
}
