import Foundation

/// A short French text whose people are emphasized, e.g. « **Lucas** a terminé « Nettoyer la cuisine » »: the view
/// draws the emphasized runs in bold; `plainText` is the whole sentence (accessibility).
public struct EmphasizedText: Sendable, Hashable {
    public struct Run: Sendable, Hashable {
        public var text: String
        public var isEmphasized: Bool

        public init(_ text: String, isEmphasized: Bool = false) {
            self.text = text
            self.isEmphasized = isEmphasized
        }
    }

    public var runs: [Run]

    public init(_ runs: [Run]) {
        self.runs = runs
    }

    /// The whole text, without emphasis.
    public var plainText: String { runs.map(\.text).joined() }

    /// The emphasized parts, in order.
    public var emphasized: [String] { runs.filter(\.isEmphasized).map(\.text) }
}

/// French wording of the activity feed (docs/CONTRACTS-V2.md §7). Pure.
///
/// People are « Tu » for the current user, the short name given by `names` for a current member (see
/// `MemberDirectory.shortNames`), and « Un ancien membre » for anyone else: someone who left, or a nil id (a deleted
/// account). `member_left` has three cases: a member who left (« Lucas a quitté le groupe »), a member removed by
/// someone (« Camille a retiré Lucas du groupe »), and a deleted account (« Un membre a supprimé son compte »).
public enum ActivityText {
    /// Someone the app does not know (any more), at the start of a sentence.
    public static let formerMember = "Un ancien membre"
    /// The author of an account deletion.
    public static let deletedAccountMember = "Un membre"

    /// The sentence of one event, its people emphasized.
    public static func text(for event: ActivityEvent, currentUserId: UUID, names: [UUID: String]) -> EmphasizedText {
        let actor = Person(event.actorId, me: currentUserId, names: names)
        let task = event.taskTitle.map(FrenchText.quoted)
        switch event.kind {
        case .taskCreated:
            return sentence(actor, "créé", " " + (task ?? "une tâche"))
        case .taskCompleted:
            return sentence(actor, "terminé", " " + (task ?? "une tâche"))
        case .checklistItemDone:
            switch (event.itemTitle.map(FrenchText.quoted), task) {
            case let (item?, task?): return sentence(actor, "coché", " \(item) dans \(task)")
            case let (item?, nil): return sentence(actor, "coché", " \(item)")
            case let (nil, task?): return sentence(actor, "coché un élément de", " \(task)")
            case (nil, nil): return sentence(actor, "coché", " un élément")
            }
        case .turnStarted:
            let holder = Person(event.subjectId, me: currentUserId, names: names)
            let rest = task.map { " pour \($0)" } ?? ""
            if holder.isMe {
                return EmphasizedText([.init("C’est "), .init("ton tour", isEmphasized: true), .init(rest)])
            }
            let name = holder.objectForm
            return EmphasizedText([
                .init("C’est au tour " + FrenchText.dePrefix(before: name)),
                .init(name, isEmphasized: true),
                .init(rest),
            ])
        case .memberJoined:
            let member = Person(event.subjectId ?? event.actorId, me: currentUserId, names: names)
            return sentence(member, "rejoint", " le groupe")
        case .memberLeft:
            return memberLeft(event, currentUserId: currentUserId, names: names)
        }
    }

    /// Title of a day of the feed: « Aujourd’hui », « Hier », then « Lundi 21 septembre » (with the year when it is
    /// not the year of `now`), in `calendar`'s time zone. A later day (a device clock behind the server) reads
    /// « Aujourd’hui ».
    public static func dayTitle(of date: Date, now: Date, calendar: Calendar) -> String {
        let formatter = FrenchDateFormatter(timeZone: calendar.timeZone)
        switch formatter.dayOffset(of: date, from: now) {
        case 0...:
            return "Aujourd’hui"
        case -1:
            return "Hier"
        default:
            let sameYear = formatter.calendar.component(.year, from: date) == formatter.calendar.component(.year, from: now)
            return FrenchDateFormatter.capitalizingFirstLetter(formatter.day(date, includeYear: !sameYear))
        }
    }

    // MARK: - Sentences

    /// A person of an event.
    private enum Person {
        case me
        case member(String)
        case former

        init(_ id: UUID?, me: UUID, names: [UUID: String]) {
            guard let id else {
                self = .former
                return
            }
            if id == me {
                self = .me
            } else if let name = names[id], !name.isEmpty {
                self = .member(name)
            } else {
                self = .former
            }
        }

        var isMe: Bool {
            if case .me = self { return true }
            return false
        }

        /// At the start of a sentence: « Tu », « Lucas », « Un ancien membre ».
        var subjectForm: String {
            switch self {
            case .me: "Tu"
            case let .member(name): name
            case .former: ActivityText.formerMember
            }
        }

