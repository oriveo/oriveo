package ai.oriveo.community.core.voice.realtime

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Process-wide source of truth for the realtime model (connection id, model id) selected by the home pill; home, settings and provider details read and write it together.
 * In memory only, not persisted; empty on cold start. The last-used model is not recorded.
 */
class HomeRealtimeSelectionStore {
    private val state = MutableStateFlow<Pair<String, String>?>(null)

    val selection: StateFlow<Pair<String, String>?> = state.asStateFlow()

    fun set(providerId: String, modelId: String) {
        state.value = providerId to modelId
    }

    fun clear() {
        state.value = null
    }

    companion object {
        /** Process-wide singleton: all production entry points share this one. */
        val shared = HomeRealtimeSelectionStore()
    }
}
