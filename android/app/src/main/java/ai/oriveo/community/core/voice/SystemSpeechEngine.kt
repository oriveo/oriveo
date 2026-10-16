package ai.oriveo.community.core.voice

import android.content.Context
import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import java.util.Locale

/**
 * System TextToSpeech: each segment is queued with QUEUE_ADD and utteranceId "<session>:<index>"; callbacks from old sessions are dropped.
 */
class SystemSpeechEngine(context: Context) : SpeechEngine {
    private val appContext = context.applicationContext
    private val lock = Any()
    private var tts: TextToSpeech? = null
    private var ready = false
    private var pendingSpeak: (() -> Unit)? = null
    private var pendingListener: SpeechEngine.Listener? = null
    private var session = 0L

    override fun speak(utterances: List<String>, locale: Locale, listener: SpeechEngine.Listener) {
        if (utterances.isEmpty()) {
            listener.onDoneAll()
            return
        }
        val action: () -> Unit
        synchronized(lock) {
            val id = ++session
            action = { enqueue(id, utterances, locale, listener) }
            if (ready) {
                pendingSpeak = null
                pendingListener = null
            } else {
                pendingSpeak = action
                pendingListener = listener
                if (tts == null) tts = createTts()
                return
            }
        }
        action()
    }

    override fun stop() {
        synchronized(lock) {
            session++
            pendingSpeak = null
            pendingListener = null
            if (ready) tts?.stop()
        }
    }

    private fun createTts(): TextToSpeech =
        TextToSpeech(appContext) { status ->
            val action: (() -> Unit)?
            synchronized(lock) {
                if (status == TextToSpeech.SUCCESS) {
                    ready = true
                    action = pendingSpeak
                    pendingSpeak = null
                    pendingListener = null
                } else {
                    // The next speak call recreates the engine and tries again
                    tts?.shutdown()
                    tts = null
                    val waiting = pendingListener
                    pendingSpeak = null
                    pendingListener = null
                    action = waiting?.let { { it.onError(SpeechError.UNAVAILABLE) } }
                }
            }
            action?.invoke()
        }

    private fun enqueue(id: Long, utterances: List<String>, locale: Locale, listener: SpeechEngine.Listener) {
        val engine = synchronized(lock) { if (id != session) null else tts } ?: return
        val result = runCatching {
            val lang = engine.setLanguage(locale)
            if (lang == TextToSpeech.LANG_MISSING_DATA || lang == TextToSpeech.LANG_NOT_SUPPORTED) {
                engine.setLanguage(engine.defaultVoice?.locale ?: Locale.getDefault())
            }
            engine.setOnUtteranceProgressListener(progressListener(id, utterances.size, listener))
            utterances.withIndex().all { (index, text) ->
                engine.speak(text, TextToSpeech.QUEUE_ADD, Bundle(), "$id:$index") == TextToSpeech.SUCCESS
            }
        }.getOrDefault(false)
        if (!result && synchronized(lock) { id == session }) listener.onError(SpeechError.FAILED)
    }

    private fun progressListener(id: Long, total: Int, listener: SpeechEngine.Listener) =
        object : UtteranceProgressListener() {
            private fun index(utteranceId: String?): Int? {
                val parts = utteranceId?.split(':') ?: return null
                if (parts.size != 2 || parts[0].toLongOrNull() != id) return null
                if (synchronized(lock) { id != session }) return null
                return parts[1].toIntOrNull()
            }

            override fun onStart(utteranceId: String?) {
                index(utteranceId)?.let(listener::onStart)
            }

            override fun onDone(utteranceId: String?) {
                if (index(utteranceId) == total - 1) listener.onDoneAll()
            }

            @Deprecated("Deprecated in Java")
            override fun onError(utteranceId: String?) {
                if (index(utteranceId) != null) listener.onError(SpeechError.FAILED)
            }

            override fun onError(utteranceId: String?, errorCode: Int) {
                if (index(utteranceId) != null) listener.onError(SpeechError.FAILED)
            }
        }
}
