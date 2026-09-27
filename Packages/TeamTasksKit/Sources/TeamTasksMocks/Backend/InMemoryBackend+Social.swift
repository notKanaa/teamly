import Foundation
import TeamTasksCore

// The v3 features (docs/CONTRACTS-V3.md): « Relancer », « Mode absent », « Échanger mon tour », « Bravo », comments,
// photos and the personal stats. Same check orders and error codes as the SQL; push is not mirrored.
extension InMemoryBackend {
    // MARK: - Relancer (§1)

    /// `nudge_task`: any member of the task's group (`task_not_found` otherwise) → not done (`task_done`) → someone
    /// assigned besides the caller (`nudge_no_recipient`) → no nudge of the caller on this task in the last
    /// `Limits.nudgeCooldownHours` hours (`nudge_rate_limited`; inclusive: a nudge exactly that old still counts). One
    /// row and one `task_nudged` event per assignee (in id order), a bump of the group. Returns the number of
    /// assignees nudged.
    func nudge(clientId: UUID, taskId: UUID) throws -> Int {
        try write(as: clientId) { transaction, me in
            guard let task = transaction.data.visibleTask(taskId, to: me) else { throw AppError.notFound }
            guard task.status != .done else { throw AppError.taskDone }
            let recipients = transaction.data.assigneeIds(of: task.id).filter { $0 != me }
            guard !recipients.isEmpty else { throw AppError.nudgeNoRecipient }
            let windowStart = transaction.now.addingTimeInterval(-TimeInterval(Limits.nudgeCooldownHours) * 3600)
            let recent = transaction.data.nudges.contains { nudge in
                nudge.taskId == task.id && nudge.fromUser == me && nudge.createdAt >= windowStart
            }
            guard !recent else { throw AppError.nudgeRateLimited }
            for recipient in recipients {
                transaction.insertNudge(NudgeRecord(
                    id: UUID(), taskId: task.id, groupId: task.groupId, fromUser: me, toUser: recipient,
                    createdAt: transaction.now
                ))
                transaction.logActivity(
                    groupId: task.groupId, kind: .taskNudged, actorId: me, subjectId: recipient, taskId: task.id,
                    taskTitle: task.title
                )
            }
            transaction.bump(task.groupId)
            return recipients.count
        }
    }

    // MARK: - Mode absent (§2)

    /// `set_away`: `invalid_away` unless `from <= until`, `until >= today - 1` (the UTC date of the backend's clock)
    /// and `until - from <= 365`. Writes the profile (the user's devices get
    /// `.membershipsChanged`; new dates bump every group of the user, so co-members reload the members), announces the
    /// absence to each group of the user (`member_away`, in group id order) when asked, then hands over the turns
    /// held in the range (`Transaction.handOverTurnsOfAbsence`). Returns the profile as `myProfile()` reads it.
    func setAway(clientId: UUID, from: LocalDate, until: LocalDate, announce: Bool) throws -> UserProfile {
        try write(as: clientId) { transaction, me in
            try InputValidation.awayRange(from: from, until: until, today: InputValidation.serverToday(now: transaction.now))
            guard let stored = transaction.data.profiles[me] else { throw AppError.notAuthenticated }
            transaction.data.profiles[me]?.awayFrom = from
            transaction.data.profiles[me]?.awayUntil = until
            transaction.profileUpdated(me)
            let groupIds = transaction.data.groupIds(of: me)
            if stored.awayFrom != from || stored.awayUntil != until {
                for groupId in groupIds {
                    transaction.bump(groupId)
                }
            }
            if announce {
                for groupId in groupIds {
                    transaction.logActivity(
                        groupId: groupId, kind: .memberAway, actorId: me, subjectId: me, startsOn: from, endsOn: until
                    )
                }
            }
            transaction.handOverTurnsOfAbsence(of: me, from: from, until: until)
            guard let profile = transaction.data.profiles[me] else { throw AppError.notAuthenticated }
            return transaction.data.ownProfile(profile)
        }
    }

