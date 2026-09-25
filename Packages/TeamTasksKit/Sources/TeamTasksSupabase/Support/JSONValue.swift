import Foundation
import TeamTasksCore

/// A JSON document to send (RPC parameters, PATCH bodies). Unlike synthesized `Encodable`, a `nil` optional is
/// written as an explicit `null`: PostgREST resolves functions by their named parameters, so `update_task` needs
/// `"p_details": null` rather than a missing key.
enum JSONValue: Sendable, Hashable, Encodable {
    case null
    case bool(Bool)
    case int(Int)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    static func uuid(_ value: UUID) -> JSONValue {
        .string(RestQuery.uuid(value))
    }

    static func optionalString(_ value: String?) -> JSONValue {
        guard let value else { return .null }
        return .string(value)
    }

    /// UTC, 6 fractional digits (`PostgresTimestamp.format`), or `null`.
    static func timestamp(_ value: Date?) -> JSONValue {
        value.map { .string(PostgresTimestamp.format($0)) } ?? .null
    }

    /// Sorted (by `uuidString`) array of lowercase UUID strings: deterministic request bodies.
    static func uuids(_ values: some Sequence<UUID>) -> JSONValue {
        .array(values.sorted { $0.uuidString < $1.uuidString }.map { JSONValue.uuid($0) })
    }

    /// `p_recurrence` (docs/CONTRACTS-V2.md §5): `{}` = no repetition; a rule is `{"freq", "interval", "tz",
    /// "weekdays"}`, the weekdays ascending or `null` (the due date's weekday). `monthDay` is never sent: the server
    /// derives it from the due date.
    static func recurrence(_ rule: RecurrenceRule?) -> JSONValue {
        guard let rule else { return .object([:]) }
        return .object([
            "freq": .string(rule.frequency.rawValue),
            "interval": .int(rule.interval),
            "tz": .string(rule.timeZoneId),
            "weekdays": rule.weekdays.map { weekdays in .array(weekdays.sorted().map(JSONValue.int)) } ?? .null,
        ])
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(values): try container.encode(values)
        case let .object(values): try container.encode(values)
        }
    }

    /// Compact JSON with sorted keys.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
