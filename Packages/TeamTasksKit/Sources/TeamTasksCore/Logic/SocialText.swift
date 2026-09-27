import Foundation

/// French wording of the absences (docs/CONTRACTS-V3.md §2): the badge next to a member, and the range of the feed.
/// Gender-neutral: the app does not know anyone's gender, so the badge says « Absent·e » for everyone. Pure.
public enum AwayText {
    /// The word of the badge, gender-neutral (U+00B7).
    public static let awayWord = "Absent\u{00B7}e"
    /// Short month names, indexed by `month - 1`.
    public static let shortMonthNames = [
        "janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août", "sept.", "oct.", "nov.", "déc.",
    ]

    /// The badge of an absence on `today`:
    /// - under way: « Absent·e jusqu’au 12 oct. », « Absent·e aujourd’hui » on its last day;
    /// - to come: « Absent·e du 12 au 19 oct. », « Absent·e du 28 sept. au 4 oct. », « Absent·e le 12 oct. »;
    /// - over, or no absence: nil.
    /// The year is added to a date of another year than `today`'s (« jusqu’au 3 janv. 2027 »).
    public static func badge(from: LocalDate?, until: LocalDate?, today: LocalDate) -> String? {
        guard let from, let until, from <= until, until >= today else { return nil }
        if from <= today {
            return until == today
                ? "\(awayWord) aujourd’hui"
                : "\(awayWord) jusqu’au \(shortDay(until, referenceYear: today.year))"
        }
        if from == until {
            return "\(awayWord) le \(shortDay(from, referenceYear: today.year))"
        }
        return "\(awayWord) \(shortRange(from: from, until: until, referenceYear: today.year))"
    }

    /// The badge of a member on `today` (`badge(from:until:today:)` of their away dates).
    public static func badge(for profile: UserProfile, today: LocalDate) -> String? {
        badge(from: profile.awayFrom, until: profile.awayUntil, today: today)
    }

    /// The range of an absence, full month names, for a sentence: « du 12 au 19 octobre », « du 28 septembre au
    /// 4 octobre », « le 12 octobre » (one day), « du 28 décembre 2026 au 3 janvier 2027 » (over two years).
    public static func range(from: LocalDate, until: LocalDate) -> String {
        if from == until {
            return "le \(dayNumber(from)) \(monthName(from))"
        }
        if from.year != until.year {
            return "du \(dayNumber(from)) \(monthName(from)) \(from.year) au \(dayNumber(until)) \(monthName(until)) \(until.year)"
        }
        if from.month != until.month {
            return "du \(dayNumber(from)) \(monthName(from)) au \(dayNumber(until)) \(monthName(until))"
        }
        return "du \(dayNumber(from)) au \(dayNumber(until)) \(monthName(until))"
    }

    /// « 12 oct. », « 1er janv. », « 3 janv. 2027 » when the year is not `referenceYear`.
    public static func shortDay(_ date: LocalDate, referenceYear: Int?) -> String {
        let text = "\(dayNumber(date)) \(shortMonthName(date))"
        return date.year == referenceYear ? text : "\(text) \(date.year)"
    }

    /// « du 12 au 19 oct. », « du 28 sept. au 4 oct. », « du 28 déc. au 3 janv. 2027 »: the year of a date that is
    /// not `referenceYear`, once for two dates of the same year.
    static func shortRange(from: LocalDate, until: LocalDate, referenceYear: Int) -> String {
        let untilText = shortDay(until, referenceYear: referenceYear)
        guard from.year == until.year else {
            return "du \(shortDay(from, referenceYear: referenceYear)) au \(untilText)"
        }
        if from.month == until.month {
            return "du \(dayNumber(from)) au \(untilText)"
        }
        return "du \(dayNumber(from)) \(shortMonthName(from)) au \(untilText)"
    }

    static func dayNumber(_ date: LocalDate) -> String {
        date.day == 1 ? "1er" : "\(date.day)"
    }

    static func monthName(_ date: LocalDate) -> String {
        FrenchDateFormatter.monthNames[((date.month - 1) % 12 + 12) % 12]
    }

