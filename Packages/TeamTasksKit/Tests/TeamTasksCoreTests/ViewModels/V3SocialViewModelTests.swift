import Foundation
import Testing
@testable import TeamTasksCore
import TeamTasksMocks

// v3 screens (docs/CONTRACTS-V3.md) on the showcase, seen by Camille on Thursday 24 September 2026 at 10:00 (Paris):
// « Relancer », « Échanger mon tour », « Bravo », the comments, the photos, « Mode absent », and the local notifications
// of the Realtime social events.

@MainActor
@Suite struct NudgeViewModelTests {
    typealias F = VMFixtures
    typealias T = VMFixtures.Tasks

    @Test func nudgeFromTheTaskScreen() async throws {
        let harness = VMHarness(.showcase)
        let session = harness.makeSession()
        let model = TaskDetailViewModel(session: session, groupId: F.lilas, taskId: T.payerLoyer)
        await model.load()
        #expect(model.canNudge)
        #expect(model.nudgeRecipients.map(\.shortName) == ["Inès"])
        #expect(model.nudgeButtonTitle == "Relancer Inès")

        let revision = session.feed.groupRevision(F.lilas)
        #expect(await model.nudge())
        #expect(model.toast?.message == "Relance envoyée à Inès")
        #expect(model.hasNudged)
        #expect(model.nudgeButtonTitle == "Relance envoyée")
        #expect(session.feed.groupRevision(F.lilas) > revision)
        // Once is enough.
        #expect(await !model.nudge())
        #expect(model.error == nil)

        // A second screen: the server refuses a second nudge the same day, in French.
        let again = TaskDetailViewModel(session: session, groupId: F.lilas, taskId: T.payerLoyer)
        await again.load()
        #expect(await !again.nudge())
        #expect(again.errorMessage == "Tu as déjà relancé cette tâche aujourd’hui.")
        #expect(again.hasNudged)

        // Nobody else to nudge on the user's own turn.
        let mine = TaskDetailViewModel(session: session, groupId: F.lilas, taskId: T.sortirPoubelles)
        await mine.load()
        #expect(!mine.canNudge)

        // The feed says who nudged whom.
        let activity = GroupActivityViewModel(session: session, groupId: F.lilas)
        await activity.load()
        #expect(activity.sections.first?.rows.first?.text.plainText == "Tu as relancé Inès pour «\u{00A0}Payer le loyer\u{00A0}»")
        #expect(activity.sections.first?.rows.first?.systemImage == "bell.badge")
    }

    @Test func nudgeFromTheGroupScreen() async throws {
        let harness = VMHarness(.showcase)
        let model = GroupDetailViewModel(session: harness.makeSession(), groupId: F.lilas)
        await model.load()
        let rent = try #require(model.tasks.first { $0.id == T.payerLoyer })
        let shopping = try #require(model.tasks.first { $0.id == T.faireCourses })
        #expect(model.canNudge(rent))
        #expect(model.nudgeTitle(for: rent) == "Relancer Inès")
        // Not overdue: no « Relancer » on its card.
        #expect(!model.canNudge(shopping))

        #expect(await model.nudge(rent))
        #expect(model.toast?.message == "Relance envoyée à Inès")
        #expect(model.nudgingTaskIds.isEmpty)
        #expect(await !model.nudge(rent))
        #expect(model.errorMessage == "Tu as déjà relancé cette tâche aujourd’hui.")

        harness.faults.fail(.nudge, with: AppError.network)
        let other = GroupDetailViewModel(session: harness.makeSession(user: F.lucas), groupId: F.lilas)
        await other.load()
        #expect(await !other.nudge(rent))
        #expect(other.errorMessage == AppError.network.messageFR)
    }
}

@MainActor
@Suite struct TurnSwapViewModelTests {
    typealias F = VMFixtures
    typealias T = VMFixtures.Tasks
    typealias S = DemoData.Showcase

