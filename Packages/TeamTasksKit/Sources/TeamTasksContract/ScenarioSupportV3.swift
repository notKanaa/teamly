import Foundation
import TeamTasksCore

// Helpers of the v3 scenarios (docs/CONTRACTS-V3.md). As in v2, only the public service API and server timestamps;
// recurring tasks and absences are in 2041, so the server's clock never matters (an absence ending in 2041 is never in
// the past, and completing an occurrence is always « early »).

/// A calendar date written `2041-03-04`.
func day(_ text: String, file: StaticString = #fileID, line: UInt = #line) throws -> LocalDate {
    try Verify.unwrap(LocalDate(isoString: text), "date \(text)", file: file, line: line)
}

enum Photo {
    /// A valid 48 × 36 JPEG (772 bytes).
    static let jpeg: Data = Data(base64Encoded: [
        "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAoHBwgHBgoICAgLCgoLDhgQDg0NDh0VFhEYIx8lJCIfIiEmKzcvJik0KSEiMEEx",
        "NDk7Pj4+JS5ESUM8SDc9Pjv/2wBDAQoLCw4NDhwQEBw7KCIoOzs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7",
        "Ozs7Ozs7Ozs7Ozs7Ozv/wAARCAAkADADASIAAhEBAxEB/8QAGgAAAgMBAQAAAAAAAAAAAAAAAAUCBAYDB//EADQQAAEDAwID",
        "BAgGAwAAAAAAAAECAwQABRESIQYTMRRBUVUVFiJWkZSjpCNhcYHR0oSywf/EABgBAAMBAQAAAAAAAAAAAAAAAAACAwEE/8QA",
        "HxEAAgEDBQEAAAAAAAAAAAAAABEBAkFRAxIhIjHR/9oADAMBAAIRAxEAPwD1PFLZFxlGa7EttvM1xgJL/wCMlsI1bpG/XYHp",
        "TXFZ+NebfaOJrx2+RyebyNHsKVnCN+gPiKoc6yWO1cQe7n3rdHauIPdz71urPrnw/wCYfRc/rR658P8AmH0XP61jnA22nJWT",
        "c5zD7KbnajCafcDTbgfS5lZ6AgbjODvTXFILzxBa7s5a2IUrmuJuDSynlqTtuM7geIrRYrRVD4J6aVWbbie+/wCP/oac4pBF",
        "fiw+I72mdIRFTISxoLjvLKxoIJScjoe8dKWw/kwaNC0OJ1IUlQBIyk53BwR+xBFZm8cVOGYzbrCES5K1AqWn2kY66R3Hbqe4",
        "fn0SyoJhJdhWfiGIYEkDmJdloBByAfiDnbGQCDnbOhsyeHLLGShm4wVvYwt9TyNS89e/YbDb/u9S7TwkQmvV1Oq25n4S4m1l",
        "mzlxKUrNyY1BJyAd84OBn4U100lvs6JcHLUzClMyXE3FpZQy4FkJAVk4HcPGn2KrYvcniuEmDEmae1RWX9GdPNbCsZ64z+lF",
        "FYMcPQlp8rh/Lo/ij0JafK4fy6P4oooYKDrHt0GI4XI0OOwsjBU20lJI8MgVZxRRQB//2Q==",
    ].joined()) ?? Data()

    /// PNG bytes: not a JPEG (`.invalidPhoto` before any upload).
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00])
}

extension ContractUser {
    /// A recurring task « à tour de rôle » due `dueAt`, titled `"<base> <token>"`.
    func makeRotatingTask(
        in groupId: UUID, _ base: String = "Tour", dueAt: Date, rotation: [ContractUser], rule: RecurrenceRule = Rule.weekly()
    ) async throws -> TaskItem {
        try await makeRecurringTask(in: groupId, base, rule: rule, dueAt: dueAt, rotation: rotation)
    }

    /// The group's feed events of `kind`, newest first.
    func events(_ kind: ActivityKind, in groupId: UUID) async throws -> [ActivityEvent] {
        try await feed(of: groupId).filter { $0.kind == kind }
    }

    /// The members of `groupId` as this user reads them, by id.
    func member(_ userId: UUID, of groupId: UUID) async throws -> Membership {
        let members = try await groups.members(groupId: groupId)
        return try Verify.unwrap(members.first { $0.user.id == userId }, "member \(userId) of \(groupId)")
    }
}

func isSocialEvent(_ event: RealtimeEvent) -> Bool {
    event.socialGroupId != nil
}
