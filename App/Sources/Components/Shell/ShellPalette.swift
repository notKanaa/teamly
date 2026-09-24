import SwiftUI

/// Colors of coloured text (status and priority capsules, due dates, error messages) and of filled controls.
///
/// The system `.orange`, `.green`, `.red`, `.blue` and `.gray` are too light for small text on the white rows
/// (1.95:1 to 4.02:1, WCAG AA asks 4.5:1). The Palette* colors of Assets.xcassets are darker in light mode and keep
/// bright colors in dark mode; every one reaches 4.5:1 on the rows, on the grouped background and inside its own
/// 12–15 % capsule, in both appearances.
enum ShellPalette {
    static var orange: Color { Color("PaletteOrange") }
    static var green: Color { Color("PaletteGreen") }
    static var red: Color { Color("PaletteRed") }
    static var blue: Color { Color("PaletteBlue") }
    static var gray: Color { Color("PaletteGray") }
    /// Accent-colored small text on an accent capsule (« Admin »): darker than the accent in light mode.
    static var accentText: Color { Color("PaletteAccentText") }
    /// Text on a solid `orange` / `green` / `red` / `blue` / `gray` fill: white in light mode, black in dark mode
    /// (the dark-mode fills are bright).
    static var onTint: Color { Color("PaletteOnTint") }
    /// Fill behind white text (selected chip, « Nouveau », prominent buttons): the light-mode accent in both
    /// appearances (4.8:1 with white; the dark-mode accent only gives 2.9:1).
    static var accentFill: Color { Color(red: 65 / 255, green: 108 / 255, blue: 217 / 255) }
}

extension View {
    /// `.borderedProminent` filled with `ShellPalette.accentFill`, so that its white label stays readable in dark mode.
    func shellProminentButtonStyle() -> some View {
        buttonStyle(.borderedProminent)
            .tint(ShellPalette.accentFill)
    }
}