    /// `clear_away`: both dates NULL; no event, no turn moves back. Ending an absence bumps the user's groups; without
    /// an absence nothing is written (no signal).
    func clearAway(clientId: UUID) throws -> UserProfile {
        try write(as: clientId) { transaction, me in
            guard let stored = transaction.data.profiles[me] else { throw AppError.notAuthenticated }
            if stored.awayFrom != nil || stored.awayUntil != nil {
                transaction.data.profiles[me]?.awayFrom = nil
                transaction.data.profiles[me]?.awayUntil = nil
                transaction.profileUpdated(me)
                for groupId in transaction.data.groupIds(of: me) {
                    transaction.bump(groupId)
                }
            }
            guard let profile = transaction.data.profiles[me] else { throw AppError.notAuthenticated }
            return transaction.data.ownProfile(profile)
        }
    }

    // MARK: - Échanger mon tour (§3)

    /// `request_turn_swap`: `task_not_found` → the caller holds the turn of a pending rotating occurrence
    /// (`not_your_turn`) → the target is a current member listed in the rotation, not the caller (`invalid_rotation`)
    /// → no pending swap on the task (`swap_pending`). Inserts a pending swap (Realtime INSERT for the target) and bumps
    /// the group, like every write of `turn_swaps`.
    func requestTurnSwap(clientId: UUID, taskId: UUID, to target: UUID) throws -> TurnSwap {
        try write(as: clientId) { transaction, me in
            guard let task = transaction.data.visibleTask(taskId, to: me) else { throw AppError.notFound }
            guard task.status != .done, !task.rotation.isEmpty, task.turnUserId == me else { throw AppError.notYourTurn }
            guard target != me, task.rotation.contains(target), transaction.data.isMember(target, of: task.groupId) else {
                throw AppError.invalidRotation
            }
            let pending = transaction.data.swaps.values.contains { $0.taskId == task.id && $0.status == .pending }
            guard !pending else { throw AppError.swapPending }
            let swap = SwapRecord(
                id: UUID(), taskId: task.id, groupId: task.groupId, seriesId: task.seriesId ?? task.id, fromUser: me,
                toUser: target, status: .pending, createdAt: transaction.now
            )
            transaction.data.swaps[swap.id] = swap
            transaction.swapInserted(swap.id)
            transaction.bump(task.groupId)
            return swap.swap
        }
    }

    /// `respond_turn_swap`: `swap_not_found` (unknown, or not a member of its group) → only the target (`forbidden`)
    /// → pending (`swap_not_pending`). Declined: `declined`, `responded_at`. Accepted: `accepted`, `responded_at`; the
    /// occurrence's turn and only assignee become the caller (`assigned_by` = the caller: no notification) and a
    /// `turn_swapped` event is written (actor = the caller, subject = the author). Both bump the group; the author gets
    /// a Realtime UPDATE.
    func respondToTurnSwap(clientId: UUID, swapId: UUID, accept: Bool) throws -> TurnSwap {
        try write(as: clientId) { transaction, me in
            let swap = try transaction.data.visibleSwap(swapId, to: me)
            guard swap.toUser == me else { throw AppError.forbidden }
            guard swap.status == .pending else { throw AppError.swapNotPending }
            var updated = swap
            updated.respondedAt = transaction.now
            updated.status = accept ? .accepted : .declined
            if accept {
                guard let task = transaction.data.tasks[swap.taskId] else { throw AppError.notFound }
                // `turn_user_id` must be listed in the rotation (check constraint).
                guard task.rotation.contains(me) else { throw AppError.invalidRotation }
                transaction.data.swaps[swap.id] = updated
                transaction.data.tasks[task.id]?.turnUserId = me
                for userId in transaction.data.assigneeIds(of: task.id) where userId != me {
                    transaction.data.assignees[task.id]?[userId] = nil
                }
                if transaction.data.assignees[task.id]?[me] == nil {
                    transaction.insertAssignee(taskId: task.id, groupId: task.groupId, userId: me, assignedBy: me)
                }
                transaction.bump(task.groupId)
                transaction.logActivity(
                    groupId: task.groupId, kind: .turnSwapped, actorId: me, subjectId: swap.fromUser, taskId: task.id,
                    taskTitle: task.title
                )
            } else {
                transaction.data.swaps[swap.id] = updated
            }
            transaction.bump(swap.groupId)
            transaction.swapUpdated(swap.id)
            return updated.swap
        }
    }

