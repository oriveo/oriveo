package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.model.StreamEvent
import kotlinx.coroutines.flow.Flow

internal class RelayAnthropicMessagesTransport(
    private val delegate: Delegate,
) {
    interface Delegate {
        suspend fun sendAnthropicMessages(request: RelayTransportRequest): StreamEvent.Done
        fun streamAnthropicMessages(request: RelayTransportRequest): Flow<StreamEvent>
    }

    suspend fun send(request: RelayTransportRequest): StreamEvent.Done =
        delegate.sendAnthropicMessages(request)

    fun stream(request: RelayTransportRequest): Flow<StreamEvent> =
        delegate.streamAnthropicMessages(request)
}
