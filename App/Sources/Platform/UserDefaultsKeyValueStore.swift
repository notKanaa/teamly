import Foundation
import TeamTasksCore

/// `KeyValueStore` backed by `UserDefaults` (reminder lead time, « Mes tâches » last-seen date, notification
/// cursors). `UserDefaults` is documented as thread-safe, hence `@unchecked Sendable`.
final class UserDefaultsKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func data(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    func set(_ data: Data?, forKey key: String) {
        if let data {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
