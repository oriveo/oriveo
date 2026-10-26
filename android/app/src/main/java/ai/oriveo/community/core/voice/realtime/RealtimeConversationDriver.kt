package ai.oriveo.community.core.voice.realtime

import ai.oriveo.community.core.data.repository.PlannedRealtimeSession
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveSessionExpiredException
import ai.oriveo.community.core.voice.realtime.wire.RealtimeSessionControl
import ai.oriveo.community.core.voice.realtime.wire.RealtimeTransport
import java.util.Base64
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow

/**
 * Glues a realtime connection to [RealtimeAudioIO].
 * Microphone frames go up after ready, assistant audio is played per item, barge-in stops playback and
 * truncates the item being played, and audio interruption closes the session. Events pass through unchanged;
 * nothing is persisted here.
 */
internal class RealtimeConversationDriver<C>(
    private val connection: C,
    private val audio: RealtimeAudioIO,
) where C : RealtimeTransport, C : RealtimeSessionControl {

    private val lock = Any()
    private var playingItem: String? = null

    // Item truncated by barge-in; its audio arriving afterwards is dropped until another item or turn end.
    private var truncatedItem: String? = null

    // Barge-in without an item id (Gemini): all assistant audio is dropped until interrupted or turn end.
    private var droppingUnkeyed = false

    fun run(plan: PlannedRealtimeSession): Flow<RealtimeSessionEvent> = flow {
        var started = false
        synchronized(lock) {
            playingItem = null
            truncatedItem = null
            droppingUnkeyed = false
        }
        val transport = plan.transportInput()
        var expired = false
        try {
            connection.openRealtimeSession(transport).collect { event ->
                when (event) {
                    RealtimeSessionEvent.Ready -> if (!started) {
                        started = true
                        audio.start(
                            onFrame = { frame -> connection.sendAudio(frame) },
                            onInterruption = {
                                connection.close()
                                audio.stop()
                            },
                            uplinkRateHz = connection.uplinkSampleRateHz,
                        )
                    }
                    is RealtimeSessionEvent.AssistantAudio -> playAssistantAudio(event)
                    is RealtimeSessionEvent.UserSpeechStarted -> interruptPlayback()
                    is RealtimeSessionEvent.AssistantTurnDone -> synchronized(lock) {
                        truncatedItem = null
                        droppingUnkeyed = false
                    }
                    RealtimeSessionEvent.Interrupted -> synchronized(lock) {
                        audio.stopPlayback()
                        droppingUnkeyed = false
                    }
                    else -> Unit
                }
                emit(event)
            }
        } catch (failure: GeminiLiveSessionExpiredException) {
            // A muted expiry may reopen on the same audio (contract C item 1); the controller stops it on end.
            expired = true
            throw failure
        } finally {
            if (!expired) audio.stop()
        }
    }

    /**
     * Barge-in from the voice bar: same path as user speech start. Without playback this does nothing;
     * otherwise playback stops, the played item is truncated when it has an id, and its late audio is dropped.
     */
    fun interruptPlayback() = synchronized(lock) {
        if (!audio.isPlaying) return@synchronized
        val itemId = playingItem
        val playedMs = audio.playedMs(itemId ?: NO_ITEM)
        audio.stopPlayback()
        if (itemId != null) {
            connection.truncate(itemId, 0, playedMs.toDouble())
            truncatedItem = itemId
        } else {
            droppingUnkeyed = true
        }
    }

    private fun playAssistantAudio(event: RealtimeSessionEvent.AssistantAudio) = synchronized(lock) {
        val itemId = event.itemId
        // Late audio after barge-in: neither played nor truncated again.
        if (droppingUnkeyed || (itemId != null && itemId == truncatedItem)) return@synchronized
        truncatedItem = null
        // A corrupt chunk is skipped; it must not end the session.
        runCatching { Base64.getDecoder().decode(event.base64) }.getOrNull()?.let { pcm ->
            audio.enqueue(pcm, itemId ?: NO_ITEM)
            playingItem = itemId
        }
    }

    private companion object {
        /** Playback key for transports without item ids (Gemini); their barge-in drops audio until interrupted. */
        const val NO_ITEM = ""
    }
}
