import Foundation
import Testing
@testable import TeamTasksCore

// docs/CONTRACTS-V3.md: models, errors, validation, permissions, wording and stats of the v3 core.

@Suite struct LocalDateTests {
    @Test func isoStringsRoundTrip() throws {
        let date = try #require(LocalDate(isoString: "2026-10-12"))
        #expect(date == LocalDate(year: 2026, month: 10, day: 12))
        #expect(date.isoString == "2026-10-12")
        #expect(LocalDate(year: 987, month: 1, day: 2).isoString == "0987-01-02")
        #expect(LocalDate(isoString: "2026-02-30") == nil)
        #expect(LocalDate(isoString: "2026-2-3") == nil)
        #expect(LocalDate(isoString: "2026-10-12T00:00:00Z") == nil)
        #expect(LocalDate(isoString: "2028-02-29") != nil)
        let encoded = try JSONEncoder().encode([date])
        #expect(String(decoding: encoded, as: UTF8.self) == #"["2026-10-12"]"#)
        #expect(try JSONDecoder().decode([LocalDate].self, from: encoded) == [date])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([LocalDate].self, from: Data(#"["12/10/2026"]"#.utf8)) }
    }

    @Test func arithmeticAndOrder() throws {
        let date = LocalDate(year: 2026, month: 12, day: 31)
        #expect(date.adding(days: 1) == LocalDate(year: 2027, month: 1, day: 1))
        #expect(date.adding(days: -365) == LocalDate(year: 2025, month: 12, day: 31))
        #expect(LocalDate(year: 2028, month: 2, day: 28).adding(days: 1) == LocalDate(year: 2028, month: 2, day: 29))
        #expect(LocalDate(year: 2041, month: 1, day: 1).days(to: LocalDate(year: 2042, month: 1, day: 2)) == 366)
        #expect(LocalDate(year: 2026, month: 9, day: 28).isoWeekday == 1)
        #expect(LocalDate(year: 2026, month: 10, day: 4).isoWeekday == 7)
        #expect(LocalDate(year: 2026, month: 9, day: 30) < LocalDate(year: 2026, month: 10, day: 1))
        #expect(LocalDate(dayNumber: 0) == LocalDate(year: 1970, month: 1, day: 1))
    }

    /// The local date of an instant, like SQL `(instant at time zone tz)::date`.
    @Test func localDateOfAnInstant() throws {
        let instant = try #require(ISO8601DateFormatter().date(from: "2041-03-10T22:30:00Z"))
        #expect(LocalDate(instant, timeZone: TimeZone(identifier: "Europe/Paris")!) == LocalDate(year: 2041, month: 3, day: 10))
        #expect(LocalDate(instant, timeZone: TimeZone(identifier: "Asia/Tokyo")!) == LocalDate(year: 2041, month: 3, day: 11))
        #expect(LocalDate(instant, timeZone: TimeZone(secondsFromGMT: 0)!) == LocalDate(year: 2041, month: 3, day: 10))
        let midnight = try #require(ISO8601DateFormatter().date(from: "2026-10-24T22:00:00Z"))
        #expect(LocalDate(midnight, calendar: LogicFixtures.parisCalendar) == LocalDate(year: 2026, month: 10, day: 25))
        #expect(LocalDate(year: 2026, month: 10, day: 25).startDate(in: LogicFixtures.parisCalendar) == midnight)
    }
}

@Suite struct V3ModelTests {
    typealias F = LogicFixtures

    /// The v2 initializers still compile and leave every v3 field empty.
    @Test func v2InitializersHaveEmptyV3Fields() {
        let date = F.date(2026, 9, 24)
        let profile = UserProfile(id: F.me, displayName: "Camille")
        #expect(profile.awayFrom == nil && profile.awayUntil == nil && profile.awayRange == nil)
        let task = TaskItem(id: F.uuid(1), groupId: F.groupA, title: "T", createdBy: F.me, createdAt: date, updatedAt: date)
        #expect(task.commentCount == 0 && task.photos.isEmpty)
        let event = ActivityEvent(id: 1, kind: .taskCreated, createdAt: date)
        #expect(event.reactions.isEmpty && event.startsOn == nil && event.endsOn == nil)
        #expect(TaskCompletion(taskId: F.uuid(1), completedBy: nil, completedAt: date).groupId == nil)
    }

