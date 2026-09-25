import SwiftUI
import TeamTasksCore
import UIKit
import UniformTypeIdentifiers

/// « Réglages » (docs/DESIGN-V2.md §7.8): the avatar row (it opens the « Ton avatar » sheet) and the display name, the
/// notifications (permission, « Récap du lundi »), the reminder lead time, the optional ntfy push, sign-out and account
/// deletion. Sign-out and deletion end the session: `AppModel` shows the login screen.
///
/// Native form controls on cards over the grouped background, each row led by an icon tile. Sections that do not need
/// the profile (reminders, notifications, account) stay usable when it cannot be loaded, so that signing out always
/// works.
struct SettingsView: View {
    @State private var model: SettingsViewModel

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isConfirmingSignOut = false
    @State private var isConfirmingPushDisable = false
    @State private var isShowingDeleteAccount = false
    @State private var avatarEditor: AvatarEditorViewModel?
    @State private var didCopyTopic = false
    @FocusState private var isNameFocused: Bool

    /// The free ntfy app on the App Store.
    static let ntfyAppStoreURL = URL(string: "https://apps.apple.com/app/ntfy/id1625396347")

    init(session: SessionModel) {
        _model = State(initialValue: SettingsViewModel(session: session))
    }

    var body: some View {
        Form {
            if let message = model.loadState.failureMessage {
                loadFailedSection(message)
            }
            avatarSection
            profileSection
            notificationsSection
            remindersSection
            pushSection
            accountSection
            aboutSection
        }
        .screenBackground()
        .navigationTitle("Réglages")
        .task(id: model.refreshKey) {
            await model.load()
        }
        .refreshable {
            await model.reload()
        }
        .onChange(of: scenePhase) { _, phase in
            // The permission may have been changed in the iPhone's Settings app.
            if phase == .active {
                Task {
                    await model.refreshNotificationStatus()
                }
            }
        }
        // The deletion and avatar sheets show the errors of their own model.
        .shellErrorAlert(model, isEnabled: !isShowingDeleteAccount)
        .confirmationDialog("Se déconnecter\u{00A0}?", isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
            Button("Se déconnecter", role: .destructive) {
                Task {
                    await model.signOut()
                }
            }
            .accessibilityIdentifier(AccessibilityID.Settings.confirmSignOut)
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Les rappels programmés sur cet iPhone seront supprimés. Tu pourras te reconnecter à tout moment.")
        }
        .confirmationDialog(
            "Désactiver les notifications push\u{00A0}?",
            isPresented: $isConfirmingPushDisable,
            titleVisibility: .visible
        ) {
            Button("Désactiver", role: .destructive) {
                Task {
                    await model.disablePush()
                }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Ton sujet ntfy sera supprimé. Si tu les réactives, il faudra t’abonner au nouveau sujet dans ntfy.")
        }
        .sheet(isPresented: $isShowingDeleteAccount) {
            SettingsDeleteAccountView(model: model)
        }
        .sheet(isPresented: isShowingAvatarEditor) {
            if let avatarEditor {
                AvatarEditorSheet(model: avatarEditor) { profile in
                    model.apply(profile)
                }
            }
        }
    }

    // MARK: - Load failure

    private func loadFailedSection(_ message: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("Profil indisponible", systemImage: "wifi.exclamationmark")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.vertical, 4)
            Button {
                Task {
                    await model.reload()
                }
            } label: {
                Label("Réessayer", systemImage: "arrow.clockwise")
            }
            .accessibilityIdentifier(AccessibilityID.Settings.retry)
        }
        .listRowBackground(Theme.card)
    }

    // MARK: - Avatar (v2)

    private var avatarSection: some View {
        Section {
            Button(action: openAvatarEditor) {
                HStack(spacing: 14) {
                    if let appearance = model.avatarAppearance {
                        AvatarView(appearance, size: 56)
                    } else {
                        Circle()
                            .fill(Theme.track)
                            .frame(width: 56, height: 56)
                            .overlay {
                                if model.loadState.isLoading || model.loadState == .idle {
                                    ProgressView()
                                }
                            }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.profile?.displayName ?? "Ton profil")
                            .font(.rounded(.title3, weight: .heavy))
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Modifier l’avatar")
                            .font(Font.subheadline.weight(.semibold))
                            .foregroundStyle(model.profile == nil ? Theme.textSecondary : Theme.accent)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(Font.footnote.weight(.bold))
                        .foregroundStyle(Theme.textTertiary)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.profile == nil)
            .accessibilityLabel("Avatar de \(model.profile?.displayName ?? "ton profil")")
            .accessibilityHint("Modifier ta couleur et ton symbole")
            .accessibilityIdentifier(AccessibilityID.Settings.avatarButton)
        }
        .listRowBackground(Theme.card)
    }

    private var isShowingAvatarEditor: Binding<Bool> {
        Binding(
            get: { avatarEditor != nil },
            set: { isShown in
                if !isShown {
                    avatarEditor = nil
                }
            }
        )
    }

    private func openAvatarEditor() {
        avatarEditor = model.makeAvatarEditor()
    }

    // MARK: - Profile

    private var profileSection: some View {
        Section {
            LabeledContent {
                // On one line (cut in the middle) beside its label; whole when the label is above it.
                Text(model.email ?? "—")
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } label: {
                rowLabel("E-mail", systemImage: "envelope.fill", tone: ColorKey.blue.tone)
            }
            .accessibilityIdentifier(AccessibilityID.Settings.email)

            if model.profile == nil {
                LabeledContent {
                    if model.loadState.isLoading || model.loadState == .idle {
                        ProgressView()
                    } else {
                        Text("—")
                            .foregroundStyle(Theme.textSecondary)
                    }
                } label: {
                    rowLabel("Nom affiché", systemImage: "person.fill", tone: SoftTone.accent)
                }
            } else {
                LabeledContent {
                    TextField("Ton nom", text: $model.displayName)
                        .multilineTextAlignment(.trailing)
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .focused($isNameFocused)
                        .onSubmit(saveDisplayName)
                        .accessibilityIdentifier(AccessibilityID.Settings.displayNameField)
                } label: {
                    rowLabel("Nom affiché", systemImage: "person.fill", tone: SoftTone.accent)
                }

                if model.canSaveDisplayName || model.isSavingName {
                    Button(action: saveDisplayName) {
                        HStack {
                            Text("Enregistrer le nom")
                                .fontWeight(.semibold)
                            Spacer()
                            if model.isSavingName {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(!model.canSaveDisplayName)
                    .accessibilityIdentifier(AccessibilityID.Settings.saveDisplayName)
                }
            }
        } header: {
            Text("Profil")
        } footer: {
            if let error = model.displayNameError {
                Text(error)
                    .foregroundStyle(Theme.danger)
            } else {
                Text("Ton nom est visible par les membres de tes groupes.")
            }
        }
        .listRowBackground(Theme.card)
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        Section {
            LabeledContent {
                Text(model.notificationStatusText)
                    .foregroundStyle(Theme.textSecondary)
            } label: {
                rowLabel("Autorisation", systemImage: "bell.badge.fill", tone: ColorKey.coral.tone)
            }
            .accessibilityIdentifier(AccessibilityID.Settings.notificationStatus)

            if model.canRequestNotifications {
                Button {
                    Task {
                        await model.requestNotifications()
                    }
                } label: {
                    Text("Autoriser les notifications")
                        .fontWeight(.semibold)
                }
                .accessibilityIdentifier(AccessibilityID.Settings.requestNotifications)
            } else if model.notificationStatus == .denied {
                Button(action: openSystemNotificationSettings) {
                    Text("Ouvrir les Réglages de l’iPhone")
                        .fontWeight(.semibold)
                }
                .accessibilityIdentifier(AccessibilityID.Settings.openSystemSettings)
            }

            Toggle(isOn: $model.isWeeklyRecapEnabled) {
                rowLabel(SettingsViewModel.weeklyRecapTitle, systemImage: "trophy.fill", tone: ColorKey.amber.tone)
            }
            .accessibilityIdentifier(AccessibilityID.Settings.weeklyRecapToggle)
        } header: {
            Text("Notifications")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let hint = model.notificationHint {
                    Text(hint)
                }
                Text(SettingsViewModel.weeklyRecapFooter)
            }
        }
        .listRowBackground(Theme.card)
    }

    // MARK: - Reminders

    private var remindersSection: some View {
        Section {
            Picker(selection: $model.leadTime) {
                ForEach(model.leadTimeOptions) { option in
                    Text(option.label)
                        .tag(option)
                }
            } label: {
                rowLabel("Rappel", systemImage: "alarm.fill", tone: ColorKey.orange.tone)
            }
            .accessibilityIdentifier(AccessibilityID.Settings.leadTimePicker)
        } header: {
            Text("Rappels d’échéance")
        } footer: {
            Text(remindersFooter)
        }
        .listRowBackground(Theme.card)
    }

    private var remindersFooter: String {
        guard model.leadTime.isEnabled else {
            return "Aucun rappel d’échéance ne sera programmé sur cet iPhone."
        }
        var text = "Pour chaque tâche qui t’est assignée et qui a une échéance, un rappel est programmé sur cet iPhone."
        if model.notificationStatus == .denied {
            text += " Les notifications étant refusées, les rappels ne s’afficheront pas."
        }
        return text
    }

    // MARK: - Push (ntfy)

    private var pushSection: some View {
        Section {
            if let topic = model.pushTopic {
                ForEach(Array(SettingsViewModel.pushInstructionSteps.enumerated()), id: \.offset) { index, step in
                    Label {
                        Text(step)
                            .foregroundStyle(Theme.textPrimary)
                    } icon: {
                        Image(systemName: "\(index + 1).circle.fill")
                            .foregroundStyle(Theme.accent)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Ton sujet ntfy")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Text(topic)
                        .font(.callout.monospaced())
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Ton sujet ntfy")
                // Spelled out character by character by VoiceOver, to be typed elsewhere.
                .accessibilityValue(Text(topic).speechSpellsOutCharacters())
                .accessibilityIdentifier(AccessibilityID.Settings.pushTopic)

                Button {
                    copyTopic(topic)
                } label: {
                    Label(
                        didCopyTopic ? "Sujet copié" : "Copier le sujet",
                        systemImage: didCopyTopic ? "checkmark" : "doc.on.doc"
                    )
                }
                .accessibilityIdentifier(AccessibilityID.Settings.copyPushTopic)

                if model.ntfyAppURL != nil {
                    Button(action: openNtfy) {
                        Label("Ouvrir dans ntfy", systemImage: "arrow.up.forward.app")
                    }
                    .accessibilityIdentifier(AccessibilityID.Settings.openNtfy)
                }

                if let appStoreURL = Self.ntfyAppStoreURL {
                    Link(destination: appStoreURL) {
                        Label("Installer ntfy (App Store)", systemImage: "arrow.down.app")
                    }
                    .accessibilityIdentifier(AccessibilityID.Settings.installNtfy)
                }

                Button(role: .destructive) {
                    isConfirmingPushDisable = true
                } label: {
                    HStack {
                        Label("Désactiver les notifications push", systemImage: "bell.slash")
                        Spacer()
                        if model.isUpdatingPush {
                            ProgressView()
                        }
                    }
                }
                .disabled(model.isUpdatingPush)
                .accessibilityIdentifier(AccessibilityID.Settings.disablePush)
            } else {
                Button {
                    Task {
                        await model.enablePush()
                    }
                } label: {
                    HStack {
                        rowLabel(
                            "Activer les notifications push",
                            systemImage: "antenna.radiowaves.left.and.right",
                            tone: ColorKey.teal.tone,
                            textColor: model.loadState.isLoaded ? Theme.accent : Theme.textSecondary
                        )
                        Spacer()
                        if model.isUpdatingPush {
                            ProgressView()
                        }
                    }
                }
                .disabled(model.isUpdatingPush || !model.loadState.isLoaded)
                .accessibilityIdentifier(AccessibilityID.Settings.enablePush)
            }
        } header: {
            Text("Notifications push (ntfy)")
        } footer: {
            Text(model.isPushEnabled ? SettingsViewModel.pushPrivacyNote : SettingsViewModel.pushDisabledExplanation)
        }
        .listRowBackground(Theme.card)
    }

    // MARK: - Account

    private var accountSection: some View {
        Section {
            Button {
                isConfirmingSignOut = true
            } label: {
                HStack {
                    rowLabel(
                        "Se déconnecter",
                        systemImage: "rectangle.portrait.and.arrow.right",
                        tone: SoftTone.neutral,
                        textColor: Theme.textPrimary
                    )
                    Spacer()
                    if model.isSigningOut {
                        ProgressView()
                    }
                }
            }
            .disabled(model.isSigningOut || model.isDeletingAccount)
            .accessibilityIdentifier(AccessibilityID.Settings.signOut)

            Button(role: .destructive) {
                model.deleteConfirmation = ""
                isShowingDeleteAccount = true
            } label: {
                rowLabel("Supprimer mon compte", systemImage: "trash.fill", tone: SoftTone.danger, textColor: Theme.danger)
            }
            .disabled(model.isSigningOut || model.isDeletingAccount)
            .accessibilityIdentifier(AccessibilityID.Settings.deleteAccount)
        } header: {
            Text("Compte")
        } footer: {
            Text("La suppression du compte efface définitivement ton profil et tes assignations.")
        }
        .listRowBackground(Theme.card)
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            LabeledContent {
                Text(Self.appVersion)
                    .foregroundStyle(Theme.textSecondary)
            } label: {
                rowLabel("Version", systemImage: "info.circle.fill", tone: SoftTone.neutral)
            }
            .accessibilityIdentifier(AccessibilityID.Settings.version)
        } footer: {
            Text("Équipe — les tâches de ton groupe.")
        }
        .listRowBackground(Theme.card)
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    // MARK: - Rows

    /// A row's title led by its icon tile (docs/DESIGN-V2.md §7.8).
    private func rowLabel(
        _ title: String,
        systemImage: String,
        tone: SoftTone,
        textColor: Color = Theme.textPrimary
    ) -> some View {
        Label {
            Text(title)
                .foregroundStyle(textColor)
        } icon: {
            IconTile(systemImage: systemImage, tone: tone, size: 30)
        }
    }

    // MARK: - Actions

    private func saveDisplayName() {
        guard model.canSaveDisplayName else { return }
        isNameFocused = false
        Task {
            await model.saveDisplayName()
        }
    }

    private func copyTopic(_ topic: String) {
        // The topic is a secret (whoever knows it can read this user's pushes and send fake ones): kept on this
        // iPhone (no Universal Clipboard to the user's other devices), where the ntfy app is, and for 2 minutes only.
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: topic]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)]
        )
        didCopyTopic = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            didCopyTopic = false
        }
    }

    /// Opens the topic in the ntfy app, or its App Store page when the app is not installed.
    private func openNtfy() {
        guard let url = model.ntfyAppURL else { return }
        let appStoreURL = Self.ntfyAppStoreURL
        Task {
            let opened = await UIApplication.shared.open(url, options: [:])
            if !opened, let appStoreURL {
                _ = await UIApplication.shared.open(appStoreURL, options: [:])
            }
        }
    }

    private func openSystemNotificationSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        openURL(url)
    }
}
