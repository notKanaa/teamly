import SwiftUI
import TeamTasksCore

/// « À tour de rôle » in the « Qui s’en occupe ? » card of the task editor (docs/DESIGN-V2.md §7.7), as rows of its
/// section: the people of the rotation in turn order — their place, avatar, name, the « Commence » / « C’est ton tour »
/// badge, and « Monter » / « Descendre » (a drag reorders too) — then the other members, to add. A tap on a person takes
/// them out of the rotation, or adds them at its end. VoiceOver: each person is one element (place and badge in its
/// value) with « Monter » / « Descendre » actions.
struct TaskEditorRotationRows: View {
    @Bindable var model: TaskEditorViewModel

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: TaskEditorViewModel) {
        self.model = model
    }

    var body: some View {
        let entries = model.rotationEntries
        let included = entries.filter(\.isIncluded)
        let others = entries.filter { !$0.isIncluded }

        ForEach(included) { entry in
            includedRow(entry, count: included.count)
                .listRowInsets(Self.rowInsets)
        }
        .onMove { source, destination in
            withAnimation(animation) {
                model.moveRotation(fromOffsets: source, toOffset: destination)
            }
        }

        if !others.isEmpty {
            Text("Pas dans le tour de rôle")
                .font(Font.footnote.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 6)
            ForEach(others) { entry in
                otherRow(entry)
                    .listRowInsets(Self.rowInsets)
            }
        }

        if let message = model.rotationError {
            TaskEditorErrorText(message: message)
                .font(.footnote)
        }
    }

    private var animation: Animation? { reduceMotion ? nil : .snappy }

    /// 56 pt rows, as on the mockups; the arrows' 44 pt targets reach closer to the card's edge.
    private static var rowInsets: EdgeInsets { EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 8) }

    // MARK: - Rows

    private func includedRow(_ entry: RotationEditorEntry, count: Int) -> some View {
        let position = entry.position ?? 1
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 0))
        return layout {
            Button {
                toggle(entry)
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    RotationPositionBadge(position: position)
                    AvatarView(entry.person.appearance, size: 34)
                    // The badge next to the name when both fit, under it otherwise.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: 8) {
                            nameText(entry.person)
                            badge(entry)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            nameText(entry.person)
                            badge(entry)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Self.fullName(of: entry.person))
            .accessibilityValue(entry.badge.map { "Position \(position), \($0)" } ?? "Position \(position)")
            .accessibilityAddTraits(.isSelected)
            .accessibilityHint("Retire cette personne du tour de rôle.")
            .accessibilityActions {
                if position > 1 {
                    Button("Monter") { move(entry, by: -1) }
                }
                if position < count {
                    Button("Descendre") { move(entry, by: 1) }
                }
            }
            .accessibilityIdentifier(AccessibilityID.Tasks.rotationMember(entry.person.name))

            HStack(spacing: 0) {
                moveButton(entry, by: -1, isEnabled: position > 1)
                moveButton(entry, by: 1, isEnabled: position < count)
            }
        }
    }

    private func nameText(_ person: PersonBadge) -> some View {
        Text(Self.shortName(of: person))
            .font(Font.body.weight(.semibold))
            .foregroundStyle(Theme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// « Commence », « C’est ton tour », « C’est son tour ».
    @ViewBuilder
    private func badge(_ entry: RotationEditorEntry) -> some View {
        if let badge = entry.badge {
            Chip(badge, tone: .accent, weight: .bold)
        }
    }

    private func otherRow(_ entry: RotationEditorEntry) -> some View {
        Button {
            toggle(entry)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .frame(minWidth: 28)
                AvatarView(entry.person.appearance, size: 34)
                Text(Self.shortName(of: entry.person))
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.fullName(of: entry.person))
        .accessibilityValue("Pas dans le tour de rôle")
        .accessibilityHint("Ajoute cette personne à la fin du tour de rôle.")
        .accessibilityIdentifier(AccessibilityID.Tasks.rotationMember(entry.person.name))
    }

    private func moveButton(_ entry: RotationEditorEntry, by offset: Int, isEnabled: Bool) -> some View {
        let isUp = offset < 0
        let name = Self.shortName(of: entry.person)
        return Button {
            move(entry, by: offset)
        } label: {
            Image(systemName: isUp ? "chevron.up" : "chevron.down")
                .font(Font.body.weight(.bold))
                .foregroundStyle(isEnabled ? Theme.accent : Theme.textTertiary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(isUp ? "Monter \(name)" : "Descendre \(name)")
        .accessibilityIdentifier(
            isUp
                ? AccessibilityID.Tasks.rotationMoveUp(entry.person.name)
                : AccessibilityID.Tasks.rotationMoveDown(entry.person.name)
        )
    }

    // MARK: - Actions

    private func toggle(_ entry: RotationEditorEntry) {
        withAnimation(animation) {
            model.toggleRotationMember(entry.id)
        }
    }

    private func move(_ entry: RotationEditorEntry, by offset: Int) {
        withAnimation(animation) {
            model.moveRotationMember(entry.id, by: offset)
        }
    }

    // MARK: - Names

    /// « Inès », « Camille (toi) ».
    static func shortName(of person: PersonBadge) -> String {
        person.isMe ? "\(person.shortName) (toi)" : person.shortName
    }

    /// « Inès Dubois », « Camille Martin (toi) » (VoiceOver).
    static func fullName(of person: PersonBadge) -> String {
        person.isMe ? "\(person.name) (toi)" : person.name
    }
}

/// The place of a person in a rotation: the number on an accent disc (white, rounded heavy). Grows with the text.
struct RotationPositionBadge: View {
    let position: Int

    init(position: Int) {
        self.position = position
    }

    var body: some View {
        Text(String(position))
            .font(.roundedNumber(.subheadline))
            .foregroundStyle(Theme.onFill)
            .lineLimit(1)
            .padding(4)
            .frame(minWidth: 28, minHeight: 28)
            .background(Circle().fill(Theme.accentFill))
            .accessibilityHidden(true)
    }
}
