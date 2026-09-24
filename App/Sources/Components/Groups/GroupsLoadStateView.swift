import SwiftUI
import TeamTasksCore

/// First-load placeholder of a screen: a spinner while loading, or the failure message with « Réessayer ».
/// Shows nothing once loaded (use it in an `.overlay` of the screen's list).
struct GroupsLoadStateView: View {
    let loadState: LoadState
    /// « Réessayer »: the view calls `reload()` of its model.
    let retry: () -> Void

    var body: some View {
        if let message = loadState.failureMessage {
            ContentUnavailableView {
                Label("Chargement impossible", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button {
                    retry()
                } label: {
                    Label("Réessayer", systemImage: "arrow.clockwise")
                }
                .shellProminentButtonStyle()
                .accessibilityIdentifier(AccessibilityID.Groups.retryButton)
            }
        } else if !loadState.isLoaded {
            ProgressView("Chargement…")
                .accessibilityIdentifier(AccessibilityID.Groups.loading)
        }
    }
}
