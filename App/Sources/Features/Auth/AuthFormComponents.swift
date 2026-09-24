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

/// Rounded field with a leading icon and an inline error message (authentication screens).
struct AuthFieldStyle: ViewModifier {
    let systemImage: String
    var error: String?

    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                content
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(error == nil ? Color.clear : Color.red, lineWidth: 1)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
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
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRevealed ? "Masquer le mot de passe" : "Afficher le mot de passe")
        }
        .authFieldStyle(systemImage: "lock", error: error)
    }
}

/// Neutral information banner (« Si un compte existe… », « Un nouveau code… »).
struct AuthInfoBanner: View {
    let message: String
    var systemImage = "info.circle.fill"

    var body: some View {
        Label {
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(Color.accentColor)
        }
        .font(.callout)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
