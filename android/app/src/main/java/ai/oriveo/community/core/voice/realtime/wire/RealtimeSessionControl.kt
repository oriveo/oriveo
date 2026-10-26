package ai.oriveo.community.core.voice.realtime.wire

import ai.oriveo.community.core.voice.realtime.RealtimePCM
import ai.oriveo.community.core.voice.realtime.RealtimeTransportKind

/** Controls the live session opened by a realtime transport. */
internal interface RealtimeSessionControl {
    /** Sample rate [sendAudio] expects; the capture produces frames at this rate (OpenAI / xAI: 24 kHz). */
    val uplinkSampleRateHz: Int get() = RealtimePCM.OUTPUT_RATE

    /** Microphone PCM16 LE mono @ [uplinkSampleRateHz]; dropped until the session is ready. */
    fun sendAudio(pcm: ByteArray)

    /** Barge-in truncate of the assistant item being played; nothing is sent without an item id. */
    fun truncate(itemId: String?, contentIndex: Int, playedMs: Double)

    /** Ends the session: the event flow completes without error. */
    fun close()
}

/** Connection parameters of one realtime endpoint. */
internal data class RealtimeEndpoint(
    val host: String,
    val apiKey: String,
    val model: String,
    val path: String,
    val voice: String,
    val inputTranscriptionModel: String? = null,
) {
    override fun toString(): String =
        "RealtimeEndpoint(host=$host, model=$model, path=$path, voice=$voice, " +
            "inputTranscriptionModel=$inputTranscriptionModel)"
}

/** A realtime transport whose live session the host drives through [RealtimeSessionControl]. */
internal interface RealtimeSessionTransport : RealtimeTransport, RealtimeSessionControl

internal object RealtimeTransportFactory {
    /**
     * GA transport for OpenAI / xAI; [GeminiLiveSessionControl] for Gemini Live.
     * [resumeHandle] (Gemini only) resumes a session opened earlier under the same fingerprint.
     */
    fun make(
        kind: RealtimeTransportKind,
        endpoint: RealtimeEndpoint,
        resumeHandle: String? = null,
        socketFactory: RealtimeSocketFactory = OkHttpRealtimeSocketFactory(),
        geminiSocketFactory: GeminiLiveSocketFactory = OkHttpGeminiLiveSocketFactory,
    ): RealtimeSessionTransport = when (kind) {
        RealtimeTransportKind.OpenAiRealtime, RealtimeTransportKind.XaiRealtime ->
            GARealtimeTransport(kind, endpoint, socketFactory)
        RealtimeTransportKind.GeminiLive -> GeminiLiveSessionControl(
            GeminiLiveTransport(
                GeminiLiveConfig(
                    host = endpoint.host,
                    path = endpoint.path,
                    model = endpoint.model,
                    voice = endpoint.voice,
                    apiKey = endpoint.apiKey,
                ),
                resumeHandle = resumeHandle,
                socketFactory = geminiSocketFactory,
            ),
        )
    }
}
