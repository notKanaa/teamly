import Foundation
import Observation

/// One event of the activity feed, ready to display.
public struct ActivityFeedRow: Sendable, Hashable, Identifiable {
    public var event: ActivityEvent
    /// « **Lucas** a terminé « Nettoyer la cuisine » » (`ActivityText`): draw the emphasized runs in bold.
    public var text: EmphasizedText
    /// « 14:32 ».
    public var timeText: String
    /// The member the event is about (who acted; the turn holder of `turnStarted`; the member who joined), with
    /// their avatar; nil when it is not a current member: draw `systemImage` instead.
    public var person: PersonBadge?
    /// v3: the « Bravo » chips, one per emoji used (« 👏 2 »), highlighted when the user is among them.
    public var reactions: [ReactionSummary]
    /// v3: the secondary line (the excerpt of a comment, `ActivityText.detail(for:)`).
    public var detail: String?

    public init(
        event: ActivityEvent,
        text: EmphasizedText,
        timeText: String,
        person: PersonBadge?,
        reactions: [ReactionSummary] = [],
        detail: String? = nil
    ) {
        self.event = event
        self.text = text
        self.timeText = timeText
        self.person = person
        self.reactions = reactions
        self.detail = detail
    }

    public var id: Int64 { event.id }
    /// The event's v2 kind; `.taskCreated` for a v3 kind (the feed shows them since v3): draw with `activityKind`.
    public var kind: ActivityEvent.Kind { ActivityEvent.Kind(event.kind) ?? .taskCreated }
    /// v3: the event's kind, v3 kinds included.
    public var activityKind: ActivityKind { event.kind }
    public var systemImage: String { event.kind.systemImage }
    /// The task concerned (it may have been deleted since): `AppRoute.task(groupId:taskId:)`.
    public var taskId: UUID? { event.taskId }
}

/// The events of one day, newest first.
public struct ActivityFeedSection: Sendable, Hashable, Identifiable {
    /// « Aujourd’hui », « Hier », « Lundi 21 septembre » (`ActivityText.dayTitle`).
    public var title: String
    public var rows: [ActivityFeedRow]

    public init(title: String, rows: [ActivityFeedRow]) {
        self.title = title
        self.rows = rows
    }

    public var id: String { title }
}

/// A member of the weekly podium.
public struct PodiumEntry: Sendable, Hashable, Identifiable {
    public var person: PersonBadge
    /// Tasks done this week.
    public var count: Int
    /// 1, 2 or 3; members with the same count share a place.
    public var place: Int

    public init(person: PersonBadge, count: Int, place: Int) {
        self.person = person
        self.count = count
        self.place = place
    }

    public var id: UUID { person.id }
    /// « 1re », « 2e », « 3e ».
    public var placeText: String { RecapText.place(place) }
}

/// « Activité » tab of a group (docs/CONTRACTS-V2.md §7, §8), for every member: the weekly recap (the week's range,
/// the total done, the podium, the streak) and the feed of the last `Limits.activityFeedMax` events, by day.
///
/// v3 (docs/CONTRACTS-V3.md §4, §7): the feed has every kind, the v3 ones included (nudges, absences, swaps, comments
/// with their excerpt, photos), and the « Bravo » reactions of each event (`ActivityFeedRow.reactions`), toggled at
/// once by `toggleReaction(_:on:)` and put back when the server refuses.
///
/// Reads, in parallel, at each load: `GroupService.activity(groupId:)`, `TaskService.completions(groupId:since:)`
/// from `WeeklyRecap.readStart(now:calendar:)`, and `GroupService.members(groupId:)` (names and avatars).
/// Reloads when the group's revision changes (every event comes with a group signal).
/// View: `.task(id: model.refreshKey) { await model.load() }`, `.refreshable { await model.reload() }`; leave the
/// group's screens when `isGone` becomes true.
@MainActor
@Observable
public final class GroupActivityViewModel: ErrorPresenting {
    public static let feedTitle = "Fil d’activité"
    public static let emptyFeedMessage = "Rien pour l’instant\u{00A0}: les tâches créées et terminées apparaîtront ici."
    public static let goneMessage = GroupDetailViewModel.goneMessage

    public let groupId: UUID
    /// The feed, newest first.
    public private(set) var events: [ActivityEvent] = []
    public private(set) var members: [Membership] = []
    public private(set) var recap: WeeklyRecap?
    public private(set) var loadState: LoadState = .idle
    /// The user is no longer a member (or the group was deleted).
    public private(set) var isGone = false
    /// Date of the day titles and of the recap's week (refreshed at every load).
    public private(set) var referenceDate: Date
    public var error: ErrorState?

    /// v3: the reactions being saved, by `reactionKey(eventId:emoji:)`: whether the user's reaction is shown. A load
    /// that ends meanwhile keeps them as shown.
    public private(set) var pendingReactions: [String: Bool] = [:]

