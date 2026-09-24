// Accessibility identifiers shared by the app and the UI test target (the whole App/Sources/Shared folder is
// compiled into both). Areas add their own identifiers in `AccessibilityID+<Area>.swift`.
enum AccessibilityID {
    enum Auth {
        static let email = "auth.email"
        static let password = "auth.password"
        static let displayName = "auth.displayName"
        static let signInButton = "auth.signIn"
        static let signUpButton = "auth.signUp"
        static let goToSignUp = "auth.goToSignUp"
        static let forgotPassword = "auth.forgotPassword"

        /// Containers of the login and sign-up screens.
        static let loginScreen = "auth.loginScreen"
        static let signUpScreen = "auth.signUpScreen"
        /// Sign-up screen: « Déjà un compte ? Se connecter ».
        static let goToSignIn = "auth.goToSignIn"
        /// Sign-up screen: message shown when the e-mail must be confirmed, and its « Retour à la connexion » button.
        static let signUpConfirmation = "auth.signUpConfirmation"
        static let backToSignIn = "auth.backToSignIn"

        // « Mot de passe oublié » flow (sheet) and « Nouveau mot de passe » (password recovery).
        static let resetScreen = "auth.reset.screen"
        static let resetEmail = "auth.reset.email"
        static let resetSendCode = "auth.reset.sendCode"
        static let resetInfo = "auth.reset.info"
        static let resetCode = "auth.reset.code"
        static let resetVerifyCode = "auth.reset.verifyCode"
        static let resetResendCode = "auth.reset.resendCode"
        static let resetChangeEmail = "auth.reset.changeEmail"
        static let newPassword = "auth.reset.newPassword"
        static let newPasswordConfirmation = "auth.reset.newPasswordConfirmation"
        static let saveNewPassword = "auth.reset.saveNewPassword"
        static let resetCancel = "auth.reset.cancel"
        static let resetDone = "auth.reset.done"
    }

    enum Tabs {
        // Set on the tab items' labels. SwiftUI does not always forward them to the tab bar buttons: UI tests
        // should find the buttons by title, e.g. `app.tabBars.buttons[AccessibilityID.Tabs.groupsTitle]`.
        static let groups = "tab.groups"
        static let myTasks = "tab.myTasks"
        static let settings = "tab.settings"

        /// Tab titles (same values as `AppTab.title`, which the UI test target cannot import).
        static let groupsTitle = "Groupes"
        static let myTasksTitle = "Mes tâches"
        static let settingsTitle = "Réglages"
    }

    enum Groups {
        static let list = "groups.list"
        static let createButton = "groups.create"
        static let joinButton = "groups.join"
        static let nameField = "groups.nameField"
        static let codeField = "groups.codeField"
        static let saveButton = "groups.save"
        static let membersButton = "groups.members"
        static let inviteButton = "groups.invite"
        static let inviteCode = "groups.inviteCode"
    }

    enum Tasks {
        static let list = "tasks.list"
        static let addButton = "tasks.add"
        static let titleField = "tasks.titleField"
        static let detailsField = "tasks.detailsField"
        static let saveButton = "tasks.save"
        static let filterPicker = "tasks.filter"
        static let statusButton = "tasks.status"
    }

    enum Settings {
        static let signOut = "settings.signOut"
        static let deleteAccount = "settings.deleteAccount"

        /// Shown when the profile could not be loaded (the rest of the form stays usable).
        static let retry = "settings.retry"
        static let email = "settings.email"
        static let displayNameField = "settings.displayName"
        static let saveDisplayName = "settings.saveDisplayName"
        static let leadTimePicker = "settings.leadTime"
        static let notificationStatus = "settings.notificationStatus"
        static let requestNotifications = "settings.requestNotifications"
        static let openSystemSettings = "settings.openSystemSettings"
        static let enablePush = "settings.enablePush"
        static let disablePush = "settings.disablePush"
        static let pushTopic = "settings.pushTopic"
        static let copyPushTopic = "settings.copyPushTopic"
        static let openNtfy = "settings.openNtfy"
        static let installNtfy = "settings.installNtfy"
        /// Confirmation dialog button of « Se déconnecter ».
        static let confirmSignOut = "settings.confirmSignOut"
        /// « Supprimer le compte » sheet: typed « SUPPRIMER » field, final button and cancel.
        static let deleteConfirmationField = "settings.deleteConfirmation"
        static let confirmDeleteAccount = "settings.confirmDeleteAccount"
        static let cancelDeleteAccount = "settings.cancelDeleteAccount"
        static let version = "settings.version"
    }
}
