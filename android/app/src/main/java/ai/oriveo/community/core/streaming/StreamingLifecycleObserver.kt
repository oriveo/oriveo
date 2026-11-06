package ai.oriveo.community.core.streaming

import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class StreamingLifecycleObserver(
    // Resolved on the IO scope at ON_STOP: the manager pulls the whole chat graph, which must not be built in Application.onCreate.
    private val chatStreamingManager: () -> ChatStreamingManager,
) : DefaultLifecycleObserver {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onStop(owner: LifecycleOwner) {

        scope.launch {
            chatStreamingManager().flushAllPartialsToMessage()
        }
    }
}
