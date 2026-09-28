import Foundation

// v3 presentation values shared by the view models (docs/CONTRACTS-V3.md): the confirmations shown for a few seconds,
// the wording of « Relancer » and « Échanger mon tour », the comment rows and their @mentions, the away texts of the
// members, the reaction chips and the size of an uploaded photo. Pure.

/// A short confirmation shown for a few seconds at the bottom of a screen (« Relance envoyée à Inès »). Every instance
/// is distinct (`id`): the same message twice shows twice.
public struct ToastNotice: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let message: String
    /// SF Symbols name drawn before the message.
    public let systemImage: String

    public init(_ message: String, systemImage: String = "checkmark") {
        id = UUID()
        self.message = message
        self.systemImage = systemImage
    }
}

// MARK: - Relancer (§1)

/// The wording of « Relancer » (docs/CONTRACTS-V3.md §1). Pure.
public enum NudgeText {
    /// The button once the task was nudged from the screen (a nudge per day at most).
    public static let doneTitle = "Relance envoyée"
    /// Under the button: why it is there.
    public static let hint = "Un rappel sympa, une fois par jour au plus."

    /// « Relancer Inès », « Relancer Inès et Lucas », « Relancer 3 personnes ».
    public static func buttonTitle(names: [String]) -> String {
        "Relancer \(people(names, count: names.count))"
    }

    /// « Relance envoyée à Inès », « Relance envoyée à Inès et Lucas », « Relance envoyée à 3 personnes ».
    /// - Parameter count: how many the server nudged (the names are the assignees seen by the screen: a different
    ///   count reads « 2 personnes »).
    public static func sentMessage(names: [String], count: Int) -> String {
        "Relance envoyée à \(people(names, count: count))"
    }

    /// « Inès », « Inès et Lucas », « 3 personnes »; « 2 personnes » when `count` is not the number of names.
    static func people(_ names: [String], count: Int) -> String {
        guard names.count == count else { return FrenchText.count(count, "personne", "personnes") }
        switch names.count {
        case 1: return names[0]
        case 2: return "\(names[0]) et \(names[1])"
        default: return FrenchText.count(count, "personne", "personnes")
        }
    }
}

// MARK: - Échanger mon tour (§3)

/// The wording of « Échanger mon tour » (docs/CONTRACTS-V3.md §3). Pure.
public enum TurnSwapText {
    /// The menu of the turn holder.
    public static let proposeTitle = "Proposer mon tour à…"
    public static let cancelTitle = "Annuler la proposition"
    public static let acceptTitle = "Accepter"
    public static let declineTitle = "Refuser"
    public static let cancelledMessage = "Proposition annulée"
    /// The title of the requests of « Mes tâches ».
    public static let requestsTitle = "Échanges de tour"

    /// « Proposition envoyée à Lucas ».
    public static func proposedMessage(to name: String) -> String {
        "Proposition envoyée à \(name)"
    }

    /// « En attente de la réponse de Lucas », « … d’Inès ».
    public static func waitingText(for name: String) -> String {
        "En attente de la réponse \(FrenchText.de(name))"
    }

    /// « **Lucas** te propose son tour pour « Ranger le matériel » »; « **Lucas** te propose son tour » without a title
    /// (on the task's own screen).
    public static func request(from name: String, taskTitle: String?) -> EmphasizedText {
        EmphasizedText([
            .init(name, isEmphasized: true),
            .init(" te propose son tour" + (taskTitle.map { " pour \(FrenchText.quoted($0))" } ?? "")),
        ])
    }

    /// After « Accepter »: « Tu prends le tour de Lucas », « … d’Inès ».
    public static func acceptedMessage(from name: String) -> String {
        "Tu prends le tour \(FrenchText.de(name))"
    }

    /// After « Refuser »: « Proposition de Lucas refusée ».
    public static func declinedMessage(from name: String) -> String {
        "Proposition \(FrenchText.de(name)) refusée"
    }
}

/// A turn proposed to the current user, ready to display: who proposes it, for which task, with « Accepter » and
/// « Refuser ».
public struct TurnSwapRequest: Sendable, Hashable, Identifiable {
    public var swap: TurnSwap
    /// Who proposes their turn.
    public var from: PersonBadge
    /// The task's title; nil on the task's own screen (or when the task could not be read).
    public var taskTitle: String?
    /// « Samedi à 19:00 », nil without due date.
    public var dueText: String?
    /// The group's name and badge, on « Mes tâches » only.
    public var groupName: String?
    public var groupAppearance: AvatarAppearance?

    public init(
        swap: TurnSwap,
        from: PersonBadge,
        taskTitle: String? = nil,
        dueText: String? = nil,
        groupName: String? = nil,
        groupAppearance: AvatarAppearance? = nil
    ) {
        self.swap = swap
        self.from = from
        self.taskTitle = taskTitle
        self.dueText = dueText
        self.groupName = groupName
        self.groupAppearance = groupAppearance
    }

