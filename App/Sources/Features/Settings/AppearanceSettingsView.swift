import SwiftUI
import TeamTasksCore
import UIKit

/// « Apparence » (pushed from « Réglages », the SettingsAppearance mockup, docs/CONTRACTS-V3.md §9):
/// - « Thème »: Auto / Clair / Sombre, as three cards with a small preview, applied to the whole app at once;
/// - « Icône de l’app »: A « Trio », B « Carte cochée », C « Monogramme », drawn from their preview images (iOS
///   confirms a change with its own alert);
/// - « Effets »: « Confettis » when the user completes a task, « Vibrations » of the checkboxes and statuses.
///
/// Every choice is stored on this iPhone (`DevicePreferences`).
struct AppearanceSettingsView: View {
    @Environment(DevicePreferences.self) private var preferences
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isChangingIcon = false

    init() {}

    var body: some View {
        @Bindable var settings = preferences
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                themeSection
                iconSection
                VStack(alignment: .leading, spacing: 8) {
                    SettingsSection("Effets") {
                        Toggle(isOn: $settings.isConfettiEnabled) {
                            effectLabel("Confettis", subtitle: "Quand tu termines une tâche", systemImage: "sparkles", tone: ColorKey.pink.tone)
                        }
                        .tint(Theme.accentFill)
                        .padding(.vertical, 6)
                        .accessibilityIdentifier(AccessibilityID.Settings.confettiToggle)
                        SettingsDivider()
                        Toggle(isOn: $settings.isHapticsEnabled) {
                            effectLabel(
                                "Vibrations",
                                subtitle: "Au toucher des cases et statuts",
                                systemImage: "iphone.radiowaves.left.and.right",
                                tone: ColorKey.blue.tone
                            )
                        }
                        .tint(Theme.accentFill)
                        .padding(.vertical, 6)
                        .accessibilityIdentifier(AccessibilityID.Settings.hapticsToggle)
                    }
                    Text("La taille du texte suit les réglages de ton iPhone.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .screenBackground()
        .navigationTitle("Apparence")
        .onAppear {
            preferences.refreshAppIcon()
        }
    }

    // MARK: - Theme

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Thème")
                .font(Font.subheadline.weight(.heavy))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
                // The scheme the app shows now (the UI tests read it).
                .accessibilityValue(colorScheme == .dark ? "Sombre" : "Clair")
                .accessibilityIdentifier(AccessibilityID.Settings.themeTitle)
            let columns = dynamicTypeSize.isAccessibilitySize ? 1 : 3
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 10) {
                ForEach(ThemePreference.allCases) { theme in
                    themeCard(theme)
                }
            }
        }
    }

    private func themeCard(_ theme: ThemePreference) -> some View {
        let isSelected = preferences.theme == theme
        return Button {
            select(theme)
        } label: {
            VStack(spacing: 8) {
                ThemePreview(theme: theme)
                Text(theme.label)
                    .font(Font.subheadline.weight(.heavy))
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .cardSurface(radius: 20, elevation: .subtle)
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent : Color.clear, lineWidth: 3)
            }
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("Thème \(theme.label)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(AccessibilityID.Settings.themeOption(theme.rawValue))
    }

    private func select(_ theme: ThemePreference) {
        guard theme != preferences.theme else { return }
        preferences.theme = theme
        if theme == .auto {
            preferences.resetWindowsInterfaceStyle()
        }
    }

    // MARK: - App icon

    private var iconSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Icône de l’app")
            let columns = dynamicTypeSize.isAccessibilitySize ? 2 : 3
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 12) {
                ForEach(AppIconChoice.allCases) { icon in
                    iconButton(icon)
                }
            }
            .padding(16)
            .cardSurface()
            if !preferences.supportsAlternateIcons {
                Text("Cet iPhone ne permet pas de changer l’icône.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func iconButton(_ icon: AppIconChoice) -> some View {
        let isSelected = preferences.appIcon == icon
        return Button {
            choose(icon)
        } label: {
            VStack(spacing: 8) {
                Image(decorative: Self.previewName(icon))
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .padding(3)
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(isSelected ? Theme.accent : Color.clear, lineWidth: 3)
                    }
                Text(icon.label)
                    .font(Font.footnote.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(4)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .disabled(isChangingIcon || !preferences.supportsAlternateIcons)
        .accessibilityLabel("Icône \(icon.letter), \(icon.label)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(AccessibilityID.Settings.iconOption(icon.rawValue))
    }

    /// The preview image of an icon (App/Resources/Assets.xcassets, rendered by scripts/render-app-icon.mjs).
    static func previewName(_ icon: AppIconChoice) -> String {
        switch icon {
        case .trio: "AppIconPreviewTrio"
        case .checkedCard: "AppIconPreviewCarte"
        case .monogram: "AppIconPreviewMonogramme"
        }
    }

    private func choose(_ icon: AppIconChoice) {
        guard icon != preferences.appIcon, !isChangingIcon else { return }
        isChangingIcon = true
        Task {
            await preferences.setAppIcon(icon)
            isChangingIcon = false
        }
    }

    // MARK: - Effects

    private func effectLabel(_ title: String, subtitle: String, systemImage: String, tone: SoftTone) -> some View {
        HStack(spacing: 12) {
            IconTile(systemImage: systemImage, tone: tone, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Font.body.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The small screen of a theme card: two halves, each a ground with a colored bar and two cards (light and dark for
/// « Auto »). Decorative.
private struct ThemePreview: View {
    let theme: ThemePreference

    var body: some View {
        HStack(spacing: 0) {
            half(isDark: theme == .dark)
            half(isDark: theme != .light)
        }
        .frame(width: 64, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: Theme.shadow.opacity(0.12), radius: 4, x: 0, y: 2)
        .accessibilityHidden(true)
    }

    private func half(isDark: Bool) -> some View {
        let ground = Color(uiColor: UIColor(rgb: isDark ? 0x0F0E17 : 0xF4F3F8))
        let card = Color(uiColor: UIColor(rgb: isDark ? 0x1C1A27 : 0xFFFFFF))
        return VStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(ColorKey.coral.fill)
                .frame(height: 7)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(card)
                .frame(height: 12)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(card)
                .frame(height: 12)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ground)
    }
}
