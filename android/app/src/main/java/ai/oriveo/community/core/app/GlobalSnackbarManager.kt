package ai.oriveo.community.core.app

import android.content.Context
import androidx.annotation.StringRes
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow

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


enum class GlobalToastStyle {
    Success,
    Error,
    Warning,
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

class GlobalSnackbarManager {
    private val _messages = MutableSharedFlow<GlobalSnackbarMessage>(extraBufferCapacity = 1)
    val messages = _messages.asSharedFlow()

    fun show(message: GlobalSnackbarMessage) {
        _messages.tryEmit(message)
    }
}
