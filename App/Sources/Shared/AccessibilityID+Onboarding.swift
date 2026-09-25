// Accessibility identifiers of the v2 onboarding, of the design system's pickers and of the v2 rows of « Réglages ».
// Compiled into the app and the UI test target: plain strings only, no imports.
extension AccessibilityID {
    /// The onboarding of a new account (OnboardingView).
    enum Onboarding {
        /// The whole onboarding.
        static let screen = "onboarding.screen"
        /// The content of a step, by `OnboardingStep.rawValue`: `welcome`, `avatar`, `firstGroup`, `notifications`.
        static func step(_ rawValue: String) -> String { "onboarding.step.\(rawValue)" }
        /// The step progress (« 2 sur 4 »).
        static let progress = "onboarding.progress"
        /// The round back button (from the second step).
        static let backButton = "onboarding.back"
        /// « Passer » (top trailing): ends the onboarding at once.
        static let skipButton = "onboarding.skip"
        /// The primary button of the step: « C’est parti », « Continuer », « Créer le groupe »…
        static let primaryButton = "onboarding.primary"
        /// « Plus tard » (first group and notifications steps).
        static let laterButton = "onboarding.later"
        /// « Créer » / « Rejoindre » of the first group step, by `FirstGroupMode.rawValue`: `create`, `join`.
        static func mode(_ rawValue: String) -> String { "onboarding.mode.\(rawValue)" }
        static let groupNameField = "onboarding.groupName"
        static let groupNameError = "onboarding.groupNameError"
        static let inviteCodeField = "onboarding.inviteCode"
        /// « Le groupe « X » est créé. », once the first group is done (back on its step).
        static let firstGroupDone = "onboarding.firstGroupDone"
    }

    /// The color and emoji pickers (SwatchGrid, EmojiGrid) and the avatar preview.
    enum Picker {
        /// A swatch, by `ColorKey.rawValue` (`indigo`, `coral`…).
        static func color(_ rawValue: String) -> String { "picker.color.\(rawValue)" }
        /// An emoji cell, by the emoji itself.
        static func emoji(_ emoji: String) -> String { "picker.emoji.\(emoji)" }
        /// The initials cell of the avatar picker (no emoji).
        static let initials = "picker.emoji.initials"
        /// The big preview of the avatar editor.
        static let avatarPreview = "picker.avatarPreview"
    }
}

extension AccessibilityID.Settings {
    /// The avatar row at the top of « Réglages »: opens the avatar editor.
    static let avatarButton = "settings.avatar"
    /// « Récap du lundi » switch.
    static let weeklyRecapToggle = "settings.weeklyRecap"
    /// The avatar editor sheet: its « Enregistrer » and « Annuler ».
    static let avatarSaveButton = "settings.avatar.save"
    static let avatarCancelButton = "settings.avatar.cancel"
}
