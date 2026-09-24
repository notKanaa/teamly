package io.github.notkanaa.equipe.core.viewmodel

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlin.coroutines.cancellation.CancellationException

// Port of TeamTasksCore/ViewModels/Support/LoadRunner.swift (LoadRunner, BackgroundWork).

/**
 * Runs a screen's fetch at most once at a time.
 *
 * The fetch runs in its own job, launched in [scope], so cancelling a caller (a `LaunchedEffect` restarted because its
 * key changed, a `collectLatest` block replaced by a newer key, or a screen that left the composition) never cancels a
 * fetch that other callers wait for. A caller that needs data newer than the fetch in progress asks for one more run
 * (`rerunIfRunning`), which starts right after it: concurrent requests coalesce into at most one extra fetch.
 *
 * A [CancellationException] thrown by the operation while its job is still active (a callee's own cancellation, Swift's
 * ignored `CancellationError`) ends that run like a normal return; a real cancellation of the job ends the job.
 * Main-thread confined.
 */
internal class LoadRunner(private val scope: CoroutineScope) {
    private var job: Job? = null
    private var rerunRequested = false

    /** True while a fetch (or its rerun) is in progress. */
    val isRunning: Boolean get() = job != null

    /**
     * Starts [operation], or joins the run in progress. With [rerunIfRunning], a run in progress is followed by one
     * more run of the operation it was started with. Returns when the whole run is over (throws
     * [CancellationException] right away when the caller is cancelled; the run goes on).
     */
    suspend fun run(rerunIfRunning: Boolean, operation: suspend () -> Unit) {
        val running = job
        if (running != null) {
            if (rerunIfRunning) rerunRequested = true
            running.join()
            return
        }
        val newJob = scope.launch(start = CoroutineStart.LAZY) {
            val self = currentCoroutineContext()[Job]
            try {
                do {
                    rerunRequested = false
                    try {
                        operation()
                    } catch (error: CancellationException) {
                        currentCoroutineContext().ensureActive()
                    }
                } while (rerunRequested)
            } finally {
                if (job === self) job = null
            }
        }
        job = newJob
        newJob.start()
        try {
            newJob.join()
        } finally {
            // A job cancelled before it started (cancelled scope) never ran its own `finally`.
            if (job === newJob && newJob.isCompleted) job = null
        }
    }

    /** Waits for the run in progress, if any. */
    suspend fun wait() {
        job?.join()
    }
}

/**
 * Runs one-shot background work of a view model in [scope] (e.g. a reminder resynchronization triggered by a setter)
 * and lets tests wait for it. Main-thread confined.
 */
internal class BackgroundWork(private val scope: CoroutineScope) {
    private val jobs = ArrayList<Job>()

    fun start(operation: suspend () -> Unit) {
        val job = scope.launch(start = CoroutineStart.LAZY) { operation() }
        jobs.add(job)
        job.invokeOnCompletion { jobs.remove(job) }
        job.start()
    }

    /** Waits until every started operation is over. */
    suspend fun waitForAll() {
        while (true) {
            val job = jobs.firstOrNull() ?: return
            job.join()
            jobs.remove(job)
        }
    }

    fun cancelAll() {
        val all = jobs.toList()
        jobs.clear()
        for (job in all) job.cancel()
    }
}
