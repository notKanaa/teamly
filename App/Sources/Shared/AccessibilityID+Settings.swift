// Accessibility identifiers of the v3 « Réglages » (docs/CONTRACTS-V3.md §8, §9) and of the home-screen quick actions.
// Compiled into the app and the UI test target: plain strings only, no imports.
//
// Also used by « Réglages » (declared in AccessibilityID.swift and AccessibilityID+Onboarding.swift):
// - `Settings.avatarButton` (the avatar of the profile card: opens « Mon profil »), `Settings.email`,
//   `Settings.displayNameField` (the name field of « Mon profil »), `Settings.avatarSaveButton` /
//   `Settings.avatarCancelButton` (« Enregistrer » / « Annuler » of « Mon profil »);
// - `Settings.notificationStatus` (the « Notifications » tile), `Settings.leadTimePicker` (the « Rappels » tile, a
//   menu), `Settings.weeklyRecapToggle` (the switch of the « Récap du lundi » tile);
// - `Settings.signOut`, `Settings.confirmSignOut`, `Settings.deleteAccount` and its sheet, `Settings.retry`,
//   `Settings.version` (the footer);
// - the ntfy screen (« Notifications push »): `Settings.enablePush`, `disablePush`, `pushTopic`, `copyPushTopic`,
//   `openNtfy`, `installNtfy`.
extension AccessibilityID.Settings {
    // MARK: Profile card

    /// The profile card (avatar, name, e-mail, figures, « Modifier mon profil »).
    static let profileCard = "settings.profileCard"
    /// The user's name in the profile card, shown once the profile is loaded.
    static let profileName = "settings.profileName"
    /// « Modifier mon profil »: opens « Mon profil » (name and avatar).
    static let editProfileButton = "settings.editProfile"
    /// A figure of the profile card: `month` (« tâches ce mois »), `streak` (« semaines de série »), `groups`.
    static func stat(_ key: String) -> String { "settings.stat.\(key)" }

    // MARK: Quick tiles

    /// The « Heures calmes » tile; its value is « Désactivées » or the window (« 22:00 → 8:00 »).
    static let quietHoursTile = "settings.quietHours"

    // MARK: « Heures calmes » sheet

    static let quietHoursToggle = "settings.quietHours.toggle"
    static let quietHoursStart = "settings.quietHours.start"
    static let quietHoursEnd = "settings.quietHours.end"
    static let quietHoursDone = "settings.quietHours.done"
    static let quietHoursCancel = "settings.quietHours.cancel"

    // MARK: Rows

    /// « Apparence » (Personnalisation): pushes the appearance screen.
    static let appearanceRow = "settings.appearance"
    static let groupRowPrefix = "settings.group."
    /// A row of « Mes groupes », by group name: opens the group.
    static func groupRow(_ name: String) -> String { groupRowPrefix + name }
    /// « Mot de passe » (Compte): opens the password sheet.
    static let passwordRow = "settings.password"
    /// « Notifications push » (Compte): pushes the ntfy screen.
    static let pushRow = "settings.push"
    /// « Inviter des amis sur Teamly », « Nouveautés », « Aide et contact ».
    static let inviteFriends = "settings.inviteFriends"
    static let whatsNew = "settings.whatsNew"
    static let help = "settings.help"
    /// « OK » of the « Nouveautés » and « Aide et contact » sheets.
    static let infoDone = "settings.info.done"

    // MARK: Appearance screen

    /// The « Thème » title; its value is the scheme the app shows: « Clair » or « Sombre ».
    static let themeTitle = "settings.theme"
    /// A theme card, by `ThemePreference.rawValue`: `auto`, `light`, `dark` (selected when chosen).
    static func themeOption(_ rawValue: String) -> String { "settings.theme.\(rawValue)" }
    /// An app icon, by `AppIconChoice.rawValue`: `trio`, `checkedCard`, `monogram` (selected when shown).
    static func iconOption(_ rawValue: String) -> String { "settings.icon.\(rawValue)" }
    static let confettiToggle = "settings.confetti"
    static let hapticsToggle = "settings.haptics"

    // MARK: Password sheet

    static let newPasswordField = "settings.password.new"
    static let passwordConfirmationField = "settings.password.confirmation"
    static let savePassword = "settings.password.save"
    static let cancelPassword = "settings.password.cancel"
    /// « Ton mot de passe a été modifié. » and its « OK ».
    static let passwordDone = "settings.password.done"
}

extension AccessibilityID {
    /// The home-screen quick actions: the group picker of « Nouvelle tâche » (several groups).
    enum QuickActions {
        static let groupPicker = "quickActions.groupPicker"
        static let cancel = "quickActions.cancel"
        /// A group of the picker, by name.
        static func group(_ name: String) -> String { "quickActions.group.\(name)" }
    }
}
