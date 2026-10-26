package ai.oriveo.community.core.voice.realtime.wire

import ai.oriveo.community.core.data.repository.RealtimeTransportInput
import ai.oriveo.community.core.voice.realtime.RealtimeSessionEvent
import ai.oriveo.community.core.voice.realtime.RealtimeTransportKind
import java.util.Base64
import kotlinx.coroutines.flow.Flow

/**
 * Adapts [GeminiLiveTransport] to [RealtimeSessionControl]: the uplink is declared at 16 kHz, so microphone PCM
 * arrives at Gemini's input rate and is base64-encoded as is, handed to the transport in call order.
 * Gemini Live has no truncate, so [truncate] sends nothing.
 */
internal class GeminiLiveSessionControl(private val transport: GeminiLiveTransport) : RealtimeSessionTransport {

    override val kind: RealtimeTransportKind = RealtimeTransportKind.GeminiLive

    /** Latest resumable handle; reopen with it under the same fingerprint to resume the session. */
    val lastResumeHandle: String? get() = transport.lastResumeHandle

    override val uplinkSampleRateHz: Int = GeminiLiveWire.INPUT_SAMPLE_RATE_HZ

    private val appendOrder = Any()

    override fun openRealtimeSession(transport: RealtimeTransportInput): Flow<RealtimeSessionEvent> =
        this.transport.openRealtimeSession(transport)

    override fun sendAudio(pcm: ByteArray) {
        // Whole samples only: a trailing odd byte is dropped.
        val bytes = pcm.size and 1.inv()
        if (bytes == 0) return
        val whole = if (bytes == pcm.size) pcm else pcm.copyOf(bytes)
        // Serialised so the append order follows the call order.
        synchronized(appendOrder) { transport.appendAudio(Base64.getEncoder().encodeToString(whole)) }
    }

    override fun truncate(itemId: String?, contentIndex: Int, playedMs: Double) = Unit

    override fun close() = transport.close()
}
