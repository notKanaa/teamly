import SwiftUI
import TeamTasksCore

/// « Assigner à » screen pushed from the task editor: the group's members (admins first, then by name) with their
/// avatar and a search field; a tap adds or removes an assignee (20 at most, the editor refuses more with a message).
struct TaskEditorAssigneePicker: View {
    let model: TaskEditorViewModel
    @State private var searchText = ""

    var body: some View {
        List {
            if let message = model.assigneesError {
                Section {
                    TaskEditorErrorText(message: message)
                }
                .listRowBackground(Theme.card)
            }

            Section {
                ForEach(filteredOptions) { option in
                    optionRow(option)
                }
            } footer: {
                Text(selectionSummary)
                    .foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.card)
        }
        .listStyle(.insetGrouped)
        .screenBackground()
        .accessibilityIdentifier(AccessibilityID.Tasks.assigneeList)
        .overlay {
            if filteredOptions.isEmpty {
                noResultView
            }
        }
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Rechercher un membre"
        )
        .navigationTitle("Assigner à")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Tout retirer") {
                    clearSelection()
                }
                .disabled(model.assigneeIds.isEmpty)
            }
        }
    }

    private func optionRow(_ option: AssigneeOption) -> some View {
        let isBlocked = !option.isSelected && model.assigneeLimitReached
        return Button {
            model.toggleAssignee(option.id)
        } label: {
            HStack(spacing: 12) {
                AvatarView(appearances[option.id] ?? .unknown(id: option.id), size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.name)
                        .font(Font.body.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if option.role == .admin {
                        Text(option.role.label)
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: option.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(option.isSelected ? Theme.accent : Theme.textSecondary)
            }
            .frame(minHeight: 44)
            .opacity(isBlocked ? 0.45 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(for: option))
        .accessibilityAddTraits(option.isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(AccessibilityID.Tasks.assigneeRow(option.name))
    }

    @ViewBuilder
    private var noResultView: some View {
        if model.assigneeOptions.isEmpty {
            ContentUnavailableView(
                "Aucun membre",
                systemImage: "person.2.slash",
                description: Text("Ce groupe n’a pas encore de membres à assigner.")
            )
        } else {
            ContentUnavailableView(
                "Aucun résultat",
                systemImage: "magnifyingglass",
                description: Text(noResultMessage)
            )
        }
    }

    // MARK: - Helpers

    /// The members' avatars, by user id.
    private var appearances: [UUID: AvatarAppearance] {
        Dictionary(model.members.map { ($0.user.id, $0.user.appearance) }, uniquingKeysWith: { first, _ in first })
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredOptions: [AssigneeOption] {
        let query = trimmedSearch
        let options = model.assigneeOptions
        guard !query.isEmpty else { return options }
        return options.filter { $0.name.localizedStandardContains(query) }
    }

    private var noResultMessage: String {
        "Aucun membre ne correspond à «\u{00A0}\(trimmedSearch)\u{00A0}»."
    }

    /// « 2 personnes sélectionnées sur 20 au maximum. »
    private var selectionSummary: String {
        let count = model.assigneeIds.count
        let selected = count > 1 ? "\(count) personnes sélectionnées" : "\(count) personne sélectionnée"
        return "\(selected) sur \(TaskEditorViewModel.maxAssignees) au maximum."
    }

    /// Name and role; the selection itself is announced through the `.isSelected` trait.
    private func accessibilityText(for option: AssigneeOption) -> String {
        option.role == .admin ? "\(option.name), \(option.role.label)" : option.name
    }

    private func clearSelection() {
        for userId in model.assigneeIds {
            model.toggleAssignee(userId)
        }
    }
}