    public var id: UUID { swap.id }
    public var taskId: UUID { swap.taskId }
    public var groupId: UUID { swap.groupId }

    /// « **Lucas** te propose son tour pour « Ranger le matériel » ».
    public var text: EmphasizedText { TurnSwapText.request(from: from.shortName, taskTitle: taskTitle) }
}

// MARK: - Commentaires (§5)

/// A comment of the task screen, ready to display.
public struct CommentRow: Sendable, Hashable, Identifiable {
    public var comment: TaskComment
    /// The author's badge; nil once their account is deleted.
    public var author: PersonBadge?
    /// « Lucas », « Toi », « Ancien membre ».
    public var authorName: String
    /// « Aujourd’hui à 14:32 ».
    public var timeText: String
    /// The text, its mentions emphasized (« **@Camille** tu peux… »).
    public var body: EmphasizedText
    public var isMine: Bool
    /// The author (still a member) or an admin.
    public var canDelete: Bool

    public init(
        comment: TaskComment,
        author: PersonBadge?,
        authorName: String,
        timeText: String,
        body: EmphasizedText,
        isMine: Bool,
        canDelete: Bool
    ) {
        self.comment = comment
        self.author = author
        self.authorName = authorName
        self.timeText = timeText
        self.body = body
        self.isMine = isMine
        self.canDelete = canDelete
    }

    public var id: UUID { comment.id }
}

/// The @mentions of the comments (docs/CONTRACTS-V3.md §5): what is being typed after « @ », the members it may name,
/// and the members a text mentions. A mention is « @ » followed by a member's short name (`MemberDirectory.shortNames`),
/// compared without case nor accents, and not followed by a letter or a digit. Pure.
public enum MentionText {
    /// Suggestions shown at most.
    public static let suggestionsMax = 5

    /// The mention being typed at the end of `text`: what follows its last « @ » when that « @ » starts a word and no
    /// space follows it (« » right after « @ »); nil otherwise.
    public static func query(in text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        if at != text.startIndex, !text[text.index(before: at)].isWhitespace {
            return nil
        }
        let rest = text[text.index(after: at)...]
        guard !rest.contains(where: { $0.isWhitespace }), rest.count <= 40 else { return nil }
        return String(rest)
    }

    /// The members whose short name starts with `query` (without case nor accents), the current user and former
    /// members excepted, in the order given, at most `suggestionsMax`.
    public static func suggestions(for query: String, people: [PersonBadge]) -> [PersonBadge] {
        let key = folded(query)
        return Array(people.filter { person in
            person.isMember && !person.isMe && folded(person.shortName).hasPrefix(key)
        }.prefix(suggestionsMax))
    }

    /// `text` with the mention being typed (`query(in:)`) replaced by « @Short name » and a space; `text` and the
    /// mention when nothing is being typed.
    public static func completing(_ text: String, with person: PersonBadge) -> String {
        let mention = "@\(person.shortName) "
        guard query(in: text) != nil, let at = text.lastIndex(of: "@") else {
            let separator = text.isEmpty || text.last?.isWhitespace == true ? "" : " "
            return text + separator + mention
        }
        return String(text[..<at]) + mention
    }

    /// The members `body` mentions, in the order of their first mention, each once.
    public static func mentions(in body: String, people: [PersonBadge]) -> [UUID] {
        var ids: [UUID] = []
        for match in matches(in: body, people: people) where !ids.contains(match.person.id) {
            ids.append(match.person.id)
        }
        return ids
    }

    /// `body` with its mentions (« @Camille ») emphasized.
    public static func emphasized(_ body: String, people: [PersonBadge]) -> EmphasizedText {
        let characters = Array(body)
        var runs: [EmphasizedText.Run] = []
        var position = 0
        for match in matches(in: body, people: people) {
            if match.start > position {
                runs.append(.init(String(characters[position..<match.start])))
            }
            runs.append(.init(String(characters[match.start..<match.end]), isEmphasized: true))
            position = match.end
        }
        if position < characters.count {
            runs.append(.init(String(characters[position...])))
        }
        return EmphasizedText(runs)
    }

    /// The mentions of `body`, in order: character offsets of « @Name » and the member named (the longest name wins
    /// when two short names start alike).
    static func matches(in body: String, people: [PersonBadge]) -> [(start: Int, end: Int, person: PersonBadge)] {
        let characters = Array(body)
        let candidates = people
            .filter { $0.isMember && !$0.shortName.isEmpty }
            .sorted { $0.shortName.count > $1.shortName.count }
        var result: [(start: Int, end: Int, person: PersonBadge)] = []
        var index = 0
        while index < characters.count {
            guard characters[index] == "@", index == 0 || characters[index - 1].isWhitespace else {
                index += 1
                continue
            }
            var found: (end: Int, person: PersonBadge)?
            for person in candidates {
                let name = Array(person.shortName)
                let end = index + 1 + name.count
                guard end <= characters.count else { continue }
                let typed = String(characters[(index + 1)..<end])
                guard folded(typed) == folded(person.shortName) else { continue }
                if end < characters.count, characters[end].isLetter || characters[end].isNumber {
                    continue
                }
                found = (end, person)
                break
            }
            if let found {
                result.append((index, found.end, found.person))
                index = found.end
            } else {
                index += 1
            }
        }
        return result
    }

    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
    }
}

