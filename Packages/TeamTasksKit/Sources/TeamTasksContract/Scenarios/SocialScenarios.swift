import Foundation
import TeamTasksCore

// v3 « Relancer », « Bravo », comments, photos and personal stats (docs/CONTRACTS-V3.md §1, §4–§8, §10). The 20-hour
// window of the nudges needs a controllable clock: it is covered by the backend-specific tests (mock clock, pgTAP).
extension ContractScenarios {
    static let socialScenarios: [ContractScenario] = [
        ContractScenario("nudge.basics") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let carol = try await harness.user("Carol")
            let dan = try await harness.user("Dan")
            let eve = try await harness.user("Eve")
            let group = try await alice.makeGroup(joinedBy: [bob, carol, dan])
            let task = try await alice.makeTask(in: group.id, "Courses", assignees: [alice, bob, carol])
            var bumped = try await alice.lastActivity(of: group.id)

            // Any member may nudge, not only the editors: every assignee but the caller.
            let byDan = try await dan.tasks.nudge(taskId: task.id)
            try Verify.equal(byDan, 3, "dan nudges alice, bob and carol")
            bumped = try await alice.checkBumped(group.id, since: bumped, "a nudge")
            let byAlice = try await alice.tasks.nudge(taskId: task.id)
            try Verify.equal(byAlice, 2, "alice nudges bob and carol, not herself")
            bumped = try await alice.checkBumped(group.id, since: bumped, "another caller's nudge")
            let events = try await bob.events(.taskNudged, in: group.id)
            try Verify.equal(events.count, 5, "one task_nudged event per assignee nudged")
            let shapes = Set(events.map { "\($0.actorId?.uuidString ?? "nil")>\($0.subjectId?.uuidString ?? "nil")" })
            let expected = Set([(dan, alice), (dan, bob), (dan, carol), (alice, bob), (alice, carol)].map { "\($0.0.id.uuidString)>\($0.1.id.uuidString)" })
            try Verify.equal(shapes, expected, "actor = the caller, subject = the assignee nudged")
            try Verify.that(events.allSatisfy { $0.taskId == task.id && $0.taskTitle == task.title }, "the task and its title")

            // One nudge per task and caller in 20 hours; a refused call writes nothing.
            let before = try await bob.feed(of: group.id)
            try await Verify.fails(with: .nudgeRateLimited, "dan again") { try await dan.tasks.nudge(taskId: task.id) }
            try await Verify.fails(with: .nudgeRateLimited, "alice again") { try await alice.tasks.nudge(taskId: task.id) }
            try Verify.equal(try await bob.feed(of: group.id), before, "refused nudges write no event")
            try Verify.equal(try await alice.lastActivity(of: group.id), bumped, "refused nudges do not bump")
            let other = try await alice.makeTask(in: group.id, "Autre", assignees: [bob])
            try Verify.equal(try await dan.tasks.nudge(taskId: other.id), 1, "the window is per task")

            // Errors: task_not_found → task_done → nudge_no_recipient → nudge_rate_limited.
            try await Verify.fails(with: .notFound, "a non-member") { try await eve.tasks.nudge(taskId: task.id) }
            try await Verify.fails(with: .notFound, "an unknown task") { try await dan.tasks.nudge(taskId: UUID()) }
            let nobody = try await alice.makeTask(in: group.id, "Personne")
            try await Verify.fails(with: .nudgeNoRecipient, "no assignee") { try await dan.tasks.nudge(taskId: nobody.id) }
            let onlyMe = try await alice.makeTask(in: group.id, "Moi", assignees: [dan])
            try await Verify.fails(with: .nudgeNoRecipient, "the caller is the only assignee") {
                try await dan.tasks.nudge(taskId: onlyMe.id)
            }
            _ = try await alice.reassign(other, to: [])
            try await Verify.fails(with: .nudgeNoRecipient, "no recipient any more comes before the window") {
                try await dan.tasks.nudge(taskId: other.id)
            }
            _ = try await alice.tasks.setStatus(taskId: task.id, status: .done)
            try await Verify.fails(with: .taskDone, "a done task, before the window") { try await dan.tasks.nudge(taskId: task.id) }
            _ = try await alice.tasks.setStatus(taskId: nobody.id, status: .done)
            try await Verify.fails(with: .taskDone, "a done task, before the recipients") {
                try await dan.tasks.nudge(taskId: nobody.id)
            }
        },

        ContractScenario("reactions.toggle") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let carol = try await harness.user("Carol")
            let eve = try await harness.user("Eve")
            let group = try await alice.makeGroup(joinedBy: [bob, carol])
            let task = try await alice.makeTask(in: group.id, "Bravo")
            let created = try Verify.unwrap(try await bob.events(.taskCreated, in: group.id).first, "task_created")
            var bumped = try await alice.lastActivity(of: group.id)

