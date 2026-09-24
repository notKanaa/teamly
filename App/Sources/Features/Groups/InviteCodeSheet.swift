import SwiftUI
import TeamTasksCore

/// « Code d’invitation » sheet (admins): the code in large monospaced type, « Partager le code » (`ShareLink` with
/// the view model's share text) and « Générer un nouveau code ».
struct InviteCodeSheet: View {
    @State private var model: MembersViewModel
    @State private var isConfirmingRegeneration = false
    @Environment(\.dismiss) private var dismiss

    init(session: SessionModel, groupId: UUID) {
        _model = State(initialValue: MembersViewModel(session: session, groupId: groupId))
    }

    var body: some View {
        NavigationStack {
            content
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
        .alert("Erreur", isPresented: $model.isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let code = model.inviteCodeText, model.canSeeInviteCode {
            ScrollView {
                VStack(spacing: 20) {
                    Text("Partagez ce code avec les personnes à inviter dans « \(model.groupName) ». Elles le saisiront dans « Rejoindre ».")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.center)
                    Text(code)
                        .font(.system(size: 44, weight: .bold, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .textSelection(.enabled)
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity)
                        .background(
                            Color.accentColor.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                        )
                        .accessibilityHint("Code d’invitation du groupe")
                        .accessibilityIdentifier(AccessibilityID.Groups.inviteCode)
                    if let shareText = model.shareText {
                        ShareLink(item: shareText, subject: Text("Invitation dans Équipe")) {
                            Label("Partager le code", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .accessibilityIdentifier(AccessibilityID.Groups.shareCodeButton)
                    }
                    Button {
                        isConfirmingRegeneration = true
                    } label: {
                        if model.isRegeneratingCode {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Label("Générer un nouveau code", systemImage: "arrow.triangle.2.circlepath")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(model.isRegeneratingCode)
                    .accessibilityIdentifier(AccessibilityID.Groups.regenerateCodeButton)
                    Text("Le code reste valable jusqu’à ce qu’un admin en génère un nouveau.")
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
            }
        } else if model.isGone {
            ContentUnavailableView(
                "Groupe indisponible",
                systemImage: "person.3",
                description: Text(MembersViewModel.goneMessage)
            )
        } else if model.loadState.isLoaded {
            ContentUnavailableView(
                "Code réservé aux admins",
                systemImage: "lock",
                description: Text("Seuls les admins du groupe peuvent voir et partager le code d’invitation.")
            )
        } else {
            GroupsLoadStateView(loadState: model.loadState) {
                Task { await model.reload() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
