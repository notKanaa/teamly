import SwiftUI

// Typography of docs/DESIGN-V2.md §2: titles, numbers, section titles and buttons in SF Pro Rounded (heavy / bold),
// body text in SF Pro. Every font is a Dynamic Type text style: never a fixed size for text that informs.
//
//   screen title        .rounded(.largeTitle)                (the navigation bars get it from NavigationBarAppearance)
//   step / hero title   .rounded(.title)
//   block title         .rounded(.title3, weight: .heavy)    (« À qui le tour ? », « Checklist »)
//   card title          .headline                            (a task title), .rounded(.headline, weight: .heavy) (a group)
//   meta                .subheadline / .footnote
//   chip                .chip                                (footnote, semibold)
//   button              .rounded(.headline, weight: .bold)   (PrimaryButtonStyle)
//   number              .roundedNumber(.title2)              (rings, podium, counts: fixed-width digits)

extension Font {
    /// SF Pro Rounded in a Dynamic Type text style, heavy by default.
    static func rounded(_ style: Font.TextStyle, weight: Font.Weight = .heavy) -> Font {
        .system(style, design: .rounded, weight: weight)
    }

    /// Rounded figures with fixed-width digits (progress rings, podium, counts), heavy by default.
    static func roundedNumber(_ style: Font.TextStyle, weight: Font.Weight = .heavy) -> Font {
        .system(style, design: .rounded, weight: weight).monospacedDigit()
    }

    /// Text of the chips: footnote, semibold.
    static var chip: Font { .footnote.weight(.semibold) }
}

/// The title of a group of rows or cards.
/// - `.small`: above a list or a card (« En retard », « Aujourd’hui », « Quand »): subheadline heavy, `textSecondary`.
/// - `.large`: a titled block of a screen (« À qui le tour ? », « Fil d’activité »): rounded heavy title3,
///   `textPrimary`.
/// An optional `trailing` text sits on the other side (« 2 tâches tournantes », a day). Marked as a header.
struct SectionTitle: View {
    enum Size {
        case small
        case large
    }

    let title: String
    var size: Size
    /// nil: `textSecondary` (small) or `textPrimary` (large). « En retard » uses `Theme.danger`.
    var color: Color?
    var trailing: String?

    init(_ title: String, size: Size = .small, color: Color? = nil, trailing: String? = nil) {
        self.title = title
        self.size = size
        self.color = color
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(size == .small ? Font.subheadline.weight(.heavy) : Font.rounded(.title3, weight: .heavy))
                .foregroundStyle(color ?? (size == .small ? Theme.textSecondary : Theme.textPrimary))
                .accessibilityAddTraits(.isHeader)
            if let trailing {
                Spacer(minLength: 8)
                Text(trailing)
                    .font(Font.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, size == .small ? 4 : 0)
    }
}