    @Test func proposeAndCancelMyTurn() async throws {
        let harness = VMHarness(.showcase)
        let session = harness.makeSession()
        let model = TaskDetailViewModel(session: session, groupId: F.lilas, taskId: T.sortirPoubelles)
        await model.load()
        #expect(model.canProposeSwap)
        #expect(model.swapCandidates.map(\.shortName) == ["Inès", "Lucas"])
        #expect(model.pendingSwap == nil)

        let myTasks = session.feed.myTasksRevision
        #expect(await model.proposeSwap(to: F.lucas.id))
        #expect(model.toast?.message == "Proposition envoyée à Lucas")
        #expect(model.outgoingSwap?.toUserId == F.lucas.id)
        #expect(model.outgoingSwapText == "En attente de la réponse de Lucas")
        #expect(model.incomingSwap == nil)
        #expect(!model.canProposeSwap)
        #expect(session.feed.myTasksRevision > myTasks)

        // Lucas sees it on « Mes tâches ».
        let lucas = TurnSwapRequestsViewModel(session: harness.makeSession(user: F.lucas))
        await lucas.load()
        #expect(lucas.requests.map(\.text.plainText) == [
            "Camille te propose son tour pour «\u{00A0}Sortir les poubelles\u{00A0}»",
        ])

        #expect(await model.cancelSwap())
        #expect(model.toast?.message == "Proposition annulée")
        #expect(model.outgoingSwap == nil)
        #expect(model.turnSwaps.last?.status == .cancelled)
        #expect(model.canProposeSwap)
    }

    @Test func acceptTheTurnProposedToMe() async throws {
        let harness = VMHarness(.showcase)
        let session = harness.makeSession()
        let model = TaskDetailViewModel(session: session, groupId: F.sport, taskId: S.materielTaskId)
        await model.load()
        #expect(!model.canProposeSwap)
        let request = try #require(model.incomingSwapRequest)
        #expect(request.text.plainText == "Lucas te propose son tour")
        #expect(model.outgoingSwap == nil)

        #expect(await model.respondToSwap(accept: true))
        #expect(model.toast?.message == "Tu prends le tour de Lucas")
        #expect(model.task?.turnUserId == F.camille.id)
        #expect(model.task?.assigneeIds == [F.camille.id])
        #expect(model.incomingSwap == nil)
        await model.reload()
        #expect(model.rotationText == "C’est ton tour, puis Lucas.")
    }

    @Test func requestsOfMyTasksAndOfAGroup() async throws {
        let harness = VMHarness(.showcase)
        let session = harness.makeSession()
        let model = TurnSwapRequestsViewModel(session: session)
        await model.load()
        #expect(model.loadState == .loaded)
        let request = try #require(model.requests.first)
        #expect(model.requests.count == 1)
        #expect(request.text.plainText == "Lucas te propose son tour pour «\u{00A0}Ranger le matériel\u{00A0}»")
        #expect(request.from.shortName == "Lucas")
        #expect(request.groupName == "Projet Asso Sport")
        #expect(request.dueText == "Samedi à 19:00")
        #expect(request.taskId == S.materielTaskId)

        let lilas = TurnSwapRequestsViewModel(session: session, groupId: F.lilas)
        await lilas.load()
        #expect(lilas.isEmpty)
        let sport = TurnSwapRequestsViewModel(session: session, groupId: F.sport)
        await sport.load()
        #expect(sport.requests.map(\.id) == [S.pendingSwapId])
        #expect(sport.requests.first?.groupName == nil)

        #expect(await model.respond(to: request, accept: false))
        #expect(model.toast?.message == "Proposition de Lucas refusée")
        #expect(model.requests.isEmpty)
        // Answered elsewhere meanwhile: it leaves the list with the reason.
        #expect(await !sport.respond(to: request, accept: true))
        #expect(sport.errorMessage == "Cette proposition n’est plus en attente.")
        #expect(sport.requests.isEmpty)
    }
}

@MainActor
@Suite struct ReactionViewModelTests {
    typealias F = VMFixtures

