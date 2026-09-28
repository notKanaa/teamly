import Foundation
import Observation

/// A turn of the user that the absence hands over (docs/CONTRACTS-V3.md §2, « Tes tours pendant ce temps »).
public struct AwayHandover: Sendable, Hashable, Identifiable {
    public var taskId: UUID
    public var groupId: UUID
    public var title: String
    /// The occurrence's local due date.
    public var dueDay: LocalDate
    /// Who takes the turn: the next member of the rotation who is not away that day; nil when nobody else is listed
    /// (the user keeps it).
    public var taker: PersonBadge?
    /// « ven. 10 oct. → Lucas le fera », « ven. 10 oct. → tu le gardes ».
    public var text: String

    public init(taskId: UUID, groupId: UUID, title: String, dueDay: LocalDate, taker: PersonBadge?, text: String) {
        self.taskId = taskId
        self.groupId = groupId
        self.title = title
        self.dueDay = dueDay
        self.taker = taker
        self.text = text
    }

    public var id: UUID { taskId }
}

/// v3 « Mode absent » of the current user (docs/CONTRACTS-V3.md §2): the dates (both included), « Prévenir mes
/// groupes », the turns the absence hands over (computed like the server: the next member of each rotation who is not
/// away on the occurrence's local due date), then « Activer le mode absent », or, while an absence is set,
/// « Modifier mon absence » and « Terminer mon absence ».
///
/// `load()` reads the profile, the user's tasks (their pending turns) and the members of those tasks' groups (their
/// absences). `activate()` / `endAbsence()` set `resultMessage` for the screen below the sheet, which closes, and bump
/// every revision (turns move, the members show the absence).
@MainActor
@Observable
public final class AwayModeViewModel: ErrorPresenting {
    public static let title = "Mode absent"
    public static let message = "Pendant ton absence, tes tours passent automatiquement à la personne suivante."
    public static let fromTitle = "Du"
    public static let untilTitle = "Au"
    public static let announceTitle = "Prévenir mes groupes"
    public static let announceMessage = "Un message dans leur activité"
    public static let handoversTitle = "Tes tours pendant ce temps"
    public static let noHandoverText = "Aucun de tes tours ne tombe pendant ces dates."
    public static let activateTitle = "Activer le mode absent"
    public static let updateTitle = "Modifier mon absence"
    public static let endTitle = "Terminer mon absence"
    public static let endedMessage = "Mode absent terminé"

    /// The first day (a date of that day, in the injected calendar). A day after `untilDate` moves `untilDate` with it.
    public var fromDate: Date {
        get { fromDateValue }
        set {
            fromDateValue = newValue
            if untilDay < fromDay { untilDateValue = newValue }
        }
    }

    /// The last day (a date of that day). A day before `fromDate` moves `fromDate` with it.
    public var untilDate: Date {
        get { untilDateValue }
        set {
            untilDateValue = newValue
            if untilDay < fromDay { fromDateValue = newValue }
        }
    }

    /// « Prévenir mes groupes »: a `memberAway` event in each group of the user.
    public var announce = true
    /// The user's profile (their current absence), once loaded.
    public private(set) var profile: UserProfile?
    public private(set) var loadState: LoadState = .idle
    public private(set) var isSaving = false
    /// Set by `activate()` and `endAbsence()`: the sheet closes and the screen shows it (« Mode absent activé du 12 au
    /// 19 octobre »).
    public private(set) var resultMessage: String?
    public var error: ErrorState?

    public let session: SessionModel
    private var fromDateValue: Date
    private var untilDateValue: Date
    /// The user's pending turns with a due date.
    private var turnTasks: [TaskItem] = []
    private var membersByGroup: [UUID: [Membership]] = [:]

