package ai.oriveo.community.core.voice.live

import android.Manifest
import android.content.Context
import android.media.AudioManager
import android.os.Build
import android.os.SystemClock
import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import ai.oriveo.community.R
import ai.oriveo.community.core.voice.AndroidAudioSessionCoordinator
import ai.oriveo.community.core.voice.AudioRecordCapture
import ai.oriveo.community.core.voice.DefaultReadAloudEngineFactory
import ai.oriveo.community.core.voice.DictationEngineFactory
import ai.oriveo.community.core.voice.PcmSource
import ai.oriveo.community.core.voice.ReadAloudEngineSource
import ai.oriveo.community.core.voice.SpeechAudioCache
import ai.oriveo.community.core.voice.SystemSTTRoute
import ai.oriveo.community.core.voice.SystemSpeechEngine
import ai.oriveo.community.core.voice.conversation.AndroidConversationAudio
import ai.oriveo.community.core.voice.conversation.ConversationDisplayState
import ai.oriveo.community.core.voice.conversation.ConversationRoute
import ai.oriveo.community.core.voice.conversation.ConversationStatusKey
import ai.oriveo.community.core.voice.conversation.ConversationStt
import ai.oriveo.community.core.voice.conversation.ConversationSttSource
import ai.oriveo.community.core.voice.conversation.ConversationTts
import ai.oriveo.community.core.voice.conversation.ReadAloudConversationTtsSource
import ai.oriveo.community.core.voice.conversation.SpeakerBargeInMemory
import ai.oriveo.community.core.voice.conversation.SystemConversationTts
import ai.oriveo.community.core.voice.conversation.TtsOutcome
import ai.oriveo.community.core.voice.conversation.VoiceConversationChatPort
import ai.oriveo.community.core.voice.conversation.VoiceConversationController
import ai.oriveo.community.core.voice.conversation.VoiceConversationDiagnostics
import ai.oriveo.community.core.voice.conversation.VoiceConversationEnvironment
import ai.oriveo.community.core.voice.conversation.VoiceConversationEvent
import ai.oriveo.community.core.voice.conversation.VoiceConversationForeground
import ai.oriveo.community.core.voice.conversation.VoicePrompt
import ai.oriveo.community.core.voice.conversation.VoiceReplyEvent
import ai.oriveo.community.core.voice.SpeakablePlaceholder
import io.ktor.client.HttpClient
import java.io.File
import java.util.Locale
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject
import org.koin.mp.KoinPlatform

/**
 * S5 device rig: production [VoiceConversationController] + production [AndroidConversationAudio] (real capture, speaker routing).
 * System recognition goes through the system branch of production [DictationEngineFactory] (matches the system branch of DictationConversationSttSource).
 * System TTS goes through production [SystemConversationTts] (via the system branch of ReadAloudConversationTtsSource).
 * Injection: newCapture wraps the real open(); the outer [InjectingPcmSource] adds the corpus sample by sample onto the real microphone samples, paced by capture.
 * Noise bed: [setNoise] attaches a looping noise bed that is added sample by sample alongside the injected speech (noise first, then speech).
 * The port stand-in records the text and timing of send / amend; replies come from the driving preset sentence. See [Timeline] for the timeline.
 * [mic]: real = real microphone samples; silent = still reads the real source to keep capture pacing, but zeroes the samples read before adding the noise bed and injection
 * (production capture, VAD, recognition and speaker output still run), used to exclude room voices; echo / short-answer / noise-only runs must use real.
 */
class VoiceS5Rig(private val context: Context, val mic: String = MIC_REAL) {
    init {
        require(mic in MICS) { "mic must be one of $MICS, got $mic" }
    }

    /** One driving utterance: injected wav samples, recognition language, preset reply. */
    class Utterance(val id: String, val lang: String, val text: String, val reply: String, val samples: ShortArray)

