import Foundation

/// `timestamptz` values as PostgREST exchanges them (docs/CONTRACTS.md §4.3).
///
/// - Parsing accepts ISO-8601 with an offset (`Z`, `±HH`, `±HHMM`, `±HH:MM`, optional seconds) and **0 to 6**
///   fractional digits (more are rounded to the microsecond), with a `T` or a space between date and time.
/// - Formatting always writes UTC with exactly 6 fractional digits (`2026-09-24T08:00:00.123456Z`): the server
///   keeps microseconds, so a timestamp read from the server and sent back as a filter value (e.g.
///   `assignments(since:)`) designates exactly the same instant.
///
/// Pure integer arithmetic (no `Calendar`, no `DateFormatter`): identical on Linux and Apple platforms, and the
/// microsecond value survives a parse/format round trip.
enum PostgresTimestamp {
    private static let microsPerSecond: Int64 = 1_000_000
    /// Seconds between 1970-01-01 and 2001-01-01 (Foundation's reference date).
    private static let referenceOffsetSeconds: Int64 = 978_307_200

    // MARK: - Formatting

    /// UTC, 6 fractional digits, `Z` suffix.
    static func format(_ date: Date) -> String {
        let micros = epochMicroseconds(date)
        let seconds = floorDiv(micros, microsPerSecond)
        let fraction = micros - seconds * microsPerSecond
        let days = floorDiv(seconds, 86_400)
        let secondOfDay = seconds - days * 86_400
        let (year, month, day) = civil(fromDays: days)
        let hour = secondOfDay / 3_600
        let minute = (secondOfDay % 3_600) / 60
        let second = secondOfDay % 60
        return pad(year, 4) + "-" + pad(month, 2) + "-" + pad(day, 2) + "T" + pad(hour, 2) + ":" + pad(minute, 2)
            + ":" + pad(second, 2) + "." + pad(fraction, 6) + "Z"
    }

    /// The instant in whole microseconds since 1970 (rounded to the nearest microsecond).
    static func epochMicroseconds(_ date: Date) -> Int64 {
        // `timeIntervalSinceReferenceDate` is Foundation's storage: reading it involves no rounding.
        let sinceReference = (date.timeIntervalSinceReferenceDate * 1_000_000).rounded()
        return Int64(sinceReference) + referenceOffsetSeconds * microsPerSecond
    }

    /// The date for a number of microseconds since 1970 (one rounding only, so formatting gives the value back).
    static func date(epochMicroseconds micros: Int64) -> Date {
        Date(timeIntervalSinceReferenceDate: Double(micros - referenceOffsetSeconds * microsPerSecond) / 1_000_000)
    }

    // MARK: - Parsing

    static func parse(_ text: String) -> Date? {
        var scanner = Scanner(Array(text.utf8))
        guard let year = scanner.number(digits: 4), scanner.skip(UInt8(ascii: "-")),
              let month = scanner.number(digits: 2), scanner.skip(UInt8(ascii: "-")),
              let day = scanner.number(digits: 2),
              scanner.skip(UInt8(ascii: "T")) || scanner.skip(UInt8(ascii: "t")) || scanner.skip(UInt8(ascii: " ")),
              let hour = scanner.number(digits: 2), scanner.skip(UInt8(ascii: ":")),
              let minute = scanner.number(digits: 2), scanner.skip(UInt8(ascii: ":")),
              let second = scanner.number(digits: 2)
        else { return nil }
        guard (1...12).contains(month), (1...daysIn(month: month, year: year)).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second)
        else { return nil }

        var micros: Int64 = 0
        if scanner.skip(UInt8(ascii: ".")) {
            guard let fraction = scanner.fraction() else { return nil }
            micros = fraction
        }

        let offset: Int64
        if scanner.skip(UInt8(ascii: "Z")) || scanner.skip(UInt8(ascii: "z")) {
            offset = 0
        } else if let sign = scanner.sign() {
            guard let offsetHours = scanner.number(digits: 2), offsetHours <= 23 else { return nil }
            var offsetSeconds = offsetHours * 3_600
            _ = scanner.skip(UInt8(ascii: ":"))
            if let offsetMinutes = scanner.number(digits: 2) {
                guard offsetMinutes <= 59 else { return nil }
                offsetSeconds += offsetMinutes * 60
                _ = scanner.skip(UInt8(ascii: ":"))
                if let offsetSecondsPart = scanner.number(digits: 2) {
                    guard offsetSecondsPart <= 59 else { return nil }
                    offsetSeconds += offsetSecondsPart
                }
            }
            offset = sign * offsetSeconds
        } else {
            return nil
        }
        guard scanner.isAtEnd else { return nil }

        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second - offset
        return date(epochMicroseconds: seconds * microsPerSecond + micros)
    }

    // MARK: - Calendar arithmetic (proleptic Gregorian, H. Hinnant's algorithms)

    private static func daysFromCivil(year: Int64, month: Int64, day: Int64) -> Int64 {
        let y = month <= 2 ? year - 1 : year
        let era = floorDiv(y, 400)
        let yearOfEra = y - era * 400
        let monthIndex = month > 2 ? month - 3 : month + 9
        let dayOfYear = (153 * monthIndex + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func civil(fromDays days: Int64) -> (year: Int64, month: Int64, day: Int64) {
        let z = days + 719_468
        let era = floorDiv(z, 146_097)
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return (year, month, day)
    }

    private static func daysIn(month: Int64, year: Int64) -> Int64 {
        switch month {
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }

    private static func floorDiv(_ value: Int64, _ divisor: Int64) -> Int64 {
        let quotient = value / divisor
        return (value % divisor != 0 && (value < 0) != (divisor < 0)) ? quotient - 1 : quotient
    }

    private static func pad(_ value: Int64, _ width: Int) -> String {
        let digits = String(value)
        return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
    }

    /// Minimal ASCII scanner.
    private struct Scanner {
        let bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8]) {
            self.bytes = bytes
        }

        var isAtEnd: Bool { index == bytes.count }

        mutating func skip(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        /// Exactly `digits` ASCII digits.
        mutating func number(digits: Int) -> Int64? {
            guard index + digits <= bytes.count else { return nil }
            var value: Int64 = 0
            for offset in 0..<digits {
                let byte = bytes[index + offset]
                guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
                value = value * 10 + Int64(byte - UInt8(ascii: "0"))
            }
            index += digits
            return value
        }

        /// One or more digits after the decimal point, as microseconds (rounded half up beyond 6 digits).
        mutating func fraction() -> Int64? {
            var micros: Int64 = 0
            var count = 0
            var roundUp = false
            while index < bytes.count, bytes[index] >= UInt8(ascii: "0"), bytes[index] <= UInt8(ascii: "9") {
                let digit = Int64(bytes[index] - UInt8(ascii: "0"))
                if count < 6 {
                    micros = micros * 10 + digit
                } else if count == 6 {
                    roundUp = digit >= 5
                }
                count += 1
                index += 1
            }
            guard count > 0 else { return nil }
            for _ in count..<max(count, 6) {
                micros *= 10
            }
            return roundUp ? micros + 1 : micros
        }

        mutating func sign() -> Int64? {
            if skip(UInt8(ascii: "+")) { return 1 }
            if skip(UInt8(ascii: "-")) { return -1 }
            return nil
        }
    }
}
