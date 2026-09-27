import SwiftUI
import TeamTasksCore

/// « Nouvelle tâche » from the home-screen quick action, when the user has several groups: the groups as cards (tile,
/// name, role); picking one opens its task editor (`onPick`).
struct QuickNewTaskGroupPicker: View {
    let groups: [GroupSummary]
    let onPick: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    init(groups: [GroupSummary], onPick: @escaping (UUID) -> Void) {
        self.groups = groups
        self.onPick = onPick
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle("Dans quel groupe\u{00A0}?")
                    ForEach(groups) { summary in
                        Button {
                            onPick(summary.id)
                        } label: {
                            row(summary)
                        }
                        .buttonStyle(.pressable)
                        .accessibilityIdentifier(AccessibilityID.QuickActions.group(summary.group.name))
                    }
                }
                .padding(.horizontal, Theme.Spacing.pageDense)
                .padding(.vertical, 16)
            }
            .accessibilityIdentifier(AccessibilityID.QuickActions.groupPicker)
            .screenBackground()
            .navigationTitle("Nouvelle tâche")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        dismiss()
                    }
                    .accessibilityIdentifier(AccessibilityID.QuickActions.cancel)
                }
            }
        }
    }

    private func row(_ summary: GroupSummary) -> some View {
        HStack(spacing: 14) {
            GroupTile(summary.group.appearance, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.group.name)
                    .font(.rounded(.headline, weight: .heavy))
                    .foregroundStyle(Theme.textPrimary)
                Text(summary.myRole == .admin ? "Tu es admin" : "Tu es membre")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(Font.footnote.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
        }
        .padding(Theme.Spacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