    /** One TTS playback: start = speak call, end = TtsOutcome.endedAtMs (defaults to the time speak returns). */
    class Span(val turn: Int, val kind: String, val text: String, val startAt: Long) {
        val endAt = AtomicLong(-1)
    }

    class Send(val turn: Int, val kind: String, val text: String, val at: Long)

    /** Timeline: every time is milliseconds from the rig start, measured on elapsedRealtime. */
    inner class Timeline {
        val events = CopyOnWriteArrayList<JSONObject>()
        val spans = CopyOnWriteArrayList<Span>()
        val sends = CopyOnWriteArrayList<Send>()

        fun add(type: String, vararg fields: Pair<String, Any?>) {
            val obj = JSONObject().put("t", rel(now())).put("turn", turn.get()).put("type", type)
            for ((k, v) in fields) obj.put(k, v ?: JSONObject.NULL)
            events += obj
        }

        fun toJson(): JSONArray = JSONArray().apply { events.forEach { put(it) } }
    }

    val timeline = Timeline()
    private val origin = SystemClock.elapsedRealtime()
    private val turn = AtomicInteger(0)
    private val current = AtomicReference<Utterance?>(null)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val audioManager = context.getSystemService(AudioManager::class.java)
    private var previousVolume: Int? = null
    private val injector = AtomicReference<Injection?>(null)
    private val noiseBed = AtomicReference<NoiseBed?>(null)
    private val promptTexts = java.util.Collections.newSetFromMap(java.util.concurrent.ConcurrentHashMap<String, Boolean>())

    @Volatile var language: String = "zh-CN"
        private set

    val audio = AndroidConversationAudio(
        context,
        KoinPlatform.getKoin().get<AndroidAudioSessionCoordinator>(),
        File(context.cacheDir, "voice-s5-conversation"),
        { ai.oriveo.community.core.voice.MediaCodecAacEncoder() },
        { openSource -> AudioRecordCapture({ InjectingPcmSource(openSource()) }) },
    )

    private val engines: DictationEngineFactory = KoinPlatform.getKoin().get()
    private val httpClient: HttpClient = KoinPlatform.getKoin().get()

    /** Same as the system branch of DictationConversationSttSource; this rig only measures system recognition, cloud selection is not involved. */
    private val sttSource = ConversationSttSource {
        val lang = language
        val route = engines.systemRoute(lang)
        timeline.add("sttRoute", "lang" to lang, "route" to route.toString())
        when (route) {
            SystemSTTRoute.Unavailable -> ConversationStt.Unavailable
            is SystemSTTRoute.Pipe -> ConversationStt.FromFile(
                engines.system(),
                lang,
                live = { engines.startPipeSession(route) },
                liveRoute = route,
            )
            is SystemSTTRoute.SelfRecord -> ConversationStt.Unavailable.also {
                timeline.add("error", "detail" to "selfRecord route not supported by rig")
            }
        }
    }

    private val tempDir = File(context.cacheDir, "voice-s5-conversation-tts").apply { deleteRecursively() }
    private val voice = RecordingTts(
        SystemConversationTts(
            context,
            speechRate = { 1.0 },
            localeFor = { Locale.forLanguageTag(current.get()?.lang ?: language) },
            tempDir = tempDir,
        ),
    )

    private val chat = PresetChat()

