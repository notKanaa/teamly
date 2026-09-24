import SwiftUI
import UIKit

/// « Configuration manquante »: the app was built without the address of its Supabase project
/// (Info.plist `SupabaseHost` / `SupabasePublishableKey`, from Config/Secrets.xcconfig).
struct ShellConfigurationMissingView: View {
    let issue: ConfigurationIssue

    private let steps = [
        "Sur GitHub, ouvrez votre dépôt › Settings › Secrets and variables › Actions › onglet « Variables ».",
        "Ajoutez SUPABASE_HOST (l’hôte du projet, par exemple « abcdefgh.supabase.co », sans « https:// ») et SUPABASE_PUBLISHABLE_KEY (Supabase › Project Settings › API Keys, clé « sb_publishable_… »).",
        "Relancez le workflow « CI », puis réinstallez l’IPA « Equipe-unsigned-ipa » avec Sideloadly.",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(spacing: 12) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.system(size: 48, weight: .semibold))
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text("Configuration manquante")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text("Cette version d’Équipe a été compilée sans l’adresse de votre projet Supabase : elle ne peut pas se connecter.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)

                card(title: "Ce qui manque") {
                    ForEach(Array(issue.problems.enumerated()), id: \.offset) { _, problem in
                        Label {
                            Text(problem.message)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                card(title: "Comment corriger") {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        Label {
                            Text(step)
                        } icon: {
                            Image(systemName: "\(index + 1).circle.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Text("Sur votre ordinateur : copiez Config/Secrets.example.xcconfig vers Config/Secrets.xcconfig et remplissez-le, puis relancez « xcodegen generate ».")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Shell.configurationMissing)
    }

    private func card<CardContent: View>(title: String, @ViewBuilder content: () -> CardContent) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .font(.callout)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
