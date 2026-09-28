import Foundation

// The client-only settings of « Réglages › Apparence » (docs/CONTRACTS-V3.md §9), stored per device. The quiet hours
// are `QuietHours`; the app icon is whatever iOS shows (`UIApplication.alternateIconName`), not stored.

/// The app's appearance: the system's, or always light, or always dark.
public enum ThemePreference: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case auto
    case light
    case dark

    public var id: String { rawValue }

    /// « Auto », « Clair », « Sombre ».
    public var label: String {
        switch self {
        case .auto: "Auto"
        case .light: "Clair"
        case .dark: "Sombre"
        }
    }
}

/// The app icon: A « Trio », B « Carte cochée » (the primary icon), C « Monogramme ».
public enum AppIconChoice: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case trio
    case checkedCard
    case monogram

    /// The primary icon.
    public static let `default` = AppIconChoice.checkedCard

    public var id: String { rawValue }

    /// « A », « B », « C ».
    public var letter: String {
        switch self {
        case .trio: "A"
        case .checkedCard: "B"
        case .monogram: "C"
        }
    }

    /// « Trio », « Carte cochée », « Monogramme ».
    public var label: String {
        switch self {
        case .trio: "Trio"
        case .checkedCard: "Carte cochée"
        case .monogram: "Monogramme"
        }
    }

    /// The alternate icon set of the asset catalog (`UIApplication.setAlternateIconName`), nil for the primary icon.
    public var alternateIconName: String? {
        switch self {
        case .trio: "AppIconTrio"
        case .checkedCard: nil
        case .monogram: "AppIconMonogramme"
        }
    }

    /// The choice shown by iOS (`UIApplication.alternateIconName`); an unknown name is the primary icon.
    public init(alternateIconName: String?) {
        self = Self.allCases.first { $0.alternateIconName == alternateIconName } ?? .default
    }
}

/// The theme and the effect switches: confetti when the user completes a task, haptics. Everything on « Auto » and on
/// by default.
public struct DeviceSettings: Sendable, Hashable, Codable {
    /// `KeyValueStore` key.
    public static let storageKey = "settings.device"

    public var theme: ThemePreference
    public var isConfettiEnabled: Bool
    public var isHapticsEnabled: Bool

    public init(theme: ThemePreference = .auto, isConfettiEnabled: Bool = true, isHapticsEnabled: Bool = true) {
        self.theme = theme
        self.isConfettiEnabled = isConfettiEnabled
        self.isHapticsEnabled = isHapticsEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case theme
        case isConfettiEnabled
        case isHapticsEnabled
    }

    /// Missing or unknown values take their default (settings written by a later version stay readable).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `try?` flattens the optional of `decodeIfPresent`: nil when missing or unreadable.
        let theme: ThemePreference? = try? container.decodeIfPresent(ThemePreference.self, forKey: .theme)
        let confetti: Bool? = try? container.decodeIfPresent(Bool.self, forKey: .isConfettiEnabled)
        let haptics: Bool? = try? container.decodeIfPresent(Bool.self, forKey: .isHapticsEnabled)
        self.init(theme: theme ?? .auto, isConfettiEnabled: confetti ?? true, isHapticsEnabled: haptics ?? true)
    }

    /// The stored settings, or the defaults when missing or unreadable.
    public static func load(from store: any KeyValueStore) -> DeviceSettings {
        store.value(DeviceSettings.self, forKey: storageKey) ?? DeviceSettings()
    }

    public func save(to store: any KeyValueStore) {
        store.setValue(self, forKey: Self.storageKey)
    }

    /// « Auto · Icône B », the summary of the « Apparence » row.
    public func summary(icon: AppIconChoice) -> String {
        "\(theme.label) · Icône \(icon.letter)"
    }
}
