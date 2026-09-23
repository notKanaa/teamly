import Foundation
import Testing
@testable import TeamTasksSupabase

@Suite struct ConfigurationTests {
    @Test func storesValues() throws {
        let url = try #require(URL(string: "http://127.0.0.1:54321"))
        let config = SupabaseConfiguration(url: url, publishableKey: "sb_publishable_test")
        #expect(config.url.host() == "127.0.0.1")
        #expect(config.publishableKey == "sb_publishable_test")
    }
}
