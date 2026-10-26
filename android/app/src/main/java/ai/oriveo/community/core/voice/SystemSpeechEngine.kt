package ai.oriveo.community.core.voice

import android.content.Context
import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import java.util.Locale

/**
 * System TextToSpeech: each segment is queued with QUEUE_ADD and utteranceId "<session>:<index>"; callbacks from old sessions are dropped.
 * The speech rate is the slider value at enqueue time.
 */
class SystemSpeechEngine(
    context: Context,
    /** Read-aloud rate slider value (1.0 is normal speed), read on every enqueue. */
    private val speechRate: () -> Double = { VoiceEngineSettings.DEFAULT_SPEECH_RATE },
    /** Test injection point: production constructs the system TextToSpeech directly. */
    private val ttsFactory: (Context, TextToSpeech.OnInitListener) -> TextToSpeech =
        { ctx, listener -> TextToSpeech(ctx, listener) },
) : SpeechEngine {
    private val appContext = context.applicationContext
    private val lock = Any()
    private var tts: TextToSpeech? = null
    private var ready = false
    /** Initialization of this createTts has failed (including a synchronous ERROR callback inside the constructor, when [tts] is not yet assigned). */
    private var initFailed = false
    private var pendingSpeak: (() -> Unit)? = null
    private var pendingListener: SpeechEngine.Listener? = null
    private var session = 0L

    override val engineName: String = "system"

    override fun speak(utterances: List<String>, locale: Locale, listener: SpeechEngine.Listener) =
        speak(utterances, locale, List(utterances.size) { locale }, listener)

    override fun speak(
        utterances: List<String>,
        locale: Locale,
        segmentLocales: List<Locale>,
        listener: SpeechEngine.Listener,
    ) {
        if (utterances.isEmpty()) {
            listener.onDoneAll()
            return
        }
        val action: () -> Unit
        synchronized(lock) {
            val id = ++session
            action = { enqueue(id, utterances, locale, segmentLocales, listener) }
            if (ready) {
                pendingSpeak = null
                pendingListener = null
            } else {
                pendingSpeak = action
                pendingListener = listener
                if (tts == null) {
                    initFailed = false
                    val created = createTts()
                    // When onInit(ERROR) fires synchronously inside the constructor the callback cannot clear the not-yet-assigned instance: discard it here and rebuild on the next speak
                    if (initFailed) created.shutdown() else tts = created
                }
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
        ttsFactory(appContext, TextToSpeech.OnInitListener { status ->
            val action: (() -> Unit)?
            synchronized(lock) {
                if (status == TextToSpeech.SUCCESS) {
                    ready = true
                    action = pendingSpeak
                    pendingSpeak = null
                    pendingListener = null
                } else {
                    // Recreate the engine and retry on the next speak
                    initFailed = true
                    tts?.shutdown()
                    tts = null
                    val waiting = pendingListener
                    pendingSpeak = null
                    pendingListener = null
                    action = waiting?.let { { it.onError(SpeechError.UNAVAILABLE) } }
                }
            }
            action?.invoke()
        })

    private fun enqueue(
        id: Long,
        utterances: List<String>,
        locale: Locale,
        segmentLocales: List<Locale>,
        listener: SpeechEngine.Listener,
    ) {
        val engine = synchronized(lock) { if (id != session) null else tts } ?: return
        val result = runCatching {
            engine.setSpeechRate(speechRate().toFloat())
            engine.setOnUtteranceProgressListener(progressListener(id, utterances.size, listener))
            var current: Locale? = null
            utterances.withIndex().all { (index, text) ->
                // Switch to this segment's language before enqueueing (a placeholder may be in a different language than the sentences); skip if same as the previous segment
                val segmentLocale = segmentLocales.getOrNull(index) ?: locale
                if (segmentLocale != current) {
                    current = segmentLocale
                    val lang = engine.setLanguage(segmentLocale)
                    if (lang == TextToSpeech.LANG_MISSING_DATA || lang == TextToSpeech.LANG_NOT_SUPPORTED) {
                        engine.setLanguage(engine.defaultVoice?.locale ?: Locale.getDefault())
                    }
                }
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