    public let session: SessionModel
    private let runner = LoadRunner()
    private var loadedRevision: Int?
    private var fetchingRevision: Int?

    public init(session: SessionModel, groupId: UUID) {
        self.session = session
        self.groupId = groupId
        referenceDate = session.platform.now()
    }

    // MARK: - Loading

    public var refreshKey: RefreshKey { RefreshKey(revision: session.feed.groupRevision(groupId)) }

    public var needsRefresh: Bool { loadState != .loaded || loadedRevision != refreshKey.revision }

    public func load() async {
        guard needsRefresh, !isGone else { return }
        let upToDate = runner.isRunning && fetchingRevision == refreshKey.revision
        await runner.run(rerunIfRunning: !upToDate) { [weak self] in await self?.fetch() }
    }

    public func reload() async {
        guard !isGone else { return }
        await runner.run(rerunIfRunning: true) { [weak self] in await self?.fetch() }
    }

    private func fetch() async {
        guard !isGone else { return }
        let revision = refreshKey.revision
        fetchingRevision = revision
        defer { fetchingRevision = nil }
        if loadState != .loaded { loadState = .loading }
        let groupService = session.services.groups
        let taskService = session.services.tasks
        let groupId = groupId
        let now = session.platform.now()
        let calendar = session.platform.calendar
        let since = WeeklyRecap.readStart(now: now, calendar: calendar)
        do {
            async let eventsRequest = groupService.activity(groupId: groupId)
            async let completionsRequest = taskService.completions(groupId: groupId, since: since)
            async let membersRequest = groupService.members(groupId: groupId)
            let (events, completions, members) = try await (eventsRequest, completionsRequest, membersRequest)
            // Non-members read empty lists (RLS).
            guard members.contains(where: { $0.user.id == session.userId }) else {
                markGone()
                return
            }
            // v3: every kind this client knows (the adapters leave the unknown ones out), with the reactions being
            // saved as the user set them.
            self.events = events.sorted { $0.id > $1.id }.map { withPendingReactions($0) }
            self.members = members
            recap = WeeklyRecap(completions: completions, members: members, now: now, calendar: calendar)
            referenceDate = now
            loadedRevision = revision
            loadState = .loaded
        } catch {
            handleLoadFailure(error)
        }
    }

    private func markGone() {
        isGone = true
        if loadState != .loaded { loadState = .loaded }
    }

    private func handleLoadFailure(_ error: any Error) {
        guard let state = ErrorState(from: error) else {
            if loadState == .loading { loadState = .idle }
            return
        }
        if loadState == .loaded {
            self.error = state
        } else {
            loadState = .failed(state.message)
        }
    }

    // MARK: - Feed

    public var directory: MemberDirectory {
        MemberDirectory(members: members, currentUserId: session.userId)
    }

    /// The feed by day, newest first.
    public var sections: [ActivityFeedSection] {
        let directory = directory
        let shortNames = directory.shortNames
        let calendar = session.platform.calendar
        let formatter = FrenchDateFormatter(timeZone: calendar.timeZone)
        let me = session.userId
        var sections: [ActivityFeedSection] = []
        var indexByTitle: [String: Int] = [:]
        for event in events {
            let row = ActivityFeedRow(
                event: event,
                text: ActivityText.text(for: event, currentUserId: me, names: shortNames),
                timeText: formatter.time(event.createdAt),
                person: Self.personId(of: event).flatMap { id in
                    let badge = directory.badge(of: id, shortNames: shortNames)
                    return badge.isMember ? badge : nil
                },
                reactions: event.reactionSummaries(currentUserId: me),
                detail: ActivityText.detail(for: event)
            )
            let title = ActivityText.dayTitle(of: event.createdAt, now: referenceDate, calendar: calendar)
            if let index = indexByTitle[title] {
                sections[index].rows.append(row)
            } else {
                indexByTitle[title] = sections.count
                sections.append(ActivityFeedSection(title: title, rows: [row]))
            }
        }
        return sections
    }

    /// Loaded, without any event.
    public var isFeedEmpty: Bool { loadState == .loaded && events.isEmpty }

    /// Who an event is about: the actor, the turn holder of `turnStarted`, the member of the member events; v3: the
    /// actor (who nudged, who took the turn, the author), the member of `memberAway`.
    static func personId(of event: ActivityEvent) -> UUID? {
        switch event.kind {
        case .taskCreated, .taskCompleted, .checklistItemDone: event.actorId
        case .turnStarted, .memberLeft: event.subjectId
        case .memberJoined, .memberAway: event.subjectId ?? event.actorId
        case .taskNudged, .turnSwapped, .commentAdded, .photoAdded: event.actorId
        }
    }

    // MARK: - Weekly recap

    public static let recapTitle = RecapText.title