// MARK: - Mode absent (§2)

extension MemberDirectory {
    /// v3: the away badge of a member on `today` (`AwayText.badge(for:today:)`): « Absent·e jusqu’au 12 oct. »; nil
    /// when they are not away (any more), or not a member.
    public func awayBadge(of userId: UUID?, today: LocalDate) -> String? {
        guard let userId, let member = members.first(where: { $0.user.id == userId }) else { return nil }
        return AwayText.badge(for: member.user, today: today)
    }
}

extension AwayText {
    /// Short weekday names, indexed by ISO weekday − 1 (Monday first).
    public static let shortWeekdayNames = ["lun.", "mar.", "mer.", "jeu.", "ven.", "sam.", "dim."]

    /// « ven. 10 oct. », « lun. 4 janv. 2027 » (the year when it is not `referenceYear`).
    public static func shortWeekdayDay(_ date: LocalDate, referenceYear: Int?) -> String {
        let weekday = shortWeekdayNames[((date.isoWeekday - 1) % 7 + 7) % 7]
        return "\(weekday) \(shortDay(date, referenceYear: referenceYear))"
    }
}

// MARK: - Bravo (§4)

extension ReactionSummary {
    /// VoiceOver's value of a chip: « 2 réactions, dont la tienne », « 1 réaction ».
    public var accessibilityValue: String {
        FrenchText.count(count, "réaction", "réactions") + (includesMe ? ", dont la tienne" : "")
    }
}

// MARK: - Photo preuve (§6)

/// The pixel size of a photo as uploaded (docs/CONTRACTS-V3.md §6): its longest side brought down to
/// `Limits.photoLongestSide` pixels, the ratio kept, never enlarged. Pure.
public struct PhotoPixelSize: Sendable, Hashable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// The size of a `width` × `height` photo once resized: unchanged when its longest side is at most `longestSide`,
    /// else scaled down (rounded, at least 1 pixel a side).
    public static func resized(width: Int, height: Int, longestSide: Int = Limits.photoLongestSide) -> PhotoPixelSize {
        let longest = max(width, height)
        guard longest > longestSide, longestSide > 0 else {
            return PhotoPixelSize(width: max(1, width), height: max(1, height))
        }
        let scale = Double(longestSide) / Double(longest)
        return PhotoPixelSize(
            width: max(1, Int((Double(width) * scale).rounded())),
            height: max(1, Int((Double(height) * scale).rounded()))
        )
    }
}

/// The wording of the photos of a task (docs/CONTRACTS-V3.md §6). Pure.
public enum PhotoText {
    public static let title = "Photos"
    public static let addTitle = "Ajouter une photo"
    public static let libraryTitle = "Choisir dans la photothèque"
    public static let cameraTitle = "Prendre une photo"
    public static let addedMessage = "Photo ajoutée"
    public static let deletedMessage = "Photo supprimée"
    public static let deleteTitle = "Supprimer la photo"
    /// The light prompt after the user completed the task.
    public static let promptTitle = "Ajouter une photo\u{00A0}?"
    public static let promptMessage = "Montre le travail fait au groupe."
    public static let promptDismissTitle = "Non merci"
    /// Shown when no photo was added yet.
    public static let emptyText = "Aucune photo pour l’instant."

    /// « 1 photo », « 3 photos sur 5 » once near the limit.
    public static func countText(_ count: Int) -> String {
        count >= Limits.photosPerTaskMax - 1
            ? "\(count) sur \(Limits.photosPerTaskMax)"
            : FrenchText.count(count, "photo", "photos")
    }

    /// « Photo 2 sur 3, ajoutée par Camille ».
    public static func accessibilityLabel(index: Int, count: Int, uploaderName: String?) -> String {
        let base = "Photo \(index + 1) sur \(count)"
        guard let uploaderName else { return base }
        return "\(base), ajoutée par \(uploaderName)"
    }
}

/// The wording of the comments (docs/CONTRACTS-V3.md §5). Pure.
public enum CommentText {
    public static let title = "Commentaires"
    public static let placeholder = "Écrire un commentaire…"
    public static let sendTitle = "Envoyer"
    public static let deleteTitle = "Supprimer le commentaire"
    public static let emptyText = "Pas encore de commentaire. Mentionne quelqu’un avec @."

    /// « 2 commentaires », « 1 commentaire ».
    public static func countText(_ count: Int) -> String {
        FrenchText.count(count, "commentaire", "commentaires")
    }
}
