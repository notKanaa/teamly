package io.github.notkanaa.equipe

import android.app.Application
import io.github.notkanaa.equipe.config.AppContainer
import io.github.notkanaa.equipe.platform.SignificantTimeChanges
import io.github.notkanaa.equipe.platform.TaskNotifications

/** Application class: owns the process-wide [AppContainer] and the process-level platform hooks. */
class EquipeApplication : Application() {
    /** Root model of the process, shared by the activity, notification taps and background refresh (main thread). */
    val container: AppContainer by lazy { AppContainer(this) }

    override fun onCreate() {
        super.onCreate()
        TaskNotifications.createChannel(this)
        SignificantTimeChanges.register(this) { container.onSignificantTimeChange() }
    }
}
