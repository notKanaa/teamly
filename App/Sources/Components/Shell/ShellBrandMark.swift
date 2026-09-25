import SwiftUI

/// The app's mark: the app icon (« Carte cochée », the `AppLogo` image) in its rounded square, with a soft shadow in
/// light mode. Decorative.
struct ShellBrandMark: View {
    var size: CGFloat = 80

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // The continuous corner of an iOS app icon (22.37 % of its side).
        let shape = RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
        Image(decorative: "AppLogo")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .clipShape(shape)
            .background {
                shape
                    .fill(Theme.card)
                    .shadow(
                        color: Color(red: 214 / 255, green: 56 / 255, blue: 90 / 255)
                            .opacity(colorScheme == .dark ? 0 : 0.28),
                        radius: size * 0.16, x: 0, y: size * 0.1
                    )
            }
            .overlay {
                if colorScheme == .dark {
                    shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                }
            }
            .accessibilityHidden(true)
    }
}

/// Brand mark, app name and a subtitle, centered (top of the authentication screens).
struct ShellBrandHeader: View {
    var title = "Équipe"
    var subtitle: String?

    var body: some View {
        VStack(spacing: 14) {
            ShellBrandMark(size: 88)
                .padding(.bottom, 4)
            Text(title)
                .font(.rounded(.largeTitle))
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
