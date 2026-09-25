import SwiftUI
import TeamTasksCore
import UIKit

/// « Mot de passe oublié »: e-mail → 6-digit code received by e-mail → new password.
///
/// Presented as a sheet from the login screen (`AppModel.passwordReset`); once the code is verified the user is
/// signed in with a recovery session and `RootView` shows this same model full screen
/// (`AppPhase.passwordRecovery`) at the « Nouveau mot de passe » step, until the password is changed or the
/// recovery is abandoned (local sign-out). Embed it in a `NavigationStack`.
struct PasswordResetView: View {
    @Bindable var model: PasswordResetViewModel

    @Environment(\.isUITesting) private var isUITesting
    @FocusState private var focus: AuthFocusField?
    @State private var isConfirmingAbandon = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header

                if let info = model.infoMessage, model.step != .done {
                    AuthInfoBanner(message: info)
                        .accessibilityIdentifier(AccessibilityID.Auth.resetInfo)
                }

                switch model.step {
                case .email:
                    emailStep
                case .code:
                    codeStep
                case .newPassword:
                    newPasswordStep
                case .done:
                    doneStep
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.Auth.resetScreen)
        }
        .scrollDismissesKeyboard(.interactively)
        .screenBackground()
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if model.step != .done {
                    Button("Annuler", action: cancel)
                        .disabled(model.isSubmitting)
                        .accessibilityIdentifier(AccessibilityID.Auth.resetCancel)
                }
            }
        }
        // Swiping the sheet down must not skip the sign-out of an abandoned recovery.
        .interactiveDismissDisabled(model.isSubmitting || model.step == .newPassword || model.step == .done)
        .confirmationDialog(
            "Abandonner le changement de mot de passe\u{00A0}?",
            isPresented: $isConfirmingAbandon,
            titleVisibility: .visible
        ) {
            Button("Abandonner", role: .destructive) {
                Task {
                    await model.cancel()
                }
            }
            Button("Continuer", role: .cancel) {}
        } message: {
            Text("Ton mot de passe ne sera pas modifié et tu reviendras à l’écran de connexion.")
        }
        .shellErrorAlert(model)
        .animation(.default, value: model.step)
        .onAppear {
            focus = initialFocus(for: model.step)
        }
        .onChange(of: model.step) { _, step in
            focus = initialFocus(for: step)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 14) {
            IconTile(
                systemImage: headerSymbol,
                tone: model.step == .done ? SoftTone.done : SoftTone.accent,
                size: 64
            )
            Text(headerText)
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var headerSymbol: String {
        switch model.step {
        case .email: "key.fill"
        case .code: "envelope.open.fill"
        case .newPassword: "lock.rotation"
        case .done: "checkmark.seal.fill"
        }
    }

    private var headerText: String {
        switch model.step {
        case .email:
            "Saisis l’adresse e-mail de ton compte\u{00A0}: nous t’enverrons un code à 6 chiffres pour choisir un nouveau mot de passe."
        case .code:
            "Saisis le code à 6 chiffres reçu par e-mail. Pense à vérifier tes courriers indésirables."
        case .newPassword:
            "Choisis un nouveau mot de passe (8 caractères minimum)."
        case .done:
            PasswordResetViewModel.doneMessage
        }
    }

    // MARK: - Steps

    private var emailStep: some View {
        VStack(spacing: 20) {
            TextField("Adresse e-mail", text: $model.email)
                .keyboardType(.emailAddress)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .focused($focus, equals: .email)
                .onSubmit(sendCode)
                .accessibilityIdentifier(AccessibilityID.Auth.resetEmail)
                .authFieldStyle(systemImage: "envelope.fill")

            PrimaryButton("Envoyer le code", isLoading: model.isSubmitting, action: sendCode)
                .disabled(!model.canSendCode)
                .accessibilityIdentifier(AccessibilityID.Auth.resetSendCode)
        }
    }

    private var codeStep: some View {
        VStack(spacing: 20) {
            TextField("Code à 6 chiffres", text: $model.code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.roundedNumber(.title2, weight: .bold))
                .multilineTextAlignment(.center)
                .focused($focus, equals: .code)
                .accessibilityLabel("Code reçu par e-mail")
                .accessibilityIdentifier(AccessibilityID.Auth.resetCode)
                .authFieldStyle(systemImage: "number")

            PrimaryButton("Valider le code", isLoading: model.isSubmitting, action: verifyCode)
                .disabled(!model.canVerifyCode)
                .accessibilityIdentifier(AccessibilityID.Auth.resetVerifyCode)

            VStack(spacing: 4) {
                Button("Renvoyer le code") {
                    Task {
                        await model.resendCode()
                    }
                }
                .buttonStyle(.secondary)
                .accessibilityIdentifier(AccessibilityID.Auth.resetResendCode)

                Button("Modifier l’adresse e-mail") {
                    model.goBack()
                }
                .buttonStyle(SecondaryButtonStyle(tint: Theme.textSecondary))
                .accessibilityIdentifier(AccessibilityID.Auth.resetChangeEmail)
            }
            .disabled(model.isSubmitting)
        }
    }

    private var newPasswordStep: some View {
        VStack(spacing: 20) {
            VStack(spacing: 12) {
                AuthPasswordField(
                    title: "Nouveau mot de passe",
                    text: $model.newPassword,
                    focus: $focus,
                    field: .newPassword,
                    accessibilityID: AccessibilityID.Auth.newPassword
                )
                .newPasswordContentType(isUITesting: isUITesting)
                .submitLabel(.next)
                .onSubmit { focus = .passwordConfirmation }

                AuthPasswordField(
                    title: "Confirme le mot de passe",
                    text: $model.passwordConfirmation,
                    focus: $focus,
                    field: .passwordConfirmation,
                    accessibilityID: AccessibilityID.Auth.newPasswordConfirmation
                )
                .newPasswordContentType(isUITesting: isUITesting)
                .submitLabel(.done)
                .onSubmit(updatePassword)
            }

            PrimaryButton("Enregistrer le mot de passe", isLoading: model.isSubmitting, action: updatePassword)
                .disabled(!model.canUpdatePassword)
                .accessibilityIdentifier(AccessibilityID.Auth.saveNewPassword)
        }
    }

    private var doneStep: some View {
        // The app opens right after this step; the spinner covers the transition.
        ProgressView("Ouverture d’Équipe…")
            .tint(Theme.accent)
            .padding(.top, 8)
            .accessibilityIdentifier(AccessibilityID.Auth.resetDone)
    }

    // MARK: - Actions

    private func initialFocus(for step: PasswordResetViewModel.Step) -> AuthFocusField? {
        switch step {
        case .email:
            return model.email.isEmpty ? AuthFocusField.email : nil
        case .code:
            return AuthFocusField.code
        case .newPassword:
            return AuthFocusField.newPassword
        case .done:
            return nil
        }
    }

    private func sendCode() {
        guard model.canSendCode else { return }
        focus = nil
        Task {
            await model.sendCode()
        }
    }

    private func verifyCode() {
        guard model.canVerifyCode else { return }
        focus = nil
        Task {
            await model.verifyCode()
        }
    }

    private func updatePassword() {
        guard model.canUpdatePassword else { return }
        focus = nil
        Task {
            await model.updatePassword()
        }
    }

    private func cancel() {
        if model.step == .newPassword {
            isConfirmingAbandon = true
        } else {
            Task {
                await model.cancel()
            }
        }
    }
}
