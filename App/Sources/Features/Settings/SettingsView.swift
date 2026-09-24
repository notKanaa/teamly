import SwiftUI
import TeamTasksCore
import UIKit

/// « Réglages »: profile (display name), reminder lead time, notification permission, optional ntfy push,
/// sign-out and account deletion. Sign-out and deletion end the session: `AppModel` shows the login screen.
///
/// Sections that do not need the profile (reminders, notifications, account) stay usable when it cannot be
/// loaded, so that signing out always works.
struct SettingsView: View {
    @State private var model: SettingsViewModel

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var isConfirmingSignOut = false
    @State private var isConfirmingPushDisable = false
    @State private var isShowingDeleteAccount = false
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
            profileSection
            remindersSection
            notificationsSection
            pushSection
            accountSection
            aboutSection
        }
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
        // The deletion sheet shows the errors of the same model itself.
        .shellErrorAlert(model, isEnabled: !isShowingDeleteAccount)
        .confirmationDialog("Se déconnecter ?", isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
            Button("Se déconnecter", role: .destructive) {
                Task {
                    await model.signOut()
                }
            }
            .accessibilityIdentifier(AccessibilityID.Settings.confirmSignOut)
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Les rappels programmés sur cet iPhone seront supprimés. Vous pourrez vous reconnecter à tout moment.")
        }
        .confirmationDialog(
            "Désactiver les notifications push ?",
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
            Text("Votre sujet ntfy sera supprimé. Si vous les réactivez, il faudra vous abonner au nouveau sujet dans ntfy.")
        }
        .sheet(isPresented: $isShowingDeleteAccount) {
            SettingsDeleteAccountView(model: model)
        }
    }

    // MARK: - Load failure

    private func loadFailedSection(_ message: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("Profil indisponible", systemImage: "wifi.exclamationmark")
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
    }

    // MARK: - Profile

    private var profileSection: some View {
        Section {
            LabeledContent("E-mail") {
                Text(model.email ?? "—")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .accessibilityIdentifier(AccessibilityID.Settings.email)

            if model.profile == nil {
                LabeledContent("Nom affiché") {
                    if model.loadState.isLoading || model.loadState == .idle {
                        ProgressView()
                    } else {
                        Text("—")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                LabeledContent("Nom affiché") {
                    TextField("Votre nom", text: $model.displayName)
                        .multilineTextAlignment(.trailing)
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .focused($isNameFocused)
                        .onSubmit(saveDisplayName)
                        .accessibilityIdentifier(AccessibilityID.Settings.displayNameField)
                }

                if model.canSaveDisplayName || model.isSavingName {
                    Button(action: saveDisplayName) {
                        HStack {
                            Text("Enregistrer le nom")
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
                    .foregroundStyle(.red)
            } else {
                Text("Votre nom est visible par les membres de vos groupes.")
            }
        }
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
                Label("Rappel", systemImage: "alarm")
            }
            .accessibilityIdentifier(AccessibilityID.Settings.leadTimePicker)
        } header: {
            Text("Rappels d’échéance")
        } footer: {
            Text(remindersFooter)
        }
    }

    private var remindersFooter: String {
        guard model.leadTime.isEnabled else {
            return "Aucun rappel d’échéance ne sera programmé sur cet iPhone."
        }
        var text = "Pour chaque tâche qui vous est assignée et qui a une échéance, un rappel est programmé sur cet iPhone."
        if model.notificationStatus == .denied {
            text += " Les notifications étant refusées, les rappels ne s’afficheront pas."
        }
        return text
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        Section {
            LabeledContent {
                Text(model.notificationStatusText)
            } label: {
                Label("Autorisation", systemImage: "bell")
            }
            .accessibilityIdentifier(AccessibilityID.Settings.notificationStatus)

            if model.canRequestNotifications {
                Button {
                    Task {
                        await model.requestNotifications()
                    }
                } label: {
                    Label("Autoriser les notifications", systemImage: "bell.badge")
                }
                .accessibilityIdentifier(AccessibilityID.Settings.requestNotifications)
            } else if model.notificationStatus == .denied {
                Button(action: openSystemNotificationSettings) {
                    Label("Ouvrir les Réglages de l’iPhone", systemImage: "gear")
                }
                .accessibilityIdentifier(AccessibilityID.Settings.openSystemSettings)
            }
        } header: {
            Text("Notifications")
        } footer: {
            if let hint = model.notificationHint {
                Text(hint)
            }
        }
    }

    // MARK: - Push (ntfy)

    private var pushSection: some View {
        Section {
            if let topic = model.pushTopic {
                ForEach(Array(SettingsViewModel.pushInstructionSteps.enumerated()), id: \.offset) { index, step in
                    Label {
                        Text(step)
                    } icon: {
                        Image(systemName: "\(index + 1).circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Votre sujet ntfy")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(topic)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
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
                        Label("Activer les notifications push", systemImage: "bell.badge")
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
    }

    // MARK: - Account

    private var accountSection: some View {
        Section {
            Button {
                isConfirmingSignOut = true
            } label: {
                HStack {
                    Label("Se déconnecter", systemImage: "rectangle.portrait.and.arrow.right")
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
                Label("Supprimer mon compte", systemImage: "trash")
            }
            .disabled(model.isSigningOut || model.isDeletingAccount)
            .accessibilityIdentifier(AccessibilityID.Settings.deleteAccount)
        } header: {
            Text("Compte")
        } footer: {
            Text("La suppression du compte efface définitivement votre profil et vos assignations.")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Self.appVersion)
                .accessibilityIdentifier(AccessibilityID.Settings.version)
        } footer: {
            Text("Équipe — les tâches de votre groupe.")
        }
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
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
        UIPasteboard.general.string = topic
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