    /// `cancel_turn_swap`: `swap_not_found` → only the author (`forbidden`) → pending (`swap_not_pending`). The swap
    /// becomes `cancelled`, with `responded_at`; the group bumps.
    func cancelTurnSwap(clientId: UUID, swapId: UUID) throws -> TurnSwap {
        try write(as: clientId) { transaction, me in
            let swap = try transaction.data.visibleSwap(swapId, to: me)
            guard swap.fromUser == me else { throw AppError.forbidden }
            guard swap.status == .pending else { throw AppError.swapNotPending }
            let now = transaction.now // local copy: see Transaction.finish()
            transaction.data.swaps[swap.id]?.status = .cancelled
            transaction.data.swaps[swap.id]?.respondedAt = now
            transaction.bump(swap.groupId)
            transaction.swapUpdated(swap.id)
            guard let cancelled = transaction.data.swaps[swap.id] else { throw AppError.notFound }
            return cancelled.swap
        }
    }

    /// `turn_swaps?select=*&task_id=eq.<t>&order=created_at.asc`: members of the group only (RLS).
    func turnSwaps(clientId: UUID, taskId: UUID) throws -> [TurnSwap] {
        try read(as: clientId) { data, me in
            data.swaps.values
                .filter { $0.taskId == taskId && data.isMember(me, of: $0.groupId) }
                .sorted(by: SwapRecord.olderFirst)
                .map(\.swap)
        }
    }

    /// `turn_swaps?select=*&status=eq.pending&or=(from_user.eq.<me>,to_user.eq.<me>)&order=created_at.asc`.
    func pendingTurnSwaps(clientId: UUID) throws -> [TurnSwap] {
        try read(as: clientId) { data, me in
            data.swaps.values
                .filter { swap in
                    swap.status == .pending && (swap.fromUser == me || swap.toUser == me) && data.isMember(me, of: swap.groupId)
                }
                .sorted(by: SwapRecord.olderFirst)
                .map(\.swap)
        }
    }

    // MARK: - Bravo (§4)

    /// `toggle_reaction`: a member of the event's group (`activity_not_found` otherwise; a typed emoji is always in
    /// the set). Removes the caller's reaction with that emoji (false) or adds it (true, `target_user` = the event's
    /// actor, a Realtime INSERT for them); bumps the group either way.
    func toggleReaction(clientId: UUID, activityId: Int64, emoji: ReactionEmoji) throws -> Bool {
        try write(as: clientId) { transaction, me in
            guard let event = transaction.data.activity.first(where: { $0.id == activityId }),
                  transaction.data.isMember(me, of: event.groupId)
            else { throw AppError.notFound }
            transaction.bump(event.groupId)
            if let index = transaction.data.reactions.firstIndex(where: {
                $0.activityId == activityId && $0.userId == me && $0.emoji == emoji
            }) {
                transaction.data.reactions.remove(at: index)
                return false
            }
            let target = event.actorId.flatMap { transaction.data.profiles[$0] == nil ? nil : $0 }
            transaction.insertReaction(ReactionRecord(
                activityId: activityId, groupId: event.groupId, userId: me, targetUser: target, emoji: emoji,
                createdAt: transaction.now
            ))
            return true
        }
    }

    // MARK: - Commentaires (§5)

