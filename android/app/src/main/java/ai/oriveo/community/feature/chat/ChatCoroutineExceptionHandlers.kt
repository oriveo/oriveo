package ai.oriveo.community.feature.chat

import android.util.Log
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope

/**
 * Historically malformed rows (e.g. SQLiteBlobTooBigException) are already caught and
 * downgraded inside [ai.oriveo.community.core.data.repository.chat.MessageWindowLoader];
 * this adds a second safety net on the [ChatViewModel] side to catch anything that still
 * slips through, so a window-load or history-paging failure never crashes the whole app
 * (same pattern as ChatStreamingManager.streamingExceptionHandler).
 */
fun messageWindowLoaderScope(base: CoroutineScope): CoroutineScope {
    val handler = CoroutineExceptionHandler { _, e ->
        Log.e("ChatViewModel", "message window coroutine crashed: ${e.localizedMessage}", e)
    }
    return CoroutineScope(base.coroutineContext + handler)
}
