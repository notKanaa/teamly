import Foundation
import TeamTasksCore

/// A failed contract expectation, with its source location.
public struct ContractFailure: Error, CustomStringConvertible, Sendable {
    public let message: String
    public let location: String

    public init(_ message: String, file: StaticString = #fileID, line: UInt = #line) {
        self.message = message
        location = "\(file):\(line)"
    }

    public var description: String { "\(message) (\(location))" }
}

extension ContractFailure: LocalizedError {
    public var errorDescription: String? { description }
}

/// Tiny assertion helpers that throw descriptive `ContractFailure`s (no dependency on a test framework).
public enum Verify {
    public static func that(
        _ condition: Bool,
        _ message: @autoclosure () -> String,
        file: StaticString = #fileID,
        line: UInt = #line
    ) throws {
        guard condition else { throw ContractFailure(message(), file: file, line: line) }
    }

    public static func equal<Value: Equatable>(
        _ actual: Value,
        _ expected: Value,
        _ message: @autoclosure () -> String,
        file: StaticString = #fileID,
        line: UInt = #line
    ) throws {
        guard actual == expected else {
            throw ContractFailure("\(message()): expected \(expected), got \(actual)", file: file, line: line)
        }
    }

    public static func unwrap<Value>(
        _ value: Value?,
        _ message: @autoclosure () -> String,
        file: StaticString = #fileID,
        line: UInt = #line
    ) throws -> Value {
        guard let value else { throw ContractFailure("\(message()): unexpected nil", file: file, line: line) }
        return value
    }

    /// Expects `body` to throw exactly `expected`.
    public static func fails<Value>(
        with expected: AppError,
        _ message: @autoclosure () -> String,
        file: StaticString = #fileID,
        line: UInt = #line,
        _ body: () async throws -> Value
    ) async throws {
        try await fails(withAnyOf: [expected], message(), file: file, line: line, body)
    }

    /// Expects `body` to throw one of `expected`.
    public static func fails<Value>(
        withAnyOf expected: Set<AppError>,
        _ message: @autoclosure () -> String,
        file: StaticString = #fileID,
        line: UInt = #line,
        _ body: () async throws -> Value
    ) async throws {
        let wanted = expected.map { "\($0)" }.sorted().joined(separator: " | ")
        do {
            let value = try await body()
            throw ContractFailure("\(message()): expected error \(wanted), got success \(value)", file: file, line: line)
        } catch let error as ContractFailure {
            throw error
        } catch let error as AppError {
            guard expected.contains(error) else {
                throw ContractFailure("\(message()): expected error \(wanted), got \(error)", file: file, line: line)
            }
        } catch {
            throw ContractFailure("\(message()): expected error \(wanted), got non-AppError \(error)", file: file, line: line)
        }
    }

    /// Non-members see nothing: an empty result (RLS), never an error (lead decision).
    public static func hidden<Result: Collection>(
        _ message: @autoclosure () -> String,
        file: StaticString = #fileID,
        line: UInt = #line,
        _ body: () async throws -> Result
    ) async throws {
        let result: Result
        do {
            result = try await body()
        } catch let error as ContractFailure {
            throw error
        } catch {
            throw ContractFailure("\(message()): expected an empty result, got error \(error)", file: file, line: line)
        }
        guard result.isEmpty else {
            throw ContractFailure("\(message()): expected nothing visible, got \(result)", file: file, line: line)
        }
    }

    /// Runs a setup/action step and labels any unexpected error with `label`.
    @discardableResult
    public static func step<Value>(
        _ label: @autoclosure () -> String,
        file: StaticString = #fileID,
        line: UInt = #line,
        _ body: () async throws -> Value
    ) async throws -> Value {
        do {
            return try await body()
        } catch let error as ContractFailure {
            throw error
        } catch {
            throw ContractFailure("\(label()) failed: \(error)", file: file, line: line)
        }
    }
}
