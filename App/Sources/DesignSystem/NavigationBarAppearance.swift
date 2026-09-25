import UIKit

/// The navigation bar titles of docs/DESIGN-V2.md §2: SF Pro Rounded, heavy for the large titles and bold for the
/// inline ones, in `textPrimary`, at the Dynamic Type size of launch. Only the title attributes change: the bars keep
/// their system background and behavior (Liquid Glass on iOS 26). Applied once, before the first bar exists
/// (`AppDelegate`).
enum NavigationBarAppearance {
    @MainActor
    static func apply() {
        let textColor = Theme.dynamicUIColor(light: 0x16141F, dark: 0xF4F3F8)
        let bar = UINavigationBar.appearance()
        bar.largeTitleTextAttributes = [
            .font: roundedFont(.largeTitle, weight: .heavy),
            .foregroundColor: textColor,
        ]
        bar.titleTextAttributes = [
            .font: roundedFont(.headline, weight: .bold),
            .foregroundColor: textColor,
        ]
    }

    /// The system font of `style` at the current text size, in the rounded design.
    @MainActor
    private static func roundedFont(_ style: UIFont.TextStyle, weight: UIFont.Weight) -> UIFont {
        let size = UIFont.preferredFont(forTextStyle: style).pointSize
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = font.fontDescriptor.withDesign(.rounded) else { return font }
        return UIFont(descriptor: descriptor, size: size)
    }
}
