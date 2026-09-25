import SwiftUI
import TeamTasksCore
import UIKit

/// « Configuration manquante »: the app was built without the address of its Supabase project
/// (Info.plist `SupabaseHost` / `SupabasePublishableKey`, from Config/Secrets.xcconfig).
struct ShellConfigurationMissingView: View {
    let issue: ConfigurationIssue

    private let steps = [
        "Sur GitHub, ouvre ton dépôt › Settings › Secrets and variables › Actions › onglet «\u{00A0}Variables\u{00A0}».",
        "Ajoute SUPABASE_HOST (l’hôte du projet, par exemple «\u{00A0}abcdefgh.supabase.co\u{00A0}», sans «\u{00A0}https://\u{00A0}») et SUPABASE_PUBLISHABLE_KEY (Supabase › Project Settings › API Keys, clé «\u{00A0}sb_publishable_…\u{00A0}»).",
        "Relance le workflow «\u{00A0}CI\u{00A0}», puis réinstalle l’IPA «\u{00A0}Equipe-unsigned-ipa\u{00A0}» avec Sideloadly.",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(spacing: 14) {
                    IconTile(systemImage: "wrench.and.screwdriver.fill", tone: ColorKey.orange.tone, size: 64)
                    Text("Configuration manquante")
                        .font(.rounded(.title))
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text("Cette version d’Équipe a été compilée sans l’adresse de ton projet Supabase\u{00A0}: elle ne peut pas se connecter.")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)

                card(title: "Ce qui manque") {
                    ForEach(Array(issue.problems.enumerated()), id: \.offset) { _, problem in
                        Label {
                            Text(problem.message)
                                .foregroundStyle(Theme.textPrimary)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(ColorKey.orange.accent)
                        }
                    }
                }

                card(title: "Comment corriger") {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        Label {
                            Text(step)
                                .foregroundStyle(Theme.textPrimary)
                        } icon: {
                            Image(systemName: "\(index + 1).circle.fill")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    Text("Sur ton ordinateur\u{00A0}: copie Config/Secrets.example.xcconfig vers Config/Secrets.xcconfig et remplis-le, puis relance «\u{00A0}xcodegen generate\u{00A0}».")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .screenBackground()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Shell.configurationMissing)
    }

    private func card<CardContent: View>(title: String, @ViewBuilder content: () -> CardContent) -> some View {
        Card(spacing: 14) {
            Text(title)
                .font(.rounded(.headline, weight: .heavy))
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .font(.callout)
    }
}