    /** Per-turn diagnostics from the production host: written to the timeline as type="diag" + name. Frame times record the frame number as is (20 ms per frame); clock times are converted to be relative to the rig start. */
    private val diagnostics = object : VoiceConversationDiagnostics {
        override fun vadMode(mode: String, reason: String?) = diag("vadMode", "mode" to mode, "reason" to reason)

        override fun level(
            frame: Long,
            db: Double,
            floorDb: Double,
            voiced: Boolean,
            prob: Float?,
            mode: String,
            inferenceUs: Long?,
        ) = diag(
            "level",
            "frame" to frame,
            "db" to db,
            "floorDb" to floorDb,
            "voiced" to voiced,
            "prob" to prob,
            "mode" to mode,
            "inferenceUs" to inferenceUs,
        )

        override fun vadStart(frame: Long, prerollFrame: Long, floorDb: Double, prob: Float?, mode: String) =
            diag("vadStart", "frame" to frame, "prerollFrame" to prerollFrame, "floorDb" to floorDb, "prob" to prob, "mode" to mode)

        override fun vadEnd(frame: Long, floorDb: Double, voicedMs: Int, reason: String, prob: Float?, mode: String) =
            diag(
                "vadEnd",
                "frame" to frame,
                "floorDb" to floorDb,
                "voicedMs" to voicedMs,
                "reason" to reason,
                "prob" to prob,
                "mode" to mode,
            )

        override fun vadDiscarded(frame: Long, floorDb: Double) =
            diag("vadDiscarded", "frame" to frame, "floorDb" to floorDb)

        override fun liveStart(utteranceId: String, recognizer: String?, component: String?, languageTag: String?) =
            diag(
                "liveStart",
                "utterance" to utteranceId,
                "recognizer" to recognizer,
                "component" to component,
                "languageTag" to languageTag,
            )

        override fun liveOpened(utteranceId: String, elapsedMs: Long) =
            diag("liveOpened", "utterance" to utteranceId, "elapsedMs" to elapsedMs)

        override fun liveOpenFailed(utteranceId: String, elapsedMs: Long, code: String) =
            diag("liveOpenFailed", "utterance" to utteranceId, "elapsedMs" to elapsedMs, "code" to code)

        override fun transcript(utteranceId: String, atMs: Long, finalChars: Int, partialChars: Int) =
            diag(
                "transcript",
                "utterance" to utteranceId,
                "at" to rel(atMs),
                "finalChars" to finalChars,
                "partialChars" to partialChars,
            )

        override fun transcribed(utteranceId: String, source: String, recognizerCode: Int?, chars: Int) =
            diag(
                "transcribed",
                "utterance" to utteranceId,
                "source" to source,
                "recognizerCode" to recognizerCode,
                "chars" to chars,
            )

        override fun deadline(atMs: Long?, reason: String) =
            diag("deadline", "at" to atMs?.let(::rel), "reason" to reason)

        override fun captureStats(atMs: Long, reads: Long, zeroReads: Long, errorReads: Long) =
            diag(
                "captureStats",
                "at" to rel(atMs),
                "reads" to reads,
                "zeroReads" to zeroReads,
                "errorReads" to errorReads,
            )

        override fun captureStopped(atMs: Long, reason: String) =
            diag("captureStopped", "at" to rel(atMs), "reason" to reason)

        override fun sinkGate(atMs: Long, paused: Boolean, muted: Boolean, live: Boolean) =
            diag("sinkGate", "at" to rel(atMs), "paused" to paused, "muted" to muted, "live" to live)

        override fun consumerFailed(atMs: Long, error: String) =
            diag("consumerFailed", "at" to rel(atMs), "error" to error)

        override fun consumerExit(atMs: Long) = diag("consumerExit", "at" to rel(atMs))

        private fun diag(name: String, vararg fields: Pair<String, Any?>) =
            timeline.add("diag", "name" to name, *fields)
    }

    val controller = VoiceConversationController(
        audio = audio,
        sttSource = sttSource,
        ttsSource = ReadAloudConversationTtsSource(
            readAloud = ReadAloudEngineSource.fixed(
                DefaultReadAloudEngineFactory(
                    httpClient = httpClient,
                    cache = SpeechAudioCache(File(context.cacheDir, "voice-s5-conversation-cache")),
                    systemEngine = SystemSpeechEngine(context, speechRate = { 1.0 }),
                    speechRate = { 1.0 },
                ).system(),
            ),
            system = voice,
            cloud = { error("S5 rig picked a cloud engine") },
        ),
        foreground = object : VoiceConversationForeground {
            override suspend fun awaitStarted(): Boolean = true

            override val endRequests: Flow<Unit> = emptyFlow()

            override fun stop() = Unit
        },
        environment = object : VoiceConversationEnvironment {
            override fun stopReadAloud() = Unit
        },
        memory = SpeakerBargeInMemory({ context.getSharedPreferences(MEMORY_PREFS, Context.MODE_PRIVATE) }),
        prompt = { which -> promptText(which) },
        diagnostics = diagnostics,
        speechProbs = ai.oriveo.community.core.voice.conversation.SpeechProbSource.silero(context),
    )

