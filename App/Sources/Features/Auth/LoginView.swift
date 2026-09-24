import SwiftUI
import TeamTasksCore
import UIKit

/// « Connexion ». On success `AppModel` switches to the signed-in app by itself.
struct LoginView: View {
    @Bindable var model: LoginViewModel
    let onSignUp: () -> Void
    let onForgotPassword: () -> Void

    @FocusState private var focus: AuthFocusField?

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                ShellBrandHeader(subtitle: "Les tâches de votre groupe, partagées et à jour.")
                    .padding(.top, 24)

                VStack(spacing: 14) {
                    TextField("Adresse e-mail", text: $model.email)
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focus, equals: .email)
                        .onSubmit { focus = .password }
                        .accessibilityIdentifier(AccessibilityID.Auth.email)
                        .authFieldStyle(systemImage: "envelope")

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
                        Button("Mot de passe oublié ?", action: onForgotPassword)
                            .font(.subheadline.weight(.medium))
                            .disabled(model.isSubmitting)
                            .accessibilityIdentifier(AccessibilityID.Auth.forgotPassword)
                    }
                }

                Button(action: signIn) {
                    ShellPrimaryButtonLabel(title: "Se connecter", isLoading: model.isSubmitting)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canSubmit)
                .accessibilityIdentifier(AccessibilityID.Auth.signInButton)

                VStack(spacing: 6) {
                    Text("Pas encore de compte ?")
                        .foregroundStyle(.secondary)
                    Button("Créer un compte", action: onSignUp)
                        .fontWeight(.semibold)
                        .disabled(model.isSubmitting)
                        .accessibilityIdentifier(AccessibilityID.Auth.goToSignUp)
                }
                .font(.callout)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.Auth.loginScreen)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
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
