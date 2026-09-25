import SwiftUI
import TeamTasksCore

/// « Code d’invitation » sheet (admins): the group's tile, the code in large monospaced type on the soft accent,
/// « Partager le code » (`ShareLink` with the view model's share text) and « Générer un nouveau code ».
struct InviteCodeSheet: View {
    @State private var model: MembersViewModel
    @State private var isConfirmingRegeneration = false
    @Environment(\.dismiss) private var dismiss

    init(session: SessionModel, groupId: UUID) {
        _model = State(initialValue: MembersViewModel(session: session, groupId: groupId))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(.horizontal, Theme.Spacing.page)
                    .padding(.vertical, 20)
            }
            .screenBackground()
                .navigationTitle("Code d’invitation")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fermer") {
                            dismiss()
                        }
                        .accessibilityIdentifier(AccessibilityID.Groups.doneButton)
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .task(id: model.refreshKey) {
            await model.load()
        }
        .onChange(of: model.isGone) { _, isGone in
            if isGone {
                dismiss()
            }
        }
        .confirmationDialog(
            "Générer un nouveau code\u{00A0}?",
            isPresented: $isConfirmingRegeneration,
            titleVisibility: .visible
        ) {
            Button("Générer un nouveau code", role: .destructive) {
                Task { await model.regenerateInviteCode() }
            }
            .accessibilityIdentifier(AccessibilityID.Groups.regenerateConfirmButton)
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("L’ancien code ne fonctionnera plus. Les membres actuels restent dans le groupe.")
        }
        .shellErrorAlert(model)
    }

    @ViewBuilder
    private var content: some View {
        if let code = model.inviteCodeText, model.canSeeInviteCode {
            codeContent(code)
        } else if model.isGone {
            GroupsStateView(
                systemImage: "person.2.slash",
                tone: .neutral,
                title: "Groupe indisponible",
                message: MembersViewModel.goneMessage
            )
        } else if model.loadState.isLoaded {
            GroupsStateView(
                systemImage: "lock.fill",
                tone: .neutral,
                title: "Code réservé aux admins",
                message: "Seuls les admins du groupe peuvent voir et partager le code d’invitation."
            )
        } else {
            GroupsLoadStateView(loadState: model.loadState) {
                Task { await model.reload() }
            }
        }
    }

    private func codeContent(_ code: String) -> some View {
        VStack(spacing: 18) {
            if let group = model.group {
                GroupTile(group.appearance, size: 56)
            }
            Text("Partage ce code avec les personnes à inviter dans «\u{00A0}\(model.groupName)\u{00A0}». Elles le saisiront dans «\u{00A0}Rejoindre un groupe\u{00A0}».")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            // Spelled out by VoiceOver (« L, Y, L, A, tiret, S… »), not read as a word and a number.
            Text(code)
                .speechSpellsOutCharacters()
                .font(.system(size: 40, weight: .heavy, design: .monospaced))
                .foregroundStyle(Theme.accentSoftText)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .textSelection(.enabled)
                .padding(.vertical, 18)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .background(
                    Theme.accentSoft,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                )
                .accessibilityHint("Code d’invitation du groupe")
                .accessibilityIdentifier(AccessibilityID.Groups.inviteCode)
            if let shareText = model.shareText {
                ShareLink(item: shareText, subject: Text("Invitation dans Équipe")) {
                    Label("Partager le code", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.primary)
                .accessibilityIdentifier(AccessibilityID.Groups.shareCodeButton)
            }
            Button {
                isConfirmingRegeneration = true
            } label: {
                if model.isRegeneratingCode {
                    ProgressView()
                        .accessibilityLabel("Génération d’un nouveau code")
                } else {
                    Label("Générer un nouveau code", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .buttonStyle(.secondary)
            .disabled(model.isRegeneratingCode)
            .accessibilityIdentifier(AccessibilityID.Groups.regenerateCodeButton)
            Text("Le code reste valable jusqu’à ce qu’un admin en génère un nouveau.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}