    @Test func activityKinds() {
        #expect(ActivityKind.allCases.map(\.rawValue) == [
            "task_created", "task_completed", "turn_started", "checklist_item_done", "member_joined", "member_left",
            "task_nudged", "member_away", "turn_swapped", "comment_added", "photo_added",
        ])
        #expect(ActivityKind.allCases.filter(\.isV3) == [.taskNudged, .memberAway, .turnSwapped, .commentAdded, .photoAdded])
        for kind in ActivityEvent.Kind.allCases {
            #expect(kind.activityKind.rawValue == kind.rawValue)
            #expect(ActivityEvent.Kind(kind.activityKind) == kind)
        }
        #expect(ActivityEvent.Kind(ActivityKind.memberAway) == nil)
        #expect(ActivityKind(rawValue: "task_renamed") == nil)
        #expect(Set(ActivityKind.allCases.map(\.systemImage)).count == ActivityKind.allCases.count)
    }

    @Test func awayRange() {
        let from = LocalDate(year: 2026, month: 10, day: 5)
        let until = LocalDate(year: 2026, month: 10, day: 11)
        let profile = UserProfile(id: F.me, displayName: "Inès", awayFrom: from, awayUntil: until)
        #expect(profile.awayRange == from...until)
        #expect(profile.isAway(on: from) && profile.isAway(on: until))
        #expect(!profile.isAway(on: from.adding(days: -1)) && !profile.isAway(on: until.adding(days: 1)))
        #expect(UserProfile(id: F.me, displayName: "X", awayFrom: until, awayUntil: from).awayRange == nil)
        #expect(UserProfile(id: F.me, displayName: "X", awayFrom: from).awayRange == nil)
    }

    @Test func reactionsAreSortedAndSummarized() {
        let reactions = [
            ActivityReaction(userId: F.uuid(3), emoji: .joy), ActivityReaction(userId: F.uuid(2), emoji: .clap),
            ActivityReaction(userId: F.me, emoji: .clap), ActivityReaction(userId: F.uuid(2), emoji: .heart),
        ]
        #expect(ActivityReaction.sorted(reactions).map(\.emoji) == [.clap, .clap, .heart, .joy])
        let event = ActivityEvent(id: 1, kind: .taskCompleted, createdAt: F.date(2026, 9, 24), reactions: reactions)
        let summaries = event.reactionSummaries(currentUserId: F.me)
        #expect(summaries.map(\.emoji) == [.clap, .heart, .joy])
        #expect(summaries.map(\.count) == [2, 1, 1])
        #expect(summaries.map(\.includesMe) == [true, false, false])
        #expect(summaries.first?.text == "\u{1F44F} 2")
        #expect(ReactionEmoji.allCases.map(\.rawValue) == ["👏", "🔥", "💪", "❤️", "😂"])
        #expect(ReactionEmoji.heart.rawValue.unicodeScalars.map(\.value) == [0x2764, 0xFE0F])
    }

    @Test func photoPaths() {
        let group = UUID(uuidString: "A0000000-0000-4000-8000-000000000001")!
        let task = UUID(uuidString: "B0000000-0000-4000-8000-000000000005")!
        let object = UUID(uuidString: "F2000000-0000-4000-8000-000000000001")!
        #expect(TaskPhoto.folder(groupId: group, taskId: task) == "a0000000-0000-4000-8000-000000000001/b0000000-0000-4000-8000-000000000005/")
        #expect(TaskPhoto.newPath(groupId: group, taskId: task, objectId: object)
            == "a0000000-0000-4000-8000-000000000001/b0000000-0000-4000-8000-000000000005/f2000000-0000-4000-8000-000000000001.jpg")
        #expect(InputValidation.isPhotoPath(TaskPhoto.newPath(groupId: group, taskId: task), groupId: group, taskId: task))
        #expect(!InputValidation.isPhotoPath(TaskPhoto.folder(groupId: group, taskId: task), groupId: group, taskId: task))
        #expect(!InputValidation.isPhotoPath(TaskPhoto.newPath(groupId: task, taskId: group), groupId: group, taskId: task))
        let folder = TaskPhoto.folder(groupId: group, taskId: task)
        for name in ["f2000000-0000-4000-8000-000000000001.jpeg", "f2000000-0000-4000-8000-000000000001.png",
                     "f2000000-0000-4000-8000-000000000001.heic"] {
            #expect(InputValidation.isPhotoPath(folder + name, groupId: group, taskId: task), "\(name)")
        }
        for name in ["F2000000-0000-4000-8000-000000000001.jpg", "f2000000-0000-4000-8000-000000000001.JPG",
                     "f2000000-0000-4000-8000-000000000001.gif", "photo.jpg", "x/f2000000-0000-4000-8000-000000000001.jpg"] {
            #expect(!InputValidation.isPhotoPath(folder + name, groupId: group, taskId: task), "\(name)")
        }
        #expect(TaskPhoto.bucket == "task-photos")
    }

    @Test func sortedSwapsCommentsAndPhotos() {
        let early = F.date(2026, 9, 24, 8)
        let late = F.date(2026, 9, 24, 9)
        let swap = { (id: Int, at: Date) in
            TurnSwap(id: F.uuid(id), taskId: F.uuid(9), groupId: F.groupA, seriesId: F.uuid(9), fromUserId: F.me,
                     toUserId: F.other, status: .pending, createdAt: at)
        }
        #expect(TurnSwap.sorted([swap(2, late), swap(3, early), swap(1, early)]).map(\.id) == [F.uuid(1), F.uuid(3), F.uuid(2)])
        let comment = { (id: Int, at: Date) in
            TaskComment(id: F.uuid(id), taskId: F.uuid(9), groupId: F.groupA, authorId: F.me, body: "x", createdAt: at)
        }
        #expect(TaskComment.sorted([comment(2, late), comment(1, early)]).map(\.id) == [F.uuid(1), F.uuid(2)])
        #expect(TurnSwap.Status.allCases.map(\.rawValue) == ["pending", "accepted", "declined", "cancelled"])
    }

    @Test func realtimeEventGroups() {
        #expect(RealtimeEvent.connected.socialGroupId == nil)
        #expect(RealtimeEvent.groupActivity(groupId: F.groupA).socialGroupId == nil)
        #expect(RealtimeEvent.nudged(nudgeId: F.uuid(1), taskId: F.uuid(2), groupId: F.groupA, fromUserId: F.me).socialGroupId == F.groupA)
        #expect(RealtimeEvent.reactionAdded(activityId: 4, groupId: F.groupB, userId: F.me, emoji: .fire).socialGroupId == F.groupB)
        #expect(RealtimeEvent.commentAdded(commentId: F.uuid(1), taskId: F.uuid(2), groupId: F.groupA, authorId: nil, mentions: [])
            .socialGroupId == F.groupA)
    }
}

