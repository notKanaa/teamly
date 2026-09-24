import SwiftUI
import TeamTasksCore

/// Due date of a task (« Aujourd’hui à 20:00 », already formatted by the view model), in red when overdue.
/// Without a due date it shows nothing, or « Aucune échéance » when `showsPlaceholder`.
struct TasksDueDateLabel: View {
    let text: String?
    let isOverdue: Bool
    let showsPlaceholder: Bool

    init(text: String?, isOverdue: Bool = false, showsPlaceholder: Bool = false) {
        self.text = text
        self.isOverdue = isOverdue
        self.showsPlaceholder = showsPlaceholder
    }

    var body: some View {
        if let text {
            Label(text, systemImage: isOverdue ? "exclamationmark.circle.fill" : "calendar")
                .foregroundStyle(isOverdue ? Color.red : Color.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText(for: text))
        } else if showsPlaceholder {
            Label("Aucune échéance", systemImage: "calendar")
                .foregroundStyle(Color.secondary)
        }
    }

    private func accessibilityText(for text: String) -> String {
        isOverdue ? "Échéance dépassée : \(text)" : "Échéance : \(text)"
    }
}