    /// `task_comments?select=*&task_id=eq.<t>&order=created_at.asc`: members only (RLS).
    func comments(clientId: UUID, taskId: UUID) throws -> [TaskComment] {
        try read(as: clientId) { data, me in
            TaskComment.sorted(
                data.comments.values.filter { $0.taskId == taskId && data.isMember(me, of: $0.groupId) }.map(\.comment)
            )
        }
    }

    /// `add_task_comment`: `task_not_found` → the body (`invalid_comment`) → the mentions (duplicates dropped in order,
    /// at most 20, members of the group: `invalid_mentions`; oneself allowed). Writes the comment (Realtime INSERT for the group), a
    /// `comment_added` event (the first 80 characters as `item_title`) and bumps the group.
    func addComment(clientId: UUID, taskId: UUID, body: String, mentions: [UUID]) throws -> TaskComment {
        try write(as: clientId) { transaction, me in
            guard let task = transaction.data.visibleTask(taskId, to: me) else { throw AppError.notFound }
            let body = try InputValidation.commentBody(body)
            let mentions = try InputValidation.mentions(mentions)
            guard mentions.allSatisfy({ transaction.data.isMember($0, of: task.groupId) }) else {
                throw AppError.invalidMentions
            }
            let comment = CommentRecord(
                id: UUID(), taskId: task.id, groupId: task.groupId, authorId: me, body: body, mentions: mentions,
                createdAt: transaction.now
            )
            transaction.insertComment(comment)
            transaction.logActivity(
                groupId: task.groupId, kind: .commentAdded, actorId: me, taskId: task.id, taskTitle: task.title,
                itemTitle: InputValidation.commentExcerpt(body)
            )
            transaction.bump(task.groupId)
            return comment.comment
        }
    }

    /// `delete_task_comment`: `comment_not_found` (unknown, or not a member) → the author or an admin (`forbidden`).
    /// Bumps the group (the comment counts of the rows change).
    func deleteComment(clientId: UUID, commentId: UUID) throws {
        try write(as: clientId) { transaction, me in
            guard let comment = transaction.data.comments[commentId],
                  let role = transaction.data.role(of: me, in: comment.groupId)
            else { throw AppError.notFound }
            guard comment.authorId == me || role == .admin else { throw AppError.forbidden }
            transaction.data.comments[commentId] = nil
            transaction.bump(comment.groupId)
        }
    }

    // MARK: - Photo preuve (§6)

    /// The client's steps in one transaction: the task (`task_not_found`), the bytes as the bucket checks them
    /// (`InputValidation.photo(_:)`), the upload to `<group_id>/<task_id>/<uuid>.jpg` (storage policy: a member of
    /// the group), then `attach_task_photo`. A failed attach leaves no object behind (the adapter removes it).
    func uploadPhoto(clientId: UUID, taskId: UUID, jpegData: Data) throws -> TaskPhoto {
        try write(as: clientId) { transaction, me in
            guard let task = transaction.data.visibleTask(taskId, to: me) else { throw AppError.notFound }
            let bytes = try InputValidation.photo(jpegData)
            let path = TaskPhoto.newPath(groupId: task.groupId, taskId: task.id)
            transaction.data.photoObjects[path] = StoredObject(
                path: path, data: bytes, contentType: "image/jpeg", owner: me, createdAt: transaction.now
            )
            return try InMemoryBackend.attachPhoto(&transaction, me: me, taskId: task.id, path: path)
        }
    }