@Suite struct V3ErrorTests {
    static let codes: [(String, AppError, String)] = [
        ("task_done", .taskDone, "Cette tâche est déjà terminée."),
        ("nudge_no_recipient", .nudgeNoRecipient, "Personne d’autre n’est assigné à cette tâche."),
        ("nudge_rate_limited", .nudgeRateLimited, "Tu as déjà relancé cette tâche aujourd’hui."),
        ("invalid_away", .invalidAway, "Dates d’absence invalides."),
        ("not_your_turn", .notYourTurn, "Ce n’est pas ton tour."),
        ("swap_pending", .swapPending, "Une proposition est déjà en attente pour cette tâche."),
        ("swap_not_pending", .swapNotPending, "Cette proposition n’est plus en attente."),
        ("invalid_reaction", .invalidReaction, "Réaction invalide."),
        ("invalid_comment", .invalidComment, "Un commentaire doit contenir entre 1 et 1000 caractères."),
        ("invalid_mentions", .invalidMentions, "Une personne mentionnée ne fait pas partie du groupe."),
        ("invalid_photo", .invalidPhoto, "Photo invalide."),
        ("photo_limit", .photoLimit, "5 photos au maximum par tâche."),
    ]

    @Test(arguments: V3ErrorTests.codes)
    func messageCodesMapToTheirCase(_ code: String, _ error: AppError, _ message: String) {
        #expect(BackendErrorMapper.map(code: "P0001", message: code, httpStatus: 400) == error)
        #expect(error.messageFR == message)
    }

    @Test func notFoundCodes() {
        for code in ["swap_not_found", "activity_not_found", "comment_not_found", "photo_not_found"] {
            #expect(BackendErrorMapper.map(code: "P0001", message: code, httpStatus: 400) == .notFound)
        }
    }
}

@Suite struct V3ValidationTests {
    typealias D = LocalDate

