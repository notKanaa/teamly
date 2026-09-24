import SwiftUI
import UIKit

/// Shown while the stored session is restored (`AppPhase.launching`), usually for a split second.
struct ShellSplashView: View {
    var body: some View {
        VStack(spacing: 24) {
            ShellBrandMark(size: 96)
            ProgressView()
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Chargement d’Équipe")
        .accessibilityIdentifier(AccessibilityID.Shell.splash)
    }
}
