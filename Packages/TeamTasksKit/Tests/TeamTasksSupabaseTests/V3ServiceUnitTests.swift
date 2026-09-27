import Foundation
@testable import RealtimeV2
import Supabase
import TeamTasksCore
import Testing
@testable import TeamTasksSupabase

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A `PhotoStorage` that records the calls and fails on demand.
final class FakePhotoStorage: PhotoStorage, @unchecked Sendable {
    struct Upload: Equatable {
        let path: String
        let bytes: Int
        let contentType: String
    }

    private let lock = NSLock()
    private var _uploads: [Upload] = []
    private var _removed: [String] = []
    private var _signed: [(String, Int)] = []
    var uploadError: (any Error)?

    var uploads: [Upload] { lock.withLock { _uploads } }
    var removed: [String] { lock.withLock { _removed } }
    var signed: [(String, Int)] { lock.withLock { _signed } }

    func upload(path: String, data: Data, contentType: String) async throws {
        if let uploadError { throw uploadError }
        lock.withLock { _uploads.append(Upload(path: path, bytes: data.count, contentType: contentType)) }
    }

    func remove(path: String) async throws {
        lock.withLock { _removed.append(path) }
    }

    func signedURL(path: String, expiresIn: Int) async throws -> URL {
        lock.withLock { _signed.append((path, expiresIn)) }
        return URL(string: "http://127.0.0.1:9/storage/v1/object/sign/task-photos/\(path)?token=essai")!
    }
}

extension UnitBackend {
    /// Services whose PostgREST calls go to `transport` and whose photos go to `storage`, signed in as `me`.
    static func services(_ transport: FakeTransport, storage: FakePhotoStorage, me: UUID = Seed.camille) -> AppServices {
        SupabaseBackend.services(for: SupabaseContext(
            configuration: configuration,
            authStorage: InMemoryAuthStorage(),
            now: { Date() },
            transport: transport,
            credentials: FixedCredentials(userId: me),
            photoStorage: storage
        ))
    }
}

/// The v3 calls against a fake PostgREST and a fake bucket (docs/CONTRACTS-V3.md): requests sent, checks before any call,
/// decoding, the Realtime records and the storage errors.
@Suite struct V3ServiceUnitTests {
    static let task = uuid("94d0d49f-a303-4611-9621-ced98f3d9086")
    static let group = uuid("68b726d0-9f22-460c-8410-39efeead2cc1")
    static let lucas = Seed.lucas

    static func taskJSON(photos: String = "[]", comments: Int = 0) -> String {
        """
        [{"id":"94d0d49f-a303-4611-9621-ced98f3d9086","group_id":"68b726d0-9f22-460c-8410-39efeead2cc1","title":"Frigo",
        "details":null,"status":"done","priority":"medium","due_at":null,"created_by":"11111111-1111-4111-8111-111111111111",
        "created_at":"2026-09-24T10:00:00+00:00","updated_at":"2026-09-24T11:00:00.5+00:00","completed_at":"2026-09-24T11:00:00.5+00:00",
        "completed_by":"11111111-1111-4111-8111-111111111111","assignees":[{"user_id":"11111111-1111-4111-8111-111111111111"}],
        "checklist":[],"comments":[{"count":\(comments)}],"photos":\(photos)}]
        """
    }

