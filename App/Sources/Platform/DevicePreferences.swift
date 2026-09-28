import Observation
import SwiftUI
import TeamTasksCore
import UIKit

/// The per-device settings of « Réglages » (docs/CONTRACTS-V3.md §9) for the views: the theme, the confetti and haptics
/// switches (`DeviceSettings`), the quiet hours (`QuietHours`) and the app icon.
///
/// Read from and written to the platform's `KeyValueStore` (UserDefaults on a device; in memory with the mock backend,
/// so that every UI test starts from the defaults). The icon is the one iOS shows (`UIApplication.alternateIconName`).
/// One instance, created at launch (`AppContainer`), in the environment of every screen; the root view applies the
/// theme and passes the switches down (`\.hapticsEnabled`, `\.celebrate`).
@MainActor
@Observable
final class DevicePreferences {
    private(set) var settings: DeviceSettings
    private(set) var quietHours: QuietHours
    /// The icon shown on the home screen (read again by `refreshAppIcon()`).
    private(set) var appIcon: AppIconChoice = .default

    private let store: any KeyValueStore

    init(store: any KeyValueStore) {
        self.store = store
        settings = DeviceSettings.load(from: store)
        quietHours = QuietHours.load(from: store)
    }

    // MARK: - Appearance

    var theme: ThemePreference {
        get { settings.theme }
        set { update { $0.theme = newValue } }
    }

    var isConfettiEnabled: Bool {
        get { settings.isConfettiEnabled }
        set { update { $0.isConfettiEnabled = newValue } }
    }

    var isHapticsEnabled: Bool {
        get { settings.isHapticsEnabled }
        set { update { $0.isHapticsEnabled = newValue } }
    }

    /// The scheme to force on the app: nil for « Auto » (the system's).
    var colorScheme: ColorScheme? {
        switch settings.theme {
        case .auto: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// « Auto · Icône B ».
    var appearanceSummary: String {
        settings.summary(icon: appIcon)
    }

    private func update(_ change: (inout DeviceSettings) -> Void) {
        var changed = settings
        change(&changed)
        guard changed != settings else { return }
        settings = changed
        changed.save(to: store)
    }

    // MARK: - Quiet hours

    /// Stores the quiet hours. The caller resynchronizes the reminders (`SessionModel.synchronizeReminders()`).
    func setQuietHours(_ value: QuietHours) {
        guard value != quietHours else { return }
        quietHours = value
        value.save(to: store)
    }

    // MARK: - App icon

    /// Whether this device can change the app icon.
    var supportsAlternateIcons: Bool {
        UIApplication.shared.supportsAlternateIcons
    }

    /// Reads the icon iOS shows.
    func refreshAppIcon() {
        appIcon = AppIconChoice(alternateIconName: UIApplication.shared.alternateIconName)
    }

    /// Asks iOS to show `choice` (iOS confirms it with its own alert). Returns false when it refused.
    @discardableResult
    func setAppIcon(_ choice: AppIconChoice) async -> Bool {
        guard UIApplication.shared.supportsAlternateIcons else { return false }
        guard UIApplication.shared.alternateIconName != choice.alternateIconName else {
            appIcon = choice
            return true
        }
        do {
            try await UIApplication.shared.setAlternateIconName(choice.alternateIconName)
            appIcon = choice
            return true
        } catch {
            refreshAppIcon()
            return false
        }
    }

    // MARK: - Window

    /// Back to « Auto »: clears the style forced on the windows as well (`preferredColorScheme(nil)` may leave the
    /// previous one in place).
    func resetWindowsInterfaceStyle() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = .unspecified
            }
        }
    }
}

// MARK: - Environment

private struct HapticsEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// « Vibrations » of « Réglages › Apparence »: the design system's haptics (`sensoryFeedback`) play only when true.
    var hapticsEnabled: Bool {
        get { self[HapticsEnabledKey.self] }
        set { self[HapticsEnabledKey.self] = newValue }
    }
}
