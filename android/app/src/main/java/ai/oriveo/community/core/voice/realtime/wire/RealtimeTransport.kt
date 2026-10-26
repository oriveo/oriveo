package ai.oriveo.community.core.voice.realtime.wire

import ai.oriveo.community.core.data.repository.RealtimeTransportInput
import ai.oriveo.community.core.voice.realtime.RealtimeSessionEvent
import ai.oriveo.community.core.voice.realtime.RealtimeTransportKind
import kotlinx.coroutines.flow.Flow

/**
 * Realtime wire entry point: implemented by the provider-specific transports.
 * The transport receives nothing but [RealtimeTransportInput] and reports unified events.
 */
internal interface RealtimeTransport {
    val kind: RealtimeTransportKind

    fun openRealtimeSession(transport: RealtimeTransportInput): Flow<RealtimeSessionEvent>
}
