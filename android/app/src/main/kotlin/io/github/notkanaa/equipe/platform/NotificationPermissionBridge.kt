package io.github.notkanaa.equipe.platform

import androidx.activity.result.ActivityResultLauncher
import androidx.annotation.MainThread
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Lets the notification scheduler (process-wide) show the runtime permission dialog of the activity on screen:
 * MainActivity registers its `RequestPermission` launcher in onCreate ([attach]), forwards the result ([onResult]) and
 * detaches in onDestroy. One request at a time: concurrent callers wait for the same answer.
 */
object NotificationPermissionBridge {
    private var launcher: ActivityResultLauncher<String>? = null
    private var pending: CompletableDeferred<Boolean>? = null

    @MainThread
    fun attach(launcher: ActivityResultLauncher<String>) {
        this.launcher = launcher
    }

    @MainThread
    fun detach(launcher: ActivityResultLauncher<String>) {
        if (this.launcher === launcher) this.launcher = null
    }

    /** The user answered the dialog. */
    @MainThread
    fun onResult(granted: Boolean) {
        val request = pending
        pending = null
        request?.complete(granted)
    }

    /**
     * Shows the system dialog for [permission] and returns the answer, or null when it could not be shown (no activity
     * on screen).
     */
    suspend fun request(permission: String): Boolean? = withContext(Dispatchers.Main.immediate) {
        pending?.let { return@withContext it.await() }
        val current = launcher ?: return@withContext null
        val request = CompletableDeferred<Boolean>()
        pending = request
        try {
            current.launch(permission)
        } catch (error: RuntimeException) { // IllegalStateException (not registered), ActivityNotFoundException
            pending = null
            return@withContext null
        }
        request.await()
    }
}