    @Test func awayRules() throws {
        let today = D(year: 2026, month: 9, day: 27)
        try InputValidation.awayRange(from: D(year: 2026, month: 9, day: 26), until: D(year: 2026, month: 9, day: 26), today: today)
        // 366 days at most, both ends counted: until − from <= 365.
        try InputValidation.awayRange(from: D(year: 2026, month: 10, day: 1), until: D(year: 2027, month: 10, day: 1), today: today)
        #expect(throws: AppError.invalidAway) {
            try InputValidation.awayRange(from: D(year: 2026, month: 10, day: 1), until: D(year: 2027, month: 10, day: 2), today: today)
        }
        #expect(throws: AppError.invalidAway) {
            try InputValidation.awayRange(from: D(year: 2026, month: 9, day: 20), until: D(year: 2026, month: 9, day: 25), today: today)
        }
        #expect(throws: AppError.invalidAway) {
            try InputValidation.awayDates(from: D(year: 2026, month: 10, day: 2), until: D(year: 2026, month: 10, day: 1))
        }
        #expect(throws: AppError.invalidAway) {
            try InputValidation.awayDates(from: D(year: 2026, month: 2, day: 30), until: D(year: 2026, month: 3, day: 1))
        }
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-27T23:30:00Z"))
        #expect(InputValidation.serverToday(now: now) == today)
    }

    @Test func comments() throws {
        #expect(try InputValidation.commentBody("  Salut\u{00A0}! \n") == "Salut\u{00A0}!")
        #expect(try InputValidation.commentBody(String(repeating: "é", count: 1000)).count == 1000)
        #expect(throws: AppError.invalidComment) { try InputValidation.commentBody(String(repeating: "é", count: 1001)) }
        #expect(throws: AppError.invalidComment) { try InputValidation.commentBody(" \u{3000} ") }
        #expect(throws: AppError.invalidComment) { try InputValidation.commentBody("a\u{0}b") }
        let ids = (0..<20).map { LogicFixtures.uuid($0) }
        #expect(try InputValidation.mentions(ids) == ids)
        #expect(throws: AppError.invalidMentions) { try InputValidation.mentions(ids + [LogicFixtures.uuid(99)]) }
        #expect(try InputValidation.mentions([ids[1], ids[0], ids[1]]) == [ids[1], ids[0]], "duplicates dropped, order kept")
        #expect(try InputValidation.mentions(ids + [ids[3]]) == ids, "20 distinct ids")
        #expect(InputValidation.commentExcerpt(String(repeating: "à", count: 100)).unicodeScalars.count == 80)
        #expect(InputValidation.commentExcerpt("court") == "court")
    }

    @Test func reactionsAndPhotos() throws {
        #expect(try InputValidation.reaction("👏") == .clap)
        #expect(try InputValidation.reaction("\u{2764}\u{FE0F}") == .heart)
        #expect(throws: AppError.invalidReaction) { try InputValidation.reaction("\u{2764}") }
        #expect(throws: AppError.invalidReaction) { try InputValidation.reaction("👍") }
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00])
        #expect(try InputValidation.photo(jpeg) == jpeg)
        #expect(throws: AppError.invalidPhoto) { try InputValidation.photo(Data()) }
        #expect(throws: AppError.invalidPhoto) { try InputValidation.photo(Data([0x89, 0x50, 0x4E, 0x47])) }
        #expect(throws: AppError.invalidPhoto) { try InputValidation.photo(jpeg + Data(count: Limits.photoBytesMax)) }
        #expect(Limits.photoBytesMax == 5_242_880)
    }
}

@Suite struct V3PermissionTests {
    typealias F = LogicFixtures

    @Test func nudgeSwapsCommentsAndPhotos() {
        var task = F.task(1, assignees: [F.me, F.other])
        #expect(TaskPermissions.canNudge(task, userId: F.me, role: .member))
        #expect(!TaskPermissions.canNudge(task, userId: F.me, role: nil))
        task.assigneeIds = [F.me]
        #expect(!TaskPermissions.canNudge(task, userId: F.me, role: .admin), "only the caller")
        task.assigneeIds = [F.other]
        task.status = .done
        #expect(!TaskPermissions.canNudge(task, userId: F.me, role: .member), "done")

        var rotating = F.task(2, assignees: [F.me])
        rotating.recurrence = RecurrenceRule(frequency: .weekly, timeZoneId: "Europe/Paris")
        rotating.rotation = [F.me, F.other, F.uuid(3)]
        rotating.turnUserId = F.me
        #expect(TaskPermissions.canRequestTurnSwap(rotating, userId: F.me, role: .member))
        #expect(!TaskPermissions.canRequestTurnSwap(rotating, userId: F.other, role: .admin))
        #expect(TaskPermissions.turnSwapCandidates(rotating, userId: F.me, memberIds: [F.me, F.other]) == [F.other])
        let swap = TurnSwap(
            id: F.uuid(5), taskId: rotating.id, groupId: F.groupA, seriesId: rotating.id, fromUserId: F.me, toUserId: F.other,
            status: .pending, createdAt: F.date(2026, 9, 24)
        )
        #expect(TaskPermissions.canRespond(to: swap, userId: F.other) && !TaskPermissions.canRespond(to: swap, userId: F.me))
        #expect(TaskPermissions.canCancel(swap, userId: F.me) && !TaskPermissions.canCancel(swap, userId: F.other))

        let comment = TaskComment(id: F.uuid(6), taskId: rotating.id, groupId: F.groupA, authorId: F.other, body: "x", createdAt: F.date(2026, 9, 24))
        #expect(TaskPermissions.canComment(role: .member) && !TaskPermissions.canComment(role: nil))
        #expect(TaskPermissions.canDelete(comment, userId: F.other, role: .member))
        #expect(TaskPermissions.canDelete(comment, userId: F.me, role: .admin))
        #expect(!TaskPermissions.canDelete(comment, userId: F.me, role: .member))
        #expect(!TaskPermissions.canDelete(comment, userId: F.other, role: nil), "an author who left")

        var photoTask = F.task(7, assignees: [F.other])
        photoTask.createdBy = F.uuid(8)
        #expect(TaskPermissions.canAddPhoto(photoTask, userId: F.other, role: .member))
        #expect(!TaskPermissions.canAddPhoto(photoTask, userId: F.me, role: .member))
        photoTask.photos = (0..<5).map {
            TaskPhoto(id: F.uuid(20 + $0), taskId: photoTask.id, groupId: F.groupA, path: "p\($0)", uploadedBy: F.other, createdAt: F.date(2026, 9, 24))
        }
        #expect(!TaskPermissions.canAddPhoto(photoTask, userId: F.other, role: .admin), "5 photos")
        #expect(TaskPermissions.canDelete(photoTask.photos[0], userId: F.other, role: .member))
        #expect(TaskPermissions.canDelete(photoTask.photos[0], userId: F.me, role: .admin))
        #expect(!TaskPermissions.canDelete(photoTask.photos[0], userId: F.me, role: .member))
        #expect(GroupPermissions.canReact(role: .member) && !GroupPermissions.canReact(role: nil))
    }
}

