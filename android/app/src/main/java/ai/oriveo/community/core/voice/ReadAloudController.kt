package ai.oriveo.community.core.voice

import androidx.annotation.StringRes
import ai.oriveo.community.BuildConfig
import ai.oriveo.community.R
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText
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

    /** [index] is the index of the segment being read (from 0). */
    data class Speaking(val messageId: String, val index: Int, val total: Int) : ReadAloudState

    data class Failed(val messageId: String) : ReadAloudState
}

enum class ReadAloudEndReason(val rawValue: String) {
    FINISHED("finished"),
    USER_STOPPED("user_stopped"),
    NAVIGATED("navigated"),
    NEW_GENERATION("new_generation"),
    BACKGROUNDED("backgrounded"),
    INTERRUPTED("interrupted"),
    FAILED("failed"),
}

/** Speech synthesis backend; callbacks may come from any thread. */
interface SpeechEngine {
    /** Engine name. */
    val engineName: String

    fun speak(utterances: List<String>, locale: Locale, listener: Listener)

    /**
     * Each segment carries its own locale ([segmentLocales] has the same length as [utterances]; a placeholder may be in a different language than the sentences).
     * [locale] is the reading language; the default implementation ignores segment locales and reads everything in [locale].
     */
    fun speak(utterances: List<String>, locale: Locale, segmentLocales: List<Locale>, listener: Listener) =
        speak(utterances, locale, listener)

    fun stop()

    interface Listener {
        fun onStart(index: Int)
        fun onDoneAll()
        fun onError(error: SpeechError)

        /** Called once when cloud read-aloud falls back to the system engine; the system engine itself never calls it. */
        fun onFallback(providerDisplayName: String) {}
    }
}

enum class SpeechError {
    /** No usable system voice (TextToSpeech initialization failed). */
    UNAVAILABLE,
    FAILED,
}

/** Platform side effects of a read-aloud session: audio focus, headphones unplugged, process foreground/background, localized resources. */
interface ReadAloudEnvironment {
    fun uiLocale(): Locale

    /** Placeholder sentence for [appLocale] (one of [APP_VOICE_LOCALES]). */
    fun placeholderText(kind: SpeakablePlaceholder, appLocale: String): String

    /** Requests audio focus and starts listening for interruptions; returns false if focus is denied. */
    fun beginSession(listener: SessionListener): Boolean

    fun endSession()

    fun showMessage(@StringRes resId: Int)

    interface SessionListener {
        fun onInterrupted()
        fun onBackgrounded()
    }
}

/**
 * Global read-aloud state, one message at a time: tapping the same message again stops it, tapping another stops first then starts. Public methods are called on the main thread.
 *
 * The reading locale is decided from the hypotheses of [languageDetector] via [CloudReadAloudRules.readingLanguage] (none or below 0.5 uses the UI locale);
 * engine fallbacks (the selected engine became invalid at the point of use, or a mid-way cloud fallback) are announced via [showToast] in Warning style; before starting, voice preview is stopped via [beforeStart].
 */