    @Test func toggleAtOnceThenSaved() async throws {
        let harness = VMHarness(.showcase)
        let model = GroupActivityViewModel(session: harness.makeSession(), groupId: F.lilas)
        await model.load()
        #expect(model.canReact)
        let plants = try #require(model.events.first { $0.kind == .taskCompleted && $0.taskTitle == "Arroser les plantes" })
        func row() -> ActivityFeedRow? {
            model.sections.flatMap(\.rows).first { $0.id == plants.id }
        }
        #expect(row()?.reactions.map(\.text) == ["\u{1F44F} 2", "\u{1F525} 1"])
        #expect(row()?.reactions.map(\.includesMe) == [true, false])
        #expect(row()?.reactions.first?.accessibilityValue == "2 réactions, dont la tienne")

        // Removed at once, then saved.
        harness.faults.hold(.toggleReaction)
        let removal = Task { await model.toggleReaction(.clap, on: plants.id) }
        await VMWait.until("request sent") { harness.faults.waiting(.toggleReaction) == 1 }
        #expect(row()?.reactions.map(\.text) == ["\u{1F44F} 1", "\u{1F525} 1"])
        #expect(!model.hasReacted(.clap, to: plants.id))
        #expect(model.pendingReactions.count == 1)
        // A reload meanwhile keeps it as shown.
        await model.reload()
        #expect(!model.hasReacted(.clap, to: plants.id))
        harness.faults.release(.toggleReaction)
        #expect(await removal.value)
        #expect(model.pendingReactions.isEmpty)
        #expect(row()?.reactions.first?.accessibilityValue == "1 réaction")

        #expect(await model.toggleReaction(.heart, on: plants.id))
        #expect(model.hasReacted(.heart, to: plants.id))

        // Refused: put back as it was.
        harness.faults.fail(.toggleReaction, with: AppError.network)
        #expect(await !model.toggleReaction(.joy, on: plants.id))
        #expect(!model.hasReacted(.joy, to: plants.id))
        #expect(model.errorMessage == AppError.network.messageFR)

        await model.reload()
        #expect(row()?.reactions.map(\.text) == ["\u{1F44F} 1", "\u{1F525} 1", "\u{2764}\u{FE0F} 1"])
    }
}

@MainActor
@Suite struct CommentViewModelTests {
    typealias F = VMFixtures
    typealias T = VMFixtures.Tasks

    @Test func readMentionSendAndDelete() async throws {
        let harness = VMHarness(.showcase)
        let session = harness.makeSession()
        let model = TaskDetailViewModel(session: session, groupId: F.lilas, taskId: T.faireCourses)
        await model.load()
        #expect(model.canComment)
        #expect(model.task?.commentCount == 2)
        #expect(model.commentsCountText == "2 commentaires")
        let rows = model.commentRows
        #expect(rows.map(\.authorName) == ["Lucas", "Inès"])
        #expect(rows.map(\.timeText) == ["Aujourd’hui à 04:00", "Aujourd’hui à 07:00"])
        #expect(rows.first?.body.emphasized == ["@Camille"])
        #expect(rows.first?.body.plainText == "@Camille tu peux prendre du lait d’avoine\u{00A0}?")
        // Camille is an admin of the group.
        #expect(rows.map(\.canDelete) == [true, true])
        #expect(rows.map(\.isMine) == [false, false])

        #expect(model.mentionSuggestions.isEmpty)
        model.commentDraft = "Merci @lu"
        #expect(model.mentionSuggestions.map(\.shortName) == ["Lucas"])
        model.insertMention(try #require(model.mentionSuggestions.first))
        #expect(model.commentDraft == "Merci @Lucas ")
        #expect(model.mentionSuggestions.isEmpty)
        model.commentDraft += "je prends le lait"
        #expect(model.canSendComment)

        let revision = session.feed.myTasksRevision
        #expect(await model.sendComment())
        #expect(model.commentDraft.isEmpty)
        #expect(model.comments.count == 3)
        #expect(model.comments.last?.mentions == [F.lucas.id])
        #expect(model.comments.last?.body == "Merci @Lucas je prends le lait")
        #expect(model.task?.commentCount == 3)
        #expect(model.commentRows.last?.authorName == "Toi")
        #expect(model.commentRows.last?.isMine == true)
        #expect(session.feed.myTasksRevision > revision)

        model.commentDraft = "   "
        #expect(!model.canSendComment)
        #expect(await !model.sendComment())
        #expect(model.commentError == "Un commentaire doit contenir entre 1 et 1000 caractères.")
        model.commentDraft = "Ok"
        #expect(model.commentError == nil)

        let first = try #require(model.comments.first)
        #expect(await model.deleteComment(first.id))
        #expect(model.comments.count == 2)
        #expect(model.task?.commentCount == 2)
    }

    /// A member who is not an admin deletes only their own comments.
    @Test func membersDeleteTheirOwn() async throws {
        let harness = VMHarness(.showcase)
        let model = TaskDetailViewModel(session: harness.makeSession(user: F.lucas), groupId: F.lilas, taskId: T.faireCourses)
        await model.load()
        #expect(model.commentRows.map(\.canDelete) == [true, false])
        #expect(model.commentRows.map(\.authorName) == ["Toi", "Inès"])
        let ines = try #require(model.comments.last)
        #expect(await !model.deleteComment(ines.id))
        #expect(model.errorMessage == AppError.forbidden.messageFR)
    }

    @Test func aFailedReadKeepsTheScreen() async throws {
        let harness = VMHarness(.showcase)
        harness.faults.fail(.comments, with: AppError.network)
        harness.faults.fail(.turnSwaps, with: AppError.network)
        let model = TaskDetailViewModel(session: harness.makeSession(), groupId: F.lilas, taskId: T.faireCourses)
        await model.load()
        #expect(model.loadState == .loaded)
        #expect(model.task != nil)
        #expect(model.comments.isEmpty)
        await model.reload()
        #expect(model.comments.count == 2)
    }
}

@MainActor
@Suite struct PhotoViewModelTests {
    typealias F = VMFixtures
    typealias T = VMFixtures.Tasks
    typealias S = DemoData.Showcase