@Suite struct AbsenceSkipTests {
    typealias F = LogicFixtures
    static let a = F.uuid(0xA)
    static let b = F.uuid(0xB)
    static let c = F.uuid(0xC)

    @Test func theNextTurnSkipsTheMembersAway() {
        let rotation = [Self.a, Self.b, Self.c]
        let skip = RotationHandover(after: rotation, turnUserId: Self.a, isMember: { _ in true }, isAway: { $0 == Self.b })
        #expect(skip.turnUserId == Self.c && skip.assigneeId == Self.c && skip.rotation == rotation)
        let wrap = RotationHandover(after: rotation, turnUserId: Self.b, isMember: { _ in true }, isAway: { $0 == Self.c })
        #expect(wrap.turnUserId == Self.a)
        let allAway = RotationHandover(after: rotation, turnUserId: Self.a, isMember: { _ in true }, isAway: { _ in true })
        #expect(allAway.turnUserId == Self.b, "everyone away: the normal choice")
        let previousOnly = RotationHandover(after: rotation, turnUserId: Self.a, isMember: { _ in true }, isAway: { $0 != Self.a })
        #expect(previousOnly.turnUserId == Self.a, "the previous holder is the last candidate")
        let departed = RotationHandover(after: rotation, turnUserId: Self.a, isMember: { $0 != Self.a }, isAway: { $0 == Self.b })
        #expect(departed.turnUserId == Self.c && departed.rotation == [Self.b, Self.c])
        let dropped = RotationHandover(after: rotation, turnUserId: Self.a, isMember: { $0 == Self.b }, isAway: { _ in true })
        #expect(dropped.turnUserId == nil && dropped.assigneeId == Self.b && dropped.rotation.isEmpty)
        // The v2 initializer is the same without absences.
        #expect(RotationHandover(after: rotation, turnUserId: Self.a) { _ in true }
            == RotationHandover(after: rotation, turnUserId: Self.a, isMember: { _ in true }, isAway: { _ in false }))
    }

    @Test func theFirstTurn() {
        #expect(RotationHandover.firstTurn(of: [Self.a, Self.b], isAway: { $0 == Self.a }) == Self.b)
        #expect(RotationHandover.firstTurn(of: [Self.a, Self.b], isAway: { _ in true }) == Self.a)
        #expect(RotationHandover.firstTurn(of: [], isAway: { _ in false }) == nil)
    }
}

@MainActor
@Suite struct V3WordingTests {
    typealias F = LogicFixtures
    typealias D = LocalDate
    static let me = F.me
    static let lucas = F.uuid(0xC2)
    static let ines = F.uuid(0xC3)
    static let names = [me: "Camille", lucas: "Lucas", ines: "Inès"]

    private func text(
        _ kind: ActivityKind, actor: UUID? = nil, subject: UUID? = nil, task: String? = "Sortir les poubelles",
        item: String? = nil, startsOn: LocalDate? = nil, endsOn: LocalDate? = nil
    ) -> EmphasizedText {
        let event = ActivityEvent(
            id: 1, kind: kind, actorId: actor, subjectId: subject, taskId: F.uuid(1), taskTitle: task, itemTitle: item,
            createdAt: F.date(2026, 9, 24), startsOn: startsOn, endsOn: endsOn
        )
        return ActivityText.text(for: event, currentUserId: Self.me, names: Self.names)
    }