class ReadAloudController(
    private val engineSource: ReadAloudEngineSource,
    private val environment: ReadAloudEnvironment,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
    private val languageDetector: ReadingLanguageDetector = ReadingLanguageDetector.NONE,
    private val showToast: (GlobalSnackbarMessage) -> Unit = {},
    /** Called before every read-aloud starts (production: stops the voice preview). */
    private val beforeStart: () -> Unit = {},
) {
    /** Fixed single engine. */
    constructor(
        engine: SpeechEngine,
        environment: ReadAloudEnvironment,
        scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
        languageDetector: ReadingLanguageDetector = ReadingLanguageDetector.NONE,
        showToast: (GlobalSnackbarMessage) -> Unit = {},
        beforeStart: () -> Unit = {},
    ) : this(ReadAloudEngineSource.fixed(engine), environment, scope, languageDetector, showToast, beforeStart)

    private val _state = MutableStateFlow<ReadAloudState>(ReadAloudState.Idle)
    val state: StateFlow<ReadAloudState> = _state.asStateFlow()

    private class Session(
        val token: Long,
        val messageId: String,
        val total: Int,
    ) {
        var job: Job? = null
        var environmentActive = false
        /** The engine chosen for this session; picked once at start and unchanged during the session (a mid-way cloud fallback is still the same engine). */
        var choice: ReadAloudEngineChoice? = null
        /** The mid-way cloud fallback has been announced; announced only once per read-aloud. */
        var fallbackNotified = false
    }

    private var session: Session? = null
    private var nextToken = 0L

    private var observedConversationId: String? = null
    private var observedStreamingId: String? = null
    private var hasObservedChat = false

    fun isActive(messageId: String): Boolean = session?.messageId == messageId

    /**
     * DEBUG only (screenshot entry): shows [messageId] as reading segment [index] of [total].
     * Only changes the display state: no session, no engine pick, no sound; a no-op in release builds.
     */
    fun showSpeakingForShots(messageId: String, index: Int, total: Int) {
        if (!BuildConfig.DEBUG) return
        _state.value = ReadAloudState.Speaking(messageId, index, total)
    }

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

    /** Stops when [messageId] is being read (called on the path where the message is really deleted). */
    fun stopIfSpeaking(messageId: String, reason: ReadAloudEndReason = ReadAloudEndReason.NAVIGATED) {
        session?.takeIf { it.messageId == messageId }?.let { end(it, reason) }
    }

    /**
     * Conversation switch -> navigated; streamingMessageId going from null to non-null -> new_generation.
     * Does not stop on "message not in the current list": the chat message list is a paged window, and growing / trimming the window can make a still-existing message temporarily absent.
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
        beforeStart()
        val s = Session(++nextToken, messageId, segments.size)
        session = s
        _state.value = ReadAloudState.Speaking(messageId, 0, s.total)
        s.job = scope.launch {
            val choice = engineSource.pick()
            if (session !== s) return@launch
            s.choice = choice
            choice.fallbackReason?.let {
                warn(UiText.Resource(R.string.voice_read_aloud_engine_fallback))
            }
            val uiLocale = environment.uiLocale()
            val detectInput = languageDetectionInput(segments)
            val hypotheses = if (detectInput.isEmpty()) {
                emptyList()
            } else {
                runCatching { languageDetector.detect(detectInput) }.getOrDefault(emptyList())
            }
            if (session !== s) return@launch
            val uiTag = uiLocale.toLanguageTag()
            val readingTag = CloudReadAloudRules.readingLanguage(hypotheses, uiTag)
            val locale = if (readingTag == uiTag) uiLocale else Locale.forLanguageTag(readingTag)
            val appLocale = placeholderLocale(readingTag, uiTag)
            // Read the placeholder in the language its text is in: reuse the reading locale if it is the same language, use the UI locale if it fell back to the UI language
            val placeholderSpeechLocale = when (appLocale) {
                appLocaleFor(readingTag) -> locale
                appLocaleFor(uiTag) -> uiLocale
                else -> Locale.forLanguageTag(appLocale)
            }
            val utterances = segments.map { seg ->
                when (seg) {
                    is SpeakableSegment.Sentence -> seg.text
                    is SpeakableSegment.Placeholder -> environment.placeholderText(seg.kind, appLocale)
                }
            }
            val segmentLocales = segments.map { seg ->
                when (seg) {
                    is SpeakableSegment.Sentence -> locale
                    is SpeakableSegment.Placeholder -> placeholderSpeechLocale
                }
            }
            val granted = environment.beginSession(sessionListener(s))
            s.environmentActive = true
            if (!granted) {
                end(s, ReadAloudEndReason.FAILED)
                environment.showMessage(R.string.voice_read_aloud_failed)
                return@launch
            }
            choice.engine.speak(utterances, locale, segmentLocales, engineListener(s))
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

        override fun onFallback(providerDisplayName: String) = onMain(s) {
            if (s.fallbackNotified) return@onMain
            s.fallbackNotified = true
            warn(UiText.Resource(R.string.voice_read_aloud_cloud_fallback, listOf(providerDisplayName)))
        }
    }

    private fun warn(text: UiText) {
        showToast(GlobalSnackbarMessage(text, style = GlobalToastStyle.Warning))
    }

    /** Engine / platform callbacks hop back to the controller scope; late callbacks from an ended session are dropped. */
    private fun onMain(s: Session, block: () -> Unit) {
        scope.launch { if (session === s) block() }
    }

    private fun end(s: Session, reason: ReadAloudEndReason) {
        if (session !== s) return
        session = null
        s.job?.cancel()
        s.choice?.engine?.stop()
        if (s.environmentActive) environment.endSession()
        _state.value = if (reason == ReadAloudEndReason.FAILED) ReadAloudState.Failed(s.messageId) else ReadAloudState.Idle
    }
}

/** Upper limit of the detection input (code points). */
internal const val LANGUAGE_DETECTION_MAX_CODE_POINTS = 2000

/**
 * Language detection input: speakable sentence segments joined with spaces, taking the first [LANGUAGE_DETECTION_MAX_CODE_POINTS] code points;
 * placeholder segments (code blocks, tables, etc.) do not take part. Returns an empty string when there are no sentences (no detection, read with the UI locale).
 */
internal fun languageDetectionInput(segments: List<SpeakableSegment>): String {
    val joined = segments.filterIsInstance<SpeakableSegment.Sentence>().joinToString(" ") { it.text }
    val count = joined.codePointCount(0, joined.length)
    if (count <= LANGUAGE_DETECTION_MAX_CODE_POINTS) return joined
    return joined.substring(0, joined.offsetByCodePoints(0, LANGUAGE_DETECTION_MAX_CODE_POINTS))
}
