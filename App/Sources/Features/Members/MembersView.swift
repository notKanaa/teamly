import SwiftUI
import TeamTasksCore

/// « Membres » screen: the members of a group (admins first, then by name) with their role; for admins the invite
/// code (share, regenerate) and the member actions (« Nommer admin » / « Retirer le rôle d’admin », « Retirer du
/// groupe »); « Quitter le groupe » for everyone. Leaves the group's screens when the group is gone.
struct MembersView: View {
    let session: SessionModel

    @State private var model: MembersViewModel
    @State private var memberPendingRemoval: Membership?
    @State private var isConfirmingRemoval = false
    @State private var memberPendingDemotion: Membership?
    @State private var isConfirmingSelfDemotion = false
    @State private var isConfirmingLeave = false
    @State private var isConfirmingRegeneration = false
    @Environment(AppModel.self) private var appModel
    @Environment(\.dynamicTypeSize) private var typeSize

    init(groupId: UUID, session: SessionModel) {
        self.session = session
        _model = State(initialValue: MembersViewModel(session: session, groupId: groupId))
    }

    var body: some View {
        List {
            if model.loadState.isLoaded && !model.isGone {
                if model.canSeeInviteCode {
                    inviteSection
                }
                membersSection
                leaveSection
            }
        }
        .accessibilityIdentifier(AccessibilityID.Members.list)
        .overlay {
            overlay
        }
        .navigationTitle(model.title)
        .task(id: model.refreshKey) {
            await model.load()
        }
        .refreshable {
            await model.reload()
        }
        .onChange(of: model.isGone, initial: true) { _, isGone in
            if isGone {
                appModel.router.removeRoutes(forGroup: model.groupId)
            }
        }
        .confirmationDialog(
            "Retirer ce membre\u{00A0}?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible,
            presenting: memberPendingRemoval
        ) { member in
            Button("Retirer \(member.user.displayName)", role: .destructive) {
                Task { await model.remove(member) }
            }
            .accessibilityIdentifier(AccessibilityID.Members.removeConfirmButton)
            Button("Annuler", role: .cancel) {}
        } message: { member in
            Text("\(member.user.displayName) n’aura plus accès à «\u{00A0}\(model.groupName)\u{00A0}». Ses assignations dans ce groupe seront retirées.")
        }
        .confirmationDialog(
            "Retirer votre rôle d’admin\u{00A0}?",
            isPresented: $isConfirmingSelfDemotion,
            titleVisibility: .visible,
            presenting: memberPendingDemotion
        ) { member in
            Button("Retirer mon rôle d’admin", role: .destructive) {
                Task { await model.setRole(.member, for: member) }
            }
            .accessibilityIdentifier(AccessibilityID.Members.selfDemoteConfirmButton)
            Button("Annuler", role: .cancel) {}
        } message: { _ in
            Text("Vous ne pourrez plus gérer les membres, le code d’invitation ni le nom du groupe.")
        }
        .confirmationDialog("Quitter le groupe\u{00A0}?", isPresented: $isConfirmingLeave, titleVisibility: .visible) {
            Button(leaveConfirmTitle, role: .destructive) {
                Task { await model.leave() }
            }
            .accessibilityIdentifier(AccessibilityID.Members.leaveConfirmButton)
            Button("Annuler", role: .cancel) {}
        } message: {
            Text(model.leaveConfirmationMessage)
        }
        .confirmationDialog(
            "Générer un nouveau code\u{00A0}?",
            isPresented: $isConfirmingRegeneration,
            titleVisibility: .visible
        ) {
            Button("Générer un nouveau code", role: .destructive) {
                Task { await model.regenerateInviteCode() }
            }
            .accessibilityIdentifier(AccessibilityID.Members.regenerateConfirmButton)
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("L’ancien code ne fonctionnera plus. Les membres actuels restent dans le groupe.")
        }
        .alert("Erreur", isPresented: $model.isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: - Sections

    /// Admins: the invite code, « Partager le code », « Générer un nouveau code ».
    private var inviteSection: some View {
        Section {
            HStack {
                Label("Code d’invitation", systemImage: "qrcode")
                Spacer(minLength: 8)
                // Spelled out by VoiceOver (« L, Y, L, A, tiret, S… »), not read as a word and a number.
                Text(model.inviteCodeText ?? "—")
                    .speechSpellsOutCharacters()
                    .font(.title3.monospaced().weight(.bold))
                    .textSelection(.enabled)
                    .accessibilityIdentifier(AccessibilityID.Members.inviteCode)
            }
            if let shareText = model.shareText {
                ShareLink(item: shareText, subject: Text("Invitation dans Équipe")) {
                    Label("Partager le code", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier(AccessibilityID.Members.shareCodeButton)
            }
            Button {
                isConfirmingRegeneration = true
            } label: {
                HStack {
                    Label("Générer un nouveau code", systemImage: "arrow.triangle.2.circlepath")
                    if model.isRegeneratingCode {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(model.isRegeneratingCode)
            .accessibilityIdentifier(AccessibilityID.Members.regenerateCodeButton)
        } header: {
            Text("Inviter")
        } footer: {
            Text("Toute personne qui a ce code peut rejoindre le groupe.")
        }
    }

    private var membersSection: some View {
        Section {
            ForEach(model.members) { member in
                memberRow(member)
            }
        } header: {
            Text("«\u{00A0}\(model.groupName)\u{00A0}» · \(GroupsText.memberCount(model.members.count))")
                .textCase(nil)
        }
    }

    private func memberRow(_ member: Membership) -> some View {
        let now = session.platform.now()
        // « Membre depuis le 14 septembre »: the day only, short enough for the caption line.
        let joined = MembersJoinedText.sentence(joinedAt: member.joinedAt, now: now, calendar: session.platform.calendar)
        let isBusy = model.busyMemberIds.contains(member.id)
        let isLarge = typeSize.isAccessibilitySize
        // At accessibility text sizes the avatar, the name and the role go under each other instead of being cut.
        let infoLayout = isLarge
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        return HStack(spacing: 4) {
            infoLayout {
                GroupsPersonAvatar(id: member.user.id, name: member.user.displayName, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName(of: member))
                        .font(.body)
                        .fontWeight(model.isMe(member) ? Font.Weight.semibold : Font.Weight.regular)
                        .lineLimit(isLarge ? nil : 1)
                    Text(joined)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(isLarge ? nil : 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isBusy {
                    ProgressView()
                        .accessibilityLabel("Mise à jour")
                } else {
                    GroupsRoleBadge(role: member.role)
                        .fixedSize()
                }
            }
            .accessibilityElement(children: .combine)
            if hasActions(member) {
                Menu {
                    memberActions(member)
                } label: {
                    // A 44 × 44 pt tap area at least; the frame grows with the glyph at large text sizes.
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(isBusy)
                .accessibilityLabel("Actions pour \(member.user.displayName)")
                .accessibilityIdentifier(AccessibilityID.Members.actionsButton(member.user.displayName))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Members.row(member.user.displayName))
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if model.canRemove(member) {
                Button {
                    requestRemoval(of: member)
                } label: {
                    Label("Retirer", systemImage: "person.badge.minus")
                }
                .tint(Color.red)
            }
            if model.canChangeRole(of: member) {
                Button {
                    requestRoleChange(of: member)
                } label: {
                    Label(model.roleActionTitle(for: member), systemImage: member.role == .admin ? "star.slash" : "star")
                }
                .tint(Color.orange)
            }
        }
        .contextMenu {
            if hasActions(member) {
                memberActions(member)
            }
        }
    }

    @ViewBuilder
    private func memberActions(_ member: Membership) -> some View {
        if model.canChangeRole(of: member) {
            Button {
                requestRoleChange(of: member)
            } label: {
                Label(model.roleActionTitle(for: member), systemImage: member.role == .admin ? "star.slash" : "star")
            }
            .accessibilityIdentifier(AccessibilityID.Members.roleButton)
        }
        if model.canRemove(member) {
            Button(role: .destructive) {
                requestRemoval(of: member)
            } label: {
                Label("Retirer du groupe", systemImage: "person.badge.minus")
            }
            .accessibilityIdentifier(AccessibilityID.Members.removeButton)
        }
    }

    /// « Quitter le groupe » (everyone). Disabled for the last admin, whose footer says what to do first.
    private var leaveSection: some View {
        Section {
            Button(role: .destructive) {
                requestLeave()
            } label: {
                HStack {
                    Label("Quitter le groupe", systemImage: "rectangle.portrait.and.arrow.right")
                    if model.isLeaving {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(model.isLeaving || model.isLastAdmin)
            .accessibilityIdentifier(AccessibilityID.Members.leaveButton)
        } footer: {
            if model.isLastAdmin {
                Text(model.leaveConfirmationMessage)
            } else if model.isLastMember {
                Text("Vous êtes le seul membre\u{00A0}: quitter le groupe le supprimera avec toutes ses tâches.")
            }
        }
    }

    @ViewBuilder
    private var overlay: some View {
        if model.isGone {
            ContentUnavailableView(
                "Groupe indisponible",
                systemImage: "person.3",
                description: Text(MembersViewModel.goneMessage)
            )
        } else if !model.loadState.isLoaded {
            GroupsLoadStateView(loadState: model.loadState) {
                Task { await model.reload() }
            }
        }
    }

    // MARK: - Actions

    private var leaveConfirmTitle: String {
        model.isLastMember ? "Quitter et supprimer le groupe" : "Quitter le groupe"
    }

    private func hasActions(_ member: Membership) -> Bool {
        model.canChangeRole(of: member) || model.canRemove(member)
    }

    private func requestRemoval(of member: Membership) {
        memberPendingRemoval = member
        isConfirmingRemoval = true
    }

    /// Demoting oneself asks for a confirmation (the admin rights are lost); other role changes apply at once.
    private func requestRoleChange(of member: Membership) {
        if model.isMe(member) && member.role == .admin {
            memberPendingDemotion = member
            isConfirmingSelfDemotion = true
        } else {
            Task { await model.toggleRole(of: member) }
        }
    }

    private func requestLeave() {
        // The button is disabled for the last admin (refused by the server anyway, `last_admin`): the section's
        // footer already says to name another admin first.
        guard !model.isLastAdmin else { return }
        isConfirmingLeave = true
    }
}