    @Test func v3Kinds() {
        let poubelles = "«\u{00A0}Sortir les poubelles\u{00A0}»"
        #expect(text(.taskNudged, actor: Self.lucas, subject: Self.ines).plainText == "Lucas a relancé Inès pour \(poubelles)")
        #expect(text(.taskNudged, actor: Self.lucas, subject: Self.ines).emphasized == ["Lucas", "Inès"])
        #expect(text(.taskNudged, actor: Self.lucas, subject: Self.me).plainText == "Lucas t’a envoyé une relance pour \(poubelles)")
        #expect(text(.taskNudged, actor: Self.me, subject: Self.lucas).plainText == "Tu as relancé Lucas pour \(poubelles)")
        #expect(text(.taskNudged, actor: Self.me, subject: nil, task: nil).plainText == "Tu as relancé un ancien membre")
        #expect(text(.memberAway, actor: Self.ines, subject: Self.ines, task: nil, startsOn: D(year: 2026, month: 10, day: 12),
                     endsOn: D(year: 2026, month: 10, day: 18)).plainText == "Inès a annoncé une absence du 12 au 18 octobre")
        #expect(text(.memberAway, actor: Self.me, subject: Self.me, task: nil, startsOn: D(year: 2026, month: 9, day: 28),
                     endsOn: D(year: 2026, month: 10, day: 1)).plainText == "Tu as annoncé une absence du 28 septembre au 1er octobre")
        #expect(text(.memberAway, actor: Self.ines, subject: Self.ines, task: nil).plainText == "Inès a annoncé une absence")
        #expect(text(.turnSwapped, actor: Self.lucas, subject: Self.ines).plainText == "Lucas a pris le tour d’Inès pour \(poubelles)")
        #expect(text(.turnSwapped, actor: Self.lucas, subject: Self.ines).emphasized == ["Lucas", "Inès"])
        #expect(text(.turnSwapped, actor: Self.lucas, subject: Self.me).plainText == "Lucas a pris ton tour pour \(poubelles)")
        #expect(text(.turnSwapped, actor: Self.me, subject: Self.lucas).plainText == "Tu as pris le tour de Lucas pour \(poubelles)")
        #expect(text(.commentAdded, actor: Self.ines, item: "Il reste du lait\u{00A0}?").plainText == "Inès a commenté \(poubelles)")
        #expect(text(.photoAdded, actor: Self.me).plainText == "Tu as ajouté une photo à \(poubelles)")
        #expect(text(.photoAdded, actor: Self.lucas, task: nil).plainText == "Lucas a ajouté une photo")
        let comment = ActivityEvent(id: 2, kind: .commentAdded, itemTitle: "Il reste du lait\u{00A0}?", createdAt: F.date(2026, 9, 24))
        #expect(ActivityText.detail(for: comment) == "«\u{00A0}Il reste du lait\u{00A0}?\u{00A0}»")
        #expect(ActivityText.detail(for: ActivityEvent(id: 3, kind: .taskCreated, itemTitle: "x", createdAt: F.date(2026, 9, 24))) == nil)
    }

    @Test func awayBadges() {
        let today = D(year: 2026, month: 9, day: 27)
        #expect(AwayText.badge(from: D(year: 2026, month: 9, day: 25), until: D(year: 2026, month: 10, day: 12), today: today)
            == "Absent\u{00B7}e jusqu’au 12 oct.")
        #expect(AwayText.badge(from: D(year: 2026, month: 9, day: 25), until: today, today: today) == "Absent\u{00B7}e aujourd’hui")
        #expect(AwayText.badge(from: D(year: 2026, month: 10, day: 12), until: D(year: 2026, month: 10, day: 18), today: today)
            == "Absent\u{00B7}e du 12 au 18 oct.")
        #expect(AwayText.badge(from: D(year: 2026, month: 9, day: 28), until: D(year: 2026, month: 10, day: 4), today: today)
            == "Absent\u{00B7}e du 28 sept. au 4 oct.")
        #expect(AwayText.badge(from: D(year: 2026, month: 10, day: 1), until: D(year: 2026, month: 10, day: 1), today: today)
            == "Absent\u{00B7}e le 1er oct.")
        #expect(AwayText.badge(from: D(year: 2026, month: 12, day: 28), until: D(year: 2027, month: 1, day: 3), today: today)
            == "Absent\u{00B7}e du 28 déc. au 3 janv. 2027")
        #expect(AwayText.badge(from: D(year: 2026, month: 9, day: 20), until: D(year: 2027, month: 1, day: 3), today: today)
            == "Absent\u{00B7}e jusqu’au 3 janv. 2027")
        #expect(AwayText.badge(from: D(year: 2026, month: 9, day: 20), until: D(year: 2026, month: 9, day: 26), today: today) == nil)
        #expect(AwayText.badge(from: nil, until: nil, today: today) == nil)
        #expect(AwayText.range(from: D(year: 2026, month: 12, day: 28), until: D(year: 2027, month: 1, day: 3))
            == "du 28 décembre 2026 au 3 janvier 2027")
        #expect(AwayText.range(from: D(year: 2026, month: 10, day: 12), until: D(year: 2026, month: 10, day: 12)) == "le 12 octobre")
        #expect(AwayText.shortMonthNames.count == 12)
    }

    @Test func notifications() {
        let task = F.uuid(1)
        let group = F.groupA
        let nudge = SocialNotificationText.nudge(nudgeId: F.uuid(2), taskId: task, groupId: group, fromName: "Lucas", taskTitle: "Faire les courses")
        #expect(nudge.id == "nudge-\(F.uuid(2).uuidString)")
        #expect(nudge.title == "Lucas te relance")
        #expect(nudge.body == "«\u{00A0}Faire les courses\u{00A0}»")
        #expect(nudge.userInfo == ["taskId": task.uuidString, "groupId": group.uuidString])
        #expect(SocialNotificationText.nudgeTitle(fromName: nil) == "Quelqu’un te relance")
        let proposed = SocialNotificationText.swapProposed(swapId: F.uuid(3), taskId: task, groupId: group, fromName: "Inès", taskTitle: "Poubelles")
        #expect(proposed.id == "swap-\(F.uuid(3).uuidString)")
        #expect(proposed.body == "Inès te propose son tour pour «\u{00A0}Poubelles\u{00A0}»")
        let accepted = SocialNotificationText.swapUpdated(
            swapId: F.uuid(3), taskId: task, groupId: group, status: .accepted, isRepaid: false, toName: "Lucas", taskTitle: "Poubelles"
        )
        #expect(accepted?.title == "Échange accepté" && accepted?.body == "Lucas prend ton tour pour «\u{00A0}Poubelles\u{00A0}»")
        let declined = SocialNotificationText.swapUpdated(
            swapId: F.uuid(3), taskId: task, groupId: group, status: .declined, isRepaid: false, toName: "Lucas", taskTitle: nil
        )
        #expect(declined?.body == "Lucas ne peut pas prendre ton tour")
        #expect(SocialNotificationText.swapUpdated(swapId: F.uuid(3), taskId: task, groupId: group, status: .accepted, isRepaid: true, toName: "L", taskTitle: nil) == nil)
        #expect(SocialNotificationText.swapUpdated(swapId: F.uuid(3), taskId: task, groupId: group, status: .cancelled, isRepaid: false, toName: "L", taskTitle: nil) == nil)
        let reaction = SocialNotificationText.reaction(
            activityId: 42, groupId: group, taskId: task, reactorId: F.other, currentUserId: F.me, fromName: "Camille", emoji: .clap,
            taskTitle: "Nettoyer le frigo"
        )
        #expect(reaction?.id == "reaction-42")
        #expect(reaction?.body == "Camille a réagi 👏 à «\u{00A0}Nettoyer le frigo\u{00A0}»")
        #expect(SocialNotificationText.reaction(
            activityId: 42, groupId: group, taskId: nil, reactorId: F.me, currentUserId: F.me, fromName: "Moi", emoji: .clap, taskTitle: nil
        ) == nil, "never for one's own reaction")
        #expect(SocialNotificationText.reactionBody(fromName: "Lucas", emoji: .fire, taskTitle: nil) == "Lucas a réagi 🔥 à ton activité")
        #expect(SocialNotificationText.shouldNotify(authorId: F.other, mentions: [F.me], currentUserId: F.me, isAssignee: false))
        #expect(SocialNotificationText.shouldNotify(authorId: F.other, mentions: [], currentUserId: F.me, isAssignee: true))
        #expect(!SocialNotificationText.shouldNotify(authorId: F.other, mentions: [], currentUserId: F.me, isAssignee: false))
        #expect(!SocialNotificationText.shouldNotify(authorId: F.me, mentions: [F.me], currentUserId: F.me, isAssignee: true))
        let mention = SocialNotificationText.comment(
            commentId: F.uuid(4), taskId: task, groupId: group, authorId: F.other, mentions: [F.me], currentUserId: F.me,
            isAssignee: false, authorName: "Lucas", taskTitle: "Faire les courses", body: String(repeating: "a", count: 200)
        )
        #expect(mention?.title == "Lucas te mentionne dans «\u{00A0}Faire les courses\u{00A0}»")
        #expect(mention?.body.count == 140 && mention?.body.hasSuffix("…") == true)
        #expect(SocialNotificationText.commentTitle(authorName: "Inès", taskTitle: nil, isMention: false) == "Inès a commenté une tâche")
    }

    @Test func statsLabels() {
        #expect(StatsText.monthLabel(0) == "tâche ce mois" && StatsText.monthLabel(3) == "tâches ce mois")
        #expect(StatsText.streakLabel(1) == "semaine de série" && StatsText.streakLabel(4) == "semaines de série")
    }

    /// The v3 strings follow the French typography of the app (no ASCII apostrophe, no-break spaces).
    @Test func typography() {
        let today = D(year: 2026, month: 9, day: 27)
        let shown: [String] = V3ErrorTests.codes.map(\.2) + [
            AwayText.badge(from: today, until: today.adding(days: 3), today: today) ?? "",
            SocialNotificationText.nudgeTitle(fromName: nil),
            SocialNotificationText.nudgeBody(taskTitle: "T"),
            SocialNotificationText.nudgeBody(taskTitle: nil),
            SocialNotificationText.swapProposedBody(fromName: "Inès", taskTitle: "T"),
            SocialNotificationText.reactionBody(fromName: "Inès", emoji: .joy, taskTitle: "T"),
            SocialNotificationText.commentTitle(authorName: "Inès", taskTitle: "T", isMention: true),
            text(.taskNudged, actor: Self.lucas, subject: Self.me).plainText,
        ]
        for text in shown {
            #expect(!text.contains("'"), "\(text)")
            #expect(WordingTests.typographyProblems(in: text).isEmpty, "\(text)")
        }
    }
}

