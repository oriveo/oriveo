package ai.oriveo.community.core.data.remote

import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.onStart

class MetadataRefreshEventBus(
    private val debounceMillis: Long = DEBOUNCE_MS,
) {
    private val _events = MutableSharedFlow<MetadataClient.RefreshEvent>(
        replay = 1,
        extraBufferCapacity = 8,
    )

    val rawEvents = _events.asSharedFlow()

    @OptIn(FlowPreview::class)
    val events: Flow<MetadataClient.RefreshEvent> = _events
        .let { if (debounceMillis > 0) it.debounce(debounceMillis) else it }
        .onStart { emit(MetadataClient.RefreshEvent(version = 0, contractVersion = 0)) }

    fun dispatch(event: MetadataClient.RefreshEvent) {
        _events.tryEmit(event)
    }

    companion object {
        const val DEBOUNCE_MS = 100L
    }
}
