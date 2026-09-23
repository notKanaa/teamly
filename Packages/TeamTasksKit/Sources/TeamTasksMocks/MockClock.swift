import Foundation
import TeamTasksCore

/// Controllable clock for tests, previews and UI tests.
///
/// `autoAdvance` adds a fixed amount after every read so that successive backend operations get strictly
/// increasing timestamps (like successive Postgres transactions), while staying fully deterministic.
public final class MockClock: Sendable {
    private let state: LockedValue<Date>
    private let step: TimeInterval

    public init(_ start: Date, autoAdvance: TimeInterval = 0) {
        state = LockedValue(start)
        step = autoAdvance
    }

    /// Returns the current date, then advances by `autoAdvance`.
    public func now() -> Date {
        state.withValue { value in
            let current = value
            value = value.addingTimeInterval(step)
            return current
        }
    }

    /// The current date, without advancing.
    public func peek() -> Date {
        state.withValue { $0 }
    }

    public func advance(by seconds: TimeInterval) {
        state.withValue { $0 = $0.addingTimeInterval(seconds) }
    }

    public func set(_ date: Date) {
        state.withValue { $0 = date }
    }

    /// A `NowProvider` reading this clock.
    public var provider: NowProvider {
        { [self] in now() }
    }
}

/// Minimal lock-protected box (Synchronization.Mutex needs iOS 18).
final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
