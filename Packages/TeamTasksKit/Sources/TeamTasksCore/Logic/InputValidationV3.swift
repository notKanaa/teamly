import Foundation

/// v3 input rules (docs/CONTRACTS-V3.md §2, §4–§6), shared by the mock backend and the Supabase adapters.
///
/// The adapters send comments and mentions to the server unchecked (`task_not_found` comes first there), and check
/// the photo bytes and the clock-free away rules before calling the server.
extension InputValidation {
    // MARK: - Mode absent (§2)

    /// The away dates without the clock rule: `from <= until`, and at most `Limits.awayRangeMaxDays` days, both ends
    /// counted (`until - from <= 365`), else `.invalidAway`.
    public static func awayDates(from: LocalDate, until: LocalDate) throws {
        guard from.isValid, until.isValid, from <= until, from.days(to: until) < Limits.awayRangeMaxDays else {
            throw AppError.invalidAway
        }
    }

    /// Every rule of `set_away`: `awayDates(from:until:)`, and `until` no earlier than the day before `today` (the
    /// server's `current_date - 1`: `today` is the UTC date of the server's clock, `serverToday(now:)`), else
    /// `.invalidAway`.
    public static func awayRange(from: LocalDate, until: LocalDate, today: LocalDate) throws {
        try awayDates(from: from, until: until)
        guard until >= today.adding(days: -1) else { throw AppError.invalidAway }
    }

    /// The server's « today » at `now`: the UTC date, `(now() at time zone 'UTC')::date`.
    public static func serverToday(now: Date) -> LocalDate {
        LocalDate(now, timeZone: TimeZone(secondsFromGMT: 0) ?? .gmt)
    }

    // MARK: - Bravo (§4)

    /// The reaction of a stored or typed emoji, exact (`"❤"` without its variation selector is refused), else
    /// `.invalidReaction`. Typed `ReactionEmoji` values are always valid.
    public static func reaction(_ raw: String) throws -> ReactionEmoji {
        guard let emoji = ReactionEmoji(rawValue: raw) else { throw AppError.invalidReaction }
        return emoji
    }

    // MARK: - Commentaires (§5)

    /// Trimmed comment (`clean_text`), 1–`Limits.commentBodyMax` code points, without U+0000, else `.invalidComment`.
    public static func commentBody(_ raw: String) throws -> String {
        let value = trimmed(raw)
        guard (1...Limits.commentBodyMax).contains(length(value)), !value.unicodeScalars.contains("\u{0}") else {
            throw AppError.invalidComment
        }
        return value
    }

    /// The mentions of a comment as the server stores them, except their membership (checked by the backend, with
    /// the same error): duplicates dropped, the first occurrence and the order kept; at most `Limits.mentionsMax`
    /// distinct ids, else `.invalidMentions`. Mentioning oneself is allowed.
    public static func mentions(_ ids: [UUID]) throws -> [UUID] {
        var seen = Set<UUID>()
        let distinct = ids.filter { seen.insert($0).inserted }
        guard distinct.count <= Limits.mentionsMax else { throw AppError.invalidMentions }
        return distinct
    }

    /// The excerpt of a comment copied into its `comment_added` event: its first `Limits.commentExcerptMax` code
    /// points (SQL `left(body, 80)`).
    public static func commentExcerpt(_ body: String) -> String {
        String(String.UnicodeScalarView(body.unicodeScalars.prefix(Limits.commentExcerptMax)))
    }

    // MARK: - Photo preuve (§6)

    /// JPEG bytes the bucket accepts: not empty, at most `Limits.photoBytesMax` bytes, starting with the JPEG
    /// signature (`FF D8 FF`), else `.invalidPhoto`.
    public static func photo(_ jpegData: Data) throws -> Data {
        guard !jpegData.isEmpty, jpegData.count <= Limits.photoBytesMax, isJPEG(jpegData) else {
            throw AppError.invalidPhoto
        }
        return jpegData
    }

    /// True when `data` starts with the JPEG signature `FF D8 FF`.
    public static func isJPEG(_ data: Data) -> Bool {
        data.count >= 3 && data.prefix(3).elementsEqual([0xFF, 0xD8, 0xFF])
    }

    /// The file extensions of a photo object, lowercase.
    public static let photoExtensions: Set<String> = ["jpg", "jpeg", "png", "heic"]

    /// True when `path` is a photo path of that task, exactly: `<group_id>/<task_id>/<uuid>.<ext>`, the three ids in
    /// lowercase and `<ext>` in `photoExtensions` (`attach_task_photo` also needs the object to exist).
    public static func isPhotoPath(_ path: String, groupId: UUID, taskId: UUID) -> Bool {
        let folder = TaskPhoto.folder(groupId: groupId, taskId: taskId)
        guard path.hasPrefix(folder) else { return false }
        let name = path.dropFirst(folder.count)
        guard let dot = name.lastIndex(of: ".") else { return false }
        let id = String(name[..<dot])
        let fileExtension = String(name[name.index(after: dot)...])
        guard let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id else { return false }
        return photoExtensions.contains(fileExtension)
    }
}
