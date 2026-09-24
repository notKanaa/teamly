import Foundation
import TeamTasksContract
import TeamTasksCore
import Testing
@testable import TeamTasksSupabase

#if os(Linux)
@testable import RealtimeV2
#endif

extension IntegrationTests {
    /// Realtime resilience (docs/CONTRACTS.md §6) against the local stack: `.connected` again after the channel
    /// is lost, events keep flowing after a token refresh.
    @Suite(.enabled(if: IntegrationEnvironment.realtimeEnabled, "REALTIME_IT=0"))
    struct RealtimeIntegrationTests {
        struct Subscriber {
            let context: SupabaseContext
            let user: ContractUser
            let group: GroupSummary
            let probe: StreamProbe<RealtimeEvent>
        }

        func subscribe(sockets: WebSocketRegistry = WebSocketRegistry()) async throws -> Subscriber {
            let context = try IntegrationEnvironment.makeContext(sockets: sockets)
            let user = try await SupabaseHarness.signUp(displayName: "Temps réel", services: SupabaseBackend.services(for: context))
            let group = try await user.groups.createGroup(name: "Groupe temps réel")
            let probe = StreamProbe(user.realtime.events(userId: user.id, groupIds: [group.id]))
            try await probe.waitFor("first .connected") { $0 == .connected }
            return Subscriber(context: context, user: user, group: group, probe: probe)
        }

        /// A change of the subscriber's group reaches the stream.
        func expectActivity(_ subscriber: Subscriber, _ label: String) async throws {
            let mark = subscriber.probe.mark()
            _ = try await subscriber.user.groups.rename(groupId: subscriber.group.id, name: "Groupe \(UUID().uuidString.prefix(6))")
            try await subscriber.probe.waitFor("groupActivity \(label)", after: mark) {
                $0 == .groupActivity(groupId: subscriber.group.id)
            }
        }

        /// A channel that is closed and not re-joined (as when the server shuts it down) is replaced by a new
        /// subscription, which emits `.connected` again.
        @Test(.timeLimit(.minutes(1)))
        func resubscribesWhenTheChannelIsClosed() async throws {
            let subscriber = try await subscribe()
            defer { subscriber.probe.stop() }
            let channels = subscriber.context.realtime.channels.values.filter { $0.topic.hasPrefix("realtime:equipe:") }
            let channel = try #require(channels.first)
            #expect(channels.count == 1)

            let mark = subscriber.probe.mark()
            await channel.unsubscribe()
            try await subscriber.probe.waitFor(".connected after the channel was closed", after: mark, timeout: .seconds(30)) {
                $0 == .connected
            }
            let current = subscriber.context.realtime.channels.values.filter { $0.topic.hasPrefix("realtime:equipe:") }
            #expect(current.count == 1)
            #expect(current.first?.topic != channel.topic, "a new channel replaced the closed one")
            try await expectActivity(subscriber, "on the new channel")
        }

        /// A refreshed access token is passed to the Realtime client (`setAuth`), and the channel keeps working.
        @Test(.timeLimit(.minutes(1)))
        func passesRefreshedTokensToRealtime() async throws {
            let subscriber = try await subscribe()
            defer { subscriber.probe.stop() }
            let before = try await subscriber.context.auth.session.accessToken
            let refreshed = try await subscriber.context.auth.refreshSession()
            #expect(refreshed.accessToken != before)
            #if os(Linux)
            // White-box (the Linux client is injected, so only the adapter can have updated it).
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(10))
            while subscriber.context.realtime.mutableState.value.accessToken != refreshed.accessToken, clock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(subscriber.context.realtime.mutableState.value.accessToken == refreshed.accessToken)
            #endif
            try await expectActivity(subscriber, "after a token refresh")
        }

        #if os(Linux)
        /// After a network loss, supabase-swift reconnects and re-joins the channel: `.connected` again.
        @Test(.timeLimit(.minutes(1)))
        func reconnectsAfterANetworkLoss() async throws {
            let sockets = WebSocketRegistry()
            let subscriber = try await subscribe(sockets: sockets)
            defer { subscriber.probe.stop() }
            let mark = subscriber.probe.mark()
            for case let socket as LinuxWebSocket in sockets.all {
                socket.simulateNetworkLoss()
            }
            try await subscriber.probe.waitFor(".connected after the reconnection", after: mark, timeout: .seconds(40)) {
                $0 == .connected
            }
            try await expectActivity(subscriber, "after the reconnection")
        }
        #endif
    }
}
