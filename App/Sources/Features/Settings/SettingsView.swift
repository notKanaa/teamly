import SwiftUI
import TeamTasksCore
import UIKit

/// « Réglages » (docs/DESIGN-V2.md §7.8, the SettingsMain mockup), on cards over the grouped background:
/// - the profile card: the avatar and the name (« Mon profil »: name and avatar), the e-mail, three figures (« tâches
///   ce mois », « semaines de série », « groupes », docs/CONTRACTS-V3.md §8) and « Modifier mon profil »;
/// - four quick tiles: Notifications (the permission: asks for it, or opens the iPhone's settings), Rappels (the lead
///   time), Récap du lundi (a switch), Heures calmes (a sheet, docs/CONTRACTS-V3.md §9);
/// - Personnalisation › Apparence (theme, app icon, confetti, haptics);
/// - « Mes groupes » (each row opens the group), « Compte » (password, the ntfy push screen, sign-out), « Teamly »
///   (invite friends, what's new, help), « Supprimer mon compte » and the footer.
///
/// The parts that do not need the profile (tiles, account) stay usable when it cannot be loaded, so that signing out
/// always works. Sign-out and deletion end the session: `AppModel` shows the login screen.
struct SettingsView: View {
    let session: SessionModel

    @State private var model: SettingsViewModel
    @State private var stats: PersonalStatsViewModel
    @State private var groups: GroupsListViewModel

    @Environment(DevicePreferences.self) private var preferences
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var isConfirmingSignOut = false
    @State private var isShowingDeleteAccount = false
    @State private var destination: SettingsDestination?
    @State private var profileEditor: AvatarEditorViewModel?
    @State private var passwordModel: ChangePasswordViewModel?
    @State private var activeSheet: SettingsSheet?

