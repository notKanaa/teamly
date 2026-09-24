package io.github.notkanaa.equipe.core.viewmodel

import io.github.notkanaa.equipe.core.AppError
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import java.util.UUID
import kotlin.coroutines.cancellation.CancellationException

// Port of TeamTasksCore/ViewModels/Support/ErrorState.swift (ErrorState, ErrorPresenting, LoadState, RefreshKey), plus
// the base class shared by the Kotlin view models: one immutable state per screen, exposed as a StateFlow.
//
// Threading: like the Swift view models (@MainActor), the view models, AppModel, SessionModel and Router are meant to be
// used from the main thread. The Android layer calls them from Compose callbacks, LaunchedEffect, rememberCoroutineScope
// or viewModelScope (Dispatchers.Main.immediate) and gives them scopes running on the main dispatcher. State updates are
// atomic (MutableStateFlow), but the bookkeeping of the loaders is not synchronized.

/**
 * A French message shown by a screen (alert, banner or inline text).
 *
 * Built from [AppError.messageFR], or from a client-side validation message. Every instance is distinct (identity
 * equality, unique [id]), so presenting the same error twice shows it twice.
 */
class ErrorState(
    /** Message shown to the user (French). */
    val message: String,
    /** The underlying error; null for purely client-side messages. */
    val error: AppError? = null,
) {
    constructor(error: AppError) : this(error.messageFR, error)

    /** Unique per instance (Swift `Identifiable`). */
    val id: UUID = UUID.randomUUID()

    override fun toString(): String = "ErrorState(message=$message, error=$error)"

    companion object {
        private val wrappedCancellation: AppError = AppError.wrap(CancellationException())

        /**
         * null when [error] is a cancellation: a cancelled coroutine must never surface « annulé » (docs/CONTRACTS.md
         * §9). Any other error is wrapped with [AppError.wrap].
         */
        fun from(error: Throwable): ErrorState? = if (isCancellation(error)) null else ErrorState(AppError.wrap(error))

        /** True for a [CancellationException] and for `AppError.wrap(CancellationException())` (`Unknown("annulé")`). */
        fun isCancellation(error: Throwable): Boolean = error is CancellationException || error == wrappedCancellation
    }
}

/**
 * A view model that reports errors through [error] (shown as an alert or a banner by the screen), e.g.
 * `if (state.error != null) AlertDialog(onDismissRequest = model::dismissError, text = { Text(state.errorMessage!!) })`.
 */
interface ErrorPresenting {
    /** The error to show, null when none (also `state.value.error`). */
    val error: ErrorState?

    /** French message of [error]. */
    val errorMessage: String? get() = error?.message

    /** Binding-friendly flag: setting it to false clears [error]. */
    var isShowingError: Boolean
        get() = error != null
        set(value) {
            if (!value) dismissError()
        }

    fun dismissError()
}

/** A screen state that carries the error to show. */
interface ErrorHolder {
    /** The error to show, null when none. */
    val error: ErrorState?

    /** French message of [error]. */
    val errorMessage: String? get() = error?.message
}

/**
 * Loading state of a screen's content.
 *
 * - [Idle]: never loaded (or the first load was cancelled);
 * - [Loading]: first load in progress, nothing to show yet (later reloads keep [Loaded]);
 * - [Loaded]: content available (possibly empty);
 * - [Failed]: the first load failed; the screen shows [Failed.message] and a « Réessayer » button calling `reload()`.
 *   A reload failing after a successful load keeps [Loaded] and sets the error instead.
 */
sealed interface LoadState {
    data object Idle : LoadState

    data object Loading : LoadState

    data object Loaded : LoadState

    data class Failed(val message: String) : LoadState

    val isLoading: Boolean get() = this == Loading

    val isLoaded: Boolean get() = this == Loaded

    /** Message of [Failed], null otherwise. */
    val failureMessage: String? get() = (this as? Failed)?.message
}

/**
 * Identity of what a list screen shows: screens reload when it changes (`model.autoRefresh()`, or
 * `model.refreshKeys.collectLatest { model.load() }`, the Swift `.task(id: model.refreshKey) { await model.load() }`).
 *
 * [revision] comes from the session's `ChangeFeed` (it changes when the server signals a change, after the user's own
 * mutations, on realtime reconnection and on return to foreground); [includeDone] is the screen's "show done tasks"
 * toggle, so flipping it reloads too.
 */
data class RefreshKey(
    val revision: Int,
    val includeDone: Boolean = false,
)

/**
 * Base of the screen view models: one immutable [state] (collect it in the UI, e.g. `collectAsStateWithLifecycle()`)
 * and the [ErrorPresenting] helpers. Actions are suspend functions (call them from a coroutine of the screen) or plain
 * functions/setters; background work (loads) runs in the scope given to the view model.
 */
abstract class ScreenModel<S : ErrorHolder> internal constructor(
    initialState: S,
    private val withError: (S, ErrorState?) -> S,
) : ErrorPresenting {
    internal val mutableState: MutableStateFlow<S> = MutableStateFlow(initialState)

    /** The screen's state. */
    val state: StateFlow<S> = mutableState.asStateFlow()

    /** `state.value`. */
    internal val current: S get() = mutableState.value

    final override val error: ErrorState? get() = mutableState.value.error

    final override fun dismissError() {
        mutableState.update { withError(it, null) }
    }

    internal inline fun update(transform: (S) -> S) {
        mutableState.update(transform)
    }

    /** Shows [error] unless it is a cancellation. Returns the [AppError] shown, null for a cancellation. */
    internal fun present(error: Throwable): AppError? {
        val state = ErrorState.from(error) ?: return null
        mutableState.update { withError(it, state) }
        return state.error
    }

    /** Shows a client-side message. */
    internal fun present(message: String, error: AppError? = null) {
        val state = ErrorState(message, error)
        mutableState.update { withError(it, state) }
    }
}

/** Load state and error after a failed load (Swift `handleLoadFailure`). */
internal class LoadFailure(val loadState: LoadState, val error: ErrorState?)

/**
 * A first load shows the failure with « Réessayer » ([LoadState.Failed]); a reload failing after a successful load keeps
 * [LoadState.Loaded] and sets the error. A cancellation shows nothing (a first load in progress goes back to
 * [LoadState.Idle]).
 */
internal fun loadFailure(loadState: LoadState, currentError: ErrorState?, error: Throwable): LoadFailure {
    val state = ErrorState.from(error) ?: return LoadFailure(cancelledLoad(loadState), currentError)
    return if (loadState == LoadState.Loaded) {
        LoadFailure(loadState, state)
    } else {
        LoadFailure(LoadState.Failed(state.message), currentError)
    }
}

/** Load state after a cancelled load: a first load in progress goes back to [LoadState.Idle]. */
internal fun cancelledLoad(loadState: LoadState): LoadState =
    if (loadState == LoadState.Loading) LoadState.Idle else loadState

/** [LoadState.Loading] unless already loaded (later reloads keep showing the content). */
internal fun startedLoad(loadState: LoadState): LoadState =
    if (loadState == LoadState.Loaded) loadState else LoadState.Loading
