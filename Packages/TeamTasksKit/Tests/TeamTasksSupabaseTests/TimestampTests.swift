import Foundation
import Testing
@testable import TeamTasksSupabase

/// `timestamptz` parsing (0 to 6 fractional digits, any offset) and formatting (UTC, 6 digits): §4.3.
@Suite struct TimestampTests {
    struct Valid: Decodable, Sendable, CustomTestStringConvertible {
        let text: String
        let epochMicroseconds: Int64
        let formatted: String
        var testDescription: String { text }
    }

    struct Cases: Decodable {
        let valid: [Valid]
        let invalid: [String]
    }

    static let cases: Cases = {
        do {
            return try Fixture.plain(Cases.self, "timestamps")
        } catch {
            preconditionFailure("\(error)")
        }
    }()

    @Test(arguments: cases.valid)
    func parsesExactMicroseconds(_ example: Valid) throws {
        let date = try #require(PostgresTimestamp.parse(example.text))
        #expect(PostgresTimestamp.epochMicroseconds(date) == example.epochMicroseconds)
        #expect(PostgresTimestamp.format(date) == example.formatted)
    }

    @Test(arguments: cases.invalid)
    func rejectsMalformedTimestamps(_ text: String) {
        #expect(PostgresTimestamp.parse(text) == nil)
    }

    @Test func formatsWholeSecondsWithSixDigits() {
        #expect(PostgresTimestamp.format(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00.000000Z")
        // The contract scenarios' `Fixed.dueA` and `Fixed.dueB` (whose doc comment says 12:30; the value is 00:30 UTC).
        #expect(PostgresTimestamp.format(Date(timeIntervalSince1970: 1_924_992_000)) == "2031-01-01T00:00:00.000000Z")
        #expect(PostgresTimestamp.format(Date(timeIntervalSince1970: 1_930_091_400)) == "2031-03-01T00:30:00.000000Z")
    }

    @Test func wholeSecondDatesRoundTripExactly() throws {
        let date = Date(timeIntervalSince1970: 1_924_992_000)
        let parsed = try #require(PostgresTimestamp.parse("2031-01-01T00:00:00+00:00"))
        #expect(parsed == date)
    }

    @Test func roundsToTheNearestMicrosecond() {
        let date = Date(timeIntervalSince1970: 1_789_343_546.123_456_6)
        #expect(PostgresTimestamp.format(date) == "2026-09-13T23:52:26.123457Z")
    }

    /// A timestamp read from the server and sent back as a filter designates the same instant (`assignments(since:)`).
    @Test func microsecondsSurviveARoundTrip() throws {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2_000 {
            // 1970 … 2100
            let micros = Int64.random(in: 0...4_102_444_800_000_000, using: &generator)
            let text = PostgresTimestamp.format(PostgresTimestamp.date(epochMicroseconds: micros))
            let parsed = try #require(PostgresTimestamp.parse(text))
            #expect(PostgresTimestamp.epochMicroseconds(parsed) == micros, "\(text)")
            #expect(PostgresTimestamp.format(parsed) == text)
        }
    }

    @Test func decoderAcceptsEveryPrecision() throws {
        let row = try Fixture.decode(TaskDTO.self, "task_fractional_digits")
        #expect(PostgresTimestamp.format(row.createdAt) == "2026-09-24T00:24:04.300000Z")
        #expect(PostgresTimestamp.format(row.updatedAt) == "2026-09-24T00:24:04.385320Z")
        #expect(row.completedAt.map(PostgresTimestamp.format) == "2026-09-24T00:24:04.385321Z")
        #expect(row.dueAt == Date(timeIntervalSince1970: 1_930_134_600))
        #expect(row.createdBy == nil)
    }
}
