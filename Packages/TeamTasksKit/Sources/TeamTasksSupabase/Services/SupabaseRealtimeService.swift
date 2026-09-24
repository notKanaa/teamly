import Foundation
import Supabase
import TeamTasksCore

/// `RealtimeService` on Supabase Realtime V2 (docs/CONTRACTS.md §6).
///
/// Every `events(userId:groupIds:)` call opens its own channel with the three bindings of §6 and emits
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

/// The three bindings of docs/CONTRACTS.md §6 for one user.
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
