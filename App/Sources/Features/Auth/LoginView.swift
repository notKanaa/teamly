import SwiftUI
import TeamTasksCore
import UIKit

/// « Connexion » (v2 look: the app icon, card fields, the primary button). On success `AppModel` switches to the
/// signed-in app by itself.
struct LoginView: View {
    @Bindable var model: LoginViewModel
    let onSignUp: () -> Void
    let onForgotPassword: () -> Void

    @FocusState private var focus: AuthFocusField?

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                ShellBrandHeader(subtitle: "Les tâches de ton groupe, partagées et à jour.")
                    .padding(.top, 32)

                VStack(spacing: 12) {
                    TextField("Adresse e-mail", text: $model.email)
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focus, equals: .email)
                        .onSubmit { focus = .password }
                        .accessibilityIdentifier(AccessibilityID.Auth.email)
                        .authFieldStyle(systemImage: "envelope.fill")

                    AuthPasswordField(
                        title: "Mot de passe",
                        text: $model.password,
                        focus: $focus,
                        field: .password,
                        accessibilityID: AccessibilityID.Auth.password
                    )
                    .textContentType(.password)
                    .submitLabel(.go)
                    .onSubmit(signIn)

                    HStack {
                        Spacer()
                        Button("Mot de passe oublié\u{00A0}?", action: onForgotPassword)
                            .buttonStyle(SecondaryButtonStyle(isFullWidth: false, font: Font.subheadline.weight(.bold)))
                            .disabled(model.isSubmitting)
                            .accessibilityIdentifier(AccessibilityID.Auth.forgotPassword)
                    }
                }

                PrimaryButton("Se connecter", isLoading: model.isSubmitting, action: signIn)
                    .disabled(!model.canSubmit)
                    .accessibilityIdentifier(AccessibilityID.Auth.signInButton)

                VStack(spacing: 2) {
                    Text("Pas encore de compte\u{00A0}?")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                    Button("Créer un compte", action: onSignUp)
                        .buttonStyle(.secondary)
                        .disabled(model.isSubmitting)
                        .accessibilityIdentifier(AccessibilityID.Auth.goToSignUp)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.Auth.loginScreen)
        }
        .scrollDismissesKeyboard(.interactively)
        .screenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .shellErrorAlert(model)
    }

    private func signIn() {
        guard model.canSubmit else { return }
        focus = nil
        Task {
            await model.signIn()
        }
    }
}
