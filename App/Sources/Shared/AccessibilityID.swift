// Accessibility identifiers shared by the app and the UI test target (compiled into both).
enum AccessibilityID {
    enum Auth {
        static let email = "auth.email"
        static let password = "auth.password"
        static let displayName = "auth.displayName"
        static let signInButton = "auth.signIn"
        static let signUpButton = "auth.signUp"
        static let goToSignUp = "auth.goToSignUp"
        static let forgotPassword = "auth.forgotPassword"
    }

    enum Tabs {
        static let groups = "tab.groups"
        static let myTasks = "tab.myTasks"
        static let settings = "tab.settings"
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
    }
}
