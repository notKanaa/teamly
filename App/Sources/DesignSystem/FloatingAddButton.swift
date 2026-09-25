import SwiftUI

/// The floating « + » of the group screen (docs/DESIGN-V2.md §5): a 60 pt rounded square in `accentFill` with a
/// white symbol and a soft accent shadow in light mode. Place it with `.floatingAddButton(_:identifier:action:)`, which
/// keeps it bottom trailing above the tab bar and makes room for it at the end of the scrolling content.
struct FloatingAddButton: View {
    let accessibilityLabel: String
    var systemImage: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    init(accessibilityLabel: String, systemImage: String = "plus", action: @escaping () -> Void) {
        self.accessibilityLabel = accessibilityLabel
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Theme.onFill)
                .frame(width: 60, height: 60)
                .background {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Theme.accentFill)
                        .shadow(
                            color: Theme.accentFill.opacity(colorScheme == .dark ? 0 : 0.4),
                            radius: 13, x: 0, y: 12
                        )
                }
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(accessibilityLabel)
    }
}

extension View {
    /// Adds a `FloatingAddButton` at the bottom trailing corner of the screen, 20 pt from the edge, above the tab bar
    /// (a bottom safe-area inset: lists and scroll views end above it).
    ///
    /// ```swift
    /// ScrollView { … }
    ///     .floatingAddButton("Nouvelle tâche", identifier: AccessibilityID.Tasks.addButton) { isShowingEditor = true }
    /// ```
    func floatingAddButton(
        _ accessibilityLabel: String,
        identifier: String? = nil,
        systemImage: String = "plus",
        action: @escaping () -> Void
    ) -> some View {
        safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
            FloatingAddButton(accessibilityLabel: accessibilityLabel, systemImage: systemImage, action: action)
                .accessibilityIdentifierIfPresent(identifier)
                .padding(.trailing, Theme.Spacing.page)
                .padding(.bottom, 12)
        }
    }
}