    /// Today, then the 6 days after it, until the profile says otherwise.
    public init(session: SessionModel) {
        self.session = session
        let calendar = session.platform.calendar
        let start = calendar.startOfDay(for: session.platform.now())
        fromDateValue = start
        untilDateValue = calendar.date(byAdding: .day, value: 6, to: start) ?? start.addingTimeInterval(6 * 86_400)
    }

    // MARK: - Loading

    /// Reads the profile, the user's turns and the members of their groups (once; `reload()` reads again).
    public func load() async {
        guard loadState != .loaded, loadState != .loading else { return }
        await reload()
    }

    public func reload() async {
        if loadState != .loaded { loadState = .loading }
        let services = session.services
        let me = session.userId
        let startOfToday = session.platform.calendar.startOfDay(for: session.platform.now())
        do {
            async let profileRequest = services.profiles.myProfile()
            async let tasksRequest = services.tasks.myTasks(doneSince: startOfToday)
            let (profile, tasks) = try await (profileRequest, tasksRequest)
            let turns = tasks.filter { task in
                task.status != .done && task.hasRotation && task.turnUserId == me && task.dueAt != nil
            }
            let groupIds = Array(Set(turns.map(\.groupId)))
            let members = try await withThrowingTaskGroup(
                of: (UUID, [Membership]).self,
                returning: [UUID: [Membership]].self
            ) { group in
                for groupId in groupIds {
                    group.addTask { (groupId, try await services.groups.members(groupId: groupId)) }
                }
                var result: [UUID: [Membership]] = [:]
                for try await (groupId, list) in group {
                    result[groupId] = list
                }
                return result
            }
            apply(profile)
            turnTasks = turns
            membersByGroup = members
            loadState = .loaded
        } catch {
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
    }

    /// Shows the profile's absence in the pickers when it is not over.
    private func apply(_ profile: UserProfile) {
        self.profile = profile
        guard let range = profile.awayRange, range.upperBound >= today else { return }
        let calendar = session.platform.calendar
        let from = max(range.lowerBound, today)
        if let fromDate = from.startDate(in: calendar), let untilDate = range.upperBound.startDate(in: calendar) {
            fromDateValue = fromDate
            untilDateValue = untilDate
        }
    }

    // MARK: - Dates

    /// Today in the injected calendar.
    public var today: LocalDate { LocalDate(session.platform.now(), calendar: session.platform.calendar) }

    public var fromDay: LocalDate { LocalDate(fromDateValue, calendar: session.platform.calendar) }
    public var untilDay: LocalDate { LocalDate(untilDateValue, calendar: session.platform.calendar) }

    /// The first date the pickers offer: today.
    public var earliestDate: Date { session.platform.calendar.startOfDay(for: session.platform.now()) }

    /// The last date « Au » offers: `Limits.awayRangeMaxDays` days from « Du », both counted.
    public var latestUntilDate: Date {
        let calendar = session.platform.calendar
        return calendar.date(byAdding: .day, value: Limits.awayRangeMaxDays - 1, to: calendar.startOfDay(for: fromDateValue))
            ?? fromDateValue.addingTimeInterval(TimeInterval(Limits.awayRangeMaxDays - 1) * 86_400)
    }

    /// « du 12 au 19 octobre ».
    public var rangeText: String { AwayText.range(from: fromDay, until: untilDay) }

    /// Why the dates cannot be saved (`InputValidation.awayRange`), nil when they can.
    public var rangeError: String? {
        do {
            try InputValidation.awayRange(
                from: fromDay, until: untilDay, today: InputValidation.serverToday(now: session.platform.now())
            )
            return nil
        } catch {
            return AppError.invalidAway.messageFR
        }
    }

    // MARK: - State

    /// An absence is set and not over (under way or to come).
    public var isAway: Bool { profile.map { AwayText.badge(for: $0, today: today) != nil } ?? false }

    /// « Absent·e jusqu’au 12 oct. », while an absence is set.
    public var currentAwayText: String? { profile.flatMap { AwayText.badge(for: $0, today: today) } }

    /// « Activer le mode absent », or « Modifier mon absence » while one is set.
    public var saveTitle: String { isAway ? Self.updateTitle : Self.activateTitle }

    public var canSave: Bool { loadState.isLoaded && !isSaving && rangeError == nil }

    // MARK: - The turns handed over

    /// The user's pending turns whose local due date falls in the dates, by date: who takes each of them.
    public var handovers: [AwayHandover] {
        let from = fromDay
        let until = untilDay
        guard from <= until else { return [] }
        let me = session.userId
        let calendar = session.platform.calendar
        let referenceYear = today.year
        var result: [AwayHandover] = []
        for task in turnTasks {
            guard let dueAt = task.dueAt else { continue }
            let day = LocalDate(dueAt, timeZone: task.recurrence?.timeZone ?? calendar.timeZone)
            guard from <= day, day <= until else { continue }
            let members = membersByGroup[task.groupId] ?? []
            let directory = MemberDirectory(members: members, currentUserId: me)
            let takerId = Self.taker(of: task, userId: me, members: members, day: day)
            let taker = takerId.map { directory.badge(of: $0) }
            let dayText = AwayText.shortWeekdayDay(day, referenceYear: referenceYear)
            let text = taker.map { "\(dayText) → \($0.shortName) le fera" } ?? "\(dayText) → tu le gardes"
            result.append(AwayHandover(
                taskId: task.id, groupId: task.groupId, title: task.title, dueDay: day, taker: taker, text: text
            ))
        }
        return result.sorted { lhs, rhs in
            lhs.dueDay != rhs.dueDay ? lhs.dueDay < rhs.dueDay : (NameOrder.precedes(lhs.title, rhs.title) ?? false)
        }
    }

    /// Who takes the user's turn on `day`, like the server's `set_away`: the next member after the user in the
    /// rotation who is not away that day; when every other member is away, the next member; nil when the rotation lists
    /// no other member.
    static func taker(of task: TaskItem, userId: UUID, members: [Membership], day: LocalDate) -> UUID? {
        let rotation = task.rotation
        guard let position = rotation.firstIndex(of: userId) else { return nil }
        var candidates: [UUID] = []
        for offset in 1..<max(rotation.count, 1) {
            let candidate = rotation[(position + offset) % rotation.count]
            guard candidate != userId, !candidates.contains(candidate),
                  members.contains(where: { $0.user.id == candidate })
            else { continue }
            candidates.append(candidate)
        }
        let isAway = { (candidate: UUID) -> Bool in
            members.first { $0.user.id == candidate }?.user.isAway(on: day) ?? false
        }
        return candidates.first { !isAway($0) } ?? candidates.first
    }

    // MARK: - Actions

    /// Sets the absence (announced to the groups when `announce`): `resultMessage` « Mode absent activé du 12 au 19
    /// octobre ». Refused dates set `error`.
    @discardableResult
    public func activate() async -> Bool {
        guard loadState.isLoaded, !isSaving else { return false }
        if let message = rangeError {
            present(message: message, error: .invalidAway)
            return false
        }
        error = nil
        isSaving = true
        defer { isSaving = false }
        let from = fromDay
        let until = untilDay
        do {
            let saved = try await session.services.profiles.setAway(from: from, until: until, announce: announce)
            profile = saved
            resultMessage = "Mode absent activé \(AwayText.range(from: from, until: until))"
            session.feed.bumpAll()
            return true
        } catch {
            present(error)
            return false
        }
    }

    /// Ends the absence (no turn moves back): `resultMessage` « Mode absent terminé ».
    @discardableResult
    public func endAbsence() async -> Bool {
        guard !isSaving else { return false }
        error = nil
        isSaving = true
        defer { isSaving = false }
        do {
            profile = try await session.services.profiles.clearAway()
            resultMessage = Self.endedMessage
            session.feed.bumpAll()
            return true
        } catch {
            present(error)
            return false
        }
    }
}