    static let photoRow = #"""
    {"id":"f1000000-0000-4000-8000-000000000001","task_id":"94d0d49f-a303-4611-9621-ced98f3d9086",
    "group_id":"68b726d0-9f22-460c-8410-39efeead2cc1","path":"PATH","uploaded_by":"11111111-1111-4111-8111-111111111111",
    "created_at":"2026-09-24T11:05:00.123456+00:00"}
    """#

    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])

    // MARK: - Reads

    @Test func v3Queries() {
        let me = Seed.camille
        let since = PostgresTimestamp.date(epochMicroseconds: 1_790_244_000_123_456)
        #expect(RestQuery.turnSwaps(taskId: Self.task).readableQuery
            == "select=*&task_id=eq.94d0d49f-a303-4611-9621-ced98f3d9086&order=created_at.asc")
        #expect(RestQuery.pendingTurnSwaps(me: me).readableQuery
            == "select=*&status=eq.pending&or=(from_user.eq.11111111-1111-4111-8111-111111111111,"
            + "to_user.eq.11111111-1111-4111-8111-111111111111)&order=created_at.asc")
        #expect(RestQuery.comments(taskId: Self.task).path == "task_comments")
        #expect(RestQuery.comments(taskId: Self.task).readableQuery
            == "select=*&task_id=eq.94d0d49f-a303-4611-9621-ced98f3d9086&order=created_at.asc")
        #expect(RestQuery.myCompletions(me: me, since: since).readableQuery
            == "select=id,group_id,completed_at&completed_by=eq.11111111-1111-4111-8111-111111111111"
            + "&completed_at=gte.2026-09-24T10:00:00.123456Z")
    }

    @Test func taskReadsCarryTheCommentCountAndThePhotos() async throws {
        let photos = #"[{"id":"f1000000-0000-4000-8000-000000000002","path":"b","uploaded_by":null,"created_at":"2026-09-24T12:00:00+00:00"},"#
            + #"{"id":"f1000000-0000-4000-8000-000000000001","path":"a","uploaded_by":"11111111-1111-4111-8111-111111111111","created_at":"2026-09-24T11:00:00+00:00"}]"#
        let transport = FakeTransport([.json(200, Self.taskJSON(photos: photos, comments: 2))])
        let task = try await UnitBackend.services(transport).tasks.task(id: Self.task)
        #expect(task.commentCount == 2)
        #expect(task.photos.map(\.path) == ["a", "b"], "oldest first")
        #expect(task.photos.allSatisfy { $0.taskId == Self.task && $0.groupId == Self.group })
        #expect(task.photos.last?.uploadedBy == nil)
    }

    @Test func activityDecodesReactionsAndTheAbsence() async throws {
        let json = #"""
        [{"id":12,"kind":"member_away","actor_id":"22222222-2222-4222-8222-222222222222","subject_id":"22222222-2222-4222-8222-222222222222",
          "task_id":null,"task_title":null,"item_title":null,"starts_on":"2026-10-05","ends_on":"2026-10-11",
          "created_at":"2026-09-24T10:00:00+00:00","reactions":[]},
         {"id":11,"kind":"task_completed","actor_id":"11111111-1111-4111-8111-111111111111","subject_id":null,
          "task_id":"94d0d49f-a303-4611-9621-ced98f3d9086","task_title":"Frigo","item_title":null,"starts_on":null,"ends_on":null,
          "created_at":"2026-09-24T09:00:00+00:00",
          "reactions":[{"user_id":"33333333-3333-4333-8333-333333333333","emoji":"🔥"},
                       {"user_id":"22222222-2222-4222-8222-222222222222","emoji":"👏"},
                       {"user_id":"22222222-2222-4222-8222-222222222222","emoji":"🦄"}]},
         {"id":10,"kind":"task_renamed","actor_id":null,"subject_id":null,"task_id":null,"task_title":null,"item_title":null,
          "starts_on":null,"ends_on":null,"created_at":"2026-09-24T08:00:00+00:00","reactions":[]}]
        """#
        let transport = FakeTransport([.json(200, json)])
        let events = try await UnitBackend.services(transport).groups.activity(groupId: Self.group)
        #expect(events.map(\.id) == [12, 11], "an unknown kind is left out")
        #expect(events[0].kind == .memberAway)
        #expect(events[0].startsOn == LocalDate(year: 2026, month: 10, day: 5))
        #expect(events[0].endsOn == LocalDate(year: 2026, month: 10, day: 11))
        #expect(events[1].reactions == [
            ActivityReaction(userId: Seed.lucas, emoji: .clap), ActivityReaction(userId: Seed.ines, emoji: .fire),
        ], "sorted by emoji; an unknown emoji is left out")
    }

    @Test func swapsWithAnUnknownStatusAreLeftOut() async throws {
        let row = { (id: String, status: String) in
            #"{"id":"\#(id)","task_id":"94d0d49f-a303-4611-9621-ced98f3d9086","group_id":"68b726d0-9f22-460c-8410-39efeead2cc1","#
                + #""series_id":"94d0d49f-a303-4611-9621-ced98f3d9086","from_user":"11111111-1111-4111-8111-111111111111","#
                + #""to_user":"22222222-2222-4222-8222-222222222222","status":"\#(status)","created_at":"2026-09-24T10:00:00+00:00","#
                + #""responded_at":null,"repaid_at":null}"#
        }
        let json = "[" + row("f0000000-0000-4000-8000-000000000001", "pending") + ","
            + row("f0000000-0000-4000-8000-000000000002", "expired") + "]"
        let transport = FakeTransport([.json(200, json)])
        let swaps = try await UnitBackend.services(transport).tasks.pendingTurnSwaps()
        #expect(swaps.map(\.status) == [.pending])
        #expect(swaps.first?.fromUserId == Seed.camille && swaps.first?.toUserId == Seed.lucas)
        #expect(transport.sent.first?.target.hasPrefix("turn_swaps?select=*&status=eq.pending") == true)
    }

    @Test func membersReadTheAbsence() async throws {
        let json = #"[{"user_id":"33333333-3333-4333-8333-333333333333","role":"member","joined_at":"2026-09-20T10:00:00+00:00","#
            + #""profile":{"id":"33333333-3333-4333-8333-333333333333","display_name":"Inès","avatar_color":null,"#
            + #""avatar_emoji":null,"away_from":"2026-10-05","away_until":"2026-10-11"}}]"#
        let transport = FakeTransport([.json(200, json)])
        let members = try await UnitBackend.services(transport).groups.members(groupId: Self.group)
        #expect(members.first?.user.awayRange == LocalDate(year: 2026, month: 10, day: 5)...LocalDate(year: 2026, month: 10, day: 11))
    }

    @Test func myCompletionsAreTheCallersWithTheirGroup() async throws {
        let json = #"[{"id":"94d0d49f-a303-4611-9621-ced98f3d9086","group_id":"68b726d0-9f22-460c-8410-39efeead2cc1","#
            + #""completed_at":"2026-09-24T11:00:00+00:00"}]"#
        let transport = FakeTransport([.json(200, json)])
        let completions = try await UnitBackend.services(transport).tasks.myCompletions(since: Date(timeIntervalSince1970: 0))
        #expect(completions == [TaskCompletion(
            taskId: Self.task, completedBy: Seed.camille, completedAt: try #require(PostgresTimestamp.parse("2026-09-24T11:00:00Z")),
            groupId: Self.group
        )])
    }

    // MARK: - RPCs

    @Test func nudgeAndReactions() async throws {
        let transport = FakeTransport([.json(200, "2"), .json(200, "true"), .json(200, "false")])
        let services = UnitBackend.services(transport)
        #expect(try await services.tasks.nudge(taskId: Self.task) == 2)
        #expect(try await services.groups.toggleReaction(activityId: 42, emoji: .heart))
        #expect(try await !services.groups.toggleReaction(activityId: 42, emoji: .heart))
        #expect(transport.sent.map(\.target) == ["rpc/nudge_task", "rpc/toggle_reaction", "rpc/toggle_reaction"])
        #expect(transport.sent[0].body == #"{"p_task_id":"94d0d49f-a303-4611-9621-ced98f3d9086"}"#)
        #expect(transport.sent[1].body == #"{"p_activity_id":42,"p_emoji":"❤️"}"#)
    }

    @Test func v3ErrorsAreMapped() async throws {
        let transport = FakeTransport([
            .json(400, #"{"code":"P0001","message":"nudge_rate_limited"}"#),
            .json(400, #"{"code":"P0001","message":"activity_not_found"}"#),
            .json(400, #"{"code":"P0001","message":"swap_not_pending"}"#),
        ])
        let services = UnitBackend.services(transport)
        await #expect(throws: AppError.nudgeRateLimited) { try await services.tasks.nudge(taskId: Self.task) }
        await #expect(throws: AppError.notFound) { try await services.groups.toggleReaction(activityId: 1, emoji: .clap) }
        await #expect(throws: AppError.swapNotPending) { try await services.tasks.cancelTurnSwap(swapId: Self.task) }
    }

    @Test func setAwayChecksTheDatesThenSendsThem() async throws {
        let row = #"{"id":"11111111-1111-4111-8111-111111111111","display_name":"Camille","avatar_color":null,"avatar_emoji":null,"#
            + #""onboarded_at":"2026-09-01T10:00:00+00:00","created_at":"2026-09-01T10:00:00+00:00","updated_at":"2026-09-01T10:00:00+00:00","#
            + #""memberships_changed_at":"2026-09-01T10:00:00+00:00","away_from":"2026-10-05","away_until":"2026-10-11"}"#
        let cleared = row.replacingOccurrences(of: #""2026-10-05""#, with: "null").replacingOccurrences(of: #""2026-10-11""#, with: "null")
        let transport = FakeTransport([.json(200, row), .json(200, cleared)])
        let profiles = UnitBackend.services(transport).profiles
        let from = LocalDate(year: 2026, month: 10, day: 5)
        let until = LocalDate(year: 2026, month: 10, day: 11)
        await #expect(throws: AppError.invalidAway) { try await profiles.setAway(from: until, until: from, announce: true) }
        await #expect(throws: AppError.invalidAway) {
            try await profiles.setAway(from: from, until: from.adding(days: Limits.awayRangeMaxDays + 1), announce: true)
        }
        #expect(transport.sent.isEmpty)
        let profile = try await profiles.setAway(from: from, until: until, announce: false)
        #expect(profile.awayRange == from...until)
        #expect(profile.onboardedAt != nil)
        #expect(transport.sent[0].target == "rpc/set_away")
        #expect(transport.sent[0].body == #"{"p_announce":false,"p_from":"2026-10-05","p_until":"2026-10-11"}"#)
        let after = try await profiles.clearAway()
        #expect(after.awayFrom == nil && after.awayUntil == nil)
        #expect(transport.sent[1].target == "rpc/clear_away")
    }

    @Test func commentsAreSentAsTyped() async throws {
        let row = #"{"id":"f3000000-0000-4000-8000-000000000001","task_id":"94d0d49f-a303-4611-9621-ced98f3d9086","#
            + #""group_id":"68b726d0-9f22-460c-8410-39efeead2cc1","author_id":"11111111-1111-4111-8111-111111111111","#
            + #""body":"Lait","mentions":["33333333-3333-4333-8333-333333333333","22222222-2222-4222-8222-222222222222"],"#
            + #""created_at":"2026-09-24T10:00:00+00:00"}"#
        let transport = FakeTransport([.json(200, row), .json(200, row), .json(204, "")])
        let tasks = UnitBackend.services(transport).tasks
        let comment = try await tasks.addComment(taskId: Self.task, body: " Lait ", mentions: [Seed.ines, Seed.lucas])
        #expect(comment.mentions == [Seed.ines, Seed.lucas])
        #expect(comment.body == "Lait")
        #expect(transport.sent[0].target == "rpc/add_task_comment")
        #expect(transport.sent[0].body == #"{"p_body":" Lait ","p_mentions":["33333333-3333-4333-8333-333333333333","#
            + #""22222222-2222-4222-8222-222222222222"],"p_task_id":"94d0d49f-a303-4611-9621-ced98f3d9086"}"#)
        _ = try await tasks.addComment(taskId: Self.task, body: "a\u{0}b", mentions: [])
        #expect(transport.sent[1].body == #"{"p_body":"","p_mentions":[],"p_task_id":"94d0d49f-a303-4611-9621-ced98f3d9086"}"#,
                "U+0000 is sent as an empty body, which the server refuses after the task")
        try await tasks.deleteComment(commentId: Self.task)
        #expect(transport.sent[2].target == "rpc/delete_task_comment")
    }

    @Test func swapCalls() async throws {
        let row = #"{"id":"f0000000-0000-4000-8000-000000000001","task_id":"94d0d49f-a303-4611-9621-ced98f3d9086","#
            + #""group_id":"68b726d0-9f22-460c-8410-39efeead2cc1","series_id":"94d0d49f-a303-4611-9621-ced98f3d9086","#
            + #""from_user":"11111111-1111-4111-8111-111111111111","to_user":"22222222-2222-4222-8222-222222222222","#
            + #""status":"accepted","created_at":"2026-09-24T10:00:00+00:00","responded_at":"2026-09-24T10:05:00+00:00","repaid_at":null}"#
        let transport = FakeTransport([.json(200, row), .json(200, row), .json(200, row)])
        let tasks = UnitBackend.services(transport).tasks
        let swapId = uuid("f0000000-0000-4000-8000-000000000001")
        _ = try await tasks.requestTurnSwap(taskId: Self.task, to: Seed.lucas)
        let accepted = try await tasks.respondToTurnSwap(swapId: swapId, accept: true)
        _ = try await tasks.cancelTurnSwap(swapId: swapId)
        #expect(accepted.status == .accepted && accepted.respondedAt != nil && accepted.repaidAt == nil)
        #expect(transport.sent.map(\.target) == ["rpc/request_turn_swap", "rpc/respond_turn_swap", "rpc/cancel_turn_swap"])
        #expect(transport.sent[0].body == #"{"p_task_id":"94d0d49f-a303-4611-9621-ced98f3d9086","p_to_user":"22222222-2222-4222-8222-222222222222"}"#)
        #expect(transport.sent[1].body == #"{"p_accept":true,"p_swap_id":"f0000000-0000-4000-8000-000000000001"}"#)
        #expect(transport.sent[2].body == #"{"p_swap_id":"f0000000-0000-4000-8000-000000000001"}"#)
    }

    // MARK: - Photos

    /// Read the task, check the bytes, upload to `<group>/<task>/<uuid>.jpg`, then attach.
    @Test func uploadPhotoUploadsThenAttaches() async throws {
        let storage = FakePhotoStorage()
        let transport = FakeTransport([.json(200, Self.taskJSON()), .json(200, Self.taskJSON())])
        let tasks = UnitBackend.services(transport, storage: storage).tasks
        await #expect(throws: AppError.invalidPhoto) { try await tasks.uploadPhoto(taskId: Self.task, jpegData: Data([0x89, 0x50])) }
        #expect(storage.uploads.isEmpty, "invalid bytes are never uploaded")

        let folder = "68b726d0-9f22-460c-8410-39efeead2cc1/94d0d49f-a303-4611-9621-ced98f3d9086/"
        // The attach answer echoes the uploaded path: build it once the upload is known.
        let recording = PathEchoTransport(taskJSON: Self.taskJSON(), photoRow: Self.photoRow)
        let echoTasks = SupabaseBackend.services(for: SupabaseContext(
            configuration: UnitBackend.configuration, authStorage: InMemoryAuthStorage(), now: { Date() },
            transport: recording, credentials: FixedCredentials(userId: Seed.camille), photoStorage: storage
        )).tasks
        let photo = try await echoTasks.uploadPhoto(taskId: Self.task, jpegData: Self.jpeg)
        let upload = try #require(storage.uploads.first)
        #expect(upload.path.hasPrefix(folder) && upload.path.hasSuffix(".jpg"))
        #expect(upload.contentType == "image/jpeg" && upload.bytes == Self.jpeg.count)
        #expect(photo.path == upload.path)
        #expect(photo.taskId == Self.task && photo.groupId == Self.group && photo.uploadedBy == Seed.camille)
        #expect(recording.targets.first?.hasPrefix("tasks?select=") == true)
        #expect(recording.targets.last == "rpc/attach_task_photo")
        #expect(recording.bodies.last == #"{"p_path":"\#(upload.path)","p_task_id":"94d0d49f-a303-4611-9621-ced98f3d9086"}"#)
        #expect(storage.removed.isEmpty)
    }

    /// A refusal of the attach removes the uploaded object; a network failure leaves it (it may be attached).
    @Test func refusedPhotoIsRemoved() async throws {
        let storage = FakePhotoStorage()
        let transport = FakeTransport([
            .json(200, Self.taskJSON()), .json(403, #"{"code":"42501","message":"forbidden"}"#),
            .json(200, Self.taskJSON()), .json(400, #"{"code":"P0001","message":"photo_limit"}"#),
            .json(200, Self.taskJSON()), .failure(.networkConnectionLost),
        ])
        let tasks = UnitBackend.services(transport, storage: storage).tasks
        await #expect(throws: AppError.forbidden) { try await tasks.uploadPhoto(taskId: Self.task, jpegData: Self.jpeg) }
        await #expect(throws: AppError.photoLimit) { try await tasks.uploadPhoto(taskId: Self.task, jpegData: Self.jpeg) }
        #expect(storage.removed == storage.uploads.map(\.path), "both refused objects are removed")
        await #expect(throws: AppError.network) { try await tasks.uploadPhoto(taskId: Self.task, jpegData: Self.jpeg) }
        #expect(storage.removed.count == 2, "not after a network failure")
        // An unknown task: nothing is uploaded.
        let empty = FakeTransport([.json(200, "[]")])
        await #expect(throws: AppError.notFound) {
            try await UnitBackend.services(empty, storage: storage).tasks.uploadPhoto(taskId: Self.task, jpegData: Self.jpeg)
        }
        #expect(storage.uploads.count == 3)
    }

    @Test func deletePhotoAndSignedURL() async throws {
        let storage = FakePhotoStorage()
        let transport = FakeTransport([.json(204, "")])
        let tasks = UnitBackend.services(transport, storage: storage).tasks
        let photo = TaskPhoto(
            id: uuid("f1000000-0000-4000-8000-000000000001"), taskId: Self.task, groupId: Self.group, path: "g/t/o.jpg",
            uploadedBy: Seed.camille, createdAt: Date()
        )
        try await tasks.deletePhoto(photo)
        #expect(transport.sent.map(\.target) == ["rpc/delete_task_photo"])
        #expect(transport.sent.first?.body == #"{"p_photo_id":"f1000000-0000-4000-8000-000000000001"}"#)
        #expect(storage.removed == ["g/t/o.jpg"])
        let url = try await tasks.photoURL(photo)
        #expect(url.absoluteString.contains("g/t/o.jpg"))
        #expect(storage.signed.map(\.1) == [3600])
    }

    @Test func storageErrorsAreMapped() {
        typealias M = SupabaseErrorMapping
        #expect(M.storage(status: 413, code: "Payload too large", message: "The object exceeded the maximum allowed size") == .invalidPhoto)
        #expect(M.storage(status: 400, code: "invalid_mime_type", message: "mime type text/plain is not supported") == .invalidPhoto)
        #expect(M.storage(status: 400, code: "Unauthorized", message: "new row violates row-level security policy") == .forbidden)
        #expect(M.storage(status: 400, code: "not_found", message: "Object not found") == .notFound)
        #expect(M.storage(status: 409, code: "Duplicate", message: "The resource already exists") == .conflict)
        #expect(M.storage(status: 401, code: nil, message: "") == .notAuthenticated)
        #expect(M.storage(status: 503, code: nil, message: "") == .unknown(M.serverUnavailable))
        #expect(M.storage(StorageError(statusCode: "404", message: "Object not found", error: "not_found")) as? AppError == .notFound)
        #expect(M.storage(URLError(.notConnectedToInternet)) as? AppError == .network)
    }

    // MARK: - Realtime (§11)

    @Test func v3FiltersOfTheChannel() {
        let bindings = RealtimeBindings(userId: Seed.camille, groupIds: [Seed.lilas])
        let me = "11111111-1111-4111-8111-111111111111"
        #expect(bindings.nudgesFilter.value == "to_user=eq.\(me)")
        #expect(bindings.swapsToMeFilter.value == "to_user=eq.\(me)")
        #expect(bindings.swapsFromMeFilter.value == "from_user=eq.\(me)")
        #expect(bindings.reactionsFilter.value == "target_user=eq.\(me)")
        #expect(bindings.commentsFilter.value == "group_id=in.(a0000000-0000-4000-8000-000000000001)")
        #expect(RealtimeBindings(userId: Seed.camille, groupIds: []).commentsFilter.value == "group_id=in.()")
    }

    @Test func v3RecordsAreEvents() {
        let ids: [String: AnyJSON] = [
            "id": "f0000000-0000-4000-8000-000000000001", "task_id": "b0000000-0000-4000-8000-000000000002",
            "group_id": "a0000000-0000-4000-8000-000000000001",
        ]
        let swapId = uuid("f0000000-0000-4000-8000-000000000001")
        var nudge = ids
        nudge["from_user"] = "22222222-2222-4222-8222-222222222222"
        nudge["to_user"] = "11111111-1111-4111-8111-111111111111"
        #expect(RealtimeBindings.nudged(record: nudge) == .nudged(nudgeId: swapId, taskId: Seed.courses, groupId: Seed.lilas, fromUserId: Seed.lucas))
        #expect(RealtimeBindings.turnSwapProposed(record: nudge)
            == .turnSwapProposed(swapId: swapId, taskId: Seed.courses, groupId: Seed.lilas, fromUserId: Seed.lucas))
        var swap = nudge
        swap["status"] = "accepted"
        swap["repaid_at"] = .null
        #expect(RealtimeBindings.turnSwapUpdated(record: swap) == .turnSwapUpdated(
            swapId: swapId, taskId: Seed.courses, groupId: Seed.lilas, toUserId: Seed.camille, status: .accepted, isRepaid: false
        ))
        swap["repaid_at"] = "2026-09-24T10:00:00.123456+00:00"
        #expect(RealtimeBindings.turnSwapUpdated(record: swap) == .turnSwapUpdated(
            swapId: swapId, taskId: Seed.courses, groupId: Seed.lilas, toUserId: Seed.camille, status: .accepted, isRepaid: true
        ))
        swap["status"] = "expired"
        #expect(RealtimeBindings.turnSwapUpdated(record: swap) == nil, "a status unknown to this client")

        let reaction: [String: AnyJSON] = [
            "activity_id": .integer(42), "group_id": "a0000000-0000-4000-8000-000000000001",
            "user_id": "22222222-2222-4222-8222-222222222222", "target_user": "11111111-1111-4111-8111-111111111111", "emoji": "👏",
        ]
        #expect(RealtimeBindings.reactionAdded(record: reaction) == .reactionAdded(activityId: 42, groupId: Seed.lilas, userId: Seed.lucas, emoji: .clap))
        var other = reaction
        other["activity_id"] = "43"
        other["emoji"] = "🦄"
        #expect(RealtimeBindings.reactionAdded(record: other) == nil, "an emoji unknown to this client")
        other["emoji"] = "🔥"
        #expect(RealtimeBindings.reactionAdded(record: other) == .reactionAdded(activityId: 43, groupId: Seed.lilas, userId: Seed.lucas, emoji: .fire))

        var comment = ids
        comment["author_id"] = "22222222-2222-4222-8222-222222222222"
        comment["mentions"] = .array(["11111111-1111-4111-8111-111111111111"])
        let expected = RealtimeEvent.commentAdded(commentId: swapId, taskId: Seed.courses, groupId: Seed.lilas, authorId: Seed.lucas, mentions: [Seed.camille])
        #expect(RealtimeBindings.commentAdded(record: comment) == expected)
        comment["mentions"] = "{11111111-1111-4111-8111-111111111111}"
        #expect(RealtimeBindings.commentAdded(record: comment) == expected, "the text form of a Postgres array")
        comment["author_id"] = .null
        comment["mentions"] = "{}"
        #expect(RealtimeBindings.commentAdded(record: comment)
            == .commentAdded(commentId: swapId, taskId: Seed.courses, groupId: Seed.lilas, authorId: nil, mentions: []))
        #expect(RealtimeBindings.commentAdded(record: [:]) == nil)
    }
}

/// Answers the task read, then the attach RPC with a row echoing the path the client sent.
final class PathEchoTransport: HTTPTransport, @unchecked Sendable {
    let taskJSON: String
    let photoRow: String
    private let lock = NSLock()
    private var _targets: [String] = []
    private var _bodies: [String] = []

    init(taskJSON: String, photoRow: String) {
        self.taskJSON = taskJSON
        self.photoRow = photoRow
    }

    var targets: [String] { lock.withLock { _targets } }
    var bodies: [String] { lock.withLock { _bodies } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url ?? URL(fileURLWithPath: "/")
        let target = url.absoluteString.components(separatedBy: "/rest/v1/").last?.removingPercentEncoding ?? ""
        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        lock.withLock {
            _targets.append(target)
            _bodies.append(body)
        }
        let answer: String
        if target.hasPrefix("rpc/attach_task_photo") {
            let parameters = try JSONDecoder().decode([String: String].self, from: Data(body.utf8))
            answer = photoRow.replacingOccurrences(of: "PATH", with: parameters["p_path"] ?? "")
        } else {
            answer = taskJSON
        }
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) else {
            throw URLError(.badServerResponse)
        }
        return (Data(answer.utf8), response)
    }
}
