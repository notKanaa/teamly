import Foundation
import TeamTasksSupabase

/// Reads the Supabase project settings that project.yml writes into Info.plist from the build settings
/// (Config/Base.xcconfig, overridden by the generated Config/Secrets.xcconfig).
enum SupabaseSettings {
    static let schemeKey = "SupabaseScheme"
    static let hostKey = "SupabaseHost"
    static let publishableKeyKey = "SupabasePublishableKey"

    /// Values of Config/Secrets.example.xcconfig: copying the example without editing it is not a configuration.
    private static let exampleHost = "your-project-ref.supabase.co"
    private static let exampleKey = "sb_publishable_xxxxxxxxxxxxxxxx"

    /// The configuration of this bundle's Info.plist, or every problem found.
    static func configuration(from bundle: Bundle) -> Result<SupabaseConfiguration, ConfigurationIssue> {
        configuration { key in bundle.object(forInfoDictionaryKey: key) }
    }

    /// The configuration from Info.plist-like values, or every problem found (all of them at once, so that a
    /// single rebuild fixes everything).
    static func configuration(lookup: (String) -> Any?) -> Result<SupabaseConfiguration, ConfigurationIssue> {
        var problems: [ConfigurationIssue.Problem] = []

        let scheme = (usableValue(lookup(schemeKey)) ?? "https").lowercased()
        if scheme != "https" && scheme != "http" {
            problems.append(.invalidScheme(scheme))
        }

        var url: URL?
        switch usableValue(lookup(hostKey)) {
        case nil:
            problems.append(.missingHost)
        case let host? where host == exampleHost:
            problems.append(.exampleHost)
        case let host? where host.hasSuffix(":") || host.contains("://"):
            // `SUPABASE_HOST = https://…` in an .xcconfig file: "//" starts a comment, only "https:" is left.
            problems.append(.hostWithScheme(host))
        case let host?:
            let trimmedHost = host.hasSuffix("/") ? String(host.dropLast()) : host
            if let candidate = URL(string: "\(scheme)://\(trimmedHost)"), let parsedHost = candidate.host(), !parsedHost.isEmpty {
                url = candidate
            } else {
                problems.append(.invalidHost(host))
            }
        }

        let key = usableValue(lookup(publishableKeyKey))
        switch key {
        case nil:
            problems.append(.missingKey)
        case let key? where key == exampleKey:
            problems.append(.exampleKey)
        default:
            break
        }

        guard problems.isEmpty, let url, let key else {
            return .failure(ConfigurationIssue(problems: problems))
        }
        return .success(SupabaseConfiguration(url: url, publishableKey: key))
    }

    /// A trimmed Info.plist string; nil when missing, empty, or an unexpanded `$(BUILD_SETTING)`.
    private static func usableValue(_ raw: Any?) -> String? {
        guard let raw = raw as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }
}

/// Why the app cannot reach its backend: shown by the « Configuration manquante » screen.
struct ConfigurationIssue: Error, Sendable, Equatable {
    enum Problem: Sendable, Equatable {
        case missingHost
        case exampleHost
        case hostWithScheme(String)
        case invalidHost(String)
        case invalidScheme(String)
        case missingKey
        case exampleKey

        /// French explanation of the problem.
        var message: String {
            switch self {
            case .missingHost:
                "SUPABASE_HOST est vide : indiquez l’hôte de votre projet, par exemple « abcdefgh.supabase.co »."
            case .exampleHost:
                "SUPABASE_HOST contient encore la valeur d’exemple « your-project-ref.supabase.co »."
            case let .hostWithScheme(host):
                "SUPABASE_HOST vaut « \(host) » : indiquez seulement l’hôte, sans « https:// » (dans un fichier .xcconfig, « // » commence un commentaire)."
            case let .invalidHost(host):
                "SUPABASE_HOST « \(host) » n’est pas un nom d’hôte valide."
            case let .invalidScheme(scheme):
                "SUPABASE_SCHEME vaut « \(scheme) » : utilisez « https » (ou « http » pour un Supabase local)."
            case .missingKey:
                "SUPABASE_PUBLISHABLE_KEY est vide : copiez la clé publique « sb_publishable_… » de votre projet."
            case .exampleKey:
                "SUPABASE_PUBLISHABLE_KEY contient encore la valeur d’exemple."
            }
        }
    }

    var problems: [Problem]
}
