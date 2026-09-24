import SwiftUI
import TeamTasksCore

/// Signed-out screens: « Connexion » (root), « Créer un compte » (pushed) and the « Mot de passe oublié » sheet
/// (`AppModel.passwordReset`).
struct AuthFlowView: View {
    @Bindable var appModel: AppModel

    @State private var login: LoginViewModel
    @State private var signUp: SignUpViewModel?
    @State private var isShowingSignUp = false

    init(appModel: AppModel) {
        _appModel = Bindable(wrappedValue: appModel)
        _login = State(initialValue: appModel.makeLoginViewModel())
    }

    var body: some View {
        NavigationStack {
            LoginView(
                model: login,
                onSignUp: showSignUp,
                onForgotPassword: {
                    _ = appModel.startPasswordReset(email: login.email)
                }
            )
            .navigationDestination(isPresented: $isShowingSignUp) {
                if let signUp {
                    SignUpView(model: signUp) { email in
                        backToLogin(email: email)
                    }
                }
            }
        }
        .sheet(item: $appModel.passwordReset) { reset in
            NavigationStack {
                PasswordResetView(model: reset)
            }
        }
    }

    private func showSignUp() {
        signUp = appModel.makeSignUpViewModel()
        isShowingSignUp = true
    }

    private func backToLogin(email: String) {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            login.email = trimmed
        }
        isShowingSignUp = false
    }
}
