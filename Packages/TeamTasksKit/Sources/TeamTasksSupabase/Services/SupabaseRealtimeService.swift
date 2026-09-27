import Foundation
import Supabase
import TeamTasksCore

/// `RealtimeService` on Supabase Realtime V2 (docs/CONTRACTS.md §6, docs/CONTRACTS-V3.md §11).
///
/// Every `events(userId:groupIds:)` call opens its own channel with the three bindings of §6 (v3: and the five of
/// CONTRACTS-V3 §11, on the same channel) and emits
/// `.connected` on the `system` message that confirms the Postgres subscription (not on the join reply). If the
/// subscription fails (a `system` error, a join that never succeeds, a channel closed by the server), the channel
/// is dropped and a new one is subscribed after a backoff, which emits `.connected` again. Socket reconnections
/// are handled by supabase-swift, which re-joins the channel (→ a new `system` ok → `.connected`). Refreshed
/// access tokens are passed to the Realtime client (`setAuth`) so the channel survives the JWT expiry. The
/// stream ends only when the consumer cancels it; the channel is then removed.
struct SupabaseRealtimeService: RealtimeService {
    let context: SupabaseContext

    func events(userId: UUID, groupIds: [UUID]) -> AsyncStream<RealtimeEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: RealtimeEvent.self, bufferingPolicy: .unbounded)
        let runner = RealtimeChannelRunner(
            context: context,
            bindings: RealtimeBindings(userId: userId, groupIds: groupIds),
            continuation: continuation
        )
        let task = Task { await runner.run() }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}

/// The three bindings of docs/CONTRACTS.md §6 for one user, and the five of docs/CONTRACTS-V3.md §11.
///
/// The v3 tables must be in the server's publication: a channel whose binding names a table outside it fails as a
/// whole, so this client needs the v3 migrations.
struct RealtimeBindings: Sendable, Hashable {
    /// The server fails the whole channel at ~70 ids in one `in` filter.
    static let maxGroupIds = 60

    let userId: UUID
    /// At most `maxGroupIds` distinct ids (the first ones given), lowercase.
    let groupIds: [String]

    init(userId: UUID, groupIds: [UUID]) {
        self.userId = userId
        var seen = Set<UUID>()
        self.groupIds = groupIds.prefix(Self.maxGroupIds).filter { seen.insert($0).inserted }.map(RestQuery.uuid)
    }

    var me: String { RestQuery.uuid(userId) }

    /// UPDATE `public.groups`, `id=in.(…)` (`in.()` when empty).
    var groupsFilter: RealtimePostgresFilter {
        .in("id", values: groupIds)
    }

    /// UPDATE `public.profiles`, `id=eq.<me>`.
    var profilesFilter: RealtimePostgresFilter {
        .eq("id", value: me)
    }

    /// INSERT `public.task_assignees`, `user_id=eq.<me>`.
    var assigneesFilter: RealtimePostgresFilter {
        .eq("user_id", value: me)
    }

    // MARK: v3 (docs/CONTRACTS-V3.md §11)

    /// INSERT `public.task_nudges`, `to_user=eq.<me>`.
    var nudgesFilter: RealtimePostgresFilter {
        .eq("to_user", value: me)
    }

    /// INSERT `public.turn_swaps`, `to_user=eq.<me>`.
    var swapsToMeFilter: RealtimePostgresFilter {
        .eq("to_user", value: me)
    }

    /// UPDATE `public.turn_swaps`, `from_user=eq.<me>`.
    var swapsFromMeFilter: RealtimePostgresFilter {
        .eq("from_user", value: me)
    }

    /// INSERT `public.activity_reactions`, `target_user=eq.<me>`.
    var reactionsFilter: RealtimePostgresFilter {
        .eq("target_user", value: me)
    }

    /// INSERT `public.task_comments`, `group_id=in.(…)`: the group ids of `groupsFilter` (the same 60-id limit).
    var commentsFilter: RealtimePostgresFilter {
        .in("group_id", values: groupIds)
    }

    /// `task_nudges` INSERT record → `.nudged`.
    static func nudged(record: [String: AnyJSON]) -> RealtimeEvent? {
        guard let id = uuid(record["id"]), let taskId = uuid(record["task_id"]), let groupId = uuid(record["group_id"]),
              let from = uuid(record["from_user"])
        else { return nil }
        return .nudged(nudgeId: id, taskId: taskId, groupId: groupId, fromUserId: from)
    }

    /// `turn_swaps` INSERT record → `.turnSwapProposed`.
    static func turnSwapProposed(record: [String: AnyJSON]) -> RealtimeEvent? {
        guard let id = uuid(record["id"]), let taskId = uuid(record["task_id"]), let groupId = uuid(record["group_id"]),
              let from = uuid(record["from_user"])
        else { return nil }
        return .turnSwapProposed(swapId: id, taskId: taskId, groupId: groupId, fromUserId: from)
    }

