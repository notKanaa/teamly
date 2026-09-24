import Foundation
import Supabase

#if canImport(Security)
import Security
#endif

/// An Auth session storage that can also be emptied.
protocol ClearableAuthStorage: AuthLocalStorage {
    /// Removes every item of this storage.
    func removeAll() throws
}

extension InMemoryAuthStorage: ClearableAuthStorage {}

/// A file of the app's container that exists once the app has launched on this installation. iOS deletes the
/// container with the app but keeps its Keychain items, so a missing marker means « new installation ».
///
/// The file has no data protection, so its presence is also readable before the first unlock after a reboot
/// (a background launch): an existing installation is never mistaken for a new one.
struct InstallationMarker: Sendable {
    let url: URL

    /// `Application Support/Equipe/installation` of the app's container.
    static func applicationSupport(fileManager: FileManager = .default) -> InstallationMarker? {
        guard let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return InstallationMarker(url: directory.appendingPathComponent("Equipe").appendingPathComponent("installation"))
    }

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    func create() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if canImport(Security)
        try Data().write(to: url, options: [.atomic, .noFileProtection])
        #else
        try Data().write(to: url, options: [.atomic])
        #endif
    }
}

/// Prepares the session storage before the Auth client reads it.
enum SessionStorageSetup {
    /// On the first launch of an installation (no `marker`), removes every stored session (a reinstall must not
    /// sign straight back into the previous installation's session), then creates the marker. Returns whether it
    /// ran. The marker is created even if a removal fails, so that a later launch never removes a new session.
    @discardableResult
    static func removeSessionsOfAPreviousInstallation(
        marker: InstallationMarker,
        storages: [any ClearableAuthStorage]
    ) -> Bool {
        guard !marker.exists else { return false }
        for storage in storages {
            try? storage.removeAll()
        }
        try? marker.create()
        return true
    }
}

#if canImport(Security)
/// Auth session storage in the Keychain, readable after the first unlock (Background App Refresh while the device
/// is locked) but never included in backups nor transferred to another device
/// (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; supabase-swift's `KeychainLocalStorage` uses
/// `kSecAttrAccessibleAfterFirstUnlock`, which travels with encrypted backups).
struct KeychainAuthStorage: ClearableAuthStorage {
    /// Keychain service of the app's sessions.
    static let appService = "equipe.auth"
    /// Keychain service of supabase-swift's default storage (earlier builds): only emptied.
    static let legacyService = "supabase.gotrue.swift"

    let service: String

    func store(key: String, value: Data) throws {
        let query = itemQuery(key: key)
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = query.merging(attributes) { _, new in new }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainStatusError(status: status) }
    }

    /// nil when there is no item; throws when the Keychain cannot be read (e.g. before the first unlock).
    func retrieve(key: String) throws -> Data? {
        var query = itemQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainStatusError(status: status)
        }
    }

    func remove(key: String) throws {
        try delete(itemQuery(key: key))
    }

    func removeAll() throws {
        try delete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ])
    }

    private func delete(_ query: [String: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainStatusError(status: status) }
    }

    private func itemQuery(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

/// A Keychain call failed with this `OSStatus`.
struct KeychainStatusError: Error, Sendable, Hashable {
    let status: OSStatus
}
#endif
