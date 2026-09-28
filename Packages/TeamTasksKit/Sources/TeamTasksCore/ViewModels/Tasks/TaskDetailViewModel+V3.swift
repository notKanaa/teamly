import Foundation

// v3 of the task screen (docs/CONTRACTS-V3.md): « Relancer », « Échanger mon tour », the comments and the photos. The
// state lives in TaskDetailViewModel.swift; the comments and swaps are read with the task.
extension TaskDetailViewModel {
    // MARK: - Relancer (§1)

    /// Any member, on a task not done that has someone else assigned (`TaskPermissions.canNudge`).
    public var canNudge: Bool {
        guard let task else { return false }
        return TaskPermissions.canNudge(task, userId: session.userId, role: myRole)
    }

    /// Who a nudge reaches: the assignees but the user, by name.
    public var nudgeRecipients: [PersonBadge] {
        assignees.filter { !$0.isMe }
    }

    /// « Relancer Inès », « Relance envoyée » once done.
    public var nudgeButtonTitle: String {
        hasNudged ? NudgeText.doneTitle : NudgeText.buttonTitle(names: nudgeRecipients.map(\.shortName))
    }

    /// Nudges the assignees: `toast` « Relance envoyée à Inès » and the button says « Relance envoyée ». The server
    /// allows one nudge per task a day (`nudgeRateLimited`, then the button says so too).
    @discardableResult
    public func nudge() async -> Bool {
        guard canNudge else {
            present(AppError.forbidden)
            return false
        }
        guard !isNudging, !hasNudged else { return false }
        error = nil
        isNudging = true
        defer { isNudging = false }
        let names = nudgeRecipients.map(\.shortName)
        do {
            let count = try await session.services.tasks.nudge(taskId: taskId)
            hasNudged = true
            toast = ToastNotice(NudgeText.sentMessage(names: names, count: count), systemImage: "bell.badge.fill")
            // The feed of the group has the nudge.
            session.feed.bump(groupId: groupId)
            return true
        } catch {
            switch present(error) {
            case .nudgeRateLimited?:
                hasNudged = true
            case .notFound?:
                markGone()
            case .taskDone?, .nudgeNoRecipient?:
                await reload()
            default:
                break
            }
            return false
        }
    }

    // MARK: - Échanger mon tour (§3)

    /// The pending proposal of this occurrence, if any (at most one).
    public var pendingSwap: TurnSwap? { turnSwaps.last { $0.isPending } }

    /// The proposal the user made, waiting for an answer.
    public var outgoingSwap: TurnSwap? {
        pendingSwap.flatMap { TaskPermissions.canCancel($0, userId: session.userId) ? $0 : nil }
    }

    /// The proposal made to the user, waiting for their answer.
    public var incomingSwap: TurnSwap? {
        pendingSwap.flatMap { TaskPermissions.canRespond(to: $0, userId: session.userId) ? $0 : nil }
    }

    /// Who may take the user's turn (`TaskPermissions.turnSwapCandidates`), in turn order.
    public var swapCandidates: [PersonBadge] {
        guard let task else { return [] }
        let directory = directory
        let shortNames = directory.shortNames
        let memberIds = Set(members.map(\.user.id))
        return TaskPermissions.turnSwapCandidates(task, userId: session.userId, memberIds: memberIds).map { userId in
            directory.badge(of: userId, shortNames: shortNames)
        }
    }

    /// « Proposer mon tour à… »: the user's turn, no proposal pending, someone to propose it to.
    public var canProposeSwap: Bool {
        guard let task, pendingSwap == nil, !isChangingSwap else { return false }
        return TaskPermissions.canRequestTurnSwap(task, userId: session.userId, role: myRole) && !swapCandidates.isEmpty
    }

    /// « En attente de la réponse de Lucas », while the user's proposal waits.
    public var outgoingSwapText: String? {
        outgoingSwap.map { TurnSwapText.waitingText(for: directory.shortName(of: $0.toUserId)) }
    }

