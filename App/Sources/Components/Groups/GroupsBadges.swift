import SwiftUI
import TeamTasksCore

// Small visual building blocks of the « Groupes » tab: initials avatars, role badge, priority label,
// colors and French counts.

/// Initials of a name: « Coloc' rue des Lilas » → « CR », « Camille Martin » → « CM ».
enum GroupsInitials {
    static func make(from name: String, maxLetters: Int = 2) -> String {
        var letters: [Character] = []
        for word in name.split(whereSeparator: { $0.isWhitespace || $0 == "-" }) {
            if let first = word.first(where: { $0.isLetter || $0.isNumber }) {
                letters.append(first)
            }
            if letters.count >= maxLetters { break }
        }
        let initials = String(letters).uppercased()
        return initials.isEmpty ? "?" : initials
    }
}

/// Stable color of a group or a person (the same id always gets the same color, on every launch).
enum GroupsPalette {
    private static var colors: [Color] { [.blue, .indigo, .purple, .pink, .orange, .teal, .green, .red, .brown] }

    static func color(for id: UUID) -> Color {
        // djb2 over the uuid string: `hashValue` is randomized per launch.
        var hash: UInt64 = 5381
        for byte in id.uuidString.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        let palette = colors
        return palette[Int(hash % UInt64(palette.count))]
    }
}

/// Status and priority colors shared by the task rows.
enum GroupsStyle {
    static func statusColor(_ status: TaskStatus) -> Color {
        switch status {
        case .todo: Color.secondary
        case .inProgress: Color.blue
        case .done: Color.green
        }
    }

    static func priorityColor(_ priority: TeamTasksCore.TaskPriority) -> Color {
        switch priority {
        case .high: Color.red
        case .medium: Color.orange
        case .low: Color.gray
        }
    }
}

/// French counts: « 1 tâche », « 3 tâches » (0 takes the singular in French).
enum GroupsText {
    static func taskCount(_ count: Int) -> String {
        count <= 1 ? "\(count) tâche" : "\(count) tâches"
    }

    static func memberCount(_ count: Int) -> String {
        count <= 1 ? "\(count) membre" : "\(count) membres"
    }
}

/// Initials on a colored background (decorative: hidden from VoiceOver, the row says the name).
struct GroupsInitialsBadge: View {
    enum Style {
        case circle
        case roundedSquare
    }

    let text: String
    let color: Color
    var size: CGFloat = 40
    var style: Style = .circle

    var body: some View {
        let label = Text(text)
            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(width: size, height: size)
        switch style {
        case .circle:
            label
                .background(color.gradient, in: Circle())
                .accessibilityHidden(true)
        case .roundedSquare:
            label
                .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}

/// A few people as initials circles, then « +N » (decorative: hidden from VoiceOver).
struct GroupsAvatarStack: View {
    struct Person: Identifiable, Hashable {
        let id: UUID
        let name: String
    }

    let people: [Person]
    var maxVisible = 3
    var size: CGFloat = 26

    var body: some View {
        HStack(spacing: 3) {
            if people.isEmpty {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: size * 0.8))
                    .foregroundStyle(Color.secondary)
                    .frame(width: size, height: size)
            } else {
                ForEach(people.prefix(maxVisible)) { person in
                    GroupsInitialsBadge(
                        text: GroupsInitials.make(from: person.name),
                        color: GroupsPalette.color(for: person.id),
                        size: size,
                        style: .circle
                    )
                }
                if people.count > maxVisible {
                    Text("+\(people.count - maxVisible)")
                        .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.secondary)
                        .frame(width: size, height: size)
                        .background(Color.secondary.opacity(0.15), in: Circle())
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// « Admin » / « Membre » capsule.
struct GroupsRoleBadge: View {
    let role: MemberRole

    var body: some View {
        let tint = role == .admin ? Color.accentColor : Color.secondary
        Text(role.label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
            .accessibilityLabel("Rôle : \(role.label)")
    }
}

/// « Haute » / « Moyenne » / « Basse » with its symbol and color.
struct GroupsPriorityLabel: View {
    let priority: TeamTasksCore.TaskPriority

    var body: some View {
        Label(priority.label, systemImage: priority.systemImage)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(GroupsStyle.priorityColor(priority))
    }
}
