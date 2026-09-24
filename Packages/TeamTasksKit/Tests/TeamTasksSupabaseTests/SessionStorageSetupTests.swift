import Foundation
import Testing
@testable import TeamTasksSupabase

/// A reinstall must not sign straight back into the previous installation's session: iOS keeps Keychain items
/// when an app is deleted, but not the app's files (review SEC-5).
@Suite struct SessionStorageSetupTests {
    func temporaryMarker() -> InstallationMarker {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("equipe-\(UUID().uuidString)")
        return InstallationMarker(url: directory.appendingPathComponent("Equipe").appendingPathComponent("installation"))
    }

    @Test func firstLaunchOfAnInstallationRemovesTheStoredSessions() throws {
        let marker = temporaryMarker()
        defer { try? FileManager.default.removeItem(at: marker.url.deletingLastPathComponent().deletingLastPathComponent()) }
        let current = InMemoryAuthStorage()
        let legacy = InMemoryAuthStorage()
        try current.store(key: "sb-projet-auth-token", value: Data("ancienne".utf8))
        try legacy.store(key: "sb-projet-auth-token", value: Data("plus ancienne".utf8))
        try legacy.store(key: "supabase.session", value: Data("très ancienne".utf8))

        #expect(!marker.exists)
        #expect(SessionStorageSetup.removeSessionsOfAPreviousInstallation(marker: marker, storages: [current, legacy]))
        #expect(try current.retrieve(key: "sb-projet-auth-token") == nil)
        #expect(try legacy.retrieve(key: "sb-projet-auth-token") == nil)
        #expect(try legacy.retrieve(key: "supabase.session") == nil)
        #expect(marker.exists)
    }

    @Test func laterLaunchesKeepTheSession() throws {
        let marker = temporaryMarker()
        defer { try? FileManager.default.removeItem(at: marker.url.deletingLastPathComponent().deletingLastPathComponent()) }
        let storage = InMemoryAuthStorage()
        SessionStorageSetup.removeSessionsOfAPreviousInstallation(marker: marker, storages: [storage])

        // Signed in during this installation.
        try storage.store(key: "sb-projet-auth-token", value: Data("session".utf8))
        #expect(!SessionStorageSetup.removeSessionsOfAPreviousInstallation(marker: marker, storages: [storage]))
        #expect(try storage.retrieve(key: "sb-projet-auth-token") == Data("session".utf8))
    }

    /// A removal that fails does not stop the marker: a later launch never removes a session of this installation.
    @Test func markerIsWrittenEvenIfARemovalFails() throws {
        struct Failing: ClearableAuthStorage {
            struct Refused: Error {}
            func store(key: String, value: Data) throws {}
            func retrieve(key: String) throws -> Data? { nil }
            func remove(key: String) throws { throw Refused() }
            func removeAll() throws { throw Refused() }
        }
        let marker = temporaryMarker()
        defer { try? FileManager.default.removeItem(at: marker.url.deletingLastPathComponent().deletingLastPathComponent()) }
        let storage = InMemoryAuthStorage()
        try storage.store(key: "clé", value: Data("x".utf8))
        #expect(SessionStorageSetup.removeSessionsOfAPreviousInstallation(marker: marker, storages: [Failing(), storage]))
        #expect(try storage.retrieve(key: "clé") == nil)
        #expect(marker.exists)
    }

    @Test func applicationSupportMarkerPath() throws {
        let marker = try #require(InstallationMarker.applicationSupport())
        #expect(marker.url.lastPathComponent == "installation")
        #expect(marker.url.deletingLastPathComponent().lastPathComponent == "Equipe")
    }
}