    /// The proposal made to the user, ready to display (« Lucas te propose son tour »).
    public var incomingSwapRequest: TurnSwapRequest? {
        guard let swap = incomingSwap else { return nil }
        return TurnSwapRequest(swap: swap, from: directory.badge(of: swap.fromUserId))
    }

    /// Proposes the user's turn to `userId`: `toast` « Proposition envoyée à Lucas ».
    @discardableResult
    public func proposeSwap(to userId: UUID) async -> Bool {
        guard canProposeSwap, swapCandidates.contains(where: { $0.id == userId }) else {
            present(AppError.notYourTurn)
            return false
        }
        error = nil
        isChangingSwap = true
        defer { isChangingSwap = false }
        do {
            let swap = try await session.services.tasks.requestTurnSwap(taskId: taskId, to: userId)
            turnSwaps = TurnSwap.sorted(turnSwaps.filter { $0.id != swap.id } + [swap])
            toast = ToastNotice(TurnSwapText.proposedMessage(to: directory.shortName(of: userId)), systemImage: "arrow.left.arrow.right")
            didChangeSwap()
            return true
        } catch {
            await handleSwapFailure(error)
            return false
        }
    }

    /// Withdraws the user's pending proposal: `toast` « Proposition annulée ».
    @discardableResult
    public func cancelSwap() async -> Bool {
        guard let swap = outgoingSwap, !isChangingSwap else { return false }
        error = nil
        isChangingSwap = true
        defer { isChangingSwap = false }
        do {
            let cancelled = try await session.services.tasks.cancelTurnSwap(swapId: swap.id)
            replaceSwap(cancelled)
            toast = ToastNotice(TurnSwapText.cancelledMessage, systemImage: "arrow.uturn.backward")
            didChangeSwap()
            return true
        } catch {
            await handleSwapFailure(error)
            return false
        }
    }

    /// Accepts or declines the proposal made to the user. Accepted, the turn and the assignment are the user's at once
    /// (`toast` « Tu prends le tour de Lucas »); declined, `toast` « Proposition de Lucas refusée ».
    @discardableResult
    public func respondToSwap(accept: Bool) async -> Bool {
        guard let swap = incomingSwap, !isChangingSwap else { return false }
        error = nil
        isChangingSwap = true
        defer { isChangingSwap = false }
        let name = directory.shortName(of: swap.fromUserId)
        do {
            let answered = try await session.services.tasks.respondToTurnSwap(swapId: swap.id, accept: accept)
            replaceSwap(answered)
            if accept, var current = task {
                current.turnUserId = session.userId
                current.assigneeIds = [session.userId]
                task = current
            }
            toast = accept
                ? ToastNotice(TurnSwapText.acceptedMessage(from: name), systemImage: "arrow.left.arrow.right")
                : ToastNotice(TurnSwapText.declinedMessage(from: name), systemImage: "xmark")
            didChangeSwap()
            return true
        } catch {
            await handleSwapFailure(error)
            return false
        }
    }

    private func replaceSwap(_ swap: TurnSwap) {
        turnSwaps = TurnSwap.sorted(turnSwaps.filter { $0.id != swap.id } + [swap])
    }

    /// The group's screens and « Mes tâches » show the swaps and the turns.
    private func didChangeSwap() {
        session.feed.bump(groupId: groupId)
        session.feed.bumpMyTasks()
    }

    /// Shows why, and reads the task and its swaps again when they changed meanwhile.
    private func handleSwapFailure(_ error: any Error) async {
        guard let appError = present(error) else { return }
        switch appError {
        case .notFound, .notYourTurn, .swapPending, .swapNotPending, .invalidRotation, .forbidden:
            await reload()
        default:
            break
        }
    }

    // MARK: - Commentaires (§5)

    /// Every member may comment.
    public var canComment: Bool { TaskPermissions.canComment(role: myRole) }