    static func shortMonthName(_ date: LocalDate) -> String {
        shortMonthNames[((date.month - 1) % 12 + 12) % 12]
    }
}

/// French wording of the personal stats of Réglages (docs/CONTRACTS-V3.md §8). Pure.
public enum StatsText {
    /// Under the count of the month: « tâche ce mois » (0 and 1), « tâches ce mois ».
    public static func monthLabel(_ count: Int) -> String {
        FrenchText.isSingular(count) ? "tâche ce mois" : "tâches ce mois"
    }

    /// Under the streak: « semaine de série » (0 and 1), « semaines de série ».
    public static func streakLabel(_ weeks: Int) -> String {
        FrenchText.isSingular(weeks) ? "semaine de série" : "semaines de série"
    }
}

/// The local notifications of the v3 Realtime events (docs/CONTRACTS-V3.md §1, §3–§5), worded in French with « tu ».
/// The caller resolves the names (first names, `FrenchText.firstName(of:)`) and the titles (`TaskService.task(id:)`);
/// a nil name reads « Quelqu’un ». Every notification carries `taskId` and `groupId` (a tap opens the task) and is
/// threaded by group. Pure.
public enum SocialNotificationText {
    /// Someone the app cannot name.
    public static let someone = "Quelqu’un"
    public static let swapProposedTitle = "Échange de tour"
    public static let swapAcceptedTitle = "Échange accepté"
    public static let swapDeclinedTitle = "Échange refusé"
    public static let reactionTitle = "Nouvelle réaction"

    public static func nudgeIdentifier(_ nudgeId: UUID) -> String { "nudge-\(nudgeId.uuidString)" }
    public static func swapIdentifier(_ swapId: UUID) -> String { "swap-\(swapId.uuidString)" }
    /// One per event: a second reaction to the same event replaces the first notification (§4 throttling).
    public static func reactionIdentifier(activityId: Int64) -> String { "reaction-\(activityId)" }
    public static func commentIdentifier(_ commentId: UUID) -> String { "comment-\(commentId.uuidString)" }

    // MARK: - Relancer (§1)

    /// « Camille te relance ».
    public static func nudgeTitle(fromName: String?) -> String {
        "\(name(fromName)) te relance"
    }

    /// « « Faire les courses » »; « Une tâche t’attend. » when the title is unknown.
    public static func nudgeBody(taskTitle: String?) -> String {
        taskTitle.map(FrenchText.quoted) ?? "Une tâche t’attend."
    }

    public static func nudge(nudgeId: UUID, taskId: UUID, groupId: UUID, fromName: String?, taskTitle: String?) -> LocalNotification {
        notification(
            id: nudgeIdentifier(nudgeId), title: nudgeTitle(fromName: fromName), body: nudgeBody(taskTitle: taskTitle),
            taskId: taskId, groupId: groupId
        )
    }

    // MARK: - Échanger mon tour (§3)

    /// « Camille te propose son tour pour « Sortir les poubelles » ».
    public static func swapProposedBody(fromName: String?, taskTitle: String?) -> String {
        "\(name(fromName)) te propose son tour" + (taskTitle.map { " pour \(FrenchText.quoted($0))" } ?? "")
    }

    public static func swapProposed(swapId: UUID, taskId: UUID, groupId: UUID, fromName: String?, taskTitle: String?) -> LocalNotification {
        notification(
            id: swapIdentifier(swapId), title: swapProposedTitle,
            body: swapProposedBody(fromName: fromName, taskTitle: taskTitle), taskId: taskId, groupId: groupId
        )
    }

