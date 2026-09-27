import SwiftUI
import TeamTasksCore
import UIKit
import UniformTypeIdentifiers

/// « Notifications push » (pushed from « Réglages › Compte »): the optional ntfy push (docs/NOTIFICATIONS.md). Off: what
/// it does and « Activer les notifications push ». On: the steps, the private topic (copy it, open it in ntfy, install
/// ntfy) and « Désactiver les notifications push » (confirmed).
struct PushSettingsView: View {
    let model: SettingsViewModel

    @State private var isConfirmingPushDisable = false
    @State private var didCopyTopic = false

    /// The free ntfy app on the App Store.
    static let ntfyAppStoreURL = URL(string: "https://apps.apple.com/app/ntfy/id1625396347")

    init(model: SettingsViewModel) {
        self.model = model
    }

    var body: some View {
        Form {
            Section {
                if let topic = model.pushTopic {
                    enabledRows(topic)
                } else {
                    enableButton
                }
            } header: {
                Text("ntfy")
            } footer: {
                Text(model.isPushEnabled ? SettingsViewModel.pushPrivacyNote : SettingsViewModel.pushDisabledExplanation)
            }
            .listRowBackground(Theme.card)
        }
        .screenBackground()
        .navigationTitle("Notifications push")
        .navigationBarTitleDisplayMode(.inline)
        .shellErrorAlert(model)
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
    }

    @ViewBuilder
    private func enabledRows(_ topic: String) -> some View {
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
    }

    private var enableButton: some View {
        Button {
            Task {
                await model.enablePush()
            }
        } label: {
            HStack {
                Label {
                    Text("Activer les notifications push")
                        .foregroundStyle(model.loadState.isLoaded ? Theme.accent : Theme.textSecondary)
                } icon: {
                    IconTile(systemImage: "antenna.radiowaves.left.and.right", tone: ColorKey.teal.tone, size: 30)
                }
                Spacer()
                if model.isUpdatingPush {
                    ProgressView()
                }
            }
        }
        .disabled(model.isUpdatingPush || !model.loadState.isLoaded)
        .accessibilityIdentifier(AccessibilityID.Settings.enablePush)
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
}
