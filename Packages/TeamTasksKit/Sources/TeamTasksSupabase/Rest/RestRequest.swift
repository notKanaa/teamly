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
/// §7–§10).
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

    /// The profile columns of the members list and of the `PATCH` results (v2: with the avatar).
    static let profileSelect = "id,display_name,avatar_color,avatar_emoji"

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

    /// v2: every task read embeds the checklist (docs/CONTRACTS-V2.md §10).
    static let taskSelect =
        "*,assignees:task_assignees(user_id),checklist:task_checklist_items(id,title,position,done,done_at,done_by)"

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
        var query = [
            item(
                "select",
                "\(taskSelect),mine:task_assignees!inner(assigned_at,assigned_by,user_id),group:groups(name,color,emoji)"
            ),
            item("mine.user_id", "eq.\(uuid(me))"),
        ]
        if !includeDone {
            query.append(item("status", "neq.done"))
        }
        return RestRequest(path: "tasks", query: query)
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
    static func activity(groupId: UUID) -> RestRequest {
        RestRequest(path: "group_activity", query: [
            item("select", "id,kind,actor_id,subject_id,task_id,task_title,item_title,created_at"),
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