            try Verify.that(try await bob.groups.toggleReaction(activityId: created.id, emoji: .clap), "bob adds 👏")
            bumped = try await alice.checkBumped(group.id, since: bumped, "a reaction")
            try Verify.that(try await bob.groups.toggleReaction(activityId: created.id, emoji: .fire), "bob adds 🔥")
            try Verify.that(try await carol.groups.toggleReaction(activityId: created.id, emoji: .clap), "carol adds 👏")
            try Verify.that(try await alice.groups.toggleReaction(activityId: created.id, emoji: .heart), "alice reacts to her own event")
            var event = try Verify.unwrap(try await alice.feed(of: group.id).first { $0.id == created.id }, "the event")
            try Verify.equal(
                event.reactions,
                ActivityReaction.sorted([
                    ActivityReaction(userId: bob.id, emoji: .clap), ActivityReaction(userId: bob.id, emoji: .fire),
                    ActivityReaction(userId: carol.id, emoji: .clap), ActivityReaction(userId: alice.id, emoji: .heart),
                ]),
                "the reactions embedded in the feed"
            )
            let summaries = event.reactionSummaries(currentUserId: bob.id)
            try Verify.equal(summaries.map(\.emoji), [.clap, .fire, .heart], "one summary per emoji, in the set's order")
            try Verify.equal(summaries.map(\.count), [2, 1, 1], "the counts")
            try Verify.equal(summaries.map(\.includesMe), [true, true, false], "bob's own reactions")

            // The same emoji again removes it.
            try Verify.that(!(try await bob.groups.toggleReaction(activityId: created.id, emoji: .clap)), "bob removes 👏")
            _ = try await alice.checkBumped(group.id, since: bumped, "removing a reaction")
            event = try Verify.unwrap(try await carol.feed(of: group.id).first { $0.id == created.id }, "the event")
            try Verify.equal(
                Set(event.reactions.map { "\($0.userId.uuidString)\($0.emoji.rawValue)" }),
                Set([(bob, ReactionEmoji.fire), (carol, .clap), (alice, .heart)].map { "\($0.0.id.uuidString)\($0.1.rawValue)" }),
                "bob's 👏 is gone"
            )
            try Verify.that(try await bob.groups.toggleReaction(activityId: created.id, emoji: .clap), "and can come back")

            // An event without actor (a spawn's turn) takes reactions too.
            let rotating = try await alice.makeRotatingTask(in: group.id, dueAt: try utc("2041-03-04T07:00:00Z"), rotation: [bob, carol])
            _ = try await bob.completeAndReadNext(rotating)
            let turn = try Verify.unwrap(try await carol.events(.turnStarted, in: group.id).first, "turn_started")
            try Verify.that(try await carol.groups.toggleReaction(activityId: turn.id, emoji: .muscle), "a reaction to a server event")

