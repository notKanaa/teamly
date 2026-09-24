import Foundation

/// A French message shown by a screen (alert, banner or inline text).
///
/// Built from `AppError.messageFR`, or from a client-side validation message. Every instance is distinct
/// (`id`), so presenting the same error twice shows it twice.
public struct ErrorState: Sendable, Hashable, Identifiable {
    public let id: UUID
    /// Message shown to the user (French).
    public let message: String
    /// The underlying error; nil for purely client-side messages.
    public let error: AppError?

    public init(_ error: AppError) {
        id = UUID()
        self.error = error
        message = error.messageFR
    }

    public init(message: String, error: AppError? = nil) {
        id = UUID()
        self.message = message
        self.error = error
    }

    /// nil when `error` is a cancellation: a cancelled SwiftUI `.task` must never surface « annulé »
    /// (docs/CONTRACTS.md §9). Any other error is wrapped with `AppError.wrap`.
    public init?(from error: any Error) {
        guard !ErrorState.isCancellation(error) else { return nil }
        self.init(AppError.wrap(error))
    }

    /// True for `CancellationError`, a cancelled URL request, and `AppError.wrap(CancellationError())`.
    public static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        if let appError = error as? AppError, appError == AppError.wrap(CancellationError()) { return true }
        return false
    }
}

/// A view model that reports errors through `error` (shown as an alert or a banner by the view).
///
/// Views typically write:
/// `.alert("Erreur", isPresented: $model.isShowingError) { Button("OK", role: .cancel) {} } message: { Text(model.errorMessage ?? "") }`
@MainActor
public protocol ErrorPresenting: AnyObject {
    /// The error to show, nil when none.
    var error: ErrorState? { get set }
}

extension ErrorPresenting {
    /// French message of `error`.
    public var errorMessage: String? { error?.message }

    /// Binding-friendly flag: setting it to false clears `error`.
    public var isShowingError: Bool {
        get { error != nil }
        set {
            if !newValue { error = nil }
        }
    }

    public func dismissError() {
        error = nil
    }

    /// Shows `error` unless it is a cancellation. Returns the `AppError` shown, nil for a cancellation.
    @discardableResult
    func present(_ error: any Error) -> AppError? {
        guard let state = ErrorState(from: error) else { return nil }
        self.error = state
        return state.error
    }

    /// Shows a client-side message.
    func present(message: String, error appError: AppError? = nil) {
        error = ErrorState(message: message, error: appError)
    }
}

/// Loading state of a screen's content.
///
/// - `idle`: never loaded (or the first load was cancelled);
/// - `loading`: first load in progress, nothing to show yet (later reloads keep `loaded`);
/// - `loaded`: content available (possibly empty);
/// - `failed(message)`: the first load failed; the view shows the message and a « Réessayer » button
///   calling `reload()`. A reload failing after a successful load keeps `loaded` and sets `error` instead.
public enum LoadState: Sendable, Hashable {
    case idle
    case loading
    case loaded
    case failed(String)

    public var isLoading: Bool { self == .loading }
    public var isLoaded: Bool { self == .loaded }

    /// Message of `failed`, nil otherwise.
    public var failureMessage: String? {
        if case let .failed(message) = self { return message }
        return nil
    }
}

/// Identity of what a list screen shows: views reload with `.task(id: model.refreshKey) { await model.load() }`.
///
/// `revision` comes from the session's `ChangeFeed` (it changes when the server signals a change, after the
/// user's own mutations, on realtime reconnection and on return to foreground); `includeDone` is the screen's
/// "show done tasks" toggle, so flipping it reloads too.
public struct RefreshKey: Sendable, Hashable {
    public var revision: Int
    public var includeDone: Bool

    public init(revision: Int, includeDone: Bool = false) {
        self.revision = revision
        self.includeDone = includeDone
    }
}