    /// The comments, oldest first, ready to display.
    public var commentRows: [CommentRow] {
        let directory = directory
        let shortNames = directory.shortNames
        let people = directory.memberBadges
        let calendar = session.platform.calendar
        let now = referenceDate
        let me = session.userId
        let role = myRole
        return comments.map { comment in
            let author = comment.authorId.map { directory.badge(of: $0, shortNames: shortNames) }
            let authorName: String
            if comment.authorId == me {
                authorName = MemberDirectory.meName
            } else if let author, author.isMember {
                authorName = author.shortName
            } else {
                authorName = MemberDirectory.formerMemberName
            }
            return CommentRow(
                comment: comment,
                author: author,
                authorName: authorName,
                timeText: DateText.relative(comment.createdAt, now: now, calendar: calendar),
                body: MentionText.emphasized(comment.body, people: people),
                isMine: comment.authorId == me,
                canDelete: TaskPermissions.canDelete(comment, userId: me, role: role)
            )
        }
    }

    /// « 2 commentaires ».
    public var commentsCountText: String { CommentText.countText(comments.count) }

    /// The members the composer may mention (`MentionText`).
    public var mentionablePeople: [PersonBadge] { directory.memberBadges }

    /// The members matching the mention being typed at the end of the composer (none when nothing is typed after
    /// « @ »).
    public var mentionSuggestions: [PersonBadge] {
        guard let query = MentionText.query(in: commentDraft) else { return [] }
        return MentionText.suggestions(for: query, people: mentionablePeople)
    }

    /// Completes the mention being typed with `person` (« @Camille »).
    public func insertMention(_ person: PersonBadge) {
        commentDraft = MentionText.completing(commentDraft, with: person)
    }

    /// « Envoyer »: a member, some text, not already sending.
    public var canSendComment: Bool {
        canComment && !isSendingComment && !InputValidation.trimmed(commentDraft).isEmpty
    }

    /// Sends the composer's text with the members it mentions (then clears it). A refused text sets `commentError`.
    @discardableResult
    public func sendComment() async -> Bool {
        guard canComment else {
            present(AppError.forbidden)
            return false
        }
        guard !isSendingComment else { return false }
        error = nil
        let body: String
        do {
            body = try InputValidation.commentBody(commentDraft)
        } catch {
            commentError = AppError.invalidComment.messageFR
            return false
        }
        let mentions = MentionText.mentions(in: body, people: mentionablePeople)
        isSendingComment = true
        defer { isSendingComment = false }
        do {
            let comment = try await session.services.tasks.addComment(taskId: taskId, body: body, mentions: mentions)
            comments = TaskComment.sorted(comments.filter { $0.id != comment.id } + [comment])
            syncCommentCount()
            commentDraftValue = ""
            commentError = nil
            didChangeComments()
            return true
        } catch {
            let appError = present(error)
            switch appError {
            case .invalidComment?, .invalidMentions?:
                // Said under the composer rather than in an alert.
                commentError = appError?.messageFR
                self.error = nil
            case .notFound?:
                await reload()
            default:
                break
            }
            return false
        }
    }

    /// Deletes a comment (its author or an admin). One already deleted elsewhere just disappears.
    @discardableResult
    public func deleteComment(_ commentId: UUID) async -> Bool {
        guard let comment = comments.first(where: { $0.id == commentId }) else { return false }
        guard TaskPermissions.canDelete(comment, userId: session.userId, role: myRole) else {
            present(AppError.forbidden)
            return false
        }
        guard !deletingCommentIds.contains(commentId) else { return false }
        error = nil
        deletingCommentIds.insert(commentId)
        defer { deletingCommentIds.remove(commentId) }
        do {
            try await session.services.tasks.deleteComment(commentId: commentId)
        } catch {
            guard (error as? AppError) == .notFound else {
                present(error)
                return false
            }
        }
        comments.removeAll { $0.id == commentId }
        syncCommentCount()
        didChangeComments()
        return true
    }

    private func syncCommentCount() {
        guard var current = task else { return }
        current.commentCount = comments.count
        task = current
    }

    /// The cards of the lists show the count of comments.
    private func didChangeComments() {
        session.feed.bump(groupId: groupId)
        session.feed.bumpMyTasks()
    }

    // MARK: - Photo preuve (§6)

    /// The task's photos, oldest first.
    public var photos: [TaskPhoto] { task?.photos ?? [] }

