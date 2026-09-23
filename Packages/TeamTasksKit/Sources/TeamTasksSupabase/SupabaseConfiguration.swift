import Foundation
import Supabase
import TeamTasksCore

/// Connection settings for the Supabase project (publishable key — safe to ship in the app).
public struct SupabaseConfiguration: Sendable, Hashable {
    public var url: URL
    public var publishableKey: String

    public init(url: URL, publishableKey: String) {
        self.url = url
        self.publishableKey = publishableKey
    }
}
