import Foundation
import TeamTasksCore

/// One PostgREST request, described verbatim (path and ordered query parameters, as written in
/// docs/CONTRACTS.md §4.3) before percent-encoding and authentication.
struct RestRequest: Sendable, Hashable {
    enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
        case patch = "PATCH"
    }

    struct QueryItem: Sendable, Hashable {
        let name: String
        let value: String
    }

    var method: Method
    /// Relative to `/rest/v1/`, e.g. `group_members` or `rpc/create_group`.
    var path: String
    var query: [QueryItem]
    var body: JSONValue?
    /// `Prefer` header (e.g. `return=representation`).
    var prefer: String?

    init(method: Method = .get, path: String, query: [QueryItem] = [], body: JSONValue? = nil, prefer: String? = nil) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.prefer = prefer
    }

    /// `name=value&…` without percent-encoding: the form used in docs/CONTRACTS.md.
    var readableQuery: String {
        query.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
    }

    /// `path?query` with every character outside `RestRequest.queryAllowed` percent-encoded (a `+` in a
    /// timestamp would otherwise read as a space).
    var encodedPathAndQuery: String {
        guard !query.isEmpty else { return path }
        let encoded = query.map { item in
            "\(RestRequest.percentEncoded(item.name))=\(RestRequest.percentEncoded(item.value))"
        }
        return path + "?" + encoded.joined(separator: "&")
    }

    /// Characters left as is in query names and values: RFC 3986 unreserved characters plus the PostgREST
    /// syntax characters `* , : ( ) !`. Everything else (`+`, space, `&`, `=`, `#`, `%`, non-ASCII…) is encoded.
    static let queryAllowed: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~*,:()!")
        return set
    }()

    static func percentEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? value
    }

    /// The full URL of the request under `restURL` (`<project>/rest/v1`).
    func url(restURL: URL) -> URL? {
        var base = restURL.absoluteString
        while base.hasSuffix("/") {
            base.removeLast()
        }
        return URL(string: base + "/" + encodedPathAndQuery)
    }
}

/// Builders of every PostgREST request the adapters make (docs/CONTRACTS.md §4.1, §4.3; docs/CONTRACTS-V2.md §5,
/// §7–§10; docs/CONTRACTS-V3.md).
enum RestQuery {
    /// Lowercase canonical form, as Postgres prints UUIDs.
    static func uuid(_ value: UUID) -> String {
        value.uuidString.lowercased()
    }

    private static func item(_ name: String, _ value: String) -> RestRequest.QueryItem {
        RestRequest.QueryItem(name: name, value: value)
    }

    // MARK: - Reads

    static func myGroups(me: UUID) -> RestRequest {
        RestRequest(path: "group_members", query: [
            item("select", "role,group:groups(*)"),
            item("user_id", "eq.\(uuid(me))"),
        ])
    }

    /// The profile columns of the members list and of the `PATCH` results (v2: with the avatar; v3: the away dates).
    static let profileSelect = "id,display_name,avatar_color,avatar_emoji,away_from,away_until"

    /// `myProfile` also reads the onboarding fields (docs/CONTRACTS-V2.md §9).
    static let myProfileSelect = "\(profileSelect),onboarded_at,created_at"

    static func members(groupId: UUID) -> RestRequest {
        RestRequest(path: "group_members", query: [
            item("select", "user_id,role,joined_at,profile:profiles(\(profileSelect))"),
            item("group_id", "eq.\(uuid(groupId))"),
        ])
    }

    static func inviteCode(groupId: UUID) -> RestRequest {
        RestRequest(path: "group_invites", query: [
            item("select", "code"),
            item("group_id", "eq.\(uuid(groupId))"),
        ])
    }

    /// v2: every task read embeds the checklist (docs/CONTRACTS-V2.md §10); v3: the comment count and the photos
    /// (docs/CONTRACTS-V3.md §5, §6).
    static let taskSelect =
        "*,assignees:task_assignees(user_id),checklist:task_checklist_items(id,title,position,done,done_at,done_by)"
            + ",comments:task_comments(count),photos:task_photos(id,path,uploaded_by,created_at)"

    /// Old done tasks: cutoff = `now − 30 × 86 400 s` (not calendar days), inclusive.
    static func oldDoneCutoff(now: Date) -> Date {
        now.addingTimeInterval(-Double(Limits.oldDoneTaskDays) * 86_400)
    }