    @Test func showUploadAndDelete() async throws {
        let harness = VMHarness(.showcase)
        let model = TaskDetailViewModel(session: harness.makeSession(), groupId: F.lilas, taskId: S.photoTaskId)
        await model.load()
        let photo = try #require(model.photos.first)
        #expect(model.photos.count == 1)
        #expect(model.showsPhotos)
        #expect(model.canAddPhoto)
        #expect(model.canDelete(photo))
        #expect(model.accessibilityLabel(of: photo) == "Photo 1 sur 1, ajoutée par toi")

        let url = try #require(await model.photoURL(for: photo))
        #expect(url.scheme == "data")
        #expect(await model.photoURL(for: photo) == url)
        #expect(harness.faults.calls(.photoURL) == 1)

        #expect(await model.uploadPhoto(jpegData: S.photoJPEG))
        #expect(model.photos.count == 2)
        #expect(model.toast?.message == "Photo ajoutée")
        #expect(await !model.uploadPhoto(jpegData: Data([1, 2, 3])))
        #expect(model.errorMessage == "Photo invalide.")

        let added = try #require(model.photos.last)
        #expect(await model.deletePhoto(added))
        #expect(model.photos.map(\.id) == [photo.id])
        #expect(model.toast?.message == "Photo supprimée")
    }

    /// « Ajouter une photo ? » once the user completed a task they may add a photo to.
    @Test func promptAfterCompletion() async throws {
        let harness = VMHarness(.showcase)
        let model = TaskDetailViewModel(session: harness.makeSession(), groupId: F.lilas, taskId: T.faireCourses)
        await model.load()
        #expect(!model.showsPhotoPrompt)
        #expect(await model.setStatus(.done))
        #expect(model.showsPhotoPrompt)
        model.dismissPhotoPrompt()
        #expect(!model.showsPhotoPrompt)
        #expect(await model.setStatus(.todo))
        #expect(!model.showsPhotoPrompt)
    }

    @Test func pixelSizes() {
        #expect(PhotoPixelSize.resized(width: 4032, height: 3024) == PhotoPixelSize(width: 1600, height: 1200))
        #expect(PhotoPixelSize.resized(width: 3024, height: 4032) == PhotoPixelSize(width: 1200, height: 1600))
        #expect(PhotoPixelSize.resized(width: 800, height: 600) == PhotoPixelSize(width: 800, height: 600))
        #expect(PhotoPixelSize.resized(width: 10_000, height: 1) == PhotoPixelSize(width: 1600, height: 1))
    }
}

@MainActor
@Suite struct AwayModeViewModelTests {
    typealias F = VMFixtures
    typealias T = VMFixtures.Tasks
    typealias D = LocalDate