    /// « Ajouter une photo »: the rights of « change status », fewer than `Limits.photosPerTaskMax` photos.
    public var canAddPhoto: Bool {
        guard let task else { return false }
        return TaskPermissions.canAddPhoto(task, userId: session.userId, role: myRole)
    }

    /// The photos section shows: some photo, or the right to add one.
    public var showsPhotos: Bool { !photos.isEmpty || canAddPhoto }

    /// Its uploader (still a member) or an admin.
    public func canDelete(_ photo: TaskPhoto) -> Bool {
        TaskPermissions.canDelete(photo, userId: session.userId, role: myRole)
    }

    /// « Photo 1 sur 2, ajoutée par Camille ».
    public func accessibilityLabel(of photo: TaskPhoto) -> String {
        let index = photos.firstIndex { $0.id == photo.id } ?? 0
        let uploader: String? = photo.uploadedBy.map { userId in
            userId == session.userId ? "toi" : directory.shortName(of: userId)
        }
        return PhotoText.accessibilityLabel(index: index, count: photos.count, uploaderName: uploader)
    }

    /// A URL showing the photo (a signed URL, read once and kept while valid); nil when it cannot be read.
    public func photoURL(for photo: TaskPhoto) async -> URL? {
        let now = session.platform.now()
        // A margin of 10 minutes on the URL's lifetime.
        let freshness = TimeInterval(Limits.photoURLLifetime - 600)
        if let url = photoURLs[photo.id], let readAt = photoURLDates[photo.id], now.timeIntervalSince(readAt) < freshness {
            return url
        }
        do {
            let url = try await session.services.tasks.photoURL(photo)
            photoURLs[photo.id] = url
            photoURLDates[photo.id] = now
            return url
        } catch {
            return nil
        }
    }

    /// Uploads a JPEG already resized (`PhotoPixelSize`, `Limits.photoJPEGQuality`): `toast` « Photo ajoutée ».
    @discardableResult
    public func uploadPhoto(jpegData: Data) async -> Bool {
        guard canAddPhoto else {
            present(photos.count >= Limits.photosPerTaskMax ? AppError.photoLimit : AppError.forbidden)
            return false
        }
        guard !isUploadingPhoto else { return false }
        error = nil
        showsPhotoPrompt = false
        do {
            _ = try InputValidation.photo(jpegData)
        } catch {
            present(AppError.invalidPhoto)
            return false
        }
        isUploadingPhoto = true
        defer { isUploadingPhoto = false }
        do {
            let photo = try await session.services.tasks.uploadPhoto(taskId: taskId, jpegData: jpegData)
            if var current = task {
                current.photos = TaskPhoto.sorted(current.photos.filter { $0.id != photo.id } + [photo])
                task = current
            }
            toast = ToastNotice(PhotoText.addedMessage, systemImage: "photo.fill")
            session.feed.bump(groupId: groupId)
            return true
        } catch {
            if present(error) == .notFound {
                await reload()
            }
            return false
        }
    }

    /// Deletes a photo (its uploader or an admin): `toast` « Photo supprimée ». One already deleted just disappears.
    @discardableResult
    public func deletePhoto(_ photo: TaskPhoto) async -> Bool {
        guard canDelete(photo) else {
            present(AppError.forbidden)
            return false
        }
        guard !deletingPhotoIds.contains(photo.id) else { return false }
        error = nil
        deletingPhotoIds.insert(photo.id)
        defer { deletingPhotoIds.remove(photo.id) }
        do {
            try await session.services.tasks.deletePhoto(photo)
        } catch {
            guard (error as? AppError) == .notFound else {
                present(error)
                return false
            }
        }
        if var current = task {
            current.photos.removeAll { $0.id == photo.id }
            task = current
        }
        photoURLs[photo.id] = nil
        photoURLDates[photo.id] = nil
        toast = ToastNotice(PhotoText.deletedMessage, systemImage: "trash")
        session.feed.bump(groupId: groupId)
        return true
    }

    /// « Non merci » of « Ajouter une photo ? ».
    public func dismissPhotoPrompt() {
        showsPhotoPrompt = false
    }
}
