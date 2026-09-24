import SwiftUI

/// The app's mark (same colors as the app icon): a rounded square with a check mark. Decorative.
struct ShellBrandMark: View {
    var size: CGFloat = 80

    /// Gradient of the app icon (scripts/make-icon.mjs): accent blue to indigo.
    static var gradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 65 / 255, green: 108 / 255, blue: 217 / 255),
                Color(red: 88 / 255, green: 56 / 255, blue: 179 / 255),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(Self.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: Color.black.opacity(0.15), radius: size * 0.12, y: size * 0.06)
            .accessibilityHidden(true)
    }
}

/// Brand mark, app name and a subtitle, centered (top of the authentication screens).
struct ShellBrandHeader: View {
    var title = "Équipe"
    var subtitle: String?

    var body: some View {
        VStack(spacing: 14) {
            ShellBrandMark(size: 76)
            Text(title)
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
