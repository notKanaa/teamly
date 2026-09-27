import Foundation
import Supabase
import TeamTasksCore

/// The objects of the private bucket `task-photos` (docs/CONTRACTS-V3.md §6), behind a protocol so that unit tests can
/// answer without a server. Errors are mapped to `AppError` (`SupabaseErrorMapping.storage`).
protocol PhotoStorage: Sendable {
    /// Uploads a new object (never overwrites one).
    func upload(path: String, data: Data, contentType: String) async throws
    /// Removes an object.
    func remove(path: String) async throws
    /// A signed URL of an object, valid `expiresIn` seconds.
    func signedURL(path: String, expiresIn: Int) async throws -> URL
}

/// `PhotoStorage` on supabase-swift's storage client: the requests carry the session's access token, so the bucket's
/// policies apply (select and insert in the caller's groups, delete by the owner or an admin of the group).
struct SupabasePhotoStorage: PhotoStorage {
    let client: SupabaseClient

    private var bucket: StorageFileApi { client.storage.from(TaskPhoto.bucket) }

    func upload(path: String, data: Data, contentType: String) async throws {
        do {
            _ = try await bucket.upload(path, data: data, options: FileOptions(contentType: contentType, upsert: false))
        } catch {
            throw SupabaseErrorMapping.storage(error)
        }
    }

    func remove(path: String) async throws {
        do {
            _ = try await bucket.remove(paths: [path])
        } catch {
            throw SupabaseErrorMapping.storage(error)
        }
    }

    func signedURL(path: String, expiresIn: Int) async throws -> URL {
        do {
            return try await bucket.createSignedURL(path: path, expiresIn: expiresIn)
        } catch {
            throw SupabaseErrorMapping.storage(error)
        }
    }
}
