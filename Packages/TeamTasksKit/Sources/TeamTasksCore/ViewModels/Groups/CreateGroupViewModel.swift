import Foundation
import Observation

/// « Nouveau groupe » sheet. On success `createdGroup` is set: dismiss and show it
/// (`router.showGroup(group.id)`). The creator is the group's admin.
@MainActor
@Observable
public final class CreateGroupViewModel: ErrorPresenting {
    public static let maxNameLength = Limits.groupName.upperBound

    public var name: String {
        get { nameValue }
        set {
            nameValue = newValue
            if nameError != nil { nameError = Self.nameMessage(newValue) }
        }
    }

    public private(set) var nameError: String?
    public private(set) var isSubmitting = false
    public private(set) var createdGroup: GroupSummary?
    public var error: ErrorState?

    public let session: SessionModel
    private var nameValue = ""

    public init(session: SessionModel) {
        self.session = session
    }

    public var canSubmit: Bool { !InputValidation.trimmed(nameValue).isEmpty && !isSubmitting }

    /// Creates the group. Returns it on success, nil otherwise (`nameError` or `error` set).
    @discardableResult
    public func create() async -> GroupSummary? {
        guard !isSubmitting else { return nil }
        error = nil
        nameError = Self.nameMessage(nameValue)
        guard nameError == nil else { return nil }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let group = try await session.services.groups.createGroup(name: nameValue)
            createdGroup = group
            session.feed.bumpMemberships()
            return group
        } catch {
            guard let appError = ErrorState(from: error)?.error else { return nil }
            if appError == .invalidName {
                nameError = appError.messageFR
            } else {
                present(appError)
            }
            return nil
        }
    }

    public static func nameMessage(_ name: String) -> String? {
        do {
            _ = try InputValidation.groupName(name)
            return nil
        } catch {
            return AppError.invalidName.messageFR
        }
    }
}
