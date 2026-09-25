import SwiftUI

/// How far a surface floats (docs/DESIGN-V2.md §4). Light mode draws soft shadows; dark mode draws no shadow at all
/// but a 1 pt `hairline` stroke along the edge (except `.flat`).
enum Elevation {
    /// No shadow, no stroke: a surface inside another one.
    case flat
    /// A 1 pt contact shadow only: text fields, small controls on the ground.
    case subtle
    /// Cards and rows: a 6 % shadow (blur 24, y 8) plus the 1 pt 4 % contact shadow.
    case card
    /// Floating things (illustrations, the notification samples): a 12 % shadow (blur 28, y 10).
    case raised
}

/// Fills a shape with `fill` behind the content, with the shadows or the dark-mode stroke of `elevation`. The shadows
/// belong to the filled shape only, never to the content (text stays sharp).
struct SurfaceModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let fill: Color
    let elevation: Elevation

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background {
                filledShape
            }
            .overlay {
                if colorScheme == .dark && elevation != .flat {
                    shape.strokeBorder(Theme.hairline, lineWidth: 1)
                }
            }
    }

    @ViewBuilder private var filledShape: some View {
        switch (colorScheme == .dark, elevation) {
        case (true, _), (_, .flat):
            shape.fill(fill)
        case (false, .subtle):
            shape.fill(fill)
                .shadow(color: Theme.shadow.opacity(0.08), radius: 1.5, x: 0, y: 1)
        case (false, .card):
            shape.fill(fill)
                .shadow(color: Theme.shadow.opacity(0.06), radius: 12, x: 0, y: 8)
                .shadow(color: Theme.shadow.opacity(0.04), radius: 1, x: 0, y: 1)
        case (false, .raised):
            shape.fill(fill)
                .shadow(color: Theme.shadow.opacity(0.12), radius: 14, x: 0, y: 10)
        }
    }
}

extension View {
    /// Puts a `card` surface behind the view: continuous corners of `radius` and the shadows of `elevation`
    /// (docs/DESIGN-V2.md §4). The view keeps its own padding (see `Card` for a padded one).
    func cardSurface(
        radius: CGFloat = Theme.Radius.card,
        fill: Color = Theme.card,
        elevation: Elevation = .card
    ) -> some View {
        modifier(SurfaceModifier(
            shape: RoundedRectangle(cornerRadius: radius, style: .continuous),
            fill: fill,
            elevation: elevation
        ))
    }

    /// Same as `cardSurface`, in any insettable shape (`Capsule()`, `Circle()`…).
    func surface<S: InsettableShape>(_ shape: S, fill: Color = Theme.card, elevation: Elevation = .card) -> some View {
        modifier(SurfaceModifier(shape: shape, fill: fill, elevation: elevation))
    }

    /// The grouped `background` behind the whole screen, safe areas included. The default backgrounds of the lists,
    /// forms and text editors inside are hidden so that it shows through (their rows keep theirs: give them
    /// `.listRowBackground(Theme.card)`).
    func screenBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.background)
    }

    /// `accessibilityIdentifier(_:)` when `identifier` is not nil; the view unchanged otherwise.
    @ViewBuilder
    func accessibilityIdentifierIfPresent(_ identifier: String?) -> some View {
        if let identifier {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}