    @Test func previewActivateAndEnd() async throws {
        let harness = VMHarness(.showcase)
        let session = harness.makeSession()
        let model = AwayModeViewModel(session: session)
        await model.load()
        #expect(model.loadState == .loaded)
        #expect(!model.isAway)
        #expect(model.saveTitle == "Activer le mode absent")
        #expect(model.fromDay == D(year: 2026, month: 9, day: 24))
        #expect(model.untilDay == D(year: 2026, month: 9, day: 30))
        #expect(model.rangeText == "du 24 au 30 septembre")
        #expect(model.rangeError == nil)
        // « Sortir les poubelles » is due tonight: Lucas comes after Camille.
        #expect(model.handovers.map(\.title) == ["Sortir les poubelles"])
        #expect(model.handovers.map(\.text) == ["jeu. 24 sept. \u{2192} Lucas le fera"])

        // Next week only: that turn is not in the dates.
        model.fromDate = try #require(D(year: 2026, month: 9, day: 28).startDate(in: F.calendar))
        #expect(model.untilDay == D(year: 2026, month: 9, day: 30))
        #expect(model.handovers.isEmpty)
        // « Du » after « Au » moves « Au ».
        model.fromDate = try #require(D(year: 2026, month: 10, day: 2).startDate(in: F.calendar))
        #expect(model.untilDay == D(year: 2026, month: 10, day: 2))
        // « Au » before « Du » moves « Du ».
        model.untilDate = try #require(D(year: 2026, month: 9, day: 26).startDate(in: F.calendar))
        #expect(model.fromDay == D(year: 2026, month: 9, day: 26))
        model.fromDate = try #require(D(year: 2026, month: 9, day: 24).startDate(in: F.calendar))
        model.untilDate = try #require(D(year: 2026, month: 9, day: 30).startDate(in: F.calendar))

        #expect(await model.activate())
        #expect(model.resultMessage == "Mode absent activé du 24 au 30 septembre")
        #expect(model.isAway)
        #expect(model.currentAwayText == "Absent\u{00B7}e jusqu’au 30 sept.")
        #expect(model.saveTitle == "Modifier mon absence")

        // The turn went to Lucas; Inès, next, is away next week.
        let group = GroupDetailViewModel(session: session, groupId: F.lilas)
        await group.load()
        let card = try #require(group.turnCards.first { $0.task.id == T.sortirPoubelles })
        #expect(card.current?.shortName == "Lucas")
        #expect(card.currentAwayText == nil)
        #expect(card.next?.shortName == "Inès")
        #expect(card.nextAwayText == "Absent\u{00B7}e du 28 sept. au 4 oct.")

        let members = MembersViewModel(session: session, groupId: F.lilas)
        await members.load()
        #expect(members.myAwayText == "Absent\u{00B7}e jusqu’au 30 sept.")
        let ines = try #require(members.members.first { $0.user.id == F.ines.id })
        #expect(members.awayText(of: ines) == "Absent\u{00B7}e du 28 sept. au 4 oct.")

        let activity = GroupActivityViewModel(session: session, groupId: F.lilas)
        await activity.load()
        #expect(activity.sections.first?.rows.map(\.text.plainText).contains("Tu as annoncé une absence du 24 au 30 septembre") == true)

        // Read again, the sheet shows the absence.
        let again = AwayModeViewModel(session: session)
        await again.load()
        #expect(again.isAway)
        #expect(again.untilDay == D(year: 2026, month: 9, day: 30))

        #expect(await again.endAbsence())
        #expect(again.resultMessage == "Mode absent terminé")
        #expect(!again.isAway)
        #expect(again.profile?.awayFrom == nil)
    }

    @Test func refusedDates() async throws {
        let harness = VMHarness(.showcase)
        let model = AwayModeViewModel(session: harness.makeSession())
        await model.load()
        model.untilDate = try #require(D(year: 2026, month: 9, day: 20).startDate(in: F.calendar))
        #expect(model.fromDay == D(year: 2026, month: 9, day: 20))
        #expect(model.rangeError == "Dates d’absence invalides.")
        #expect(await !model.activate())
        #expect(model.errorMessage == "Dates d’absence invalides.")
        #expect(harness.faults.calls(.setAway) == 0)
    }