    /// `turn_swaps` UPDATE record → `.turnSwapUpdated`; nil for a status unknown to this client.
    static func turnSwapUpdated(record: [String: AnyJSON]) -> RealtimeEvent? {
        guard let id = uuid(record["id"]), let taskId = uuid(record["task_id"]), let groupId = uuid(record["group_id"]),
              let to = uuid(record["to_user"]),
              let status = record["status"]?.stringValue.flatMap(TurnSwap.Status.init(rawValue:))
        else { return nil }
        let repaid = record["repaid_at"].map { !$0.isNil } ?? false
        return .turnSwapUpdated(swapId: id, taskId: taskId, groupId: groupId, toUserId: to, status: status, isRepaid: repaid)
    }

    /// `activity_reactions` INSERT record → `.reactionAdded`; nil for an emoji unknown to this client.
    static func reactionAdded(record: [String: AnyJSON]) -> RealtimeEvent? {
        guard let activityId = int64(record["activity_id"]), let groupId = uuid(record["group_id"]),
              let userId = uuid(record["user_id"]),
              let emoji = record["emoji"]?.stringValue.flatMap(ReactionEmoji.init(rawValue:))
        else { return nil }
        return .reactionAdded(activityId: activityId, groupId: groupId, userId: userId, emoji: emoji)
    }

    /// `task_comments` INSERT record → `.commentAdded` (`mentions` as a JSON array, or as a Postgres array literal).
    static func commentAdded(record: [String: AnyJSON]) -> RealtimeEvent? {
        guard let id = uuid(record["id"]), let taskId = uuid(record["task_id"]), let groupId = uuid(record["group_id"])
        else { return nil }
        return .commentAdded(
            commentId: id, taskId: taskId, groupId: groupId, authorId: uuid(record["author_id"]),
            mentions: uuids(record["mentions"])
        )
    }

    private static func int64(_ value: AnyJSON?) -> Int64? {
        switch value {
        case let .integer(number)?: Int64(number)
        case let .double(number)? where number == number.rounded(): Int64(exactly: number)
        case let .string(text)?: Int64(text)
        default: nil
        }
    }

    private static func uuids(_ value: AnyJSON?) -> [UUID] {
        switch value {
        case let .array(items)?:
            return items.compactMap { uuid($0) }
        case let .string(text)?:
            // `{a,b}`: the text form of a Postgres array.
            let inner = text.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
            return inner.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
        default:
            return []
        }
    }

    /// `groups` UPDATE record → `.groupActivity`.
    static func groupActivity(record: [String: AnyJSON]) -> RealtimeEvent? {
        guard let id = uuid(record["id"]) else { return nil }
        return .groupActivity(groupId: id)
    }

    /// `task_assignees` INSERT record → `.assigned` (`assigned_by` may be NULL).
    static func assigned(record: [String: AnyJSON]) -> RealtimeEvent? {
        guard let taskId = uuid(record["task_id"]), let groupId = uuid(record["group_id"]) else { return nil }
        return .assigned(taskId: taskId, groupId: groupId, assignedBy: uuid(record["assigned_by"]))
    }

    private static func uuid(_ value: AnyJSON?) -> UUID? {
        value?.stringValue.flatMap(UUID.init(uuidString:))
    }

    /// What a `system` message means for the Postgres subscription.
    enum SystemStatus: Sendable, Hashable {
        /// "Subscribed to PostgreSQL": the bindings are active → `.connected`.
        case subscribed
        /// The subscription failed (or the channel is being shut down by the server).
        case failed
        /// Unrelated to the Postgres subscription.
        case other
    }

    static func systemStatus(payload: [String: AnyJSON]) -> SystemStatus {
        let status = payload["status"]?.stringValue
        let extensionName = payload["extension"]?.stringValue
        switch status {
        case "ok":
            return extensionName == nil || extensionName == "postgres_changes" ? .subscribed : .other
        case "error":
            return .failed
        default:
            return .other
        }
    }
}

/// One `events(userId:groupIds:)` stream: subscribes, watches the channel, re-subscribes after failures.
private final class RealtimeChannelRunner: Sendable {
    /// A channel left unsubscribed this long (not re-joined by supabase-swift) is replaced.
    static let unsubscribedGrace: Duration = .seconds(10)

    let context: SupabaseContext
    let bindings: RealtimeBindings
    let continuation: AsyncStream<RealtimeEvent>.Continuation

    init(context: SupabaseContext, bindings: RealtimeBindings, continuation: AsyncStream<RealtimeEvent>.Continuation) {
        self.context = context
        self.bindings = bindings
        self.continuation = continuation
    }