            try await Verify.fails(with: .notFound, "a non-member") {
                try await eve.groups.toggleReaction(activityId: created.id, emoji: .clap)
            }
            try await Verify.fails(with: .notFound, "an unknown event") {
                try await bob.groups.toggleReaction(activityId: 9_000_000_000_000_000, emoji: .clap)
            }
            _ = task
        },

        ContractScenario("comments.addReadDelete") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let carol = try await harness.user("Carol")
            let dan = try await harness.user("Dan")
            let eve = try await harness.user("Eve")
            let group = try await alice.makeGroup(joinedBy: [bob, carol, dan])
            let task = try await alice.makeTask(in: group.id, "Courses", assignees: [bob])
            var bumped = try await alice.lastActivity(of: group.id)

            // Any member may comment; the body is trimmed; the mentions keep their order, without duplicates, and the
            // author may mention herself.
            let first = try await carol.tasks.addComment(
                taskId: task.id, body: "  Il reste du lait\u{00A0}?  ", mentions: [bob.id, alice.id, bob.id, carol.id]
            )
            try Verify.equal(first.body, "Il reste du lait\u{00A0}?", "the trimmed body")
            try Verify.equal(first.mentions, [bob.id, alice.id, carol.id], "the mentions, in the order sent, duplicates dropped")
            try Verify.equal(first.authorId, carol.id, "the author")
            try Verify.equal(first.taskId, task.id, "the task")
            try Verify.equal(first.groupId, group.id, "the group")
            bumped = try await alice.checkBumped(group.id, since: bumped, "a comment")
            let long = String(repeating: "é", count: 95) + "12345"
            let second = try await bob.tasks.addComment(taskId: task.id, body: long, mentions: [])
            let limit = try await dan.tasks.addComment(taskId: task.id, body: Fixed.text(Limits.commentBodyMax), mentions: [])
            try Verify.equal(limit.body.count, Limits.commentBodyMax, "1000 characters are allowed")

            let read = try await dan.tasks.comments(taskId: task.id)
            try Verify.equal(read, [first, second, limit], "comments(taskId:) returns them oldest first, as added")
            try await Verify.hidden("a non-member reads no comment") { try await eve.tasks.comments(taskId: task.id) }
            let counted = try await alice.tasks.task(id: task.id)
            try Verify.equal(counted.commentCount, 3, "the comment count of the task")
            let listed = try await alice.tasks.tasks(groupId: group.id, includeOldDone: false)
            try Verify.equal(listed.first { $0.id == task.id }?.commentCount, 3, "the count in the group's tasks")
            let mine = try await bob.tasks.myTasks(includeDone: false)
            try Verify.equal(mine.first { $0.id == task.id }?.commentCount, 3, "the count in « Mes tâches »")

            // The feed: comment_added, the first 80 characters as item_title.
            let events = try await alice.events(.commentAdded, in: group.id)
            try Verify.equal(
                events.map(EventShape.init),
                [
                    EventShape(.commentAdded, actor: dan.id, task: task.id, title: task.title, item: Fixed.text(Limits.commentExcerptMax)),
                    EventShape(.commentAdded, actor: bob.id, task: task.id, title: task.title, item: String(long.prefix(80))),
                    EventShape(.commentAdded, actor: carol.id, task: task.id, title: task.title, item: first.body),
                ],
                "one comment_added per comment, newest first"
            )
            try Verify.equal(events.last?.createdAt, first.createdAt, "written with the comment")

            // Errors: task_not_found → invalid_comment → invalid_mentions; a refused comment writes nothing.
            try await Verify.fails(with: .invalidComment, "a blank body") {
                try await bob.tasks.addComment(taskId: task.id, body: " \u{00A0} ", mentions: [])
            }
            try await Verify.fails(with: .invalidComment, "1001 characters") {
                try await bob.tasks.addComment(taskId: task.id, body: Fixed.text(Limits.commentBodyMax + 1), mentions: [])
            }
            try await Verify.fails(with: .invalidComment, "U+0000") {
                try await bob.tasks.addComment(taskId: task.id, body: "a\u{0}b", mentions: [])
            }
            try await Verify.fails(with: .invalidMentions, "a non-member mentioned") {
                try await bob.tasks.addComment(taskId: task.id, body: "Eve ?", mentions: [eve.id])
            }
            try await Verify.fails(with: .invalidMentions, "an unknown user mentioned") {
                try await bob.tasks.addComment(taskId: task.id, body: "Qui ?", mentions: [UUID()])
            }
            try await Verify.fails(with: .invalidMentions, "more than 20 mentions") {
                try await bob.tasks.addComment(taskId: task.id, body: "Tous", mentions: (0...Limits.mentionsMax).map { _ in UUID() })
            }
            try await Verify.fails(with: .invalidComment, "the body before the mentions") {
                try await bob.tasks.addComment(taskId: task.id, body: "", mentions: [eve.id])
            }
            try await Verify.fails(with: .notFound, "a non-member, whatever the body") {
                try await eve.tasks.addComment(taskId: task.id, body: "", mentions: [])
            }
            try await Verify.fails(with: .notFound, "an unknown task") {
                try await bob.tasks.addComment(taskId: UUID(), body: "Salut", mentions: [])
            }
            try Verify.equal(try await dan.tasks.comments(taskId: task.id), read, "refused comments write nothing")

            // Delete: the author or an admin (comment_not_found → forbidden).
            try await Verify.fails(with: .forbidden, "another member") { try await dan.tasks.deleteComment(commentId: first.id) }
            try await Verify.fails(with: .notFound, "a non-member") { try await eve.tasks.deleteComment(commentId: first.id) }
            try await Verify.fails(with: .notFound, "an unknown comment") { try await bob.tasks.deleteComment(commentId: UUID()) }
            bumped = try await alice.lastActivity(of: group.id)
            try await carol.tasks.deleteComment(commentId: first.id)
            _ = try await alice.checkBumped(group.id, since: bumped, "deleting a comment")
            try await alice.tasks.deleteComment(commentId: second.id)
            try Verify.equal(try await bob.tasks.comments(taskId: task.id), [limit], "the author and an admin deleted theirs")
            try Verify.equal(try await bob.tasks.task(id: task.id).commentCount, 1, "the count follows")
            try await Verify.fails(with: .notFound, "a deleted comment") { try await carol.tasks.deleteComment(commentId: first.id) }

            // A done task can still be commented; deleting the task deletes its comments.
            _ = try await alice.tasks.setStatus(taskId: task.id, status: .done)
            _ = try await dan.tasks.addComment(taskId: task.id, body: "Merci\u{00A0}!", mentions: [bob.id])
            try await alice.tasks.delete(taskId: task.id)
            try await Verify.hidden("the comments of a deleted task") { try await alice.tasks.comments(taskId: task.id) }
        },

        ContractScenario("photos.uploadAndDelete") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let carol = try await harness.user("Carol")
            let eve = try await harness.user("Eve")
            let group = try await alice.makeGroup(joinedBy: [bob, carol])
            let task = try await alice.makeTask(in: group.id, "Cuisine", assignees: [bob])
            var bumped = try await alice.lastActivity(of: group.id)

            // The rights of « change status »: an assignee.
            let photo = try await bob.tasks.uploadPhoto(taskId: task.id, jpegData: Photo.jpeg)
            try Verify.that(photo.path.hasPrefix(TaskPhoto.folder(groupId: group.id, taskId: task.id)), "the path \(photo.path)")
            try Verify.that(photo.path.hasSuffix(".jpg"), "a JPEG object")
            try Verify.equal(photo.uploadedBy, bob.id, "the uploader")
            try Verify.equal(photo.taskId, task.id, "the task")
            try Verify.equal(photo.groupId, group.id, "the group")
            bumped = try await alice.checkBumped(group.id, since: bumped, "a photo")
            let read = try await carol.tasks.task(id: task.id)
            try Verify.equal(read.photos, [photo], "the task's photos")
            let mine = try await bob.tasks.myTasks(includeDone: false)
            try Verify.equal(mine.first { $0.id == task.id }?.photos, [photo], "the photos in « Mes tâches »")
            let events = try await carol.events(.photoAdded, in: group.id)
            try Verify.equal(
                events.map(EventShape.init), [EventShape(.photoAdded, actor: bob.id, task: task.id, title: task.title)],
                "one photo_added event"
            )
            try Verify.equal(events.first?.createdAt, photo.createdAt, "written with the photo")
            _ = try await carol.tasks.photoURL(photo)
            try await Verify.fails(with: .notFound, "a non-member gets no URL") { try await eve.tasks.photoURL(photo) }

            // Errors: task_not_found → invalid_photo → forbidden → photo_limit.
            try await Verify.fails(with: .notFound, "a non-member") { try await eve.tasks.uploadPhoto(taskId: task.id, jpegData: Photo.jpeg) }
            try await Verify.fails(with: .notFound, "an unknown task") { try await bob.tasks.uploadPhoto(taskId: UUID(), jpegData: Photo.jpeg) }
            try await Verify.fails(with: .invalidPhoto, "not a JPEG") { try await bob.tasks.uploadPhoto(taskId: task.id, jpegData: Photo.png) }
            try await Verify.fails(with: .invalidPhoto, "no bytes") { try await bob.tasks.uploadPhoto(taskId: task.id, jpegData: Data()) }
            try await Verify.fails(with: .forbidden, "a member who may not change the status") {
                try await carol.tasks.uploadPhoto(taskId: task.id, jpegData: Photo.jpeg)
            }
            var photos = [photo]
            for _ in 2...Limits.photosPerTaskMax {
                photos.append(try await alice.tasks.uploadPhoto(taskId: task.id, jpegData: Photo.jpeg))
            }
            try await Verify.fails(with: .photoLimit, "a sixth photo") { try await bob.tasks.uploadPhoto(taskId: task.id, jpegData: Photo.jpeg) }
            try Verify.equal(try await carol.tasks.task(id: task.id).photos, photos, "5 photos, oldest first")

            // Delete: the uploader or an admin (photo_not_found → forbidden).
            try await Verify.fails(with: .forbidden, "another member") { try await carol.tasks.deletePhoto(photo) }
            try await Verify.fails(with: .forbidden, "an assignee who did not upload it") { try await bob.tasks.deletePhoto(photos[1]) }
            try await Verify.fails(with: .notFound, "a non-member") { try await eve.tasks.deletePhoto(photo) }
            bumped = try await alice.lastActivity(of: group.id)
            try await bob.tasks.deletePhoto(photo)
            _ = try await alice.checkBumped(group.id, since: bumped, "deleting a photo")
            try await alice.tasks.deletePhoto(photos[1])
            try Verify.equal(try await bob.tasks.task(id: task.id).photos, Array(photos.dropFirst(2)), "two photos deleted")
            try await Verify.fails(with: .notFound, "a deleted photo") { try await bob.tasks.deletePhoto(photo) }
            try await Verify.fails(with: .notFound, "the URL of a deleted photo") { try await bob.tasks.photoURL(photo) }

            // A photo proves a done task too.
            _ = try await bob.tasks.setStatus(taskId: task.id, status: .done)
            let proof = try await bob.tasks.uploadPhoto(taskId: task.id, jpegData: Photo.jpeg)
            try Verify.that(try await alice.tasks.task(id: task.id).photos.contains(proof), "a photo of a done task")
        },

        ContractScenario("stats.myCompletions") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let group = try await alice.makeGroup(joinedBy: [bob])
            let other = try await bob.makeGroup("Autre", joinedBy: [alice])
            let first = try await alice.makeTask(in: group.id, "Un", assignees: [alice])
            let second = try await alice.makeTask(in: other.id, "Deux", assignees: [alice])
            let byBob = try await bob.makeTask(in: group.id, "Trois", assignees: [bob])
            let firstDone = try await alice.tasks.setStatus(taskId: first.id, status: .done)
            let secondDone = try await alice.tasks.setStatus(taskId: second.id, status: .done)
            _ = try await bob.tasks.setStatus(taskId: byBob.id, status: .done)

            let all = try await alice.tasks.myCompletions(since: Fixed.longAgo)
            try Verify.equal(
                all.sorted { $0.completedAt < $1.completedAt },
                [
                    TaskCompletion(taskId: first.id, completedBy: alice.id, completedAt: try Verify.unwrap(firstDone.completedAt, "done"), groupId: group.id),
                    TaskCompletion(taskId: second.id, completedBy: alice.id, completedAt: try Verify.unwrap(secondDone.completedAt, "done"), groupId: other.id),
                ],
                "the tasks alice completed, in every group, with their group"
            )
            let since = try Verify.unwrap(secondDone.completedAt, "the second completion")
            try Verify.equal(try await alice.tasks.myCompletions(since: since).map(\.taskId), [second.id], "since is inclusive")
            // Reopened, a task is no longer a completion.
            _ = try await alice.tasks.setStatus(taskId: first.id, status: .todo)
            try Verify.equal(try await alice.tasks.myCompletions(since: Fixed.longAgo).map(\.taskId), [second.id], "reopened")
            // RLS: only the tasks of the groups the user belongs to.
            try await alice.groups.leave(groupId: other.id)
            try await Verify.hidden("after leaving the group") { try await alice.tasks.myCompletions(since: Fixed.longAgo) }
        },

        ContractScenario("compat.v3ReadsAgree") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let group = try await alice.makeGroup(joinedBy: [bob])
            let task = try await alice.makeTask(in: group.id, "Complet", assignees: [alice, bob])
            _ = try await bob.tasks.addComment(taskId: task.id, body: "Un", mentions: [])
            _ = try await bob.tasks.addComment(taskId: task.id, body: "Deux", mentions: [alice.id])
            let photo = try await alice.tasks.uploadPhoto(taskId: task.id, jpegData: Photo.jpeg)

            // The rows returned by the task RPCs carry the comment count and the photos of a later read.
            var draft = TaskDraft(task: task)
            draft.title = Unique.name("Édité")
            let updated = try await alice.tasks.update(taskId: task.id, draft: draft)
            try Verify.equal(updated.commentCount, 2, "update_task: the count")
            try Verify.equal(updated.photos, [photo], "update_task: the photos")
            try Verify.equal(updated, try await bob.tasks.task(id: task.id), "update equals a later read")
            let done = try await bob.tasks.setStatus(taskId: task.id, status: .done)
            try Verify.equal(done, try await alice.tasks.task(id: task.id), "set_task_status equals a later read")
            let mine = try await alice.tasks.myTasks(includeDone: true)
            try Verify.equal(
                try Verify.unwrap(mine.first { $0.id == task.id }, "in « Mes tâches »").withoutPersonalFields, done,
                "« Mes tâches » agrees"
            )
            let listed = try await bob.tasks.tasks(groupId: group.id, includeOldDone: true)
            try Verify.equal(listed.first { $0.id == task.id }, done, "the group's tasks agree")
            let created = try await alice.makeTask(in: group.id, "Neuf")
            try Verify.equal(created.commentCount, 0, "a new task has no comment")
            try Verify.equal(created.photos, [], "nor photo")
            try Verify.equal(created, try await alice.tasks.task(id: created.id), "create equals a later read")
        },
    ]
}