    /// Like the server: the next member who is not away that day; the next one when everyone else is away; nobody when
    /// the rotation lists nobody else.
    @Test func whoTakesTheTurn() {
        let me = F.camille.id
        let day = D(year: 2026, month: 10, day: 1)
        func member(_ user: DemoUser, away: Bool) -> Membership {
            Membership(
                groupId: F.lilas,
                user: UserProfile(
                    id: user.id, displayName: user.displayName,
                    awayFrom: away ? day : nil, awayUntil: away ? day : nil
                ),
                role: .member, joinedAt: F.now
            )
        }
        let task = TaskItem(
            id: UUID(), groupId: F.lilas, title: "T", createdBy: me, createdAt: F.now, updatedAt: F.now,
            rotation: [F.ines.id, me, F.lucas.id], turnUserId: me
        )
        let everyone = [member(F.camille, away: false), member(F.ines, away: false), member(F.lucas, away: false)]
        #expect(AwayModeViewModel.taker(of: task, userId: me, members: everyone, day: day) == F.lucas.id)
        let lucasAway = [member(F.camille, away: false), member(F.ines, away: false), member(F.lucas, away: true)]
        #expect(AwayModeViewModel.taker(of: task, userId: me, members: lucasAway, day: day) == F.ines.id)
        let allAway = [member(F.camille, away: false), member(F.ines, away: true), member(F.lucas, away: true)]
        #expect(AwayModeViewModel.taker(of: task, userId: me, members: allAway, day: day) == F.lucas.id)
        var alone = task
        alone.rotation = [me]
        #expect(AwayModeViewModel.taker(of: alone, userId: me, members: everyone, day: day) == nil)
    }
}

@MainActor
@Suite struct SocialNotificationWiringTests {
    typealias F = VMFixtures
    typealias T = VMFixtures.Tasks
    typealias S = DemoData.Showcase

    /// A started session of Camille on the showcase, subscribed to Realtime.
    private func startedSession(_ harness: VMHarness) async throws -> (AppModel, SessionModel) {
        let app = harness.makeApp()
        app.start()
        await VMWait.until("signed in") { app.session != nil }
        let session = try #require(app.session)
        await session.startupTask?.value
        await VMWait.until("realtime subscribed") { harness.backend.realtimeSubscriberCount == 1 }
        await VMWait.until("connected") { session.feed.allRevision >= 1 }
        return (app, session)
    }

    private func delivered(_ harness: VMHarness, prefix: String) async -> LocalNotification? {
        await VMWait.until("\(prefix) notification") { harness.scheduler.delivered.contains { $0.id.hasPrefix(prefix) } }
        return harness.scheduler.delivered.first { $0.id.hasPrefix(prefix) }
    }

    @Test func realtimeEventsPostNotifications() async throws {
        let harness = VMHarness(.showcase)
        let (app, session) = try await startedSession(harness)
        let lucas = harness.device(F.lucas)
        let ines = harness.device(F.ines)

        // A nudge.
        _ = try await lucas.tasks.nudge(taskId: T.faireCourses)
        let nudge = try #require(await delivered(harness, prefix: "nudge-"))
        #expect(nudge.title == "Lucas te relance")
        #expect(nudge.body == "«\u{00A0}Faire les courses\u{00A0}»")
        #expect(nudge.userInfo == ["taskId": T.faireCourses.uuidString, "groupId": F.lilas.uuidString])
        #expect(nudge.threadId == F.lilas.uuidString)

        // A turn proposed to Camille.
        _ = try await lucas.tasks.cancelTurnSwap(swapId: S.pendingSwapId)
        let swap = try await lucas.tasks.requestTurnSwap(taskId: S.materielTaskId, to: F.camille.id)
        let proposed = try #require(await delivered(harness, prefix: "swap-"))
        #expect(proposed.id == SocialNotificationText.swapIdentifier(swap.id))
        #expect(proposed.title == "Échange de tour")
        #expect(proposed.body == "Lucas te propose son tour pour «\u{00A0}Ranger le matériel\u{00A0}»")

        // A reaction to Camille's completion.
        let events = try await ines.groups.activity(groupId: F.lilas)
        let fridge = try #require(events.first { $0.kind == .taskCompleted && $0.taskTitle == "Nettoyer le frigo" })
        _ = try await ines.groups.toggleReaction(activityId: fridge.id, emoji: .joy)
        let reaction = try #require(await delivered(harness, prefix: "reaction-"))
        #expect(reaction.id == "reaction-\(fridge.id)")
        #expect(reaction.body == "Inès a réagi \u{1F602} à «\u{00A0}Nettoyer le frigo\u{00A0}»")
        #expect(reaction.userInfo["taskId"] == S.photoTaskId.uuidString)

        // A comment that mentions Camille.
        let comment = try await lucas.tasks.addComment(
            taskId: T.faireCourses, body: "@Camille on prend du lait\u{00A0}?", mentions: [F.camille.id]
        )
        let mention = try #require(await delivered(harness, prefix: "comment-"))
        #expect(mention.id == SocialNotificationText.commentIdentifier(comment.id))
        #expect(mention.title == "Lucas te mentionne dans «\u{00A0}Faire les courses\u{00A0}»")
        #expect(mention.body == "@Camille on prend du lait\u{00A0}?")

        // Her own comment: nothing.
        let count = harness.scheduler.delivered.count
        _ = try await harness.device(F.camille).tasks.addComment(taskId: T.faireCourses, body: "Oui", mentions: [])
        await VMWait.settle()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(harness.scheduler.delivered.count == count)
        _ = session
        await app.shutdown()
    }

