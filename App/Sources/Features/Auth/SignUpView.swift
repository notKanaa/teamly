import SwiftUI
import TeamTasksCore
import UIKit

/// « Créer un compte ». Each field shows its own message; on success the session opens (`AppModel` switches to
/// the app), or — when the project requires e-mail confirmation — a message invites to confirm, then sign in.
struct SignUpView: View {
    @Bindable var model: SignUpViewModel
    /// Back to the login screen with this e-mail pre-filled.
    let onBackToLogin: (String) -> Void

    @Environment(\.isUITesting) private var isUITesting
    @FocusState private var focus: AuthFocusField?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if model.needsEmailConfirmation {
                    confirmation
                } else {
                    form
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.Auth.signUpScreen)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Créer un compte")
        .navigationBarTitleDisplayMode(.inline)
        .shellErrorAlert(model)
        .animation(.default, value: model.needsEmailConfirmation)
        .onAppear {
            if model.displayName.isEmpty {
                focus = .displayName
            }
        }
    }

    // MARK: - Form

    private var form: some View {
        VStack(spacing: 24) {
            Text("Rejoignez vos groupes et suivez les tâches qui vous sont confiées.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            VStack(spacing: 14) {
                TextField("Votre nom", text: $model.displayName)
                    .textContentType(.name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.next)
                    .focused($focus, equals: .displayName)
                    .onSubmit { focus = .email }
                    .accessibilityIdentifier(AccessibilityID.Auth.displayName)
                    .authFieldStyle(systemImage: "person", error: model.displayNameError)

                TextField("Adresse e-mail", text: $model.email)
                    .keyboardType(.emailAddress)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focus, equals: .email)
                    .onSubmit { focus = .password }
                    .accessibilityIdentifier(AccessibilityID.Auth.email)
                    .authFieldStyle(systemImage: "envelope", error: model.emailError)

                VStack(alignment: .leading, spacing: 6) {
                    AuthPasswordField(
                        title: "Mot de passe",
                        text: $model.password,
                        focus: $focus,
                        field: .password,
                        error: model.passwordError,
                        accessibilityID: AccessibilityID.Auth.password
                    )
                    .newPasswordContentType(isUITesting: isUITesting)
                    .submitLabel(.join)
                    .onSubmit(signUp)

                    if model.passwordError == nil {
                        Text("8 caractères minimum.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)
                    }
                }
            }

            Button(action: signUp) {
                ShellPrimaryButtonLabel(title: "Créer mon compte", isLoading: model.isSubmitting)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canSubmit)
            .accessibilityIdentifier(AccessibilityID.Auth.signUpButton)

            VStack(spacing: 6) {
                Text("Déjà un compte ?")
                    .foregroundStyle(.secondary)
                Button("Se connecter") {
                    onBackToLogin(model.email)
                }
                .fontWeight(.semibold)
                .disabled(model.isSubmitting)
                .accessibilityIdentifier(AccessibilityID.Auth.goToSignIn)
            }
            .font(.callout)
        }
    }

    // MARK: - E-mail confirmation required

    private var confirmation: some View {
        VStack(spacing: 20) {
            Image(systemName: "envelope.badge.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 32)
                .accessibilityHidden(true)
            Text("Vérifiez vos e-mails")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text(SignUpViewModel.confirmationRequiredMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier(AccessibilityID.Auth.signUpConfirmation)
            Button {
                onBackToLogin(model.email)
            } label: {
                ShellPrimaryButtonLabel(title: "Retour à la connexion")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier(AccessibilityID.Auth.backToSignIn)
        }
        .frame(maxWidth: .infinity)
    }

    private func signUp() {
        guard model.canSubmit else { return }
        focus = nil
        Task {
            await model.signUp()
        }
    }
}
