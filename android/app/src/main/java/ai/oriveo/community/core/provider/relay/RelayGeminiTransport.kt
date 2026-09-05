package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.model.StreamEvent
import kotlinx.coroutines.flow.Flow

internal class RelayGeminiTransport(
    private val delegate: Delegate,
) {
    interface Delegate {
        suspend fun sendGemini(request: RelayTransportRequest): StreamEvent.Done
        fun streamGemini(request: RelayTransportRequest): Flow<StreamEvent>
    }

    suspend fun send(request: RelayTransportRequest): StreamEvent.Done =
        delegate.sendGemini(request)

    fun stream(request: RelayTransportRequest): Flow<StreamEvent> =
        delegate.streamGemini(request)
}
