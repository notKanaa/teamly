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
        case let key? where isSecretKey(key):
            // Shipped in the app, a secret key would give everyone who extracts it access to every row (it bypasses
            // RLS): refuse to run with it rather than use it.
            problems.append(.secretKey)
        default:
            break
        }

        guard problems.isEmpty, let url, let key else {
            return .failure(ConfigurationIssue(problems: problems))
        }
        return .success(SupabaseConfiguration(url: url, publishableKey: key))
    }

    /// A Supabase key that must never ship in an app: a secret key (`sb_secret_…`), or a legacy JWT key whose `role`
    /// is not `anon` (`service_role`). Publishable keys (`sb_publishable_…`) and anon JWT keys are fine.
    static func isSecretKey(_ key: String) -> Bool {
        if key.hasPrefix("sb_secret_") {
            return true
        }
        let parts = key.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let payload = base64URLDecoded(String(parts[1])),
              let claims = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        else {
            return false
        }
        return (claims["role"] as? String) != "anon"
    }

    private static func base64URLDecoded(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
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
        /// A secret (`sb_secret_…`) or `service_role` key instead of the publishable one.
        case secretKey

        /// French explanation of the problem.
        var message: String {
            switch self {
            case .missingHost:
                "SUPABASE_HOST est vide\u{00A0}: indiquez l’hôte de votre projet, par exemple «\u{00A0}abcdefgh.supabase.co\u{00A0}»."
            case .exampleHost:
                "SUPABASE_HOST contient encore la valeur d’exemple «\u{00A0}your-project-ref.supabase.co\u{00A0}»."
            case let .hostWithScheme(host):
                "SUPABASE_HOST vaut «\u{00A0}\(host)\u{00A0}»\u{00A0}: indiquez seulement l’hôte, sans «\u{00A0}https://\u{00A0}» (dans un fichier .xcconfig, «\u{00A0}//\u{00A0}» commence un commentaire)."
            case let .invalidHost(host):
                "SUPABASE_HOST «\u{00A0}\(host)\u{00A0}» n’est pas un nom d’hôte valide."
            case let .invalidScheme(scheme):
                "SUPABASE_SCHEME vaut «\u{00A0}\(scheme)\u{00A0}»\u{00A0}: utilisez «\u{00A0}https\u{00A0}» (ou «\u{00A0}http\u{00A0}» pour un Supabase local)."
            case .missingKey:
                "SUPABASE_PUBLISHABLE_KEY est vide\u{00A0}: copiez la clé publique «\u{00A0}sb_publishable_…\u{00A0}» de votre projet."
            case .exampleKey:
                "SUPABASE_PUBLISHABLE_KEY contient encore la valeur d’exemple."
            case .secretKey:
                "SUPABASE_PUBLISHABLE_KEY contient une clé secrète, qui donnerait accès à toutes les données à quiconque l’extrait de l’app\u{00A0}: utilisez la clé publique «\u{00A0}sb_publishable_…\u{00A0}» de votre projet, et régénérez la clé secrète si cette version a été partagée."
            }
        }
    }

    var problems: [Problem]
}
