import SwiftUI
import TeamTasksCore
import UIKit

/// « Créer un compte ». Each field shows its own message; on success the session opens (`AppModel` switches to the
/// onboarding, then the app), or — when the project requires e-mail confirmation — a message invites to confirm, then
/// sign in.
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
        .screenBackground()
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
            VStack(spacing: 14) {
                ShellBrandMark(size: 64)
                Text("Rejoins tes groupes et suis les tâches qui te sont confiées.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 12) {
                TextField("Ton nom", text: $model.displayName)
                    .textContentType(.name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.next)
                    .focused($focus, equals: .displayName)
                    .onSubmit { focus = .email }
                    .accessibilityIdentifier(AccessibilityID.Auth.displayName)
                    .authFieldStyle(systemImage: "person.fill", error: model.displayNameError)

                TextField("Adresse e-mail", text: $model.email)
                    .keyboardType(.emailAddress)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focus, equals: .email)
                    .onSubmit { focus = .password }
                    .accessibilityIdentifier(AccessibilityID.Auth.email)
                    .authFieldStyle(systemImage: "envelope.fill", error: model.emailError)

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
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.leading, 4)
                    }
                }
            }

            PrimaryButton("Créer mon compte", isLoading: model.isSubmitting, action: signUp)
                .disabled(!model.canSubmit)
                .accessibilityIdentifier(AccessibilityID.Auth.signUpButton)

            VStack(spacing: 2) {
                Text("Déjà un compte\u{00A0}?")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                Button("Se connecter") {
                    onBackToLogin(model.email)
                }
                .buttonStyle(.secondary)
                .disabled(model.isSubmitting)
                .accessibilityIdentifier(AccessibilityID.Auth.goToSignIn)
            }
        }
    }

    // MARK: - E-mail confirmation required

    private var confirmation: some View {
        VStack(spacing: 20) {
            IconTile(systemImage: "envelope.badge.fill", tone: SoftTone.accent, size: 72)
                .padding(.top, 32)
            Text("Vérifie tes e-mails")
                .font(.rounded(.title))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(SignUpViewModel.confirmationRequiredMessage)
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(AccessibilityID.Auth.signUpConfirmation)
            PrimaryButton("Retour à la connexion") {
                onBackToLogin(model.email)
            }
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
