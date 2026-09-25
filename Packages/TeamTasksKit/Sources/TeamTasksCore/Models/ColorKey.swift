import Foundation

/// A color of the « Équipe » palette, for groups and avatars (docs/CONTRACTS-V2.md §1).
///
/// Stored as its raw value (SQL `text` with a check constraint), exact case: `Coral` and `""` are refused
/// (`invalid_color`). Where a color is optional, nil means « automatic »: see `automatic(for:)`. The hex values are
/// a client design matter. Cases are declared in palette order (color pickers).
public enum ColorKey: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case indigo
    case violet
    case blue
    case teal
    case green
    case amber
    case orange
    case coral
    case pink

    public var id: String { rawValue }

    /// The automatic colors, indexed by `djb2(id) % 9`. This order keeps the hues of the v1 avatars
    /// (blue, indigo, purple, pink, orange, teal, green, red, brown).
    public static let automaticOrder: [ColorKey] = [
        .blue, .indigo, .violet, .pink, .orange, .teal, .green, .coral, .amber,
    ]

    /// The color of a group or a person whose color is automatic (NULL): `automaticOrder[djb2(id) % 9]`, where djb2
    /// is `h = 5381; for byte in utf8(uppercase uuid string): h = h &* 33 &+ byte` on a wrapping `UInt64`
    /// (`UUID.uuidString` is uppercase on every platform).
    public static func automatic(for id: UUID) -> ColorKey {
        var hash: UInt64 = 5381
        for byte in id.uuidString.uppercased().utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return automaticOrder[Int(hash % UInt64(automaticOrder.count))]
    }

    /// `color`, or the automatic color of `id` when `color` is nil.
    public static func resolved(_ color: ColorKey?, for id: UUID) -> ColorKey {
        color ?? automatic(for: id)
    }
}
