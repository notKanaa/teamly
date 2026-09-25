import SwiftUI

/// Shown while the stored session is restored (`AppPhase.launching`), usually for a split second: the app icon on the
/// grouped background.
struct ShellSplashView: View {
    var body: some View {
        VStack(spacing: 28) {
            ShellBrandMark(size: 96)
            ProgressView()
                .controlSize(.large)
                .tint(Theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Chargement d’Équipe")
        .accessibilityIdentifier(AccessibilityID.Shell.splash)
    }
}
