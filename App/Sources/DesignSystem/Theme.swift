import SwiftUI
import TeamTasksCore
import UIKit

// Design tokens of the v2 redesign « Moderne & coloré » (docs/DESIGN-V2.md §3–4, API in docs/DESIGN-V2-COMPONENTS.md).
// Every color has a light and a dark value, resolved by the traits of the view that draws it (a dynamic `UIColor`):
// use the tokens as they are, never with a `colorScheme` check.

/// The neutral color tokens (docs/DESIGN-V2.md §3), corner radii and spacing (§4).
enum Theme {
    // MARK: - Neutrals

    /// Screen ground (the grouped background): #F4F3F8 / #0F0E17. Put it behind a screen with `.screenBackground()`.
    static var background: Color { dynamic(light: 0xF4F3F8, dark: 0x0F0E17) }
    /// Cards, rows and the content of sheets: #FFFFFF / #1C1A27. See `Card` and `.cardSurface()`.
    static var card: Color { dynamic(light: 0xFFFFFF, dark: 0x1C1A27) }
    /// Tracks of the segmented pills and progress bars: #E9E7F0 / #2B2840.
    static var track: Color { dynamic(light: 0xE9E7F0, dark: 0x2B2840) }
    /// A stronger track: inactive onboarding steps, dashed borders, outlines of idle filter chips: #DDDAE8 / #3A3656.
    static var trackStrong: Color { dynamic(light: 0xDDDAE8, dark: 0x3A3656) }
    /// Separators inside cards: #F1EFF6 / #2B2840.
    static var hairline: Color { dynamic(light: 0xF1EFF6, dark: 0x2B2840) }
    /// Titles and body text: #16141F / #F4F3F8.
    static var textPrimary: Color { dynamic(light: 0x16141F, dark: 0xF4F3F8) }
    /// Meta text and captions: #5F5C6E / #ABA8BD (5.9:1 / 7.4:1 on `card`).
    static var textSecondary: Color { dynamic(light: 0x5F5C6E, dark: 0xABA8BD) }
    /// Decorative glyphs that carry no information (drag handles, the dashed « Personne » circle): #A8A4B8 / #6E6A85.
    /// Never for text.
    static var textTertiary: Color { dynamic(light: 0xA8A4B8, dark: 0x6E6A85) }
    /// Brand indigo for text, links, icons, tints and selection rings: #4B3BE6 / #9D93FF.
    static var accent: Color { dynamic(light: 0x4B3BE6, dark: 0x9D93FF) }
    /// Brand indigo behind white text (primary buttons, « Nouveau », selected fills): #4B3BE6 / #5B4CF0.
    static var accentFill: Color { dynamic(light: 0x4B3BE6, dark: 0x5B4CF0) }
    /// Soft accent surface (selected tab pill, soft accent chips, selected emoji): #ECEAFD / #2A2650.
    static var accentSoft: Color { dynamic(light: 0xECEAFD, dark: 0x2A2650) }
    /// Text and icons on `accentSoft`: #4B3BE6 / #B7B0FF.
    static var accentSoftText: Color { dynamic(light: 0x4B3BE6, dark: 0xB7B0FF) }
    /// Text and icons on colored fills (group tiles, avatars, primary buttons, the group hero): white.
    static var onFill: Color { .white }
    /// Overdue dates, errors, « En retard »: #BE123C / #FF8B8B (the text of `SoftTone.danger`).
    static var danger: Color { dynamic(light: 0xBE123C, dark: 0xFF8B8B) }
    /// Color of the light-mode shadows (#161428, used with a low opacity).
    static var shadow: Color { Color(red: 22 / 255, green: 20 / 255, blue: 40 / 255) }

    // MARK: - Shape and spacing (docs/DESIGN-V2.md §4)

    /// Corner radii, always drawn with continuous corners (`RoundedRectangle(cornerRadius:style: .continuous)`).
    enum Radius {
        /// Cards (`Card`, `.cardSurface()`).
        static let card: CGFloat = 22
        /// Task rows (`TaskRowCard`).
        static let row: CGFloat = 20
        /// Big buttons (`PrimaryButtonStyle`, height 56).
        static let button: CGFloat = 18
        /// Text fields and the invite code field.
        static let field: CGFloat = 16
        /// Track of a `SegmentedPill`.
        static let track: CGFloat = 16
        /// Segments of a `SegmentedPill`, swatches.
        static let segment: CGFloat = 12
    }

    /// Spacing constants.
    enum Spacing {
        /// Page margins.
        static let page: CGFloat = 20
        /// Page margins of dense lists.
        static let pageDense: CGFloat = 16
        /// Gap between two cards (10–16).
        static let cardGap: CGFloat = 12
        /// Inner padding of a card (14–18).
        static let cardPadding: CGFloat = 16
    }

    // MARK: - Dynamic colors

    /// A color with a light and a dark value (`0xRRGGBB`, sRGB, opaque).
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: dynamicUIColor(light: light, dark: dark))
    }

    /// The UIKit color of `dynamic(light:dark:)` (navigation bar appearance).
    static func dynamicUIColor(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        }
    }
}

