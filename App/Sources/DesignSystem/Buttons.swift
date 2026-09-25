import SwiftUI

/// The big button of a screen (docs/DESIGN-V2.md §5): white rounded bold text on `accentFill`, at least 56 pt tall,
/// radius 18, full width, a soft accent shadow in light mode. Disabled: a `track` fill with `textSecondary` text,
/// unless `isLoading` (the fill stays while the spinner of `PrimaryButton` turns). The text wraps at large sizes.
///
/// ```swift
/// Button("Créer le groupe", action: create).buttonStyle(.primary)
/// ```
struct PrimaryButtonStyle: ButtonStyle {
    var fill: Color = Theme.accentFill
    var isLoading = false

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    /// Drawn with its fill: enabled, or disabled while its action runs.
    private var isActive: Bool { isEnabled || isLoading }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.rounded(.headline, weight: .bold))
            .foregroundStyle(isActive ? Theme.onFill : Theme.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                    .fill(isActive ? fill : Theme.track)
                    .shadow(
                        color: fill.opacity(isActive && colorScheme != .dark ? 0.28 : 0),
                        radius: 12, x: 0, y: 10
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

/// The plain accent text button under a primary one (« Plus tard », « Créer un compte »), 44 pt tall
/// (docs/DESIGN-V2.md §5). Full width by default.
struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent
    var isFullWidth = true
    var font: Font = Font.body.weight(.bold)

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .foregroundStyle(isEnabled ? tint : Theme.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
            .frame(maxWidth: isFullWidth ? .infinity : nil, minHeight: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}

/// A light press feedback (scale) for custom tappable surfaces: cards, tiles, the floating button.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    /// `PrimaryButtonStyle()`.
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    /// `SecondaryButtonStyle()`.
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

extension ButtonStyle where Self == PressableButtonStyle {
    /// `PressableButtonStyle()`.
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

/// A primary button with an optional SF Symbol (leading, or trailing like « C’est parti → ») and a spinner while
/// `isLoading` (VoiceOver: the title, value « En cours »). Disable it with `.disabled(_:)`; give it its identifier
/// with `.accessibilityIdentifier(_:)`.
struct PrimaryButton: View {
    enum IconPlacement {
        case leading
        case trailing
    }

    let title: String
    var systemImage: String?
    var iconPlacement: IconPlacement
    var isLoading: Bool
    let action: () -> Void

    init(
        _ title: String,
        systemImage: String? = nil,
        iconPlacement: IconPlacement = .leading,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.iconPlacement = iconPlacement
        self.isLoading = isLoading
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                HStack(spacing: 8) {
                    if let systemImage, iconPlacement == .leading {
                        Image(systemName: systemImage)
                    }
                    Text(title)
                    if let systemImage, iconPlacement == .trailing {
                        Image(systemName: systemImage)
                    }
                }
                .opacity(isLoading ? 0 : 1)
                if isLoading {
                    ProgressView()
                        .tint(Theme.onFill)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(isLoading ? "En cours" : "")
        }
        .buttonStyle(PrimaryButtonStyle(isLoading: isLoading))
    }
}

/// A round 44 pt icon button (docs/DESIGN-V2.md §7): `.card` is a `card` circle with a `textPrimary` symbol (the back
/// button of the onboarding), `.translucent` a white 22 % circle with a white symbol (on the group hero).
struct CircleIconButton: View {
    enum Style {
        case card
        case translucent
    }

    let systemImage: String
    let accessibilityLabel: String
    var style: Style
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 44

    init(systemImage: String, accessibilityLabel: String, style: Style = .card, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.style = style
        self.action = action
    }

    var body: some View {
        // 44 pt, growing with the text up to 60 pt.
        let diameter = min(max(44, side), 60)
        Button(action: action) {
            Image(systemName: systemImage)
                .font(Font.body.weight(.bold))
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .foregroundStyle(style == .card ? Theme.textPrimary : Theme.onFill)
                .frame(width: diameter, height: diameter)
                .background {
                    if style == .card {
                        Circle()
                            .fill(Theme.card)
                            .shadow(color: Theme.shadow.opacity(0.08), radius: 1.5, x: 0, y: 1)
                    } else {
                        Circle()
                            .fill(Color.white.opacity(0.22))
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(accessibilityLabel)
    }
}
