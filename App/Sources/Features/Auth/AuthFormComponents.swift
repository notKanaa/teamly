import SwiftUI
import UIKit

/// Focusable fields of the authentication screens.
enum AuthFocusField: Hashable {
    case displayName
    case email
    case password
    case code
    case newPassword
    case passwordConfirmation
}

/// A field of the authentication screens (v2 look): a `card` surface, radius 16, at least 56 pt tall, a leading icon
/// and an inline error message (the outline turns red).
struct AuthFieldStyle: ViewModifier {
    let systemImage: String
    var error: String?

    /// Width of the leading icon's column: grows with Dynamic Type like the `.body` icon it holds, up to the
    /// accessibility1 size (the text of the field needs the width more than the icon).
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 24

    init(systemImage: String, error: String? = nil) {
        self.systemImage = systemImage
        self.error = error
    }

    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(Font.body.weight(.semibold))
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    .foregroundStyle(error == nil ? Theme.textSecondary : Theme.danger)
                    .frame(width: min(iconWidth, 40))
                    .accessibilityHidden(true)
                content
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
            .cardSurface(radius: Theme.Radius.field, elevation: .subtle)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                    .strokeBorder(error == nil ? Color.clear : Theme.danger, lineWidth: 1.5)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 4)
            }
        }
    }
}

extension View {
    func authFieldStyle(systemImage: String, error: String? = nil) -> some View {
        modifier(AuthFieldStyle(systemImage: systemImage, error: error))
    }

    /// Content type of a field choosing a NEW password. Plain `.password` in UI tests: the simulator's
    /// « mot de passe fort » AutoFill overlay would cover the field and swallow the typed text.
    func newPasswordContentType(isUITesting: Bool) -> some View {
        textContentType(isUITesting ? UITextContentType.password : UITextContentType.newPassword)
    }
}

/// Password field with a « show / hide » button, styled like the other authentication fields.
struct AuthPasswordField: View {
    let title: String
    @Binding var text: String
    let focus: FocusState<AuthFocusField?>.Binding
    let field: AuthFocusField
    var error: String?
    let accessibilityID: String

    @State private var isRevealed = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if isRevealed {
                    TextField(title, text: $text)
                } else {
                    SecureField(title, text: $text)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused(focus, equals: field)
            .accessibilityIdentifier(accessibilityID)

            Button {
                let wasFocused = focus.wrappedValue == field
                isRevealed.toggle()
                if wasFocused {
                    focus.wrappedValue = field
                }
            } label: {
                // A 44 × 44 pt tap area at least; the frame grows with the glyph, up to the accessibility1 size.
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRevealed ? "Masquer le mot de passe" : "Afficher le mot de passe")
        }
        .authFieldStyle(systemImage: "lock.fill", error: error)
    }
}

/// Neutral information banner (« Si un compte existe… », « Un nouveau code… »): the soft accent pair.
struct AuthInfoBanner: View {
    let message: String
    var systemImage = "info.circle.fill"

    var body: some View {
        Label {
            Text(message)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(Theme.accentSoftText)
        }
        .font(.callout)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
    }
}
