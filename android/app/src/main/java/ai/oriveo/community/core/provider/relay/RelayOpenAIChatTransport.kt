package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.model.StreamEvent
import kotlinx.coroutines.flow.Flow

internal class RelayOpenAIChatTransport(
    private val delegate: Delegate,
) {
    interface Delegate {
        suspend fun sendOpenAIChat(request: RelayTransportRequest): StreamEvent.Done
        fun streamOpenAIChat(request: RelayTransportRequest): Flow<StreamEvent>
    }

    suspend fun send(request: RelayTransportRequest): StreamEvent.Done =
        delegate.sendOpenAIChat(request)

    fun stream(request: RelayTransportRequest): Flow<StreamEvent> =
        delegate.streamOpenAIChat(request)
}