@Suite struct MyStatsTests {
    typealias F = LogicFixtures
    static let calendar = F.parisCalendar

    static func completion(_ date: Date, _ number: Int = 1) -> TaskCompletion {
        TaskCompletion(taskId: F.uuid(number), completedBy: F.me, completedAt: date, groupId: F.groupA)
    }

    @Test func monthAndStreak() {
        // Sunday 2026-09-27 at 20:00: the current week runs from Monday 21.
        let now = F.date(2026, 9, 27, 20)
        let completions = [
            Self.completion(F.date(2026, 9, 21, 0, 0)), // this week, Monday 00:00
            Self.completion(F.date(2026, 9, 15, 10)), // the week before
            Self.completion(F.date(2026, 9, 7, 10)), // two weeks before
            Self.completion(F.date(2026, 8, 31, 23, 59)), // three weeks before (Monday), and before the month
            Self.completion(F.date(2026, 8, 20, 10)), // a gap on the week of Aug 24
        ]
        let stats = MyStats(completions: completions, now: now, calendar: Self.calendar)
        #expect(stats.tasksThisMonth == 3)
        #expect(stats.weekStreak == 4)
        #expect(stats.isCurrentWeekDone)
        #expect(stats.monthLabel == "tâches ce mois")
        #expect(stats.streakLabel == "semaines de série")
    }