    /** Production localized prompt copy (same mapping as AppModule); SayAgain / CheckLanguage / EchoHint are recorded in the timeline. */
    private fun promptText(which: VoicePrompt): String {
        val res = when (which) {
            VoicePrompt.DidNotCatch -> R.string.voice_conversation_prompt_did_not_catch
            VoicePrompt.ApprovalNeeded -> R.string.voice_conversation_prompt_approval_needed
            VoicePrompt.SayAgain -> R.string.voice_conversation_prompt_say_again
            VoicePrompt.CheckLanguage -> R.string.voice_conversation_prompt_check_language
            VoicePrompt.EchoHint -> R.string.voice_conversation_prompt_echo_hint
            is VoicePrompt.Placeholder -> when (which.kind) {
                SpeakablePlaceholder.CODE -> R.string.voice_placeholder_code
                SpeakablePlaceholder.TABLE -> R.string.voice_placeholder_table
                SpeakablePlaceholder.MATH -> R.string.voice_placeholder_math
            }
        }
        val name = when (which) {
            is VoicePrompt.Placeholder -> "Placeholder"
            else -> which.toString()
        }
        timeline.add("prompt", "which" to name)
        return context.getString(res).also { promptTexts += it }
    }

    fun now(): Long = SystemClock.elapsedRealtime()

    fun rel(at: Long): Long = at - origin

