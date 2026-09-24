import SwiftUI
import TeamTasksCore

/// Horizontal, scrollable filter chips of a task list (« Toutes », « À faire », « En cours », « Terminées »,
/// « Assignées à moi », « En retard »). The chips and what a tap does come from the view model.
struct GroupsFilterChipBar: View {
    let chips: [TaskFilterChip]
    let onToggle: (TaskFilterChip.Kind) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips) { chip in
                    Button {
                        onToggle(chip.kind)
                    } label: {
                        Text(chip.label)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(chip.isSelected ? Color.white : Color.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                chip.isSelected ? Color.accentColor : Color.secondary.opacity(0.15),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chip.isSelected ? .isSelected : [])
                    .accessibilityHint("Filtre de la liste des tâches")
                    .accessibilityIdentifier(AccessibilityID.Groups.filterChip(Self.key(for: chip.kind)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Tasks.filterPicker)
    }

    /// Stable identifier suffix of a chip.
    static func key(for kind: TaskFilterChip.Kind) -> String {
        switch kind {
        case let .status(status): status.rawValue
        case .assignedToMe: "assignedToMe"
        case .overdue: "overdue"
        }
    }
}
