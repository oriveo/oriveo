package ai.oriveo.community.core.voice

import androidx.annotation.StringRes
import ai.oriveo.community.R
import java.util.Locale
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

sealed interface ReadAloudState {
    data object Idle : ReadAloudState

    /** [index] is the segment being spoken (zero-based). */
    data class Speaking(val messageId: String, val index: Int, val total: Int) : ReadAloudState

    data class Failed(val messageId: String) : ReadAloudState
}

/** Why a read-aloud session ended. */
enum class ReadAloudEndReason(val rawValue: String) {
    FINISHED("finished"),
    USER_STOPPED("user_stopped"),
    NAVIGATED("navigated"),
    NEW_GENERATION("new_generation"),
    BACKGROUNDED("backgrounded"),
    INTERRUPTED("interrupted"),
    FAILED("failed"),
}

/** Speech synthesis backend; callbacks may arrive on any thread. */
interface SpeechEngine {
    fun speak(utterances: List<String>, locale: Locale, listener: Listener)

    fun stop()

    interface Listener {
        fun onStart(index: Int)
        fun onDoneAll()
        fun onError(error: SpeechError)
    }
}

enum class SpeechError {
    /** No system voice is available (TextToSpeech failed to initialize). */
    UNAVAILABLE,
    FAILED,
}

/** Platform side effects of a reading session: audio focus, headphones unplugged, process foreground/background, language detection, localized resources. */
interface ReadAloudEnvironment {
    fun uiLocale(): Locale

    /** Detected language of [text]; null when unknown. Implementations suspend on a background thread. */
    suspend fun detectLanguage(text: String): Locale?

    /** Placeholder sentence in [appLocale] (one of [APP_VOICE_LOCALES]). */
    fun placeholderText(kind: SpeakablePlaceholder, appLocale: String): String

    /** Requests audio focus and starts listening for interruptions; returns false when focus is denied. */
    fun beginSession(listener: SessionListener): Boolean

    fun endSession()

    fun showMessage(@StringRes resId: Int)

    interface SessionListener {
        fun onInterrupted()
        fun onBackgrounded()
    }
}

/**
 * App-wide read-aloud state; one reply at a time: tapping the same reply again stops it, tapping another
 * stops the current one and starts the new one. Public methods are called on the main thread.
 */
class ReadAloudController(
    private val engine: SpeechEngine,
    private val environment: ReadAloudEnvironment,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
) {
    private val _state = MutableStateFlow<ReadAloudState>(ReadAloudState.Idle)
    val state: StateFlow<ReadAloudState> = _state.asStateFlow()

    private class Session(
        val token: Long,
        val messageId: String,
        val total: Int,
    ) {
        var job: Job? = null
        var environmentActive = false
    }

    private var session: Session? = null
    private var nextToken = 0L

    private var observedConversationId: String? = null
    private var observedStreamingId: String? = null
    private var hasObservedChat = false

    fun isActive(messageId: String): Boolean = session?.messageId == messageId

    fun toggle(messageId: String, text: String) {
        val current = session
        if (current != null) {
            end(current, ReadAloudEndReason.USER_STOPPED)
            if (current.messageId == messageId) return
        }
        start(messageId, text)
    }

    fun stop(reason: ReadAloudEndReason = ReadAloudEndReason.USER_STOPPED) {
        session?.let { end(it, reason) }
    }

    /** Stops if [messageId] is being read (called by the paths that really delete messages). */
    fun stopIfSpeaking(messageId: String, reason: ReadAloudEndReason = ReadAloudEndReason.NAVIGATED) {
        session?.takeIf { it.messageId == messageId }?.let { end(it, reason) }
    }

    /**
     * Conversation change → navigated; streamingMessageId going from null to non-null → new_generation.
     * It does not stop when the message is missing from the current list: the chat list is a paged window, and
     * expanding or trimming it can leave a message that still exists temporarily outside the list.
     */
    fun observeChat(conversationId: String?, streamingMessageId: String?) {
        val current = session
        if (current != null) {
            when {
                hasObservedChat && conversationId != observedConversationId ->
                    end(current, ReadAloudEndReason.NAVIGATED)
                hasObservedChat && observedStreamingId == null && streamingMessageId != null ->
                    end(current, ReadAloudEndReason.NEW_GENERATION)
            }
        }
        observedConversationId = conversationId
        observedStreamingId = streamingMessageId
        hasObservedChat = true
    }

    private fun start(messageId: String, text: String) {
        val segments = speakableSegments(text, final = true)
        if (segments.isEmpty()) return
        val s = Session(++nextToken, messageId, segments.size)
        session = s
        _state.value = ReadAloudState.Speaking(messageId, 0, s.total)
        s.job = scope.launch {
            val uiLocale = environment.uiLocale()
            val reading = runCatching { environment.detectLanguage(text) }.getOrNull()
            if (session !== s) return@launch
            val appLocale = placeholderLocale(reading?.toLanguageTag(), uiLocale.toLanguageTag())
            val utterances = segments.map { seg ->
                when (seg) {
                    is SpeakableSegment.Sentence -> seg.text
                    is SpeakableSegment.Placeholder -> environment.placeholderText(seg.kind, appLocale)
                }
            }
            val granted = environment.beginSession(sessionListener(s))
            s.environmentActive = true
            if (!granted) {
                end(s, ReadAloudEndReason.FAILED)
                environment.showMessage(R.string.voice_read_aloud_failed)
                return@launch
            }
            engine.speak(utterances, reading ?: uiLocale, engineListener(s))
        }
    }

    private fun sessionListener(s: Session) = object : ReadAloudEnvironment.SessionListener {
        override fun onInterrupted() = onMain(s) { end(s, ReadAloudEndReason.INTERRUPTED) }
        override fun onBackgrounded() = onMain(s) { end(s, ReadAloudEndReason.BACKGROUNDED) }
    }

    private fun engineListener(s: Session) = object : SpeechEngine.Listener {
        override fun onStart(index: Int) = onMain(s) {
            if (index !in 0 until s.total) return@onMain
            _state.value = ReadAloudState.Speaking(s.messageId, index, s.total)
        }

        override fun onDoneAll() = onMain(s) {
            end(s, ReadAloudEndReason.FINISHED)
        }

        override fun onError(error: SpeechError) = onMain(s) {
            end(s, ReadAloudEndReason.FAILED)
            environment.showMessage(
                if (error == SpeechError.UNAVAILABLE) R.string.voice_tts_unavailable else R.string.voice_read_aloud_failed,
            )
        }
    }

    /** Moves engine / platform callbacks onto the controller scope; late callbacks for an ended session are dropped. */
    private fun onMain(s: Session, block: () -> Unit) {
        scope.launch { if (session === s) block() }
    }

    private fun end(s: Session, reason: ReadAloudEndReason) {
        if (session !== s) return
        session = null
        s.job?.cancel()
        engine.stop()
        if (s.environmentActive) environment.endSession()
        _state.value = if (reason == ReadAloudEndReason.FAILED) ReadAloudState.Failed(s.messageId) else ReadAloudState.Idle
    }
}