    init(session: SessionModel) {
        self.session = session
        _model = State(initialValue: SettingsViewModel(session: session))
        _stats = State(initialValue: PersonalStatsViewModel(session: session))
        _groups = State(initialValue: GroupsListViewModel(session: session))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let message = model.loadState.failureMessage {
                    loadFailedCard(message)
                }
                profileCard
                quickTiles
                SettingsSection("Personnalisation") {
                    appearanceRow
                }
                if !groups.groups.isEmpty {
                    groupsSection
                }
                accountSection
                teamlySection
                deleteAccountButton
                footer
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .screenBackground()
        .navigationTitle("Réglages")
        .navigationDestination(item: $destination) { destination in
            switch destination {
            case .appearance:
                AppearanceSettingsView()
            case .push:
                PushSettingsView(model: model)
            }
        }
        .task(id: model.refreshKey) {
            await model.load()
        }
        .task(id: stats.refreshKey) {
            await stats.load()
        }
        .task(id: groups.refreshKey) {
            await groups.load()
        }
        .refreshable {
            await model.reload()
            await stats.reload()
            await groups.reload()
        }
        .onChange(of: scenePhase) { _, phase in
            // The permission may have been changed in the iPhone's Settings app.
            if phase == .active {
                Task {
                    await model.refreshNotificationStatus()
                }
            }
        }
        // The sheets and the pushed ntfy screen show the errors of the model themselves.
        .shellErrorAlert(model, isEnabled: isShowingOwnErrors)
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
        .sheet(isPresented: $isShowingDeleteAccount) {
            SettingsDeleteAccountView(model: model)
        }
        .sheet(isPresented: isShowingProfileEditor) {
            if let profileEditor {
                ProfileEditorSheet(settings: model, avatar: profileEditor)
            }
        }
        .sheet(item: $passwordModel) { passwordModel in
            ChangePasswordSheet(model: passwordModel)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .quietHours:
                QuietHoursSheet(quietHours: preferences.quietHours) { quietHours in
                    saveQuietHours(quietHours)
                }
            case .whatsNew:
                WhatsNewSheet()
            case .help:
                HelpSheet()
            }
        }
    }

    /// False while a sheet or the ntfy screen shows the model's errors in its own alert.
    private var isShowingOwnErrors: Bool {
        !isShowingDeleteAccount && destination != .push && profileEditor == nil
    }

    // MARK: - Load failure

    private func loadFailedCard(_ message: String) -> some View {
        Card {
            Label("Profil indisponible", systemImage: "wifi.exclamationmark")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task {
                    await model.reload()
                }
            } label: {
                Label("Réessayer", systemImage: "arrow.clockwise")
                    .font(Font.body.weight(.bold))
                    .foregroundStyle(Theme.accent)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.Settings.retry)
        }
    }

    // MARK: - Profile card

    private var profileCard: some View {
        // At accessibility text sizes the avatar goes above the name, which then gets the whole width.
        let identityLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
        return Card(padding: 20, spacing: 18, radius: 26) {
            identityLayout {
                avatarButton
                VStack(alignment: .leading, spacing: 2) {
                    if let profile = model.profile {
                        Text(profile.displayName)
                            .font(.rounded(.title2))
                            .foregroundStyle(Theme.textPrimary)
                            .accessibilityIdentifier(AccessibilityID.Settings.profileName)
                    } else {
                        Text("Ton profil")
                            .font(.rounded(.title2))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Text(model.email ?? "—")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .accessibilityIdentifier(AccessibilityID.Settings.email)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            statTiles
            Button(action: openProfileEditor) {
                Text("Modifier mon profil")
                    .font(Font.body.weight(.heavy))
                    .foregroundStyle(model.profile == nil ? Theme.textSecondary : Theme.accent)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.pressable)
            .disabled(model.profile == nil)
            .accessibilityHint("Ton nom, ta couleur et ton symbole")
            .accessibilityIdentifier(AccessibilityID.Settings.editProfileButton)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Settings.profileCard)
    }

    /// The 72 pt avatar with a card-colored gap and a ring in its soft color: opens « Mon profil ».
    private var avatarButton: some View {
        Button(action: openProfileEditor) {
            Group {
                if let appearance = model.avatarAppearance {
                    AvatarView(appearance, size: 72)
                        .background {
                            ZStack {
                                Circle()
                                    .fill(appearance.color.tone.background)
                                    .padding(-6)
                                Circle()
                                    .fill(Theme.card)
                                    .padding(-4)
                            }
                        }
                } else {
                    Circle()
                        .fill(Theme.track)
                        .frame(width: 72, height: 72)
                        .overlay {
                            if model.loadState.isLoading || model.loadState == .idle {
                                ProgressView()
                            }
                        }
                }
            }
            .padding(6)
            .contentShape(Circle())
        }
        .buttonStyle(.pressable)
        .disabled(model.profile == nil)
        .accessibilityLabel("Avatar de \(model.profile?.displayName ?? "ton profil")")
        .accessibilityHint("Modifier ton nom, ta couleur et ton symbole")
        .accessibilityIdentifier(AccessibilityID.Settings.avatarButton)
    }

    @ViewBuilder private var statTiles: some View {
        let figures = stats.stats
        let month = SettingsStatTile(
            value: figures.map { "\($0.tasksThisMonth)" } ?? "—",
            label: figures?.tasksThisMonthLabel ?? "tâches ce mois",
            tone: SoftTone.accent
        )
        .accessibilityIdentifier(AccessibilityID.Settings.stat("month"))
        let streak = SettingsStatTile(
            value: figures.map { "\($0.streakWeeks)" } ?? "—",
            label: figures?.streakLabel ?? "semaines de série",
            systemImage: "flame.fill",
            tone: ColorKey.amber.tone
        )
        .accessibilityIdentifier(AccessibilityID.Settings.stat("streak"))
        let groupCount = SettingsStatTile(
            value: groups.loadState.isLoaded ? "\(groups.groups.count)" : "—",
            label: PersonalStats.groupsLabel(groups.groups.count),
            tone: ColorKey.teal.tone
        )
        .accessibilityIdentifier(AccessibilityID.Settings.stat("groups"))
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 10) {
                month
                streak
                groupCount
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                month
                streak
                groupCount
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Quick tiles

    @ViewBuilder private var quickTiles: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 12) {
                notificationsTile
                remindersTile
                weeklyRecapTile
                quietHoursTile
            }
        } else {
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    notificationsTile
                    remindersTile
                }
                GridRow {
                    weeklyRecapTile
                    quietHoursTile
                }
            }
        }
    }

    private var notificationsTile: some View {
        Button(action: notificationsAction) {
            SettingsQuickTile(
                "Notifications",
                status: model.notificationStatusText,
                statusColor: notificationStatusColor,
                systemImage: "bell.badge.fill",
                tone: ColorKey.coral.tone
            )
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("Notifications")
        .accessibilityValue(model.notificationStatusText)
        .accessibilityHint(notificationsHint)
        .accessibilityIdentifier(AccessibilityID.Settings.notificationStatus)
    }

    private var notificationStatusColor: Color {
        switch model.notificationStatus {
        case .authorized: ColorKey.green.tone.foreground
        case .denied: Theme.danger
        case .notDetermined, nil: Theme.textSecondary
        }
    }

    private var notificationsHint: String {
        model.canRequestNotifications ? "Autoriser les notifications" : "Ouvrir les réglages de l’iPhone"
    }

    private var remindersTile: some View {
        Menu {
            Picker("Rappel", selection: $model.leadTime) {
                ForEach(model.leadTimeOptions) { option in
                    Text(option.label)
                        .tag(option)
                }
            }
        } label: {
            SettingsQuickTile(
                "Rappels",
                status: remindersStatus,
                systemImage: "alarm.fill",
                tone: ColorKey.orange.tone
            )
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("Rappels")
        .accessibilityValue(remindersStatus)
        .accessibilityIdentifier(AccessibilityID.Settings.leadTimePicker)
    }

    /// « 1 heure avant l’échéance », « Aucun rappel ».
    private var remindersStatus: String {
        switch model.leadTime {
        case .atDueTime, .off: model.leadTime.label
        case .fifteenMinutes, .oneHour, .oneDay: "\(model.leadTime.label) l’échéance"
        }
    }

    private var weeklyRecapTile: some View {
        SettingsQuickTile(
            SettingsViewModel.weeklyRecapTitle,
            status: model.isWeeklyRecapEnabled ? "Lundi à 9:00" : "Désactivé",
            systemImage: "trophy.fill",
            tone: ColorKey.amber.tone
        ) {
            Toggle(SettingsViewModel.weeklyRecapTitle, isOn: $model.isWeeklyRecapEnabled)
                .labelsHidden()
                .tint(Theme.accentFill)
                .accessibilityHint(SettingsViewModel.weeklyRecapFooter)
                .accessibilityIdentifier(AccessibilityID.Settings.weeklyRecapToggle)
        }
        .accessibilityElement(children: .contain)
    }

    private var quietHoursTile: some View {
        let quietHours = preferences.quietHours
        let status = quietHours.isEnabled ? quietHours.rangeText : "Désactivées"
        return Button {
            activeSheet = .quietHours
        } label: {
            SettingsQuickTile("Heures calmes", status: status, systemImage: "moon.fill", tone: SoftTone.accent)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("Heures calmes")
        .accessibilityValue(status)
        .accessibilityIdentifier(AccessibilityID.Settings.quietHoursTile)
    }

    // MARK: - Personnalisation

    private var appearanceRow: some View {
        Button {
            preferences.refreshAppIcon()
            destination = .appearance
        } label: {
            SettingsRowLabel(
                "Apparence",
                systemImage: "paintpalette.fill",
                tone: ColorKey.violet.tone,
                trailing: preferences.appearanceSummary,
                showsChevron: true
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.Settings.appearanceRow)
        .onAppear {
            preferences.refreshAppIcon()
        }
    }

    // MARK: - Mes groupes

    private var groupsSection: some View {
        SettingsSection("Mes groupes") {
            ForEach(Array(groups.groups.enumerated()), id: \.element.id) { index, summary in
                if index > 0 {
                    SettingsDivider()
                }
                Button {
                    appModel.router.showGroup(summary.id)
                } label: {
                    groupRow(summary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.Settings.groupRow(summary.group.name))
            }
        }
    }

    private func groupRow(_ summary: GroupSummary) -> some View {
        HStack(spacing: 12) {
            GroupTile(summary.group.appearance, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.group.name)
                    .font(Font.body.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(groupSubtitle(summary))
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(Font.footnote.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 10)
        .frame(minHeight: 60)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// « Admin · 3 membres », « Membre » while the members are not read.
    private func groupSubtitle(_ summary: GroupSummary) -> String {
        let role = summary.myRole == .admin ? "Admin" : "Membre"
        guard let overview = groups.overview(of: summary.id) else { return role }
        return "\(role) · \(FrenchText.count(overview.members.count, "membre", "membres"))"
    }

    // MARK: - Compte

    private var accountSection: some View {
        SettingsSection("Compte") {
            Button {
                passwordModel = ChangePasswordViewModel(session: session)
            } label: {
                SettingsRowLabel(
                    ChangePasswordViewModel.title,
                    systemImage: "lock.fill",
                    tone: ColorKey.blue.tone,
                    trailing: "Modifier",
                    trailingColor: Theme.accent,
                    trailingWeight: .bold
                )
            }
            .buttonStyle(.plain)
            .disabled(model.isSigningOut || model.isDeletingAccount)
            .accessibilityIdentifier(AccessibilityID.Settings.passwordRow)

            SettingsDivider()

            Button {
                destination = .push
            } label: {
                SettingsRowLabel(
                    "Notifications push",
                    subtitle: "Même quand Teamly est fermée",
                    systemImage: "antenna.radiowaves.left.and.right",
                    tone: ColorKey.teal.tone,
                    trailing: pushStatus,
                    showsChevron: true
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.Settings.pushRow)

            SettingsDivider()

            Button {
                isConfirmingSignOut = true
            } label: {
                HStack {
                    SettingsRowLabel("Se déconnecter", systemImage: "rectangle.portrait.and.arrow.right", tone: SoftTone.neutral)
                    if model.isSigningOut {
                        ProgressView()
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(model.isSigningOut || model.isDeletingAccount)
            .accessibilityIdentifier(AccessibilityID.Settings.signOut)
        }
    }

    /// « Activées », « Désactivées », nothing while unknown.
    private var pushStatus: String? {
        guard model.loadState.isLoaded else { return nil }
        return model.isPushEnabled ? "Activées" : "Désactivées"
    }

    // MARK: - Teamly

    private var teamlySection: some View {
        SettingsSection("Teamly") {
            ShareLink(item: Self.inviteText) {
                SettingsRowLabel("Inviter des amis sur Teamly", systemImage: "square.and.arrow.up", tone: ColorKey.coral.tone)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.Settings.inviteFriends)

            SettingsDivider()

            Button {
                activeSheet = .whatsNew
            } label: {
                HStack(spacing: 8) {
                    SettingsRowLabel("Nouveautés", systemImage: "sparkles", tone: SoftTone.accent)
                    SettingsBadge("v2")
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.Settings.whatsNew)

            SettingsDivider()

            Button {
                activeSheet = .help
            } label: {
                SettingsRowLabel("Aide et contact", systemImage: "questionmark.circle.fill", tone: SoftTone.neutral)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.Settings.help)
        }
    }

    /// The text shared by « Inviter des amis sur Teamly ».
    static let inviteText = "Je m’organise avec Teamly pour partager les tâches de nos groupes (coloc, famille, asso…)\u{00A0}: qui fait quoi, à tour de rôle, avec des rappels. Installe Teamly et demande-moi le code d’invitation de notre groupe\u{00A0}!"

    // MARK: - Delete account and footer

    private var deleteAccountButton: some View {
        Button(role: .destructive) {
            model.deleteConfirmation = ""
            isShowingDeleteAccount = true
        } label: {
            Label("Supprimer mon compte", systemImage: "trash")
                .font(Font.body.weight(.heavy))
                .foregroundStyle(Theme.danger)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: 52)
                .cardSurface(radius: Theme.Radius.button, elevation: .subtle)
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
        }
        .buttonStyle(.pressable)
        .disabled(model.isSigningOut || model.isDeletingAccount)
        .accessibilityHint("Ton profil et tes assignations seront effacés définitivement")
        .accessibilityIdentifier(AccessibilityID.Settings.deleteAccount)
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Image(decorative: "AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            Text("Teamly \(Self.appVersion) · les tâches de ton groupe")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier(AccessibilityID.Settings.version)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    // MARK: - Actions

    private var isShowingProfileEditor: Binding<Bool> {
        Binding(
            get: { profileEditor != nil },
            set: { isShown in
                if !isShown {
                    profileEditor = nil
                }
            }
        )
    }

    private func openProfileEditor() {
        profileEditor = model.makeAvatarEditor()
    }

    private func notificationsAction() {
        switch model.notificationStatus {
        case .notDetermined:
            Task {
                await model.requestNotifications()
            }
        case .authorized, .denied:
            guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
            openURL(url)
        case nil:
            break
        }
    }

    private func saveQuietHours(_ quietHours: QuietHours) {
        preferences.setQuietHours(quietHours)
        // The reminders move out of the new window (or back).
        Task {
            await session.synchronizeReminders()
        }
    }
}

/// Screens pushed from « Réglages ».
private enum SettingsDestination: Hashable {
    case appearance
    case push
}

/// Sheets of « Réglages » with no model of their own.
private enum SettingsSheet: String, Identifiable {
    case quietHours
    case whatsNew
    case help

    var id: String { rawValue }
}
