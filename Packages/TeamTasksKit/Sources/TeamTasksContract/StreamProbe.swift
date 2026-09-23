import Foundation

/// Consumes an `AsyncStream` in the background and records its elements, so a scenario can wait (with a
/// bound) for an element matching a predicate. Call `stop()` when done (also done on deinit).
public final class StreamProbe<Element: Sendable>: Sendable {
    private let buffer: Buffer
    private let consumer: Task<Void, Never>

    public init(_ stream: AsyncStream<Element>) {
        let buffer = Buffer()
        self.buffer = buffer
        consumer = Task {
            for await element in stream {
                buffer.append(element)
            }
        }
    }

    deinit {
        consumer.cancel()
    }

    /// Stops consuming (cancels the subscription).
    public func stop() {
        consumer.cancel()
    }

    /// Everything received so far.
    public var events: [Element] {
        buffer.snapshot()
    }

    /// Position to pass as `after:` to only consider elements received from now on.
    public func mark() -> Int {
        buffer.snapshot().count
    }

    /// Waits until an element at index ≥ `after` matches `predicate`; throws `ContractFailure` on timeout.
    /// The default bound suits real servers (Realtime can take a moment); in-memory backends answer at once.
    @discardableResult
    public func waitFor(
        _ description: @autoclosure () -> String,
        after start: Int = 0,
        timeout: Duration = .seconds(10),
        file: StaticString = #fileID,
        line: UInt = #line,
        where predicate: (Element) -> Bool
    ) async throws -> (index: Int, element: Element) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            let received = buffer.snapshot()
            if start < received.count,
               let index = received.indices.dropFirst(start).first(where: { predicate(received[$0]) }) {
                return (index, received[index])
            }
            if clock.now >= deadline {
                throw ContractFailure(
                    "timed out after \(timeout) waiting for \(description()); received: \(received)",
                    file: file,
                    line: line
                )
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var elements: [Element] = []

        func append(_ element: Element) {
            lock.lock()
            elements.append(element)
            lock.unlock()
        }

        func snapshot() -> [Element] {
            lock.lock()
            defer { lock.unlock() }
            return elements
        }
    }
}