    @Test func rulesOfTheNotifier() async throws {
        let harness = VMHarness(.showcase)
        let camille = harness.device(F.camille)
        let notifier = SocialNotifier(
            userId: F.camille.id, groups: camille.groups, tasks: camille.tasks, scheduler: harness.scheduler
        )
        let swapId = UUID()
        let repaid = RealtimeEvent.turnSwapUpdated(
            swapId: swapId, taskId: S.materielTaskId, groupId: F.sport, toUserId: F.lucas.id, status: .accepted, isRepaid: true
        )
        #expect(await notifier.handle(repaid) == nil)
        let declined = RealtimeEvent.turnSwapUpdated(
            swapId: swapId, taskId: S.materielTaskId, groupId: F.sport, toUserId: F.lucas.id, status: .declined, isRepaid: false
        )
        let answer = try #require(await notifier.handle(declined))
        #expect(answer.title == "Échange refusé")
        // Delivered at once: the quiet hours of the device silence it (docs/CONTRACTS-V3.md §9).
        #expect(answer.fireDate == nil)
        #expect(answer.body == "Lucas ne peut pas prendre ton tour pour «\u{00A0}Ranger le matériel\u{00A0}»")
        // The user's own reaction, a comment neither mentioning nor concerning them, a v1 event: nothing.
        #expect(await notifier.handle(.reactionAdded(activityId: 1, groupId: F.lilas, userId: F.camille.id, emoji: .clap)) == nil)
        #expect(await notifier.handle(.commentAdded(
            commentId: UUID(), taskId: T.payerLoyer, groupId: F.lilas, authorId: F.lucas.id, mentions: []
        )) == nil)
        #expect(await notifier.handle(.groupActivity(groupId: F.lilas)) == nil)
        // An assignee is told about a comment on their task.
        let assigned = try #require(await notifier.handle(.commentAdded(
            commentId: UUID(), taskId: T.faireCourses, groupId: F.lilas, authorId: F.lucas.id, mentions: []
        )))
        #expect(assigned.title == "Lucas a commenté «\u{00A0}Faire les courses\u{00A0}»")

        // Not authorized: nothing is posted.
        harness.scheduler.authorization = .denied
        #expect(await notifier.handle(declined) == nil)
        #expect(harness.scheduler.delivered.count == 2)
    }
}

@MainActor
@Suite struct SocialPresentationTests {
    static let camille = PersonBadge(
        id: DemoData.camille.id, name: "Camille Martin", shortName: "Camille",
        appearance: AvatarAppearance(color: .indigo, emoji: nil, initials: "CM"), isMe: true, isMember: true
    )
    static let lucas = PersonBadge(
        id: DemoData.lucas.id, name: "Lucas Bernard", shortName: "Lucas",
        appearance: AvatarAppearance(color: .teal, emoji: nil, initials: "LB"), isMe: false, isMember: true
    )
    static let ines = PersonBadge(
        id: DemoData.ines.id, name: "Inès Dubois", shortName: "Inès",
        appearance: AvatarAppearance(color: .orange, emoji: nil, initials: "ID"), isMe: false, isMember: true
    )
    static let people = [camille, lucas, ines]