        /// Inside a sentence: « toi », « Lucas », « un ancien membre ».
        var objectForm: String {
            switch self {
            case .me: "toi"
            case let .member(name): name
            case .former: "un ancien membre"
            }
        }
    }

    /// « Tu as créé … », « Lucas a créé … »: the subject emphasized, then the verb in the passé composé.
    private static func sentence(_ subject: Person, _ participle: String, _ rest: String) -> EmphasizedText {
        EmphasizedText([
            .init(subject.subjectForm, isEmphasized: true),
            .init(" \(subject.isMe ? "as" : "a") \(participle)\(rest)"),
        ])
    }

    /// `member_left`: `actor` = who did it, `subject` = the member; both nil for a deleted account.
    private static func memberLeft(_ event: ActivityEvent, currentUserId: UUID, names: [UUID: String]) -> EmphasizedText {
        switch (event.actorId, event.subjectId) {
        case (nil, nil):
            return EmphasizedText([.init(deletedAccountMember, isEmphasized: true), .init(" a supprimé son compte")])
        case let (actorId?, subjectId?) where actorId == subjectId:
            return sentence(Person(subjectId, me: currentUserId, names: names), "quitté", " le groupe")
        case let (nil, subjectId?):
            // Removed by someone whose account was deleted since (or by a trusted context).
            return sentence(Person(subjectId, me: currentUserId, names: names), "été retiré", " du groupe")
        case let (actorId?, subjectId):
            let actor = Person(actorId, me: currentUserId, names: names)
            let subject = Person(subjectId, me: currentUserId, names: names)
            if subject.isMe {
                return EmphasizedText([.init(actor.subjectForm, isEmphasized: true), .init(" t’a retiré du groupe")])
            }
            return EmphasizedText([
                .init(actor.subjectForm, isEmphasized: true),
                .init(" \(actor.isMe ? "as" : "a") retiré "),
                .init(subject.objectForm, isEmphasized: true),
                .init(" du groupe"),
            ])
        }
    }
}

/// French wording of the weekly recap card (docs/CONTRACTS-V2.md §8). Pure.
public enum RecapText {
    public static let title = "Cette semaine"
    /// Shown when nothing was done this week.
    public static let emptyMessage = "Aucune tâche terminée cette semaine pour l’instant."

    /// The week of the recap: « Du lundi 21 au dimanche 27 septembre », « Du lundi 28 septembre au dimanche
    /// 4 octobre », « Du lundi 29 décembre 2025 au dimanche 4 janvier 2026 », in `calendar`'s time zone.
    /// - Parameter weekEnd: the exclusive end of the week (the next Monday 00:00, `WeeklyRecap.weekEnd`).
    public static func range(weekStart: Date, weekEnd: Date, calendar: Calendar) -> String {
        let french = Calendar.frenchGregorian(timeZone: calendar.timeZone)
        let sunday = french.date(byAdding: .day, value: -1, to: weekEnd) ?? weekEnd.addingTimeInterval(-86_400)
        let start = french.dateComponents([.weekday, .day, .month, .year], from: weekStart)
        let end = french.dateComponents([.weekday, .day, .month, .year], from: sunday)
        let from = "\(weekdayName(start)) \(dayNumber(start))"
        let to = "\(weekdayName(end)) \(dayNumber(end)) \(monthName(end))"
        if start.year != end.year {
            return "Du \(from) \(monthName(start)) \(start.year ?? 0) au \(to) \(end.year ?? 0)"
        }
        if start.month != end.month {
            return "Du \(from) \(monthName(start)) au \(to)"
        }
        return "Du \(from) au \(to)"
    }

    /// The label under the total: « tâches faites », « tâche faite » (0 and 1).
    public static func totalLabel(_ total: Int) -> String {
        FrenchText.isSingular(total) ? "tâche faite" : "tâches faites"
    }

    /// A place of the podium: « 1re », « 2e », « 3e ».
    public static func place(_ place: Int) -> String {
        FrenchText.ordinal(place)
    }

    /// « Inès mène pour la 3e semaine d’affilée. » / « Tu mènes pour la 3e semaine d’affilée. », the leader
    /// emphasized.
    public static func streak(name: String, isMe: Bool, weeks: Int) -> EmphasizedText {
        let week = "pour la \(FrenchText.ordinal(weeks)) semaine d’affilée."
        return EmphasizedText([
            .init(isMe ? "Tu" : name, isEmphasized: true),
            .init(isMe ? " mènes \(week)" : " mène \(week)"),
        ])
    }

    private static func weekdayName(_ components: DateComponents) -> String {
        FrenchDateFormatter.weekdayNames[((components.weekday ?? 1) - 1 + 7) % 7]
    }

    private static func dayNumber(_ components: DateComponents) -> String {
        let day = components.day ?? 1
        return day == 1 ? "1er" : "\(day)"
    }

    private static func monthName(_ components: DateComponents) -> String {
        FrenchDateFormatter.monthNames[((components.month ?? 1) - 1 + 12) % 12]
    }
}
