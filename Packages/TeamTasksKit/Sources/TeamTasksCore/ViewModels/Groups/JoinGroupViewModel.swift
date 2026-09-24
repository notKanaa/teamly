import Foundation
import Observation

/// « Rejoindre un groupe » sheet. The code field is formatted live as `ABCD-EFGH` (uppercase, only letters and
/// digits, 8 characters at most). On success `result` is set: dismiss and show the group
/// (`router.showGroup(result.groupId)`); `resultMessage` says whether it was joined or already joined.
@MainActor
@Observable
public final class JoinGroupViewModel: ErrorPresenting {
    public static let placeholder = "ABCD-EFGH"
    public static let incompleteCodeMessage = "Le code contient 8 caractères, par exemple ABCD-EFGH."

    /// Live-formatted code: whatever is typed or pasted becomes `ABCD-EFGH`.
    public var code: String {
        get { codeValue }
        set { codeValue = Self.format(newValue) }
    }

    public private(set) var isSubmitting = false
    public private(set) var result: JoinResult?
    public var error: ErrorState?

    public let session: SessionModel
    private var codeValue = ""

    public init(session: SessionModel, code: String = "") {
        self.session = session
        codeValue = Self.format(code)
    }

    /// 8 characters typed.
    public var isCodeComplete: Bool { InviteCode.normalize(codeValue).count == InviteCode.length }
    public var canSubmit: Bool { isCodeComplete && !isSubmitting }

    /// « Vous avez rejoint « X ». » / « Vous faites déjà partie de « X ». »
    public var resultMessage: String? {
        guard let result else { return nil }
        return result.alreadyMember
            ? "Vous faites déjà partie de « \(result.groupName) »."
            : "Vous avez rejoint « \(result.groupName) »."
    }

    /// Joins with the code. Invalid codes (checked locally, then by the server), too many attempts
    /// (« Réessayez dans une heure ») and network errors are shown in `error`.
    @discardableResult
    public func join() async -> JoinResult? {
        guard !isSubmitting else { return nil }
        error = nil
        guard isCodeComplete else {
            present(message: Self.incompleteCodeMessage, error: .invalidCode)
            return nil
        }
        guard let inviteCode = InviteCode(codeValue) else {
            present(AppError.invalidCode)
            return nil
        }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let joined = try await session.services.groups.join(code: inviteCode)
            result = joined
            session.feed.bumpMemberships()
            session.feed.bump(groupId: joined.groupId)
            session.feed.bumpMyTasks()
            return joined
        } catch {
            present(error)
            return nil
        }
    }

    /// `abcd efgh` → `ABCD-EFGH`, `abcde` → `ABCD-E`; keeps at most 8 letters or digits.
    public static func format(_ input: String) -> String {
        let characters = Array(InviteCode.normalize(input).prefix(InviteCode.length))
        let half = InviteCode.length / 2
        guard characters.count > half else { return String(characters) }
        return String(characters[..<half]) + "-" + String(characters[half...])
    }
}
