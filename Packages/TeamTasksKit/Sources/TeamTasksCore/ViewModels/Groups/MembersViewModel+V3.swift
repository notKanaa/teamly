import Foundation

// v3 « Mode absent » on « Membres » (docs/CONTRACTS-V3.md §2): the away badges of the members, and the entry of the
// current user's own « Mode absent » (until Réglages has one).
extension MembersViewModel {
    /// The date of the badges: today in the injected calendar.
    public var today: LocalDate { LocalDate(session.platform.now(), calendar: session.platform.calendar) }

    /// « Absent·e jusqu’au 12 oct. », « Absent·e du 12 au 19 oct. »; nil when the member is not away.
    public func awayText(of member: Membership) -> String? {
        AwayText.badge(for: member.user, today: today)
    }

    /// The current user's badge, nil when they are not away.
    public var myAwayText: String? {
        members.first { isMe($0) }.flatMap { awayText(of: $0) }
    }

    /// The « Mode absent » sheet of the current user.
    public func makeAwayModeModel() -> AwayModeViewModel {
        AwayModeViewModel(session: session)
    }
}
