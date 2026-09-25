import SwiftUI
import TeamTasksCore

/// First-load placeholder of a screen of the « Groupes » tab: a spinner while loading, or the failure message with
/// « Réessayer ». Shows nothing once loaded.
struct GroupsLoadStateView: View {
    let loadState: LoadState
    /// « Réessayer »: the view calls `reload()` of its model.
    let retry: () -> Void

    init(loadState: LoadState, retry: @escaping () -> Void) {
        self.loadState = loadState
        self.retry = retry
    }

    var body: some View {
        if let message = loadState.failureMessage {
            GroupsStateView(
                systemImage: "wifi.exclamationmark",
                tone: .danger,
                title: "Chargement impossible",
                message: message
            ) {
                PrimaryButton("Réessayer", systemImage: "arrow.clockwise", action: retry)
                    .accessibilityIdentifier(AccessibilityID.Groups.retryButton)
            }
        } else if !loadState.isLoaded {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Theme.accent)
                Text("Chargement…")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.Groups.loading)
        }
    }
}
