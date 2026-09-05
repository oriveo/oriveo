package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.model.StreamEvent
import kotlinx.coroutines.flow.Flow

internal class RelayOpenAIResponsesTransport(
    private val delegate: Delegate,
) {
    interface Delegate {
        suspend fun sendOpenAIResponses(request: RelayTransportRequest): StreamEvent.Done
        fun streamOpenAIResponses(request: RelayTransportRequest): Flow<StreamEvent>
    }

    suspend fun send(request: RelayTransportRequest): StreamEvent.Done =
        delegate.sendOpenAIResponses(request)

    fun stream(request: RelayTransportRequest): Flow<StreamEvent> =
        delegate.streamOpenAIResponses(request)
}