    @Test func nudgeWording() {
        #expect(NudgeText.buttonTitle(names: ["Inès"]) == "Relancer Inès")
        #expect(NudgeText.buttonTitle(names: ["Inès", "Lucas"]) == "Relancer Inès et Lucas")
        #expect(NudgeText.buttonTitle(names: ["A", "B", "C"]) == "Relancer 3 personnes")
        #expect(NudgeText.sentMessage(names: ["Inès"], count: 1) == "Relance envoyée à Inès")
        #expect(NudgeText.sentMessage(names: ["Inès"], count: 2) == "Relance envoyée à 2 personnes")
    }

    @Test func swapWording() {
        #expect(TurnSwapText.waitingText(for: "Inès") == "En attente de la réponse d’Inès")
        #expect(TurnSwapText.acceptedMessage(from: "Lucas") == "Tu prends le tour de Lucas")
        #expect(TurnSwapText.declinedMessage(from: "Inès") == "Proposition d’Inès refusée")
        #expect(TurnSwapText.request(from: "Lucas", taskTitle: "T").emphasized == ["Lucas"])
    }

    @Test func mentions() {
        #expect(MentionText.query(in: "Salut @") == "")
        #expect(MentionText.query(in: "Salut @In") == "In")
        #expect(MentionText.query(in: "Salut @Inès ") == nil)
        #expect(MentionText.query(in: "mail@exemple") == nil)
        #expect(MentionText.query(in: "Rien") == nil)
        #expect(MentionText.suggestions(for: "", people: Self.people).map(\.shortName) == ["Lucas", "Inès"])
        #expect(MentionText.suggestions(for: "ine", people: Self.people).map(\.shortName) == ["Inès"])
        #expect(MentionText.suggestions(for: "cam", people: Self.people).isEmpty)
        #expect(MentionText.completing("Merci @in", with: Self.ines) == "Merci @Inès ")
        #expect(MentionText.completing("Merci", with: Self.ines) == "Merci @Inès ")

        let body = "@inès et @Lucas, puis @Lucas2 et mail@Lucas; @Camille!"
        #expect(MentionText.mentions(in: body, people: Self.people) == [Self.ines.id, Self.lucas.id, Self.camille.id])
        let text = MentionText.emphasized(body, people: Self.people)
        #expect(text.emphasized == ["@inès", "@Lucas", "@Camille"])
        #expect(text.plainText == body)
        #expect(MentionText.emphasized("Rien", people: Self.people).runs == [.init("Rien")])
    }

    @Test func awayWording() {
        #expect(AwayText.shortWeekdayDay(LocalDate(year: 2026, month: 10, day: 9), referenceYear: 2026) == "ven. 9 oct.")
        #expect(AwayText.shortWeekdayDay(LocalDate(year: 2027, month: 1, day: 4), referenceYear: 2026) == "lun. 4 janv. 2027")
    }

    @Test func photoAndCommentWording() {
        #expect(PhotoText.countText(1) == "1 photo")
        #expect(PhotoText.countText(4) == "4 sur 5")
        #expect(CommentText.countText(1) == "1 commentaire")
        #expect(CommentText.countText(3) == "3 commentaires")
    }

    /// The v3 strings follow the French typography of the app.
    @Test func typography() {
        let shown: [String] = [
            NudgeText.doneTitle, NudgeText.hint, NudgeText.sentMessage(names: ["Inès"], count: 1),
            TurnSwapText.proposeTitle, TurnSwapText.cancelTitle, TurnSwapText.cancelledMessage,
            TurnSwapText.waitingText(for: "Inès"), TurnSwapText.request(from: "Lucas", taskTitle: "T").plainText,
            TurnSwapText.acceptedMessage(from: "Inès"), TurnSwapText.declinedMessage(from: "Lucas"),
            PhotoText.promptTitle, PhotoText.promptMessage, PhotoText.emptyText, PhotoText.addTitle,
            CommentText.placeholder, CommentText.emptyText,
            AwayModeViewModel.message, AwayModeViewModel.announceMessage, AwayModeViewModel.handoversTitle,
            AwayModeViewModel.noHandoverText, AwayModeViewModel.activateTitle, AwayModeViewModel.endTitle,
        ]
        for text in shown {
            #expect(!text.contains("'"), "\(text)")
            #expect(WordingTests.typographyProblems(in: text).isEmpty, "\(text)")
        }
    }
}
