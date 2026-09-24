import SwiftUI

/// Full-width label of a primary action button that shows a spinner while the action runs.
///
/// Use with `.buttonStyle(.borderedProminent)` and `.controlSize(.large)`.
struct ShellPrimaryButtonLabel: View {
    let title: String
    var isLoading = false

    var body: some View {
        ZStack {
            Text(title)
                .font(.headline)
                .opacity(isLoading ? 0 : 1)
            if isLoading {
                ProgressView()
                    .tint(.white)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isLoading ? "En cours" : "")
    }
}
