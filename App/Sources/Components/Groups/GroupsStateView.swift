import SwiftUI

/// An empty or unavailable state of the groups screens (no group, no task, an empty feed, a group that is gone, a
/// failed load): an icon tile, a rounded title, a message and optional actions, centered (docs/DESIGN-V2.md §1).
/// It is an accessibility container: the caller puts its identifier on it, and its buttons stay separate elements.
///
/// ```swift
/// GroupsStateView(systemImage: "person.2.fill", title: "Aucun groupe", message: message) {
///     PrimaryButton("Créer un groupe", systemImage: "plus", action: create)
/// }
/// .accessibilityIdentifier(AccessibilityID.Groups.emptyState)
/// ```
struct GroupsStateView<Actions: View>: View {
    let systemImage: String
    var tone: SoftTone
    let title: String
    var message: String?
    let actions: Actions

    init(
        systemImage: String,
        tone: SoftTone = .accent,
        title: String,
        message: String? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.systemImage = systemImage
        self.tone = tone
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 14) {
            IconTile(systemImage: systemImage, tone: tone, size: 64)
                .padding(.bottom, 4)
            Text(title)
                .font(.rounded(.title2))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let message {
                Text(message)
                    .font(.body)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 6) {
                actions
            }
            .frame(maxWidth: 380)
            .padding(.top, 6)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

extension GroupsStateView where Actions == EmptyView {
    /// A state without actions.
    init(systemImage: String, tone: SoftTone = .accent, title: String, message: String? = nil) {
        self.init(systemImage: systemImage, tone: tone, title: title, message: message) {
            EmptyView()
        }
    }
}