    /** Grants mic permission, sets speaker output and turns call volume to max ([close] restores it), starts the conversation and waits for listening. */
    fun start(initialLanguage: String) {
        language = initialLanguage
        InstrumentationRegistry.getInstrumentation().uiAutomation
            .grantRuntimePermission(context.packageName, Manifest.permission.RECORD_AUDIO)
        scope.launch {
            controller.events.collect { event ->
                when (event) {
                    VoiceConversationEvent.NudgeOrb -> timeline.add("nudgeOrb")
                    else -> timeline.add("event", "name" to event.toString())
                }
            }
        }
        scope.launch {
            controller.statusKey.collect { key -> timeline.add("status", "key" to key?.rawValue) }
        }
        scope.launch {
            // The display state carries userSpeaking: when VAD starts an utterance before any caption, the status key still reads listening, and only this can show it.
            controller.displayState.collect { state -> timeline.add("display", "state" to state?.rawValue) }
        }
        onMain { controller.start(chat) }
        check(awaitStatus(START_TIMEOUT_MS) { it == ConversationStatusKey.LISTENING }) { "conversation did not reach listening" }
        // Call volume is tracked per output device: raise it to max after entering communication mode and switching to speaker (restored on close).
        val max = audioManager.getStreamMaxVolume(AudioManager.STREAM_VOICE_CALL)
        previousVolume = audioManager.getStreamVolume(AudioManager.STREAM_VOICE_CALL)
        runCatching { audioManager.setStreamVolume(AudioManager.STREAM_VOICE_CALL, max, 0) }
        val device = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) audioManager.communicationDevice?.type else null
        timeline.add(
            "session",
            "route" to audio.route.name,
            "communicationDevice" to device,
            "aec" to audio.echoCancellerAvailable,
            "voiceCallVolume" to audioManager.getStreamVolume(AudioManager.STREAM_VOICE_CALL),
            "voiceCallMax" to max,
            "mode" to audioManager.mode,
            "mic" to mic,
        )
    }

    val speakerRoute: Boolean get() = audio.route == ConversationRoute.SPEAKER

    /** Recognition language changed: the next utterance is recognized in the new language (production entry recognitionLanguageChanged). */
    fun switchLanguage(lang: String) {
        if (lang == language) return
        language = lang
        onMain { controller.recognitionLanguageChanged() }
        timeline.add("language", "lang" to lang)
    }

    /** Starts turn [index]: overlays the injected corpus and blocks until capture has read all injected samples (or times out). */
    fun inject(index: Int, utterance: Utterance) {
        turn.set(index)
        current.set(utterance)
        val injection = Injection(utterance.samples)
        injector.set(injection)
        val ok = injection.done.await(INJECT_TIMEOUT_MS, java.util.concurrent.TimeUnit.MILLISECONDS)
        injector.compareAndSet(injection, null)
        timeline.add(
            "inject",
            "id" to utterance.id,
            "startT" to injection.startAt.get().takeIf { it >= 0 }?.let(::rel),
            "endT" to injection.endAt.get().takeIf { it >= 0 }?.let(::rel),
            "complete" to ok,
        )
    }

    /** Attaches / detaches the looping noise bed (null = detach); overlays sample by sample from the next capture read, wrapping at the end. */
    fun setNoise(id: String?, samples: ShortArray?) {
        val bed = samples?.takeIf { it.isNotEmpty() }?.let { NoiseBed(it) }
        val previous = noiseBed.getAndSet(bed)
        previous?.let { timeline.add("noiseOff", "mixedSamples" to it.mixed.get()) }
        if (bed != null) timeline.add("noiseOn", "id" to id, "samples" to bed.samples.size)
    }

    /** Number of samples the current noise bed has overlaid (0 when not attached). */
    fun noiseMixedSamples(): Long = noiseBed.get()?.mixed?.get() ?: 0L

    fun sendsOf(index: Int): List<Send> = timeline.sends.filter { it.turn == index }

    fun spansOf(index: Int): List<Span> = timeline.spans.filter { it.turn == index }

    /** Number of TTS playbacks in progress (started and not yet ended). */
    fun speaking(): Boolean = timeline.spans.any { it.endAt.get() < 0 }

    fun status(): ConversationStatusKey? = controller.statusKey.value

    fun display(): ConversationDisplayState? = controller.displayState.value

    /** Conversation still running (not Ended). */
    fun active(): Boolean = controller.active.value

    fun awaitStatus(timeoutMs: Long, predicate: (ConversationStatusKey?) -> Boolean): Boolean = runBlocking {
        withTimeoutOrNull(timeoutMs) { controller.statusKey.first(predicate) } != null
    }

    fun close() {
        // Restore volume on the speaker call device first, then end the conversation (ending exits communication mode).
        previousVolume?.let { runCatching { audioManager.setStreamVolume(AudioManager.STREAM_VOICE_CALL, it, 0) } }
        runCatching { onMain { controller.end() } }
        runBlocking { withTimeoutOrNull(END_TIMEOUT_MS) { controller.active.first { !it } } }
        scope.cancel()
        previousVolume = null
        tempDir.deleteRecursively()
    }

    private fun onMain(block: () -> Unit) = InstrumentationRegistry.getInstrumentation().runOnMainSync(block)

    /** A pending sample segment to overlay; [startAt] / [endAt] = when the first / last sample was read by capture. */
    private class Injection(val samples: ShortArray) {
        var position = 0
        val startAt = AtomicLong(-1)
        val endAt = AtomicLong(-1)
        val done = java.util.concurrent.CountDownLatch(1)
    }

    /** Looping noise bed: [position] is the index of the next sample to overlay, [mixed] is the cumulative overlaid sample count. */
    private class NoiseBed(val samples: ShortArray) {
        var position = 0
        val mixed = AtomicLong(0)
    }

    /** Wraps the real AudioRecord source: after each read, overlays the noise bed first, then saturating-adds the next batch of the current injected segment onto the samples read. */
    private inner class InjectingPcmSource(private val delegate: PcmSource) : PcmSource {
        override fun read(buffer: ShortArray, offset: Int, size: Int): Int {
            val n = delegate.read(buffer, offset, size)
            if (n <= 0) return n
            // Silent mic: keep the real source's read pacing but discard the real samples
            if (mic == MIC_SILENT) buffer.fill(0.toShort(), offset, offset + n)
            noiseBed.get()?.let { bed ->
                synchronized(bed) {
                    for (i in 0 until n) {
                        val mixed = buffer[offset + i] + bed.samples[bed.position]
                        buffer[offset + i] = mixed.coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()
                        bed.position = (bed.position + 1) % bed.samples.size
                    }
                    bed.mixed.addAndGet(n.toLong())
                }
            }
            val injection = injector.get() ?: return n
            synchronized(injection) {
                if (injection.position >= injection.samples.size) return n
                injection.startAt.compareAndSet(-1, now())
                val count = minOf(n, injection.samples.size - injection.position)
                for (i in 0 until count) {
                    val mixed = buffer[offset + i] + injection.samples[injection.position + i]
                    buffer[offset + i] = mixed.coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()
                }
                injection.position += count
                if (injection.position >= injection.samples.size) {
                    injection.endAt.compareAndSet(-1, now())
                    injection.done.countDown()
                }
            }
            return n
        }

        override fun observeSilenced(onSilenced: () -> Unit): () -> Unit = delegate.observeSilenced(onSilenced)

        override fun stop() = delegate.stop()

        override fun release() = delegate.release()
    }

    /** Records the start and end of every speak call (both reply and prompt sentences). */
    private inner class RecordingTts(private val delegate: ConversationTts) : ConversationTts {
        override val isCloud: Boolean get() = delegate.isCloud

        override suspend fun speak(text: String, onLevel: (Float) -> Unit): TtsOutcome {
            val kind = if (text in promptTexts) "prompt" else "reply"
            val span = Span(turn.get(), kind, text, now())
            timeline.spans += span
            timeline.add("ttsStart", "kind" to kind, "text" to text)
            var outcome: TtsOutcome? = null
            try {
                return delegate.speak(text, onLevel).also { outcome = it }
            } finally {
                val end = outcome?.endedAtMs ?: now()
                span.endAt.set(end)
                timeline.add("ttsEnd", "kind" to kind, "done" to (outcome?.done ?: false), "endT" to rel(end))
            }
        }

        override fun pause(): Boolean = delegate.pause()

        override fun resume() = delegate.resume()

        override fun release() = delegate.release()
    }

    /** Port stand-in: records send / amend; the reply is the preset reply of the current driving sentence, emitted in one piece and then Completed. */
    private inner class PresetChat : VoiceConversationChatPort {
        private val flow = MutableSharedFlow<VoiceReplyEvent>(extraBufferCapacity = 64)

        override val replies: Flow<VoiceReplyEvent> = flow

        override suspend fun send(text: String): Boolean = record("send", text)

        override suspend fun amend(text: String): Boolean = record("amend", text)

        private fun record(kind: String, text: String): Boolean {
            val at = now()
            timeline.sends += Send(turn.get(), kind, text, at)
            timeline.add(kind, "text" to text)
            val reply = current.get()?.reply ?: return false
            scope.launch {
                flow.emit(VoiceReplyEvent.Text(reply))
                flow.emit(VoiceReplyEvent.Completed())
            }
            return true
        }

        override fun cancel() = Unit
    }

    companion object {
        const val TAG = "VoiceS5"
        const val MEMORY_PREFS = "voice_s5_conversation"
        const val START_TIMEOUT_MS = 20_000L
        const val END_TIMEOUT_MS = 5_000L
        const val INJECT_TIMEOUT_MS = 30_000L
        const val MIC_REAL = "real"
        const val MIC_SILENT = "silent"
        val MICS = listOf(MIC_REAL, MIC_SILENT)

        fun log(line: String) = Log.i(TAG, line)
    }
}