    /// The answer to a swap the current user proposed: accepted (« Lucas prend ton tour pour « … » ») or declined
    /// (« Lucas ne peut pas prendre ton tour pour « … » »). nil for a pending or cancelled swap, and for the
    /// repayment of an accepted one (`isRepaid`): no news for its author.
    public static func swapUpdated(
        swapId: UUID, taskId: UUID, groupId: UUID, status: TurnSwap.Status, isRepaid: Bool, toName: String?, taskTitle: String?
    ) -> LocalNotification? {
        let rest = taskTitle.map { " pour \(FrenchText.quoted($0))" } ?? ""
        let title: String
        let body: String
        switch status {
        case .accepted where !isRepaid:
            title = swapAcceptedTitle
            body = "\(name(toName)) prend ton tour\(rest)"
        case .declined:
            title = swapDeclinedTitle
            body = "\(name(toName)) ne peut pas prendre ton tour\(rest)"
        default:
            return nil
        }
        return notification(id: swapIdentifier(swapId), title: title, body: body, taskId: taskId, groupId: groupId)
    }

    // MARK: - Bravo (§4)

    /// « Camille a réagi 👏 à « Nettoyer le frigo » »; « … à ton activité » for an event without a task.
    public static func reactionBody(fromName: String?, emoji: ReactionEmoji, taskTitle: String?) -> String {
        "\(name(fromName)) a réagi \(emoji.rawValue) à " + (taskTitle.map(FrenchText.quoted) ?? "ton activité")
    }

    /// nil for the current user's own reaction.
    public static func reaction(
        activityId: Int64, groupId: UUID, taskId: UUID?, reactorId: UUID, currentUserId: UUID, fromName: String?,
        emoji: ReactionEmoji, taskTitle: String?
    ) -> LocalNotification? {
        guard reactorId != currentUserId else { return nil }
        var userInfo = ["groupId": groupId.uuidString]
        if let taskId { userInfo["taskId"] = taskId.uuidString }
        return LocalNotification(
            id: reactionIdentifier(activityId: activityId), title: reactionTitle,
            body: reactionBody(fromName: fromName, emoji: emoji, taskTitle: taskTitle), userInfo: userInfo,
            threadId: groupId.uuidString
        )
    }

    // MARK: - Commentaires (§5)

    /// A comment is notified to the current user when they are mentioned or assigned to the task, never for their own
    /// comments.
    public static func shouldNotify(authorId: UUID?, mentions: [UUID], currentUserId: UUID, isAssignee: Bool) -> Bool {
        authorId != currentUserId && (mentions.contains(currentUserId) || isAssignee)
    }

    /// Mentioned: « Camille te mentionne dans « Faire les courses » »; otherwise (an assignee): « Camille a commenté
    /// « Faire les courses » ».
    public static func commentTitle(authorName: String?, taskTitle: String?, isMention: Bool) -> String {
        let task = taskTitle.map(FrenchText.quoted) ?? "une tâche"
        return isMention ? "\(name(authorName)) te mentionne dans \(task)" : "\(name(authorName)) a commenté \(task)"
    }

    /// The comment, cut to 140 characters (« … » added).
    public static func commentBody(_ body: String) -> String {
        body.count > 140 ? String(body.prefix(139)) + "…" : body
    }

    /// nil when `shouldNotify(authorId:mentions:currentUserId:isAssignee:)` is false.
    public static func comment(
        commentId: UUID, taskId: UUID, groupId: UUID, authorId: UUID?, mentions: [UUID], currentUserId: UUID,
        isAssignee: Bool, authorName: String?, taskTitle: String?, body: String
    ) -> LocalNotification? {
        guard shouldNotify(authorId: authorId, mentions: mentions, currentUserId: currentUserId, isAssignee: isAssignee) else {
            return nil
        }
        return notification(
            id: commentIdentifier(commentId),
            title: commentTitle(authorName: authorName, taskTitle: taskTitle, isMention: mentions.contains(currentUserId)),
            body: commentBody(body), taskId: taskId, groupId: groupId
        )
    }

    // MARK: - Helpers

    private static func name(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return someone }
        return name
    }

    private static func notification(id: String, title: String, body: String, taskId: UUID, groupId: UUID) -> LocalNotification {
        LocalNotification(
            id: id, title: title, body: body,
            userInfo: ["taskId": taskId.uuidString, "groupId": groupId.uuidString], threadId: groupId.uuidString
        )
    }
}
