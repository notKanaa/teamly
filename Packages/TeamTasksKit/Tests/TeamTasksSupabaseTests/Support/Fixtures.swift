import Foundation
import TeamTasksCore
@testable import TeamTasksSupabase

/// JSON files of `Tests/TeamTasksSupabaseTests/Fixtures`.
enum Fixture {
    struct Missing: Error, CustomStringConvertible {
        let name: String
        var description: String { "missing fixture \(name).json" }
    }

    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw Missing(name: name)
        }
        return try Data(contentsOf: url)
    }

    /// Decodes like the adapters do (`RestDecoding`).
    static func decode<Value: Decodable>(_ type: Value.Type, _ name: String) throws -> Value {
        try RestDecoding.makeDecoder().decode(type, from: data(name))
    }

    /// Decodes with a plain `JSONDecoder` (fixture metadata).
    static func plain<Value: Decodable>(_ type: Value.Type, _ name: String) throws -> Value {
        try JSONDecoder().decode(type, from: data(name))
    }
}

/// `AppError` cases by name, as written in the error fixtures.
enum AppErrorName {
    static let all: [String: AppError] = [
        "notAuthenticated": .notAuthenticated, "invalidCredentials": .invalidCredentials,
        "emailAlreadyUsed": .emailAlreadyUsed, "weakPassword": .weakPassword, "invalidEmail": .invalidEmail,
        "otpInvalid": .otpInvalid, "emailRateLimited": .emailRateLimited, "emailNotConfirmed": .emailNotConfirmed,
        "invalidInput": .invalidInput, "lastAdmin": .lastAdmin, "forbidden": .forbidden, "notFound": .notFound,
        // v2 (docs/CONTRACTS-V2.md §3)
        "invalidAppearance": .invalidAppearance, "invalidRecurrence": .invalidRecurrence,
        "recurrenceNeedsDueDate": .recurrenceNeedsDueDate, "invalidRotation": .invalidRotation,
        "invalidChecklistItem": .invalidChecklistItem, "tooManyChecklistItems": .tooManyChecklistItems,
        // Conditions without a case of their own: `.unknown` with a French detail.
        "emailDeliveryUnavailable": .unknown(SupabaseErrorMapping.emailDeliveryUnavailable),
        "signupDisabled": .unknown(SupabaseErrorMapping.signupDisabled),
        "reauthenticationNeeded": .unknown(SupabaseErrorMapping.reauthenticationNeeded),
    ]
}

/// A UUID literal (tests only).
func uuid(_ string: String) -> UUID {
    guard let value = UUID(uuidString: string) else { preconditionFailure("invalid UUID literal \(string)") }
    return value
}

/// Ids of `supabase/seed.sql` (docs/CONTRACTS.md §8), as found in the captured fixtures.
enum Seed {
    static let camille = uuid("11111111-1111-4111-8111-111111111111")
    static let lucas = uuid("22222222-2222-4222-8222-222222222222")
    static let ines = uuid("33333333-3333-4333-8333-333333333333")
    static let lilas = uuid("a0000000-0000-4000-8000-000000000001")
    static let sport = uuid("a0000000-0000-4000-8000-000000000002")
    static let poubelles = uuid("b0000000-0000-4000-8000-000000000001")
    static let courses = uuid("b0000000-0000-4000-8000-000000000002")
    static let cuisine = uuid("b0000000-0000-4000-8000-000000000005")
    static let gymnase = uuid("b0000000-0000-4000-8000-000000000006")
}
