package ai.oriveo.community.core.streaming

import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch


class StreamingLifecycleObserver(
    private val chatStreamingManager: ChatStreamingManager,
) : DefaultLifecycleObserver {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onStop(owner: LifecycleOwner) {
        
        scope.launch {
            chatStreamingManager.flushAllPartialsToMessage()
        }
    }
}
