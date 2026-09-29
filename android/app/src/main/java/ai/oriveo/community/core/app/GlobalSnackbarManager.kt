package ai.oriveo.community.core.app

import android.content.Context
import androidx.annotation.StringRes
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow

sealed interface UiText {
    data class Dynamic(val value: String) : UiText
    data class Resource(
        @param:StringRes val resId: Int,
        val args: List<Any> = emptyList(),
    ) : UiText
}

fun UiText.resolve(context: Context): String = when (this) {
    is UiText.Dynamic -> value
    is UiText.Resource -> context.getString(resId, *args.toTypedArray())
}

/**
 * Semantic type of the global top toast, matching iOS `ToastStyle`. It decides the color and glyph
 * of the round icon on the left of the capsule (the visual mapping lives in
 * [ai.oriveo.community.ui.component.GlobalToastHost], one table shared by every platform).
 */
enum class GlobalToastStyle {
    Success,
    Error,
    Warning,
    Info,
    /** Removal actions (such as "Removed X · Undo"): neutral gray circle with a minus sign. */
    Removed,
    Neutral,
}

data class GlobalToastAction(
    val label: UiText,
    val onClick: () -> Unit,
)

data class GlobalSnackbarMessage(
    val message: UiText,
    val style: GlobalToastStyle = GlobalToastStyle.Neutral,
    val action: GlobalToastAction? = null,
    val durationMs: Long? = null,
)

/**
 * A toast that is currently showing. Toasts are told apart by instance identity (the same text posted
 * twice is two toasts). [postedAtNanos] lets a host that takes over show only the remaining time
 * instead of starting a full 3s again.
 */
class ActiveGlobalToast internal constructor(
    val message: GlobalSnackbarMessage,
    val postedAtNanos: Long,
)

class GlobalSnackbarManager(
    private val nanoClock: () -> Long = System::nanoTime,
) {
    private val _messages = MutableSharedFlow<GlobalSnackbarMessage>(extraBufferCapacity = 1)
    val messages = _messages.asSharedFlow()

    private val _active = MutableStateFlow<ActiveGlobalToast?>(null)

    /** The active toast; the host matching [topHost] renders and times it, then calls [dismiss]. */
    val active: StateFlow<ActiveGlobalToast?> = _active.asStateFlow()

    // Every ModalBottomSheet / full-screen Dialog is its own window and covers the main window's host,
    // so each window hosts one and only the last attached (the topmost window) renders, so one toast
    // is never drawn twice.
    private val hosts = mutableListOf<Any>()
    private val _topHost = MutableStateFlow<Any?>(null)
    val topHost: StateFlow<Any?> = _topHost.asStateFlow()

    fun show(message: GlobalSnackbarMessage) {
        _active.value = ActiveGlobalToast(message, nanoClock())
        _messages.tryEmit(message)
    }

    /** Clears only [toast] itself; if a newer message replaced it meanwhile, nothing changes (matching iOS dismissTask rescheduling). */
    fun dismiss(toast: ActiveGlobalToast) {
        _active.compareAndSet(toast, null)
    }

    /** Remaining display time; timing continues after a host handover. */
    fun remainingMillis(toast: ActiveGlobalToast, defaultDurationMs: Long): Long {
        val elapsedMs = (nanoClock() - toast.postedAtNanos) / 1_000_000
        return ((toast.message.durationMs ?: defaultDurationMs) - elapsedMs).coerceAtLeast(0)
    }

    /**
     * Registers a host. The main window's host ([isRoot]) always stays at the bottom of the stack: even
     * when it attaches after a sheet (recreated on a configuration change), it must not take the toast
     * away from the sheet window.
     */
    fun attachHost(token: Any, isRoot: Boolean) {
        synchronized(hosts) {
            hosts.remove(token)
            if (isRoot) hosts.add(0, token) else hosts.add(token)
            _topHost.value = hosts.lastOrNull()
        }
    }

    fun detachHost(token: Any) {
        synchronized(hosts) {
            hosts.remove(token)
            _topHost.value = hosts.lastOrNull()
        }
    }
}