extension UIColor {
    /// An opaque sRGB color from `0xRRGGBB`.
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Soft tones

/// A soft pair of docs/DESIGN-V2.md §3, a `background` and the `foreground` drawn on it (≥ 4.5:1), with the solid
/// `fill` of the same hue (white text on it). Used by chips, icon tiles, selected segments, the soft headers.
struct SoftTone: Hashable {
    var background: Color
    var foreground: Color
    var fill: Color
}

extension SoftTone {
    /// The brand accent: `accentSoft` / `accentSoftText`, fill `accentFill`.
    static var accent: SoftTone {
        SoftTone(background: Theme.accentSoft, foreground: Theme.accentSoftText, fill: Theme.accentFill)
    }

    /// « Priorité haute », « en retard », errors: #FFE4E6 / #BE123C (dark #3A1818 / #FF8B8B), fill #BE123C.
    static var danger: SoftTone {
        SoftTone(
            background: Theme.dynamic(light: 0xFFE4E6, dark: 0x3A1818),
            foreground: Theme.danger,
            fill: Theme.dynamic(light: 0xBE123C, dark: 0xBE123C)
        )
    }

    /// « Priorité basse », « +N » circles, neutral chips: #EEEDF3 / #5F5C6E (dark #2A2833 / #C9C6D6), fill #5F5C6E.
    static var neutral: SoftTone {
        SoftTone(
            background: Theme.dynamic(light: 0xEEEDF3, dark: 0x2A2833),
            foreground: Theme.dynamic(light: 0x5F5C6E, dark: 0xC9C6D6),
            fill: Theme.dynamic(light: 0x5F5C6E, dark: 0x5F5C6E)
        )
    }

    /// « À faire »: the indigo soft pair.
    static var todo: SoftTone { ColorKey.indigo.tone }
    /// « En cours »: the amber soft pair (#FEF3C7 / #B45309).
    static var inProgress: SoftTone { ColorKey.amber.tone }
    /// « Terminée »: the green soft pair (#DCFCE7 / #15803D).
    static var done: SoftTone { ColorKey.green.tone }

    /// A plain colored text, without background (`Chip` style `.plain`): the foreground and the fill are `color`.
    static func ink(_ color: Color) -> SoftTone {
        SoftTone(background: .clear, foreground: color, fill: color)
    }
}

// MARK: - Palette (ColorKey)

extension ColorKey {
    /// The solid fill, the same in both appearances, with white text on it (≥ 4.5:1): group tiles, avatars, the group
    /// hero, progress bars.
    var fill: Color { Color(uiColor: UIColor(rgb: values.fill)) }

    /// The soft pair of the color (chips, icon tiles) and its `fill`.
    var tone: SoftTone {
        SoftTone(
            background: Theme.dynamic(light: values.softLight, dark: values.softDark),
            foreground: Theme.dynamic(light: values.textLight, dark: values.textDark),
            fill: fill
        )
    }

    /// The color drawn as a line or a glyph on `card` or `background` (the ring of a task to do, a group's icons): the
    /// fill in light mode, the bright soft text in dark mode, where most fills are too dark to see.
    var accent: Color { Theme.dynamic(light: values.fill, dark: values.textDark) }

    /// docs/DESIGN-V2.md §3: fill, soft light background and text, soft dark background and text.
    private var values: (fill: UInt32, softLight: UInt32, textLight: UInt32, softDark: UInt32, textDark: UInt32) {
        switch self {
        case .indigo: (0x4B3BE6, 0xECEAFD, 0x4B3BE6, 0x2A2650, 0xB7B0FF)
        case .violet: (0x7C3AED, 0xEDE9FE, 0x6D28D9, 0x2A1F4A, 0xB9A6FF)
        case .blue: (0x2563EB, 0xDBEAFE, 0x1D4ED8, 0x172542, 0x93B4FF)
        case .teal: (0x0F766E, 0xCCFBF1, 0x0F766E, 0x0F2E2B, 0x5EEAD4)
        case .green: (0x15803D, 0xDCFCE7, 0x15803D, 0x12301F, 0x6EE7A8)
        case .amber: (0xA16207, 0xFEF3C7, 0xB45309, 0x3A2A0E, 0xFCC76A)
        case .orange: (0xC2410C, 0xFFEDD5, 0xC2410C, 0x3B2210, 0xFFA86B)
        case .coral: (0xD6385A, 0xFFE4E9, 0xB01F3F, 0x3A1D28, 0xFF8FA3)
        case .pink: (0xBE185D, 0xFCE7F3, 0xBE185D, 0x3B1830, 0xF9A8D4)
        }
    }
}

// MARK: - Statuses and priorities

extension TaskStatus {
    /// Chips and selected segments: « À faire » indigo, « En cours » amber, « Terminée » green (docs/DESIGN-V2.md §3).
    var tone: SoftTone {
        switch self {
        case .todo: SoftTone.todo
        case .inProgress: SoftTone.inProgress
        case .done: SoftTone.done
        }
    }
}

extension TeamTasksCore.TaskPriority {
    /// Chips and selected segments: « Haute » `danger`, « Moyenne » orange, « Basse » `neutral`.
    var tone: SoftTone {
        switch self {
        case .high: SoftTone.danger
        case .medium: ColorKey.orange.tone
        case .low: SoftTone.neutral
        }
    }
}
