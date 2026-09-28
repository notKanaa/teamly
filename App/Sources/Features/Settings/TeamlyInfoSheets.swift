import SwiftUI
import TeamTasksCore

/// « Nouveautés » (sheet of « Réglages › Teamly »): what v2 brought, then what v3 brings next.
struct WhatsNewSheet: View {
    @Environment(\.dismiss) private var dismiss

    struct Feature: Identifiable {
        let title: String
        let text: String
        let systemImage: String
        let tone: SoftTone

        var id: String { title }
    }

    static let current: [Feature] = [
        Feature(title: "Un nouveau look", text: "Des couleurs et un emoji pour chaque groupe, ton avatar, un mode sombre soigné.", systemImage: "paintpalette.fill", tone: ColorKey.violet.tone),
        Feature(title: "Tâches répétées", text: "Chaque jour, chaque semaine ou chaque mois, avec la prochaine échéance calculée pour toi.", systemImage: "arrow.triangle.2.circlepath", tone: SoftTone.accent),
        Feature(title: "À tour de rôle", text: "Une tâche passe d’un membre à l’autre à chaque fois qu’elle est faite.", systemImage: "person.2.fill", tone: ColorKey.teal.tone),
        Feature(title: "Checklists", text: "Découpe une tâche en petites étapes à cocher.", systemImage: "checklist", tone: ColorKey.green.tone),
        Feature(title: "Activité et podium", text: "Le fil du groupe, le récap du lundi et le podium de la semaine.", systemImage: "trophy.fill", tone: ColorKey.amber.tone),
    ]

    static let next: [Feature] = [
        Feature(title: "Réglages repensés", text: "Tes chiffres du mois, les heures calmes, le thème, l’icône et les confettis.", systemImage: "gearshape.fill", tone: SoftTone.accent),
        Feature(title: "Raccourcis", text: "Balaie une tâche pour la terminer, épingle tes groupes, appuie longuement sur l’icône de Teamly.", systemImage: "hand.draw.fill", tone: ColorKey.orange.tone),
        Feature(title: "Bientôt", text: "Relancer quelqu’un, le mode absent, échanger ton tour, les réactions, les commentaires et les photos.", systemImage: "sparkles", tone: ColorKey.pink.tone),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    featureCard("Dans Teamly 2", features: Self.current)
                    featureCard("Et maintenant", features: Self.next)
                }
                .padding(.horizontal, Theme.Spacing.page)
                .padding(.vertical, 16)
            }
            .screenBackground()
            .navigationTitle("Nouveautés")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        dismiss()
                    }
                    .fontWeight(.bold)
                    .accessibilityIdentifier(AccessibilityID.Settings.infoDone)
                }
            }
        }
    }

    private func featureCard(_ title: String, features: [Feature]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title)
            Card(spacing: 16) {
                ForEach(features) { feature in
                    HStack(alignment: .top, spacing: 12) {
                        IconTile(systemImage: feature.systemImage, tone: feature.tone, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.title)
                                .font(Font.body.weight(.bold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(feature.text)
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// « Aide et contact » (sheet of « Réglages › Teamly »): a short FAQ, each answer unfolding under its question.
struct HelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    struct Question: Identifiable {
        let question: String
        let answer: String

        var id: String { question }
    }

    static let questions: [Question] = [
        Question(
            question: "Comment inviter quelqu’un dans mon groupe\u{00A0}?",
            answer: "Ouvre le groupe, touche «\u{00A0}Inviter\u{00A0}» et partage le code d’invitation. La personne le saisit dans «\u{00A0}Rejoindre un groupe\u{00A0}». Seuls les admins voient le code."
        ),
        Question(
            question: "Pourquoi je ne reçois pas de rappel\u{00A0}?",
            answer: "Vérifie que les notifications sont activées (Réglages › Notifications) et que «\u{00A0}Rappels\u{00A0}» n’est pas sur «\u{00A0}Aucun rappel\u{00A0}». Pendant les heures calmes, les rappels attendent la fin de la plage."
        ),
        Question(
            question: "Comment recevoir les notifications quand l’app est fermée\u{00A0}?",
            answer: "Active «\u{00A0}Notifications push\u{00A0}» dans Réglages › Compte, puis abonne-toi au sujet indiqué dans l’app gratuite ntfy."
        ),
        Question(
            question: "Qui peut modifier ou supprimer une tâche\u{00A0}?",
            answer: "Les admins du groupe et la personne qui l’a créée. Les personnes assignées peuvent changer son statut et cocher sa checklist."
        ),
        Question(
            question: "Comment fonctionne «\u{00A0}À tour de rôle\u{00A0}»\u{00A0}?",
            answer: "Quand la tâche est terminée, la prochaine échéance est créée et assignée au membre suivant de la liste."
        ),
        Question(
            question: "Comment quitter ou supprimer un groupe\u{00A0}?",
            answer: "Dans «\u{00A0}Groupes\u{00A0}», balaie la carte du groupe vers la gauche, ou appuie longuement dessus. Un admin peut supprimer le groupe, un membre peut le quitter."
        ),
        Question(
            question: "Mes données sont-elles supprimées avec mon compte\u{00A0}?",
            answer: "Oui\u{00A0}: «\u{00A0}Supprimer mon compte\u{00A0}» efface définitivement ton profil et tes assignations. Les groupes où il ne reste que toi sont supprimés avec leurs tâches."
        ),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle("Questions fréquentes")
                    ForEach(Self.questions) { item in
                        DisclosureGroup {
                            Text(item.answer)
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 6)
                        } label: {
                            Text(item.question)
                                .font(Font.body.weight(.bold))
                                .foregroundStyle(Theme.textPrimary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .tint(Theme.accent)
                        .padding(Theme.Spacing.cardPadding)
                        .cardSurface()
                    }
                }
                .padding(.horizontal, Theme.Spacing.page)
                .padding(.vertical, 16)
            }
            .screenBackground()
            .navigationTitle("Aide et contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        dismiss()
                    }
                    .fontWeight(.bold)
                    .accessibilityIdentifier(AccessibilityID.Settings.infoDone)
                }
            }
        }
    }
}