    func run() async {
        // Token propagation (§6: `setAuth` on refresh). `SupabaseClient` does the same for its own Realtime
        // client; done here too because the channel depends on it and the Realtime client may be injected.
        // `setAuth` ignores a token it already has.
        let tokenTask = Task { [context] in
            for await (event, session) in context.auth.authStateChanges {
                switch event {
                case .initialSession, .signedIn, .tokenRefreshed:
                    await context.realtime.setAuth(session?.accessToken ?? context.publishableKey)
                case .signedOut:
                    await context.realtime.setAuth(context.publishableKey)
                default:
                    break
                }
            }
        }
        defer { tokenTask.cancel() }

        var failures = 0
        while !Task.isCancelled {
            let reachedConnected = await subscribeOnce()
            if Task.isCancelled { break }
            failures = reachedConnected ? 1 : failures + 1
            let delay = min(30.0, pow(2.0, Double(failures - 1)))
            try? await Task.sleep(for: .seconds(delay))
        }
        continuation.finish()
    }

    /// Subscribes one channel and returns when it failed (or the consumer cancelled). True if it reached
    /// `.connected` at least once.
    private func subscribeOnce() async -> Bool {
        let realtime = context.realtime
        if let token = try? await context.auth.session.accessToken {
            await realtime.setAuth(token)
        }
        let channel = realtime.channel("equipe:\(bindings.me):\(UUID().uuidString.lowercased())")
        let (failures, failureSignal) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let connected = Flag()
        let continuation = continuation

        // Callbacks run synchronously in message order: events are yielded in commit order.
        let tokens = [
            channel.onPostgresChange(
                UpdateAction.self, schema: "public", table: "groups", filter: bindings.groupsFilter
            ) { action in
                if let event = RealtimeBindings.groupActivity(record: action.record) {
                    continuation.yield(event)
                }
            },
            channel.onPostgresChange(
                UpdateAction.self, schema: "public", table: "profiles", filter: bindings.profilesFilter
            ) { _ in
                continuation.yield(.membershipsChanged)
            },
            channel.onPostgresChange(
                InsertAction.self, schema: "public", table: "task_assignees", filter: bindings.assigneesFilter
            ) { action in
                if let event = RealtimeBindings.assigned(record: action.record) {
                    continuation.yield(event)
                }
            },
            // v3 (docs/CONTRACTS-V3.md §11).
            channel.onPostgresChange(
                InsertAction.self, schema: "public", table: "task_nudges", filter: bindings.nudgesFilter
            ) { action in
                if let event = RealtimeBindings.nudged(record: action.record) {
                    continuation.yield(event)
                }
            },
            channel.onPostgresChange(
                InsertAction.self, schema: "public", table: "turn_swaps", filter: bindings.swapsToMeFilter
            ) { action in
                if let event = RealtimeBindings.turnSwapProposed(record: action.record) {
                    continuation.yield(event)
                }
            },
            channel.onPostgresChange(
                UpdateAction.self, schema: "public", table: "turn_swaps", filter: bindings.swapsFromMeFilter
            ) { action in
                if let event = RealtimeBindings.turnSwapUpdated(record: action.record) {
                    continuation.yield(event)
                }
            },
            channel.onPostgresChange(
                InsertAction.self, schema: "public", table: "activity_reactions", filter: bindings.reactionsFilter
            ) { action in
                if let event = RealtimeBindings.reactionAdded(record: action.record) {
                    continuation.yield(event)
                }
            },
            channel.onPostgresChange(
                InsertAction.self, schema: "public", table: "task_comments", filter: bindings.commentsFilter
            ) { action in
                if let event = RealtimeBindings.commentAdded(record: action.record) {
                    continuation.yield(event)
                }
            },
            channel.onSystem { message in
                switch RealtimeBindings.systemStatus(payload: message.payload) {
                case .subscribed:
                    connected.set()
                    continuation.yield(.connected)
                case .failed:
                    failureSignal.yield()
                case .other:
                    break
                }
            },
        ]

        let watcher = Task {
            for await status in channel.statusChange where status == .unsubscribed && connected.isSet {
                try? await Task.sleep(for: Self.unsubscribedGrace)
                if Task.isCancelled { return }
                if channel.status == .unsubscribed {
                    failureSignal.yield()
                    return
                }
            }
        }

        do {
            try await channel.subscribeWithError()
            for await _ in failures {
                break
            }
        } catch {
            // Join refused or timed out: retried by `run()`.
        }

        watcher.cancel()
        failureSignal.finish()
        for token in tokens {
            token.cancel()
        }
        await realtime.removeChannel(channel)
        return connected.isSet
    }
}

/// A thread-safe boolean that can only be set.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