    /// The current week without a completion yet: the streak counts from the week before.
    @Test func currentWeekNotDoneYet() {
        let now = F.date(2026, 9, 23, 12)
        let stats = MyStats(
            completions: [Self.completion(F.date(2026, 9, 18, 10)), Self.completion(F.date(2026, 9, 9, 10))],
            now: now, calendar: Self.calendar
        )
        #expect(stats.weekStreak == 2 && !stats.isCurrentWeekDone)
        #expect(stats.tasksThisMonth == 2)
        let broken = MyStats(completions: [Self.completion(F.date(2026, 9, 9, 10))], now: now, calendar: Self.calendar)
        #expect(broken.weekStreak == 0)
        #expect(MyStats(completions: [], now: now, calendar: Self.calendar) == MyStats(tasksThisMonth: 0, weekStreak: 0, isCurrentWeekDone: false))
    }

    @Test func readStartAndBounds() {
        let now = F.date(2026, 9, 27, 20)
        #expect(MyStats.readStart(now: now, calendar: Self.calendar) == F.date(2026, 7, 6))
        #expect(MyStats.monthStart(of: now, calendar: Self.calendar) == F.date(2026, 9, 1))
        // Twelve weeks in a row at most; a completion in the future of `now`'s week is ignored.
        let weekly = (0..<14).map { Self.completion(F.date(2026, 9, 22, 10).addingTimeInterval(-Double($0) * 7 * 86_400), $0) }
        let stats = MyStats(completions: weekly + [Self.completion(F.date(2026, 9, 29, 10), 99)], now: now, calendar: Self.calendar)
        #expect(stats.weekStreak == MyStats.weeksRead)
        #expect(stats.tasksThisMonth == 4)
    }
}