    /// `attach_task_photo`: `task_not_found` → the rights of « change status » (`forbidden`) → the path is exactly
    /// `<group_id>/<task_id>/<uuid>.<ext>` (`InputValidation.isPhotoPath`), the object exists and the path is not
    /// attached yet (`invalid_photo`) → at most `Limits.photosPerTaskMax` photos (`photo_limit`). Writes a `photo_added` event and bumps
    /// the group.
    static func attachPhoto(_ transaction: inout Transaction, me: UUID, taskId: UUID, path: String) throws -> TaskPhoto {
        guard let task = transaction.data.visibleTask(taskId, to: me) else { throw AppError.notFound }
        guard transaction.data.canChangeStatus(task, userId: me) else { throw AppError.forbidden }
        guard InputValidation.isPhotoPath(path, groupId: task.groupId, taskId: task.id),
              transaction.data.photoObjects[path] != nil,
              !transaction.data.photos.values.contains(where: { $0.path == path })
        else { throw AppError.invalidPhoto }
        let count = transaction.data.photos.values.filter { $0.taskId == task.id }.count
        guard count < Limits.photosPerTaskMax else { throw AppError.photoLimit }
        let photo = PhotoRecord(
            id: UUID(), taskId: task.id, groupId: task.groupId, path: path, uploadedBy: me, createdAt: transaction.now
        )
        transaction.data.photos[photo.id] = photo
        transaction.logActivity(groupId: task.groupId, kind: .photoAdded, actorId: me, taskId: task.id, taskTitle: task.title)
        transaction.bump(task.groupId)
        return photo.photo
    }

    /// `delete_task_photo`: `photo_not_found` (unknown, or not a member) → the uploader or an admin (`forbidden`);
    /// deletes the row (and bumps the group), then the client deletes the object (storage policy: its owner or an
    /// admin of the group).
    func deletePhoto(clientId: UUID, photoId: UUID) throws {
        try write(as: clientId) { transaction, me in
            guard let photo = transaction.data.photos[photoId], let role = transaction.data.role(of: me, in: photo.groupId)
            else { throw AppError.notFound }
            guard photo.uploadedBy == me || role == .admin else { throw AppError.forbidden }
            transaction.data.photos[photoId] = nil
            transaction.data.photoObjects[photo.path] = nil
            transaction.bump(photo.groupId)
        }
    }

    /// The « signed URL » of the mocks: a `data:image/jpeg;base64,…` URL holding the stored bytes (SwiftUI's
    /// `AsyncImage` shows it). Storage select policy: the first path segment is one of the caller's groups; a missing
    /// object is `.notFound`.
    func photoURL(clientId: UUID, path: String) throws -> URL {
        try read(as: clientId) { data, me in
            let groupSegment = path.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            guard let groupId = UUID(uuidString: groupSegment), data.isMember(me, of: groupId),
                  let object = data.photoObjects[path],
                  let url = URL(string: "data:\(object.contentType);base64,\(object.data.base64EncodedString())")
            else { throw AppError.notFound }
            return url
        }
    }

    /// The stored bytes of a photo object (tests, previews); nil when absent.
    public func photoObjectData(path: String) -> Data? {
        inspect { $0.photoObjects[path]?.data }
    }

    // MARK: - Personal stats (§8)

    /// `tasks?select=id,group_id,completed_at&completed_by=eq.<me>&completed_at=gte.<since>`: in the caller's groups
    /// (RLS), in creation order.
    func myCompletions(clientId: UUID, since: Date) throws -> [TaskCompletion] {
        try read(as: clientId) { data, me in
            data.tasks.values
                .filter { task in
                    task.completedBy == me && (task.completedAt ?? .distantPast) >= since && data.isMember(me, of: task.groupId)
                }
                .sorted(by: InMemoryBackend.creationOrder)
                .compactMap { task in
                    task.completedAt.map { TaskCompletion(taskId: task.id, completedBy: me, completedAt: $0, groupId: task.groupId) }
                }
        }
    }
}

extension BackendData {
    /// A swap the caller may see (`turn_swaps` SELECT: members of its group), else `.notFound` (`swap_not_found`).
    func visibleSwap(_ swapId: UUID, to userId: UUID) throws -> SwapRecord {
        guard let swap = swaps[swapId], isMember(userId, of: swap.groupId) else { throw AppError.notFound }
        return swap
    }
}