    /// Unless `includeOldDone`, done tasks completed before `now − 30 days` are left out.
    static func groupTasks(groupId: UUID, includeOldDone: Bool, now: Date) -> RestRequest {
        var query = [
            item("select", taskSelect),
            item("group_id", "eq.\(uuid(groupId))"),
        ]
        if !includeOldDone {
            let cutoff = PostgresTimestamp.format(oldDoneCutoff(now: now))
            query.append(item("or", "(status.neq.done,completed_at.gte.\(cutoff))"))
        }
        return RestRequest(path: "tasks", query: query)
    }

    static func task(id: UUID) -> RestRequest {
        RestRequest(path: "tasks", query: [
            item("select", taskSelect),
            item("id", "eq.\(uuid(id))"),
        ])
    }

    /// v2: the embedded group also gives its color and emoji.
    static func myTasks(me: UUID, includeDone: Bool) -> RestRequest {
        var query = myTasksQuery(me: me)
        if !includeDone {
            query.append(item("status", "neq.done"))
        }
        return RestRequest(path: "tasks", query: query)
    }

    /// v2 (docs/CONTRACTS-V2.md §10): `myTasks` with the tasks not done and the done ones completed at or after
    /// `doneSince` (inclusive, microseconds).
    static func myTasks(me: UUID, doneSince: Date) -> RestRequest {
        RestRequest(path: "tasks", query: myTasksQuery(me: me) + [
            item("or", "(status.neq.done,completed_at.gte.\(PostgresTimestamp.format(doneSince)))"),
        ])
    }

    private static func myTasksQuery(me: UUID) -> [RestRequest.QueryItem] {
        [
            item(
                "select",
                "\(taskSelect),mine:task_assignees!inner(assigned_at,assigned_by,user_id),group:groups(name,color,emoji)"
            ),
            item("mine.user_id", "eq.\(uuid(me))"),
        ]
    }

    /// `in.(<id>,<id>…)`, the ids in the order given.
    static func inList(_ ids: [UUID]) -> String {
        "in.(\(ids.map(uuid).joined(separator: ",")))"
    }

    /// v2 groups overview, the members (docs/CONTRACTS-V2.md §10): the members of `groupIds` with their avatar, in pages
    /// of `limit` rows (`Limits.readRowsMax`) ordered by group.
    static func overviewMembers(groupIds: [UUID], limit: Int = Limits.readRowsMax) -> RestRequest {
        RestRequest(path: "group_members", query: [
            item("select", "group_id,user_id,role,joined_at,profile:profiles(\(profileSelect))"),
            item("group_id", inList(groupIds)),
            item("order", "group_id.asc"),
            item("limit", String(limit)),
        ])
    }

    /// v2 groups overview, the tasks (docs/CONTRACTS-V2.md §10): the tasks of `groupIds` not done or done at or after
    /// `doneSince` (inclusive, microseconds), in pages of `limit` rows (`Limits.readRowsMax`) ordered by group.
    static func overviewTasks(groupIds: [UUID], doneSince: Date, limit: Int = Limits.readRowsMax) -> RestRequest {
        RestRequest(path: "tasks", query: [
            item("select", "group_id,status,completed_at"),
            item("group_id", inList(groupIds)),
            item("or", "(status.neq.done,completed_at.gte.\(PostgresTimestamp.format(doneSince)))"),
            item("order", "group_id.asc"),
            item("limit", String(limit)),
        ])
    }

    /// Assignments to `me` made by someone else (or by a deleted account) strictly after `since`, oldest first.
    /// v2: the embedded task gives its rotation (a turn handed out by the server is worded « C’est ton tour »).
    static func assignments(me: UUID, since: Date) -> RestRequest {
        RestRequest(path: "task_assignees", query: [
            item("select", "task_id,group_id,assigned_by,assigned_at,task:tasks(title,due_at,rotation,group:groups(name))"),
            item("user_id", "eq.\(uuid(me))"),
            item("assigned_at", "gt.\(PostgresTimestamp.format(since))"),
            item("or", "(assigned_by.is.null,assigned_by.neq.\(uuid(me)))"),
            item("order", "assigned_at.asc"),
        ])
    }

    static func myProfile(me: UUID) -> RestRequest {
        RestRequest(path: "profiles", query: [
            item("select", myProfileSelect),
            item("id", "eq.\(uuid(me))"),
        ])
    }

    static func pushTopic(me: UUID) -> RestRequest {
        RestRequest(path: "push_subscriptions", query: [
            item("select", "topic"),
            item("user_id", "eq.\(uuid(me))"),
        ])
    }