    /// « Du lundi 21 au dimanche 27 septembre ».
    public var recapRangeText: String? {
        recap.map { RecapText.range(weekStart: $0.weekStart, weekEnd: $0.weekEnd, calendar: session.platform.calendar) }
    }

    /// Tasks done this week in the group (by anyone).
    public var recapTotal: Int { recap?.total ?? 0 }

    /// « tâches faites » / « tâche faite », under the total.
    public var recapTotalLabel: String { RecapText.totalLabel(recapTotal) }

    /// Nothing done this week: show `RecapText.emptyMessage` instead of the podium.
    public var isRecapEmpty: Bool { recapTotal == 0 }

    /// The podium, first place first (at most 3 members; ties share a place).
    public var podium: [PodiumEntry] {
        guard let recap else { return [] }
        let directory = directory
        let shortNames = directory.shortNames
        return recap.podium.map { entry in
            let place = 1 + recap.podium.filter { $0.count > entry.count }.count
            return PodiumEntry(person: directory.badge(of: entry.user.id, shortNames: shortNames), count: entry.count, place: place)
        }
    }

    /// The podium in stage order, the first place in the middle: 2nd, 1st, 3rd.
    public var podiumStageOrder: [PodiumEntry] {
        let entries = podium
        switch entries.count {
        case 3: return [entries[1], entries[0], entries[2]]
        case 2: return [entries[1], entries[0]]
        default: return entries
        }
    }

    /// « Inès mène pour la 3e semaine d’affilée. », nil without a streak of at least 2 weeks.
    public var streakText: EmphasizedText? {
        guard let streak = recap?.streak else { return nil }
        let userId = streak.user.id
        return RecapText.streak(name: directory.shortName(of: userId), isMe: userId == session.userId, weeks: streak.weeks)
    }

    // MARK: - Bravo (v3)

    /// Every member may react to the events of the feed.
    public var canReact: Bool { GroupPermissions.canReact(role: directory.myRole) }

    /// The key of `pendingReactions`.
    public static func reactionKey(eventId: Int64, emoji: ReactionEmoji) -> String {
        "\(eventId)-\(emoji.rawValue)"
    }

    /// True when the user reacted `emoji` to the event (as shown).
    public func hasReacted(_ emoji: ReactionEmoji, to eventId: Int64) -> Bool {
        events.first { $0.id == eventId }?.reactions.contains { $0.userId == session.userId && $0.emoji == emoji } ?? false
    }

    /// Adds the user's reaction `emoji` to the event, or removes it: shown at once, saved, and put back as it was when
    /// the server refuses (`error` then says why). A toggle of the same emoji while one is being saved is ignored.
    @discardableResult
    public func toggleReaction(_ emoji: ReactionEmoji, on eventId: Int64) async -> Bool {
        guard canReact else {
            present(AppError.forbidden)
            return false
        }
        let key = Self.reactionKey(eventId: eventId, emoji: emoji)
        guard pendingReactions[key] == nil, events.contains(where: { $0.id == eventId }) else { return false }
        error = nil
        let wasShown = hasReacted(emoji, to: eventId)
        pendingReactions[key] = !wasShown
        setReaction(emoji, on: eventId, shown: !wasShown)
        defer { pendingReactions[key] = nil }
        do {
            let added = try await session.services.groups.toggleReaction(activityId: eventId, emoji: emoji)
            // The server's answer wins (another device may have toggled it meanwhile).
            setReaction(emoji, on: eventId, shown: added)
            return true
        } catch {
            setReaction(emoji, on: eventId, shown: wasShown)
            if present(error) == .notFound {
                // The event is gone (the 90-day retention) or the user left: the reload says which.
                session.feed.bump(groupId: groupId)
            }
            return false
        }
    }

    /// Shows or hides the user's reaction `emoji` on an event.
    private func setReaction(_ emoji: ReactionEmoji, on eventId: Int64, shown: Bool) {
        guard let index = events.firstIndex(where: { $0.id == eventId }) else { return }
        events[index] = Self.event(events[index], with: emoji, by: session.userId, shown: shown)
    }

    /// A loaded event with the reactions being saved as the user set them.
    private func withPendingReactions(_ event: ActivityEvent) -> ActivityEvent {
        var event = event
        for emoji in ReactionEmoji.allCases {
            if let shown = pendingReactions[Self.reactionKey(eventId: event.id, emoji: emoji)] {
                event = Self.event(event, with: emoji, by: session.userId, shown: shown)
            }
        }
        return event
    }

    private static func event(_ event: ActivityEvent, with emoji: ReactionEmoji, by userId: UUID, shown: Bool) -> ActivityEvent {
        var event = event
        var reactions = event.reactions.filter { !($0.userId == userId && $0.emoji == emoji) }
        if shown {
            reactions.append(ActivityReaction(userId: userId, emoji: emoji))
        }
        event.reactions = ActivityReaction.sorted(reactions)
        return event
    }
}
