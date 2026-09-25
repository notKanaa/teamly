import SwiftUI
import TeamTasksCore

/// « Membres » screen: the members of a group (admins first, then by name) with their avatar and a role chip; for
/// admins the invite code (share, regenerate) and the member actions (« Nommer admin » / « Retirer le rôle d’admin »,
/// « Retirer du groupe »: the « … » of a row, its long press and its swipe); « Quitter le groupe » for everyone.
/// Cards on the grouped background, each action led by an icon tile, like « Réglages ». Leaves the group's screens
/// when the group is gone.
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
            "Retirer ton rôle d’admin\u{00A0}?",
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
            Text("Tu ne pourras plus gérer les membres, le code d’invitation ni le nom du groupe.")
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
        .shellErrorAlert(model)
    }

    // MARK: - Sections

    /// Admins: the invite code, « Partager le code », « Générer un nouveau code ».
    private var inviteSection: some View {
        Section {
            inviteCodeRow
            if let shareText = model.shareText {
                ShareLink(item: shareText, subject: Text("Invitation dans Équipe")) {
                    rowLabel("Partager le code", systemImage: "square.and.arrow.up", tone: ColorKey.blue.tone)
                }
                .accessibilityIdentifier(AccessibilityID.Members.shareCodeButton)
            }
            Button {
                isConfirmingRegeneration = true
            } label: {
                HStack {
                    rowLabel(
                        "Générer un nouveau code",
                        systemImage: "arrow.triangle.2.circlepath",
                        tone: ColorKey.orange.tone
                    )
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
        .listRowBackground(Theme.card)
    }

    /// « Code d’invitation » and the code in the accent (under the label at accessibility text sizes).
    private var inviteCodeRow: some View {
        let isLarge = typeSize.isAccessibilitySize
        let layout = isLarge
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
        return layout {
            rowLabel("Code d’invitation", systemImage: "qrcode", tone: SoftTone.accent)
            if !isLarge {
                Spacer(minLength: 8)
            }
            // Spelled out by VoiceOver (« L, Y, L, A, tiret, S… »), not read as a word and a number.
            Text(model.inviteCodeText ?? "—")
                .speechSpellsOutCharacters()
                .font(.system(.title3, design: .monospaced, weight: .bold))
                .foregroundStyle(Theme.accent)
                .textSelection(.enabled)
                .accessibilityIdentifier(AccessibilityID.Members.inviteCode)
        }
    }

    private var membersSection: some View {
        Section {
            ForEach(model.members) { member in
                memberRow(member)
            }
        } header: {
            Text("«\u{00A0}\(model.groupName)\u{00A0}» · \(FrenchText.count(model.members.count, "membre", "membres"))")
                .textCase(nil)
        }
        .listRowBackground(Theme.card)
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
                AvatarView(member.user.appearance, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName(of: member))
                        .font(Font.body.weight(model.isMe(member) ? .bold : .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(isLarge ? nil : 1)
                    Text(joined)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(isLarge ? nil : 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isBusy {
                    ProgressView()
                        .accessibilityLabel("Mise à jour")
                } else {
                    roleChip(member.role)
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
                        .foregroundStyle(Theme.accent)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(isBusy)
                .accessibilityLabel("Actions pour \(member.user.displayName)")
                .accessibilityIdentifier(AccessibilityID.Members.actionsButton(member.user.displayName))
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Members.row(member.user.displayName))
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if model.canRemove(member) {
                Button {
                    requestRemoval(of: member)
                } label: {
                    Label("Retirer", systemImage: "person.badge.minus")
                }
                .tint(SoftTone.danger.fill)
            }
            if model.canChangeRole(of: member) {
                Button {
                    requestRoleChange(of: member)
                } label: {
                    Label(model.roleActionTitle(for: member), systemImage: member.role == .admin ? "star.slash" : "star")
                }
                .tint(ColorKey.orange.fill)
            }
        }
        .contextMenu {
            if hasActions(member) {
                memberActions(member)
            }
        }
    }

    /// « Admin » (a star, on the soft accent) or « Membre » (neutral).
    private func roleChip(_ role: MemberRole) -> some View {
        Chip(
            role.label,
            systemImage: role == .admin ? "star.fill" : nil,
            tone: role == .admin ? SoftTone.accent : SoftTone.neutral
        )
        .accessibilityLabel("Rôle\u{00A0}: \(role.label)")
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
        let isBlocked = model.isLastAdmin
        return Section {
            Button(role: .destructive) {
                requestLeave()
            } label: {
                HStack {
                    rowLabel(
                        "Quitter le groupe",
                        systemImage: "rectangle.portrait.and.arrow.right",
                        tone: isBlocked ? SoftTone.neutral : SoftTone.danger,
                        textColor: isBlocked ? Theme.textSecondary : Theme.danger
                    )
                    if model.isLeaving {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(model.isLeaving || isBlocked)
            .accessibilityIdentifier(AccessibilityID.Members.leaveButton)
        } footer: {
            if isBlocked {
                Text(model.leaveConfirmationMessage)
            } else if model.isLastMember {
                Text("Tu es le seul membre\u{00A0}: quitter le groupe le supprimera avec toutes ses tâches.")
            }
        }
        .listRowBackground(Theme.card)
    }

    @ViewBuilder
    private var overlay: some View {
        if model.isGone {
            GroupsStateView(
                systemImage: "person.2.slash",
                tone: .neutral,
                title: "Groupe indisponible",
                message: MembersViewModel.goneMessage
            )
        } else if !model.loadState.isLoaded {
            GroupsLoadStateView(loadState: model.loadState) {
                Task { await model.reload() }
            }
        }
    }

    /// A row's title led by an icon tile, as in « Réglages ».
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