    /// v2: the group's activity feed, newest first, at most `Limits.activityFeedMax` events (docs/CONTRACTS-V2.md §7).
    /// v3: with the away range of `member_away` and the reactions (docs/CONTRACTS-V3.md §4).
    static func activity(groupId: UUID) -> RestRequest {
        RestRequest(path: "group_activity", query: [
            item(
                "select",
                "id,kind,actor_id,subject_id,task_id,task_title,item_title,starts_on,ends_on,created_at"
                    + ",reactions:activity_reactions(user_id,emoji)"
            ),
            item("group_id", "eq.\(uuid(groupId))"),
            item("order", "id.desc"),
            item("limit", String(Limits.activityFeedMax)),
        ])
    }

    /// v2: the group's tasks completed at or after `since` (inclusive), for the weekly recap (docs/CONTRACTS-V2.md §8).
    static func completions(groupId: UUID, since: Date) -> RestRequest {
        RestRequest(path: "tasks", query: [
            item("select", "id,completed_by,completed_at"),
            item("group_id", "eq.\(uuid(groupId))"),
            item("status", "eq.done"),
            item("completed_at", "gte.\(PostgresTimestamp.format(since))"),
        ])
    }

    // MARK: - v3 reads (docs/CONTRACTS-V3.md)

    /// Every swap of a task, oldest first (§3).
    static func turnSwaps(taskId: UUID) -> RestRequest {
        RestRequest(path: "turn_swaps", query: [
            item("select", "*"),
            item("task_id", "eq.\(uuid(taskId))"),
            item("order", "created_at.asc"),
        ])
    }

    /// The pending swaps proposed by or to `me`, oldest first (§3).
    static func pendingTurnSwaps(me: UUID) -> RestRequest {
        RestRequest(path: "turn_swaps", query: [
            item("select", "*"),
            item("status", "eq.pending"),
            item("or", "(from_user.eq.\(uuid(me)),to_user.eq.\(uuid(me)))"),
            item("order", "created_at.asc"),
        ])
    }

    /// `task_comments?select=*&task_id=eq.<t>&order=created_at.asc` (§5).
    static func comments(taskId: UUID) -> RestRequest {
        RestRequest(path: "task_comments", query: [
            item("select", "*"),
            item("task_id", "eq.\(uuid(taskId))"),
            item("order", "created_at.asc"),
        ])
    }

    /// `tasks?select=id,group_id,completed_at&completed_by=eq.<me>&completed_at=gte.<since>` (§8), `since` inclusive,
    /// with microseconds.
    static func myCompletions(me: UUID, since: Date) -> RestRequest {
        RestRequest(path: "tasks", query: [
            item("select", "id,group_id,completed_at"),
            item("completed_by", "eq.\(uuid(me))"),
            item("completed_at", "gte.\(PostgresTimestamp.format(since))"),
        ])
    }

    // MARK: - Writes

    /// `PATCH profiles?select=id,display_name,avatar_color,avatar_emoji&id=eq.<me>` with `Prefer: return=representation`
    /// (0 rows → `.forbidden`). The explicit `select` keeps the representation to the columns the client reads, so that
    /// a column-level grant on `profiles` (review SEC-3) does not break renaming.
    static func updateDisplayName(me: UUID, name: String) -> RestRequest {
        updateProfile(me: me, fields: ["display_name": .string(name)])
    }

    /// v2: `PATCH profiles` of the avatar (column grant, docs/CONTRACTS-V2.md §2): both columns, NULL = automatic color /
    /// the initials.
    static func updateAvatar(me: UUID, color: ColorKey?, emoji: String?) -> RestRequest {
        updateProfile(me: me, fields: [
            "avatar_color": .optionalString(color?.rawValue),
            "avatar_emoji": .optionalString(emoji),
        ])
    }

    private static func updateProfile(me: UUID, fields: [String: JSONValue]) -> RestRequest {
        RestRequest(
            method: .patch,
            path: "profiles",
            query: [item("select", profileSelect), item("id", "eq.\(uuid(me))")],
            body: .object(fields),
            prefer: "return=representation"
        )
    }

    /// `POST /rest/v1/rpc/<name>` with named `p_…` parameters.
    static func rpc(_ name: String, _ params: [String: JSONValue] = [:]) -> RestRequest {
        RestRequest(method: .post, path: "rpc/\(name)", body: .object(params))
    }
}
