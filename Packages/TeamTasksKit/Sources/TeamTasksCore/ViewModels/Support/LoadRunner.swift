import Foundation

/// Runs a screen's fetch at most once at a time.
///
/// The fetch runs in its own task, so cancelling a caller (a SwiftUI `.task` replaced because its id changed,
/// or a view that disappeared) never cancels a fetch that other callers wait for. A caller that needs data
/// newer than the fetch in progress asks for one more run (`rerunIfRunning`), which starts right after it:
/// concurrent requests coalesce into at most one extra fetch.
@MainActor
final class LoadRunner {
    private var task: Task<Void, Never>?
    private var rerunRequested = false

    /// True while a fetch (or its rerun) is in progress.
    var isRunning: Bool { task != nil }

    /// Starts `operation`, or joins the run in progress. With `rerunIfRunning`, a run in progress is followed by
    /// one more run of the operation it was started with. Returns when the whole run is over.
    func run(rerunIfRunning: Bool, _ operation: @escaping @MainActor @Sendable () async -> Void) async {
        if let task {
            if rerunIfRunning { rerunRequested = true }
            await task.value
            return
        }
        let newTask = Task { @MainActor [weak self] in
            repeat {
                self?.rerunRequested = false
                await operation()
            } while self?.rerunRequested == true
            self?.task = nil
        }
        task = newTask
        await newTask.value
    }

    /// Waits for the run in progress, if any.
    func wait() async {
        await task?.value
    }
}

/// Runs one-shot background work of a view model (e.g. a reminder resynchronization triggered by a setter)
/// and lets tests wait for it.
@MainActor
final class BackgroundWork {
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func start(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        let id = UUID()
        tasks[id] = Task { @MainActor [weak self] in
            await operation()
            self?.tasks[id] = nil
        }
    }

    /// Waits until every started operation is over.
    func waitForAll() async {
        while let task = tasks.values.first {
            await task.value
        }
    }

    func cancelAll() {
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
    }
}
