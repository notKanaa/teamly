import SwiftUI
import TeamTasksCore

/// Initials and color of a person's avatar, derived from the display name only (stable across launches).
enum TasksInitials {
    /// « Camille Martin » → « CM », « Vous » → « V », empty → « ? ».
    static func initials(of name: String) -> String {
        let words = name.split { $0.isWhitespace || $0 == "-" }
        let letters = words.prefix(2).compactMap { $0.first }
        let result = String(letters).uppercased()
        return result.isEmpty ? "?" : result
    }

    /// One of eight colors, chosen from the name's Unicode scalars (not `hashValue`, which changes per launch).
    static func color(for name: String) -> Color {
        var sum = 0
        for scalar in name.unicodeScalars {
            sum = (sum &* 31 &+ Int(scalar.value)) & 0x7FFF_FFFF
        }
        switch sum % 8 {
        case 0: return Color.blue
        case 1: return Color.indigo
        case 2: return Color.purple
        case 3: return Color.pink
        case 4: return Color.orange
        case 5: return Color.teal
        case 6: return Color.green
        default: return Color.brown
        }
    }
}

/// Round avatar with a person's initials. Decorative: hidden from VoiceOver (the name is always shown next to it
/// or in the parent's accessibility label).
struct TasksInitialsAvatar: View {
    let name: String
    let size: CGFloat

    init(name: String, size: CGFloat = 28) {
        self.name = name
        self.size = size
    }

    var body: some View {
        Text(TasksInitials.initials(of: name))
            .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .foregroundStyle(Color.white)
            .frame(width: size, height: size)
            .background(TasksInitials.color(for: name), in: Circle())
            .accessibilityHidden(true)
    }
}

/// Overlapping initials of a task's assignees (at most `maxVisible`, then « +N »). One accessibility element:
/// « Assignée à Vous, Lucas Bernard » / « Non assignée ».
struct TasksAssigneeInitials: View {
    let names: [String]
    let maxVisible: Int
    let size: CGFloat

    init(names: [String], maxVisible: Int = 3, size: CGFloat = 24) {
        self.names = names
        self.maxVisible = max(1, maxVisible)
        self.size = size
    }

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(Array(names.prefix(maxVisible).enumerated()), id: \.offset) { item in
                TasksInitialsAvatar(name: item.element, size: size)
                    .overlay { Circle().stroke(.background, lineWidth: 1.5) }
            }
            if names.count > maxVisible {
                Text("+\(names.count - maxVisible)")
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(Color.secondary)
                    .frame(width: size, height: size)
                    .background(Color.secondary.opacity(0.15), in: Circle())
                    .overlay { Circle().stroke(.background, lineWidth: 1.5) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        names.isEmpty ? MemberDirectory.unassignedText : "Assignée à \(names.joined(separator: ", "))"
    }
}
