package ai.oriveo.community.core.voice.conversation

import ai.oriveo.community.core.voice.DictationFailure
import ai.oriveo.community.core.voice.DictationLevelMeter
import ai.oriveo.community.core.voice.DictationLiveSession
import ai.oriveo.community.core.voice.LiveTranscript
import ai.oriveo.community.core.voice.PcmSink
import ai.oriveo.community.core.voice.DictationPrimaryAction
import ai.oriveo.community.core.voice.STTEngine
import ai.oriveo.community.core.voice.STTResult
import ai.oriveo.community.core.voice.STTSegment
import ai.oriveo.community.testing.TestSharedPreferences
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.time.Duration.Companion.seconds

/** The controller turns fake audio / recognition / chat / speech signals into turn events and runs the effects; assertions are all on the state and calls the controller actually produces. */
@OptIn(ExperimentalCoroutinesApi::class)
class VoiceConversationControllerTest {

    // ── fakes ──

    private class FakeAudio : ConversationAudio {
        override var echoCancellerAvailable = true
        override var route = ConversationRoute.SPEAKER
        lateinit var listener: ConversationAudioListener
        var openedWithCapture: Boolean? = null
        var closed = 0
        var mutedNow = false
        var paused = false
        var turnOpen = false
        var nextFrame = 0L
        var tap: PcmSink? = null
        val earcons = mutableListOf<EarconKind>()
        val written = mutableListOf<Int>()
        var writeDelayMs = 0L

        // Like the real session: close clears the turn files, drafts live elsewhere.
        private val turnFiles = mutableSetOf<File>()
        private val draftFiles = mutableSetOf<File>()

        fun alive(file: File) = file in turnFiles || file in draftFiles

        Activation result: the real implementation completes only after open returns; the test swaps in an incomplete deferred and delivers it after open.
        var activation = CompletableDeferred(true)

        override fun open(listener: ConversationAudioListener, capture: Boolean) {
            this.listener = listener
            openedWithCapture = capture
        }

        override suspend fun awaitActivation(): Boolean = activation.await()

        override fun close() {
            closed++
            turnFiles.clear()
        }

        override fun setMuted(muted: Boolean) {
            mutedNow = muted
        }

        override fun setCapturePaused(paused: Boolean) {
            this.paused = paused
        }

        override fun beginTurn(prerollFrame: Long) {
            turnOpen = true
        }

        override fun endTurn(endFrame: Long): ShortArray? {
            if (!turnOpen) return null
            turnOpen = false
            tap = null
            return ShortArray(320)
        }

        override fun cancelTurn() {
            turnOpen = false
            tap = null
        }

        /** Like the real recorder: the turn so far (a preroll marked [PREROLL_MARK]) first, then each later frame. */
        override fun tapTurn(sink: PcmSink) {
            if (!turnOpen) return
            sink.onPcm(ShortArray(PREROLL_SAMPLES) { PREROLL_MARK }, PREROLL_SAMPLES)
            tap = sink
        }

        override suspend fun writeTurn(samples: ShortArray): STTSegment {
            written += samples.size
            val file = File("turn-${written.size}.aac")
            turnFiles += file
            if (writeDelayMs > 0) delay(writeDelayMs)
            return STTSegment(file)
        }

        override suspend fun writeDraft(samples: ShortArray): STTSegment {
            written += samples.size
            val file = File("draft-${written.size}.aac")
            draftFiles += file
            if (writeDelayMs > 0) delay(writeDelayMs)
            return STTSegment(file)
        }

        override suspend fun playEarcon(kind: EarconKind) {
            earcons += kind
        }

        /** Real capture drops samples while muted / paused; so does the fake. */
        fun frames(db: Double, count: Int) {
            repeat(count) {
                if (!mutedNow && !paused) {
                    // Like liveFrameChunker: the session's speech model (if any) sees each frame first.
                    val prob = listener.speechModel?.feed(ShortArray(FRAME_SAMPLES))
                    listener.onFrame(nextFrame++, db, prob)
                    if (turnOpen) tap?.onPcm(ShortArray(FRAME_SAMPLES), FRAME_SAMPLES)
                }
            }
        }
    }

    private class FakeStt : STTEngine {
        override val engineName = "fake"
        val results = ArrayDeque<STTResult>()
        var calls = 0
        var alive: (File) -> Boolean = { true }

        /** Set: every transcription throws it (a non-recognizer error). */
        var error: Exception? = null

        /** The language each transcription was asked for, in order. */
        val languages = mutableListOf<String?>()

        override suspend fun transcribe(segment: STTSegment, language: String?): STTResult {
            calls++
            languages += language
            delay(100)
            error?.let { throw it }
            // A file deleted before it is read transcribes to nothing.
            if (!alive(segment.aac)) return STTResult.Success("")
            return results.removeFirstOrNull() ?: STTResult.Success("")
        }
    }

    /** A live recognition session: the test pushes [transcript] and completes [result]. */
    private class FakeLive : DictationLiveSession {
        val transcript = MutableStateFlow(LiveTranscript())
        override val live: StateFlow<LiveTranscript> = transcript
        val backlog = mutableListOf<ShortArray>()
        var liveSamples = 0
        var stopped = false
        var cancelled = false
        val result = CompletableDeferred<STTResult>()

        override fun onPcm(samples: ShortArray, count: Int) {
            liveSamples += count
        }

        override fun onBacklogPcm(samples: ShortArray, count: Int): Boolean {
            backlog += samples.copyOf(count)
            return true
        }

        override fun stop() {
            stopped = true
        }

        override suspend fun await(): STTResult = result.await()

        override fun cancel() {
            cancelled = true
            result.complete(STTResult.Success(""))
        }
    }

    private class FakeChat : VoiceConversationChatPort {
        val sent = mutableListOf<String>()
        val amended = mutableListOf<String>()
        var cancels = 0

        /** send / amend / cancel in call order, to check which turn a cancel landed on. */
        val calls = mutableListOf<String>()

        /** The return value of amend: the interface default (host not wired), so other tests' flow is unchanged. */
        var amendResult = false

        /** The next amend suspends and never returns (the host is still waiting for the previous round to settle), until cancelled. */
        var holdNextAmend = false

        /** The suspended amend reports delivery first (the host has replaced the user message), then suspends, simulating delivered-but-amend-not-yet-returned. */
        var deliverHeldAmend = false
        val flow = MutableSharedFlow<VoiceReplyEvent>(extraBufferCapacity = 64)
        override val replies: Flow<VoiceReplyEvent> = flow

        override suspend fun send(text: String): Boolean {
            sent += text
            calls += "send:$text"
            return true
        }

        override suspend fun amend(text: String): Boolean = amend(text) {}

        override suspend fun amend(text: String, onDelivered: () -> Unit): Boolean {
            if (holdNextAmend) {
                holdNextAmend = false
                calls += "held:$text"
                if (deliverHeldAmend) onDelivered()
                awaitCancellation()
            }
            amended += text
            calls += "amend:$text"
            return amendResult
        }

        override fun cancel() {
            cancels++
            calls += "cancel"
        }
    }

    private class FakeTts(override val isCloud: Boolean, private val name: String) : ConversationTts {
        val started = mutableListOf<String>()
        val finished = mutableListOf<String>()
        var cancelled = 0
        var released = 0
        var fail = false

        /** Sound keeps coming out this long after speak returns (reported as the real end); null = not reported. */
        var tailMs: Long? = null
        var now: () -> Long = { 0L }

        override fun release() {
            released++
        }

        /** false = like a player without pause: [pause] refuses and the controller cancels instead. */
        var pausable = true
        var pauses = 0
        var resumes = 0
        private val held = MutableStateFlow(false)

        override fun pause(): Boolean {
            if (!pausable) return false
            pauses++
            held.value = true
            return true
        }

        override fun resume() {
            if (!held.value) return
            resumes++
            held.value = false
        }

        override suspend fun speak(text: String, onLevel: (Float) -> Unit): TtsOutcome {
            started += text
            if (fail) return TtsOutcome.FAILED
            try {
                onLevel(0.5f)
                // Advance time only while not paused: resumed playback plays only the remainder.
                var left = SENTENCE_MS
                while (left > 0) {
                    held.first { !it }
                    val from = now()
                    withTimeoutOrNull(left) { held.first { it } }
                    left -= now() - from
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                cancelled++
                throw e
            } finally {
                held.value = false
            }
            finished += text
            return TtsOutcome.done(tailMs?.let { now() + it })
        }

        override fun toString() = name
    }

    private class FakeForeground : VoiceConversationForeground {
        var started = true
        var stops = 0
        override val endRequests = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
        override suspend fun awaitStarted() = started
        override fun stop() {
            stops++
        }
    }

    private class FakeEnvironment : VoiceConversationEnvironment {
        var readAloudStops = 0
        var background: ((Boolean) -> Unit)? = null
        override fun stopReadAloud() {
            readAloudStops++
        }

        override fun observeBackground(onChange: (Boolean) -> Unit): AutoCloseable {
            background = onChange
            return AutoCloseable { background = null }
        }
    }

    private class FakeSelfTurn : SelfRecordTurn {
        val result = CompletableDeferred<STTResult>()
        var interrupted = false
        override var voicedMs = 0
        override var onRmsDb: ((Float) -> Unit)? = null
        override suspend fun await(): STTResult = result.await()
        override fun interrupt() {
            interrupted = true
            result.complete(STTResult.Success(""))
        }
    }

    /** Records every diagnostic as a line, in order. */
    private class RecordingDiagnostics : VoiceConversationDiagnostics {
        val lines = mutableListOf<String>()
        var levels = 0

        /** VAD mode / probability details, kept apart from [lines]. */
        val vad = mutableListOf<String>()

        override fun vadMode(mode: String, reason: String?) {
            vad += "mode $mode reason=$reason"
        }

        override fun level(frame: Long, db: Double, floorDb: Double, voiced: Boolean, prob: Float?, mode: String, inferenceUs: Long?) {
            levels++
            vad += "level mode=$mode prob=$prob inferenceUs=$inferenceUs"
        }

        override fun vadStart(frame: Long, prerollFrame: Long, floorDb: Double, prob: Float?, mode: String) {
            lines += "vadStart"
            vad += "vadStart mode=$mode prob=$prob"
        }

        override fun vadEnd(frame: Long, floorDb: Double, voicedMs: Int, reason: String, prob: Float?, mode: String) {
            lines += "vadEnd voicedMs=$voicedMs reason=$reason"
            vad += "vadEnd mode=$mode prob=$prob reason=$reason"
        }

        override fun vadDiscarded(frame: Long, floorDb: Double) {
            lines += "vadDiscarded"
        }

        override fun liveStart(utteranceId: String, recognizer: String?, component: String?, languageTag: String?) {
            lines += "liveStart $utteranceId lang=$languageTag"
        }

        override fun liveOpened(utteranceId: String, elapsedMs: Long) {
            lines += "liveOpened $utteranceId"
        }

        override fun liveOpenFailed(utteranceId: String, elapsedMs: Long, code: String) {
            lines += "liveOpenFailed $utteranceId $code"
        }

        override fun transcript(utteranceId: String, atMs: Long, finalChars: Int, partialChars: Int) {
            lines += "transcript $utteranceId finals=$finalChars partial=$partialChars"
        }

        override fun transcribed(utteranceId: String, source: String, recognizerCode: Int?, chars: Int) {
            lines += "transcribed $utteranceId source=$source code=$recognizerCode chars=$chars"
        }

        override fun consumerLag(atMs: Long, enqueued: Long, consumed: Long) {
            lines += "consumerLag enqueued=$enqueued consumed=$consumed"
        }

        override fun captureStalled(atMs: Long, lastFrameAtMs: Long, frames: Long) {
            lines += "captureStalled at=$atMs lastFrameAt=$lastFrameAtMs frames=$frames"
        }
    }

    private class Rig(
        val test: TestScope,
        sdkInt: Int = 34,
        immediate: Boolean = false,
        io: CoroutineDispatcher? = null,
        diagnostics: VoiceConversationDiagnostics = VoiceConversationDiagnostics.NoOp,
        speechProbs: SpeechProbSource? = null,
        frameWatchdog: Boolean = false,
    ) {
        val audio = FakeAudio()
        val stt = FakeStt()
        val chat = FakeChat()
        val system = FakeTts(isCloud = false, name = "system")
        val cloud = FakeTts(isCloud = true, name = "cloud")
        val foreground = FakeForeground()
        val environment = FakeEnvironment()
        val prefs = TestSharedPreferences()
        val memory = SpeakerBargeInMemory({ prefs }, sdkInt, io = Dispatchers.Unconfined)
        var useCloud = false
        var conversationStt: ConversationStt = ConversationStt.FromFile(stt, "zh-Hans")

        /** How many times the controller resolved the STT source. */
        var resolves = 0
        val lives = mutableListOf<FakeLive>()
        var openLive: suspend () -> DictationLiveSession? = { FakeLive().also { lives += it } }

        /** Overrides the spoken text of a prompt (e.g. a long one the echo check can weigh). */
        val promptTexts = mutableMapOf<VoicePrompt, String>()

        /** System pipe route: each sentence opens a live session through [openLive]. */
        fun useLive() {
            conversationStt = ConversationStt.FromFile(stt, "zh-Hans", live = { openLive() })
        }

        init {
            stt.alive = audio::alive
            system.now = { test.testScheduler.currentTime }
            cloud.now = { test.testScheduler.currentTime }
        }
        // immediate: runs the launch body in place like Main.immediate, exposing races on the synchronous return path.
        private val dispatcher =
            if (immediate) UnconfinedTestDispatcher(test.testScheduler) else StandardTestDispatcher(test.testScheduler)
        val scope = CoroutineScope(dispatcher + SupervisorJob())

        /** Every audio file the controller deleted, with the thread that deleted it. */
        val deletes = mutableListOf<Pair<File, Thread>>()
        var onDelete: () -> Unit = {}
        val events = mutableListOf<VoiceConversationEvent>()

        // Every dispatch reads the clock once: a periodic timer shows up here even when it changes nothing.
        var clockReads = 0
        val tracked = mutableListOf<Pair<ai.oriveo.community.core.telemetry.TelemetryEvent, Map<String, Any?>>>()
        val controller = VoiceConversationController(
            audio = audio,
            sttSource = {
                resolves++
                conversationStt
            },
            ttsSource = {
                ConversationVoices(if (useCloud) cloud else system, system, providerDisplayName = "OpenAI")
            },
            foreground = foreground,
            environment = environment,
            memory = memory,
            prompt = { p ->
                promptTexts[p] ?: when (p) {
                    VoicePrompt.DidNotCatch -> "prompt:didNotCatch"
                    VoicePrompt.ApprovalNeeded -> "prompt:approvalNeeded"
                    VoicePrompt.SayAgain -> "prompt:sayAgain"
                    VoicePrompt.CheckLanguage -> "prompt:checkLanguage"
                    VoicePrompt.EchoHint -> "prompt:echoHint"
                    is VoicePrompt.Placeholder -> "prompt:${p.kind.rawValue}"
                }
            },
            scope = scope,
            clock = {
                clockReads++
                test.testScheduler.currentTime
            },
            telemetry = ai.oriveo.community.core.voice.VoiceTelemetry { event, props -> tracked += event to props },
            io = io ?: dispatcher,
            deleteFile = { file ->
                synchronized(deletes) { deletes += file to Thread.currentThread() }
                onDelete()
            },
            diagnostics = diagnostics,
            speechProbs = speechProbs,
            // The fake capture feeds frames in batches and stops once they are fed (in virtual time it looks like a backlog or a stall); enabled only in the watchdog tests.
            frameWatchdog = frameWatchdog,
        ).also { c -> scope.launch { c.events.collect { events += it } } }

        val status get() = controller.statusKey.value
        val display get() = controller.displayState.value

        fun start() {
            controller.start(chat)
            test.runCurrent()
        }

        /** 600 ms of speech then 600 ms of silence: one utterance through the real VAD. */
        fun say() {
            audio.frames(-60.0, 10)
            audio.frames(-20.0, 30)
            audio.frames(-60.0, 30)
            test.runCurrent()
        }

        fun reply(event: VoiceReplyEvent) {
            chat.flow.tryEmit(event)
            test.runCurrent()
        }

        fun advance(ms: Long) {
            test.advanceTimeBy(ms)
            test.runCurrent()
        }

        fun close() = scope.cancel()
    }

    private fun rig(
        test: TestScope,
        sdkInt: Int = 34,
        immediate: Boolean = false,
        io: CoroutineDispatcher? = null,
        diagnostics: VoiceConversationDiagnostics = VoiceConversationDiagnostics.NoOp,
        speechProbs: SpeechProbSource? = null,
        frameWatchdog: Boolean = false,
        block: Rig.() -> Unit,
    ) {
        val r = Rig(test, sdkInt, immediate, io, diagnostics, speechProbs, frameWatchdog)
        try {
            r.block()
        } finally {
            r.close()
        }
    }

    /** Speaking a reply with [sentence] in progress, on the speaker. */
    private fun Rig.intoSpeaking(sentence: String = "\u4eca\u5929\u5929\u6c14\u5f88\u597d。") {
        start()
        stt.results += STTResult.Success("\u4f60\u597d")
        say()
        advance(GATE_AFTER_SPEECH_END_MS)
        reply(VoiceReplyEvent.Text(sentence + "\u4e0b"))
        assertEquals(ConversationDisplayState.SPEAKING, display)
    }

    /** A barge-in candidate after the 1 s grace: 1.2 s silence, 400 ms speech, 600 ms silence. */
    private fun Rig.bargeIn() {
        audio.frames(-60.0, 60)
        audio.frames(-20.0, 20)
        audio.frames(-60.0, 30)
        test.runCurrent()
    }

    // ── tests ──

    /** One file-transcribed turn; returns what the conversation did, to compare runs with and without diagnostics. */
    private fun TestScope.fileTurn(diagnostics: VoiceConversationDiagnostics): List<Any> {
        var observed: List<Any> = emptyList()
        rig(this, diagnostics = diagnostics) {
            start()
            stt.results += STTResult.Success("\u4f60\u597d")
            say()
            advance(150)
            observed = listOf(chat.sent.toList(), events.toList(), clockReads, status.toString())
        }
        return observed
    }

    @Test
    fun `diagnostics report vad start and end and the file source without changing the turn`() = runTest(timeout = 30.seconds) {
        val diag = RecordingDiagnostics()
        val withDiagnostics = fileTurn(diag)
        val without = fileTurn(VoiceConversationDiagnostics.NoOp)
        assertEquals(without, withDiagnostics)
        assertEquals(listOf(listOf("\u4f60\u597d")), withDiagnostics.take(1))
        assertEquals(
            listOf("vadStart", "vadEnd voicedMs=600 reason=silence", "transcribed u1 source=file code=null chars=2"),
            diag.lines,
        )
        // 70 frames fed: one level sample per 25 frames
        assertEquals(2, diag.levels)
    }

    /** Fake speech model: every frame gets [prob]; null after close, like the Silero adapter. */
    private class FakeSpeechModel : SpeechProbModel {
        var prob = 0f
        @Volatile var closed = false
        var fed = 0

        /** Thread that ran [close]; released once closed. */
        @Volatile var closeThread: Thread? = null
        val closedSignal = Semaphore(0)

        /** Inference fails from this frame on (like the adapter after SileroVadUnavailableException: null). */
        var failFrom = Int.MAX_VALUE

        override fun feed(frame: ShortArray): Float? {
            if (closed) return null
            fed++
            return if (fed >= failFrom) null else prob
        }

        override val lastInferenceNanos: Long = 2_000L

        override fun close() {
            closed = true
            closeThread = Thread.currentThread()
            closedSignal.release()
        }
    }

    @Test
    fun `modelVad starts and ends sentences on the speech probability, not on loudness`() = runTest(timeout = 30.seconds) {
        val diag = RecordingDiagnostics()
        val model = FakeSpeechModel()
        rig(this, diagnostics = diag, speechProbs = { model }) {
            start()
            assertEquals(listOf("mode model reason=null"), diag.vad.take(1))
            audio.frames(-60.0, 10)
            // Loud but not speech: the energy rule would open a sentence here, the model mode does not.
            model.prob = 0.1f
            audio.frames(-20.0, 30)
            runCurrent()
            assertTrue(diag.lines.toString(), "vadStart" !in diag.lines)
            assertEquals(ConversationStatusKey.LISTENING, status)
            // Speech must be louder than the background level: the sustained non-voice sound at -20 dB above is already background, so speech has to exceed it.
            model.prob = 0.9f
            audio.frames(-10.0, 30)
            runCurrent()
            assertTrue(diag.vad.toString(), "vadStart mode=model prob=0.9" in diag.vad)
            // Still loud, probability gone: the sentence ends on silence.
            stt.results += STTResult.Success("\u4f60\u597d")
            model.prob = 0.05f
            audio.frames(-20.0, 30)
            runCurrent()
            advance(150)
            assertTrue(diag.vad.toString(), "vadEnd mode=model prob=0.05 reason=silence" in diag.vad)
            assertEquals(listOf("\u4f60\u597d"), chat.sent)
            assertTrue(diag.vad.toString(), "level mode=model prob=0.1 inferenceUs=2" in diag.vad)
            assertEquals(100, model.fed)
            controller.end()
            runCurrent()
            assertTrue(model.closed)
        }
    }

    @Test
    fun `modelVad inference failure hands the rest of the session to a fresh energy vad`() = runTest(timeout = 30.seconds) {
        val diag = RecordingDiagnostics()
        val model = FakeSpeechModel()
        // Old behaviour: when inference failed and switched to energy, close ran synchronously on the main dispatcher and waited on the inference lock, blocking the main thread.
        val ioExecutor = Executors.newSingleThreadExecutor { Thread(it, "conversation-io-test") }
        val io = ioExecutor.asCoroutineDispatcher()
        try {
            rig(this, io = io, diagnostics = diag, speechProbs = { model }) {
                start()
                // The model loads on a real io thread: the start waits for it before opening capture, and a single runCurrent may not catch up.
                val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
                while (audio.openedWithCapture == null && System.nanoTime() < deadline) {
                    Thread.sleep(5)
                    runCurrent()
                }
                assertEquals(true, audio.openedWithCapture)
                audio.frames(-60.0, 10)
                model.prob = 0.9f
                audio.frames(-20.0, 20)
                runCurrent()
                assertTrue(diag.vad.toString(), "vadStart mode=model prob=0.9" in diag.vad)
                // Inference fails mid-sentence: that sentence is dropped like a VAD reset, nothing is sent.
                model.failFrom = model.fed + 1
                audio.frames(-20.0, 5)
                runCurrent()
                assertTrue(diag.lines.toString(), "vadDiscarded" in diag.lines)
                assertTrue("model never closed", model.closedSignal.tryAcquire(5, TimeUnit.SECONDS))
                // Coroutine debug mode appends " @coroutine#N" to the thread name, so only the prefix is compared.
                assertTrue("closed on ${model.closeThread?.name}", model.closeThread!!.name.startsWith("conversation-io-test"))
                assertEquals(ConversationStatusKey.LISTENING, status)
                // Energy frames from here on open sentences as usual.
                stt.results += STTResult.Success("\u4f60\u597d")
                say()
                advance(150)
                assertEquals(listOf("\u4f60\u597d"), chat.sent)
                assertEquals(
                    listOf(
                        "mode model reason=null",
                        "vadStart mode=model prob=0.9",
                        "mode energy reason=inference_failed",
                        "vadStart mode=energy prob=null",
                        "vadEnd mode=energy prob=null reason=silence",
                    ),
                    diag.vad.filterNot { it.startsWith("level ") },
                )
                assertEquals(1, diag.vad.count { it.startsWith("mode energy") })
            }
        } finally {
            io.close()
        }
    }

    @Test
    fun `modelVad load failure keeps the whole session on energy mode`() = runTest(timeout = 30.seconds) {
        val diag = RecordingDiagnostics()
        rig(this, diagnostics = diag, speechProbs = { throw SileroVadUnavailableException("missing asset") }) {
            start()
            assertEquals(true, audio.openedWithCapture)
            stt.results += STTResult.Success("\u4f60\u597d")
            say()
            advance(150)
            assertEquals(listOf("\u4f60\u597d"), chat.sent)
            assertEquals(
                listOf(
                    "mode energy reason=SileroVadUnavailableException",
                    "vadStart mode=energy prob=null",
                    "vadEnd mode=energy prob=null reason=silence",
                ),
                diag.vad.filterNot { it.startsWith("level ") },
            )
            assertTrue(diag.vad.toString(), "level mode=energy prob=null inferenceUs=null" in diag.vad)
        }
    }

    @Test
    fun `diagnostics report the recognizer code of a failed file transcription`() = runTest(timeout = 30.seconds) {
        val diag = RecordingDiagnostics()
        rig(this, diagnostics = diag) {
            start()
            stt.results += STTResult.Failed(DictationFailure.Recognizer(13), DictationPrimaryAction.Retry)
            say()
            advance(150)
            assertTrue(diag.lines.toString(), "transcribed u1 source=file code=13 chars=0" in diag.lines)
        }
    }

    @Test
    fun `diagnostics report the live session and the live source`() = runTest(timeout = 30.seconds) {
        val diag = RecordingDiagnostics()
        rig(this, diagnostics = diag) {
            useLive()
            start()
            audio.frames(-60.0, 10)
            audio.frames(-20.0, 30)
            runCurrent()
            val live = lives.single()
            live.transcript.value = LiveTranscript(listOf("\u4f60"), "\u597d")
            runCurrent()
            live.result.complete(STTResult.Success("\u4f60\u597d"))
            audio.frames(-60.0, 30)
            advance(2_000)
            assertEquals(listOf("\u4f60\u597d"), chat.sent)
            assertEquals(0, stt.calls)
            assertEquals(
                listOf(
                    "vadStart",
                    "liveStart u1 lang=zh-Hans",
                    "liveOpened u1",
                    "transcript u1 finals=1 partial=1",
                    "vadEnd voicedMs=600 reason=silence",
                    "transcribed u1 source=live code=null chars=2",
                ),
                diag.lines.filterNot { it == "transcript u1 finals=0 partial=0" },
            )
        }
    }

    @Test
    fun `diagnostics report a live session that did not open`() = runTest(timeout = 30.seconds) {
        val diag = RecordingDiagnostics()
        rig(this, diagnostics = diag) {
            useLive()
            openLive = { null }
            start()
            stt.results += STTResult.Success("\u4f60\u597d")
            say()
            advance(2_000)
            assertEquals(listOf("\u4f60\u597d"), chat.sent)
            assertTrue(diag.lines.toString(), "liveOpenFailed u1 null_session" in diag.lines)
            assertTrue(diag.lines.toString(), "transcribed u1 source=file code=null chars=2" in diag.lines)
        }
    }

    @Test
    fun `full turn listens transcribes sends speaks closed sentences and listens again`() = runTest(timeout = 30.seconds) {
        rig(this) {
            start()
            assertEquals(1, environment.readAloudStops)
            assertEquals(true, audio.openedWithCapture)
            assertEquals(ConversationStatusKey.LISTENING, status)

            stt.results += STTResult.Success("\u4f60\u597d")
            say()
            assertEquals(ConversationDisplayState.THINKING, display)
            advance(150)
            assertEquals(1, stt.calls)
            assertEquals(listOf("\u4f60\u597d"), chat.sent)

            advance(GATE_AFTER_SPEECH_END_MS - 150)
            reply(VoiceReplyEvent.Text("\u4eca\u5929\u5929\u6c14\u5f88\u597d。\u4e0b"))
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d。"), system.started)
            reply(VoiceReplyEvent.Text("\u4eca\u5929\u5929\u6c14\u5f88\u597d。\u4e0b\u5348\u6709\u96e8。"))
            reply(VoiceReplyEvent.Completed())
            advance(SENTENCE_MS * 2 + 10)
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d。", "\u4e0b\u5348\u6709\u96e8。"), system.finished)
            assertEquals(ConversationStatusKey.LISTENING, status)

            controller.end()
            runCurrent()
            assertEquals(1, audio.closed)
            assertEquals(1, foreground.stops)
            assertFalse(controller.active.value)
            assertEquals(VoiceConversationEvent.Ended(EndReason.USER, null), events.last())
        }
    }

    @Test
    fun `only newly closed sentences are enqueued`() = runTest(timeout = 30.seconds) {
        rig(this) {
            intoSpeaking("\u7b2c\u4e00\u53e5。")
            reply(VoiceReplyEvent.Text("\u7b2c\u4e00\u53e5。\u7b2c\u4e8c"))
            reply(VoiceReplyEvent.Text("\u7b2c\u4e00\u53e5。\u7b2c\u4e8c\u53e5"))
            advance(SENTENCE_MS + 10)
            assertEquals(listOf("\u7b2c\u4e00\u53e5。"), system.started)
            reply(VoiceReplyEvent.Text("\u7b2c\u4e00\u53e5。\u7b2c\u4e8c\u53e5。\u7b2c\u4e09"))
            reply(VoiceReplyEvent.Completed())
            advance(SENTENCE_MS * 3)
            assertEquals(listOf("\u7b2c\u4e00\u53e5。", "\u7b2c\u4e8c\u53e5。", "\u7b2c\u4e09"), system.started)
        }
    }

    @Test
    fun `echo barge-in resumes the sentence without sending`() = runTest(timeout = 30.seconds) {
        rig(this) {
            intoSpeaking()
            stt.results += STTResult.Success("\u4eca\u5929\u5929\u6c14\u5f88\u597d")
            bargeIn()
            assertEquals(1, system.pauses)
            advance(150)
            assertEquals(1, system.cancelled)
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d。", "\u4eca\u5929\u5929\u6c14\u5f88\u597d。"), system.started)
            assertEquals(listOf("\u4f60\u597d"), chat.sent)
            assertEquals(0, chat.cancels)
            assertEquals(ConversationStatusKey.SPEAKING, status)
        }
    }

    @Test
    fun `discarded barge-in resumes from the pause point without replaying what was heard`() = runTest(timeout = 30.seconds) {
        rig(this) {
            intoSpeaking()
            advance(400)
            // Speech opens inside the candidate window (after the grace period) → pause.
            audio.frames(-60.0, 60)
            audio.frames(-20.0, 20)
            runCurrent()
            assertEquals(1, system.pauses)
            assertEquals(0, system.cancelled)
            advance(300)
            assertTrue(system.finished.isEmpty())
            // This sentence is invalidated by an outside force (screen reader speaking) → the interruption candidate is cancelled and playback resumes from the pause point.
            controller.screenReaderSpeaking(true)
            runCurrent()
            assertEquals(1, system.resumes)
            advance(SENTENCE_MS - 400 - 50)
            assertTrue(system.finished.isEmpty())
            advance(100)
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d。"), system.finished)
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d。"), system.started)
            assertEquals(0, system.cancelled)
            assertEquals(listOf("\u4f60\u597d"), chat.sent)
        }
    }

    @Test
    fun `echo barge-in replays the paused sentence from its start`() = runTest(timeout = 30.seconds) {
        rig(this) {
            intoSpeaking()
            advance(400)
            stt.results += STTResult.Success("\u4eca\u5929\u5929\u6c14\u5f88\u597d")
            bargeIn()
            assertEquals(1, system.pauses)
            advance(150)
            assertEquals(1, system.cancelled)
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d。", "\u4eca\u5929\u5929\u6c14\u5f88\u597d。"), system.started)
            // Resuming at the pause point, the remaining 600 ms would already have finished; replaying from the sentence start takes a whole sentence.
            advance(SENTENCE_MS - 100)
            assertTrue(system.finished.isEmpty())
            advance(200)
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d。"), system.finished)
        }
    }

    @Test
    fun `sentences arriving while paused play after the pause point resumes`() = runTest(timeout = 30.seconds) {
        rig(this) {
            intoSpeaking("\u7b2c\u4e00\u53e5。")
            advance(400)
            audio.frames(-60.0, 60)
            audio.frames(-20.0, 20)
            runCurrent()
            assertEquals(1, system.pauses)
            reply(VoiceReplyEvent.Text("\u7b2c\u4e00\u53e5。\u7b2c\u4e8c\u53e5。"))
            reply(VoiceReplyEvent.Completed())
            advance(300)
            assertEquals(listOf("\u7b2c\u4e00\u53e5。"), system.started)
            controller.screenReaderSpeaking(true)
            runCurrent()
            advance(SENTENCE_MS - 400 + 50)
            assertEquals(listOf("\u7b2c\u4e00\u53e5。"), system.finished)
            advance(SENTENCE_MS)
            assertEquals(listOf("\u7b2c\u4e00\u53e5。", "\u7b2c\u4e8c\u53e5。"), system.started)
            assertEquals(listOf("\u7b2c\u4e00\u53e5。", "\u7b2c\u4e8c\u53e5。"), system.finished)
            assertEquals(0, system.cancelled)
        }
    }

    @Test
    fun `a voice that cannot pause restarts the sentence on resume`() = runTest(timeout = 30.seconds) {
        rig(this) {
            system.pausable = false
            intoSpeaking()
            advance(400)
            audio.frames(-60.0, 60)
            audio.frames(-20.0, 20)
            runCurrent()
            assertEquals(1, system.cancelled)
            controller.screenReaderSpeaking(true)
            runCurrent()
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d。", "\u4eca\u5929\u5929\u6c14\u5f88\u597d。"), system.started)
        }
    }

    @Test
    fun `two false barge-ins switch to tap and two such conversations are remembered`() = runTest(timeout = 30.seconds) {
        rig(this) {
            repeat(2) { round ->
                intoSpeaking()
                repeat(2) {
                    stt.results += STTResult.Success("")
                    bargeIn()
                    advance(150)
                }
                assertEquals(ConversationStatusKey.SPEAKING_TAP_TO_INTERRUPT, status)
                // Voice no longer interrupts.
                val before = system.cancelled
                bargeIn()
                assertEquals(before, system.cancelled)
                controller.end()
                runCurrent()
                assertEquals(round == 1, memory.remembersNoSpeakerBargeIn())
            }
            intoSpeaking()
            assertEquals(ConversationStatusKey.SPEAKING_TAP_TO_INTERRUPT, status)
        }
        // A new OS version clears the memory.
        val prefs = TestSharedPreferences()
        SpeakerBargeInMemory({ prefs }, 34, io = Dispatchers.Unconfined).apply {
            conversationEnded(fellBackToTap = true, exercisedSpeakerBargeIn = true)
            conversationEnded(fellBackToTap = true, exercisedSpeakerBargeIn = true)
            assertTrue(remembersNoSpeakerBargeIn())
        }
        assertFalse(SpeakerBargeInMemory({ prefs }, 35, io = Dispatchers.Unconfined).remembersNoSpeakerBargeIn())
    }

    @Test
    fun `non-echo barge-in cancels generation and sends`() = runTest(timeout = 30.seconds) {
        rig(this) {
            intoSpeaking()
            stt.results += STTResult.Success("\u7b49\u4e00\u4e0b，\u6362\u4e2a\u8bdd\u9898")
            bargeIn()
            advance(150)
            assertEquals(1, chat.cancels)
            assertEquals(listOf("\u4f60\u597d", "\u7b49\u4e00\u4e0b，\u6362\u4e2a\u8bdd\u9898"), chat.sent)
            assertEquals(ConversationDisplayState.THINKING, display)
        }
    }

    @Test
    fun `stt fails twice then says did not catch and listens`() = runTest(timeout = 30.seconds) {
        rig(this) {
            start()
            val failed = STTResult.Failed(DictationFailure.Network, DictationPrimaryAction.Retry)
            stt.results += failed
            stt.results += failed
            say()
            advance(300)
            assertEquals(2, stt.calls)
            assertEquals(listOf("prompt:didNotCatch"), system.started)
            assertTrue(audio.paused)
            assertEquals(ConversationStatusKey.LISTENING, status)
            assertTrue(chat.sent.isEmpty())
            advance(SENTENCE_MS + 10)
            assertFalse(audio.paused)
        }
    }

    @Test
    fun `approval pending speaks a prompt and shows awaiting`() = runTest(timeout = 30.seconds) {
        rig(this) {
            start()
            stt.results += STTResult.Success("\u5220\u6389\u8fd9\u4e2a\u6587\u4ef6")
            say()
            advance(150)
            reply(VoiceReplyEvent.ApprovalPending(true))
            assertEquals(ConversationStatusKey.AWAITING_APPROVAL, status)
            assertEquals(listOf("prompt:approvalNeeded"), system.started)
            reply(VoiceReplyEvent.ApprovalPending(false))
            assertEquals(ConversationStatusKey.THINKING, status)
        }
    }

    @Test
    fun `approval prompt while speaking queues ahead and current sentence completes`() = runTest(timeout = 30.seconds) {
        rig(this) {
            intoSpeaking()
            reply(VoiceReplyEvent.Text("\u4eca\u5929\u5929\u6c14\u5f88\u597d。\u4e0b\u5348\u6709\u96e8。\u665a"))
            reply(VoiceReplyEvent.ApprovalPending(true))
            // The sentence being spoken is not interrupted, and the prompt does not start speaking at the same time.
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d。"), system.started)
            assertEquals(0, system.cancelled)
            assertFalse(audio.paused)
            advance(SENTENCE_MS + 10)
            // The prompt is inserted before the next queued sentence.
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d。"), system.finished)
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d。", "prompt:approvalNeeded"), system.started)
            assertTrue(audio.paused)
            advance(SENTENCE_MS + 10)
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d。", "prompt:approvalNeeded", "\u4e0b\u5348\u6709\u96e8。"), system.started)
            assertFalse(audio.paused)
        }
    }

    @Test
    fun `synchronous speak failure does not wedge playback`() = runTest(timeout = 30.seconds) {
        rig(this, immediate = true) {
            system.fail = true
            intoSpeaking()
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d。"), system.started)
            system.fail = false
            reply(VoiceReplyEvent.Text("\u4eca\u5929\u5929\u6c14\u5f88\u597d。\u4e0b\u5348\u6709\u96e8。\u665a"))
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d。", "\u4e0b\u5348\u6709\u96e8。"), system.started)
        }
    }

    @Test
    fun `reply failure ends the conversation with error`() = runTest(timeout = 30.seconds) {
        rig(this) {
            start()
            stt.results += STTResult.Success("\u4f60\u597d")
            say()
            advance(150)
            reply(VoiceReplyEvent.Failed("network"))
            assertEquals(ConversationDisplayState.ERROR, display)
            assertEquals(VoiceConversationEvent.Ended(EndReason.ERROR, "network"), events.last())
            assertEquals(1, audio.closed)
            assertFalse(controller.active.value)
        }
    }

    @Test
    fun `idle listening ends after two minutes with the end earcon`() = runTest(timeout = 30.seconds) {
        rig(this) {
            start()
            val t0 = currentTime
            advance(VoiceConversationConstants.IDLE_TIMEOUT_MS - 1)
            assertTrue(controller.active.value)
            assertEquals(listOf(EarconKind.START), audio.earcons)
            advance(1)
            assertEquals(t0 + VoiceConversationConstants.IDLE_TIMEOUT_MS, currentTime)
            assertEquals(listOf(EarconKind.START, EarconKind.END), audio.earcons)
            assertEquals(VoiceConversationEvent.Ended(EndReason.IDLE, null), events.last())
        }
    }

    @Test
    fun no_periodic_tick_only_one_deadline_armed() = runTest(timeout = 30.seconds) {
        rig(this) {
            start()
            val reads = clockReads
            advance(VoiceConversationConstants.IDLE_TIMEOUT_MS - 1)
            // Nothing fired while the conversation sat quiet: no tick loop, only the one pending deadline.
            assertEquals(reads, clockReads)
            assertTrue(controller.active.value)
            advance(1)
            assertEquals(listOf(EarconKind.START, EarconKind.END), audio.earcons)
            assertEquals(1, events.count { it == VoiceConversationEvent.Ended(EndReason.IDLE, null) })
            assertFalse(controller.active.value)
        }
    }

    @Test
    fun deadline_rearmed_after_activity() = runTest(timeout = 30.seconds) {
        rig(this) {
            start()
            advance(60_000)
            controller.toggleMute()
            runCurrent()
            controller.toggleMute()
            runCurrent()
            val activityAt = currentTime
            // Past the first deadline (start + IDLE): it was cancelled when activity moved it.
            advance(VoiceConversationConstants.IDLE_TIMEOUT_MS - 1)
            assertTrue(controller.active.value)
            assertEquals(listOf(EarconKind.START), audio.earcons)
            advance(1)
            assertEquals(activityAt + VoiceConversationConstants.IDLE_TIMEOUT_MS, currentTime)
            assertEquals(listOf(EarconKind.START, EarconKind.END), audio.earcons)
            assertEquals(VoiceConversationEvent.Ended(EndReason.IDLE, null), events.last())
        }
    }

    @Test
    fun `start and heard earcons, then the thinking earcon after the thinking delay`() = runTest(timeout = 30.seconds) {
        rig(this) {
            start()
            stt.results += STTResult.Success("\u4f60\u597d")
            say()
            advance(VoiceConversationConstants.THINKING_EARCON_MS - 1)
            assertEquals(listOf(EarconKind.START, EarconKind.HEARD), audio.earcons)
            advance(1)
            assertEquals(listOf(EarconKind.START, EarconKind.HEARD, EarconKind.THINKING), audio.earcons)
        }
    }

    @Test
    fun `mute drops capture and shows muted`() = runTest(timeout = 30.seconds) {
        rig(this) {
            start()
            controller.toggleMute()
            runCurrent()
            assertTrue(audio.mutedNow)
            assertEquals(ConversationDisplayState.MUTED, display)
            say()
            advance(200)
            assertEquals(0, stt.calls)
            controller.tapOrb()
            runCurrent()
            assertFalse(audio.mutedNow)
            assertEquals(ConversationDisplayState.LISTENING, display)
        }
    }

    @Test
    fun `interruption pauses playback and capture and does not auto resume`() = runTest(timeout = 30.seconds) {
        rig(this) {
            intoSpeaking()
            audio.listener.onInterruption(began = true)
            runCurrent()
            // Pause rather than cancel: the sentence stops where it is; cancel only when the phone call ends and playback stops.
            assertEquals(1, system.pauses)
            assertEquals(0, system.cancelled)
            assertTrue(audio.paused)
            audio.listener.onInterruption(began = false)
            runCurrent()
            assertEquals(1, system.cancelled)
            reply(VoiceReplyEvent.Text("\u4eca\u5929\u5929\u6c14\u5f88\u597d。\u4e0b\u5348\u6709\u96e8。"))
            reply(VoiceReplyEvent.Completed())
            advance(SENTENCE_MS * 3)
            assertFalse(audio.paused)
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d。"), system.started)
            assertEquals(ConversationStatusKey.LISTENING, status)
        }
    }

    // ── Frame stall / consumption backlog watchdog ──

    private fun RecordingDiagnostics.watchdogLines() =
        lines.filter { it.startsWith("captureStalled") || it.startsWith("consumerLag") }

    @Test
    fun `frame stall over 1500 ms after the last frame ends the conversation as a capture failure`() = runTest(timeout = 30.seconds) {
        val diag = RecordingDiagnostics()
        rig(this, diagnostics = diag, frameWatchdog = true) {
            start()
            advance(500)
            audio.frames(-60.0, 10)
            runCurrent()
            val lastFrameAt = currentTime
            advance(VoiceConversationController.FRAME_STALL_MS)
            assertTrue(controller.active.value)
            assertEquals(emptyList<String>(), diag.watchdogLines())
            advance(1)
            assertFalse(controller.active.value)
            assertEquals(VoiceConversationEvent.Ended(EndReason.SYSTEM, null), events.last())
            assertEquals(1, audio.closed)
            assertEquals(
                listOf("captureStalled at=${lastFrameAt + VoiceConversationController.FRAME_STALL_MS + 1} lastFrameAt=$lastFrameAt frames=10"),
                diag.watchdogLines(),
            )
            assertEquals("error", tracked.last().second["end_reason"])
        }
    }

    @Test
    fun `no frame at all after capture starts ends the conversation as a capture stall within 1500 ms`() = runTest(timeout = 30.seconds) {
        val diag = RecordingDiagnostics()
        rig(this, diagnostics = diag, frameWatchdog = true) {
            start()
            // Timing starts as soon as capture opens: if no frame ever arrives, it still ends as a stall.
            val startedAt = currentTime
            advance(VoiceConversationController.FRAME_STALL_MS)
            assertTrue(controller.active.value)
            assertEquals(emptyList<String>(), diag.watchdogLines())
            advance(1)
            assertFalse(controller.active.value)
            assertEquals(VoiceConversationEvent.Ended(EndReason.SYSTEM, null), events.last())
            assertEquals(1, audio.closed)
            assertEquals(
                listOf("captureStalled at=${startedAt + VoiceConversationController.FRAME_STALL_MS + 1} lastFrameAt=$startedAt frames=0"),
                diag.watchdogLines(),
            )
            assertEquals("error", tracked.last().second["end_reason"])
        }
    }

    @Test
    fun `frames keep the watchdog quiet and muted time is not counted as a stall`() = runTest(timeout = 30.seconds) {
        val diag = RecordingDiagnostics()
        rig(this, diagnostics = diag, frameWatchdog = true) {
            start()
            // Frames keep arriving: feeding intermittently for 6 s does not end it.
            repeat(12) {
                audio.frames(-60.0, 25)
                advance(500)
            }
            assertTrue(controller.active.value)
            // Frames dropped during silence: no timing.
            controller.toggleMute()
            runCurrent()
            assertTrue(audio.mutedNow)
            advance(10_000)
            assertTrue(controller.active.value)
            // After silence is cancelled, timing restarts from this moment; if still no frames, it ends as a stall.
            controller.toggleMute()
            runCurrent()
            val resumedAt = currentTime
            advance(VoiceConversationController.FRAME_STALL_MS)
            assertTrue(controller.active.value)
            advance(VoiceConversationController.FRAME_WATCHDOG_MIN_MS)
            assertFalse(controller.active.value)
            assertEquals(VoiceConversationEvent.Ended(EndReason.SYSTEM, null), events.last())
            assertEquals(1, diag.watchdogLines().size)
            assertTrue(diag.watchdogLines().toString(), diag.watchdogLines().single().startsWith("captureStalled"))
            assertTrue(currentTime - resumedAt <= VoiceConversationController.FRAME_STALL_MS + VoiceConversationController.FRAME_WATCHDOG_MIN_MS)
        }
    }

    @Test
    fun `frame watchdog does not count while capture is interrupted`() = runTest(timeout = 30.seconds) {
        val diag = RecordingDiagnostics()
        rig(this, diagnostics = diag, frameWatchdog = true) {
            start()
            audio.frames(-60.0, 10)
            runCurrent()
            audio.listener.onInterruption(began = true)
            runCurrent()
            assertTrue(audio.paused)
            advance(10_000)
            assertTrue(controller.active.value)
            assertEquals(emptyList<String>(), diag.watchdogLines())
        }
    }

    @Test
    fun `frame consumer lag over 75 frames ends the conversation once`() = runTest(timeout = 30.seconds) {
        val diag = RecordingDiagnostics()
        rig(this, diagnostics = diag, frameWatchdog = true) {
            start()
            val lag = VoiceConversationController.CONSUMER_LAG_FRAMES
            // Exactly 75 frames unconsumed: not counted as a backlog.
            audio.frames(-60.0, lag)
            runCurrent()
            assertTrue(controller.active.value)
            // The consumer coroutine did not run: enqueued minus consumed = 76 frames.
            audio.frames(-60.0, lag + 1)
            audio.frames(-60.0, 10)
            runCurrent()
            assertFalse(controller.active.value)
            assertEquals(VoiceConversationEvent.Ended(EndReason.SYSTEM, null), events.last())
            assertEquals(listOf("consumerLag enqueued=${2 * lag + 1} consumed=$lag"), diag.watchdogLines())
            assertEquals("error", tracked.last().second["end_reason"])
        }
    }

    @Test
    fun `permanent focus loss ends conversation`() = runTest(timeout = 30.seconds) {
        rig(this) {
            intoSpeaking()
            audio.listener.onFocusLost()
            runCurrent()
            assertEquals(1, system.cancelled)
            assertEquals(1, system.released)
            assertEquals(1, audio.closed)
            assertEquals(1, foreground.stops)
            assertFalse(controller.active.value)
            assertEquals(VoiceConversationEvent.Ended(EndReason.SYSTEM, null), events.last())
            val (event, ended) = tracked.last()
            assertEquals(ai.oriveo.community.core.telemetry.TelemetryEvent.VoiceConversationEnded, event)
            assertEquals("interruption", ended["end_reason"])
        }
    }

    @Test
    fun `unplugging headphones stops the sentence`() = runTest(timeout = 30.seconds) {
        rig(this) {
            audio.route = ConversationRoute.HEADPHONES
            intoSpeaking()
            audio.listener.onRouteChanged(ConversationRoute.SPEAKER, privateRouteRemoved = true)
            runCurrent()
            assertEquals(1, system.cancelled)
            reply(VoiceReplyEvent.Text("\u4eca\u5929\u5929\u6c14\u5f88\u597d。\u4e0b\u5348\u6709\u96e8。"))
            reply(VoiceReplyEvent.Completed())
            advance(SENTENCE_MS * 3)
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d。"), system.started)
            assertEquals(ConversationStatusKey.LISTENING, status)
        }
    }

    @Test
    fun `becoming noisy on headphones stops the sentence`() = runTest(timeout = 30.seconds) {
        rig(this) {
            audio.route = ConversationRoute.BLUETOOTH
            intoSpeaking()
            audio.listener.onBecomingNoisy()
            runCurrent()
            assertEquals(1, system.cancelled)
        }
    }

    @Test
    fun `cloud failure falls back to the system voice for the same sentence`() = runTest(timeout = 30.seconds) {
        rig(this) {
            useCloud = true
            cloud.fail = true
            intoSpeaking()
            runCurrent()
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d。"), cloud.started)
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d。"), system.started)
            assertTrue(events.contains(VoiceConversationEvent.EngineFallback("OpenAI")))
        }
    }

    @Test
    fun `no echo canceller starts speaker playback as tap to interrupt`() = runTest(timeout = 30.seconds) {
        rig(this) {
            audio.echoCancellerAvailable = false
            intoSpeaking()
            assertEquals(ConversationStatusKey.SPEAKING_TAP_TO_INTERRUPT, status)
            controller.tapOrb()
            runCurrent()
            assertEquals(1, system.cancelled)
        }
    }

    // Focus denied is reported after open returns (memory.load() does not suspend); the user-visible result is still an audio start failure, and no Start is sent.
    @Test
    fun `activation failure during start ends as an audio start failure`() = runTest(timeout = 30.seconds) {
        rig(this) {
            audio.activation = CompletableDeferred()
            start()
            assertEquals(true, audio.openedWithCapture)
            assertTrue(audio.earcons.isEmpty())

            audio.activation.complete(false)
            runCurrent()
            assertEquals(VoiceConversationEvent.StartFailed(StartFailure.AUDIO), events.last())
            assertTrue(audio.earcons.isEmpty())
            assertEquals(1, audio.closed)
            assertFalse(controller.active.value)
            assertTrue(tracked.isEmpty())
        }
    }

    @Test
    fun `activation success delivered after open starts the conversation`() = runTest(timeout = 30.seconds) {
        rig(this) {
            audio.activation = CompletableDeferred()
            start()
            assertTrue(audio.earcons.isEmpty())

            audio.activation.complete(true)
            runCurrent()
            assertEquals(listOf(EarconKind.START), audio.earcons)
            assertFalse(events.any { it is VoiceConversationEvent.StartFailed })
            assertTrue(controller.active.value)
            assertEquals(0, audio.closed)
        }
    }

    @Test
    fun `foreground service failure never enters the conversation`() = runTest(timeout = 30.seconds) {
        rig(this) {
            foreground.started = false
            start()
            assertEquals(null, audio.openedWithCapture)
            assertEquals(VoiceConversationEvent.StartFailed(StartFailure.FOREGROUND), events.last())
            assertFalse(controller.active.value)
        }
    }

    @Test
    fun `self recording keeps the conversation alive with the frame watchdog on and no app capture`() = runTest(timeout = 30.seconds) {
        // When the system recognizer records on its own (capture=false) the app receives no capture frames: the stall watchdog must not treat waiting for the user to speak as a capture failure.
        val diag = RecordingDiagnostics()
        rig(this, sdkInt = 32, diagnostics = diag, frameWatchdog = true) {
            val turns = mutableListOf<FakeSelfTurn>()
            conversationStt = ConversationStt.SelfRecord { FakeSelfTurn().also { turns += it } }
            start()
            assertEquals(false, audio.openedWithCapture)
            advance(VoiceConversationController.FRAME_STALL_MS * 4)
            assertTrue(controller.active.value)
            assertEquals(ConversationStatusKey.LISTENING, status)
            assertEquals(emptyList<String>(), diag.watchdogLines())
        }
    }

    @Test
    fun `self recording turns skip capture and VAD and pause in background`() = runTest(timeout = 30.seconds) {
        rig(this, sdkInt = 32) {
            val turns = mutableListOf<FakeSelfTurn>()
            conversationStt = ConversationStt.SelfRecord { FakeSelfTurn().also { turns += it } }
            start()
            assertEquals(false, audio.openedWithCapture)
            assertEquals(1, turns.size)

            turns[0].result.complete(STTResult.Success("\u4f60\u597d"))
            runCurrent()
            assertEquals(listOf("\u4f60\u597d"), chat.sent)
            advance(GATE_AFTER_SPEECH_END_MS)
            reply(VoiceReplyEvent.Text("\u4eca\u5929\u5929\u6c14\u5f88\u597d。\u4e0b"))
            assertEquals(ConversationStatusKey.SPEAKING_TAP_TO_INTERRUPT, status)
            assertEquals(1, turns.size)

            // Completing flushes the trailing unterminated text as a final sentence: two sentences play.
            reply(VoiceReplyEvent.Completed())
            advance(SENTENCE_MS * 2 + 10)
            assertEquals(ConversationStatusKey.LISTENING, status)
            // Open the mic for the next sentence only after 800 ms of playback has finished.
            advance(VoiceConversationConstants.POST_PLAYBACK_GUARD_MS.toLong())
            assertEquals(2, turns.size)

            environment.background!!.invoke(true)
            runCurrent()
            assertTrue(turns[1].interrupted)
            assertTrue(events.contains(VoiceConversationEvent.PausedInBackground))
            environment.background!!.invoke(false)
            runCurrent()
            assertEquals(3, turns.size)
        }
    }

    @Test
    fun `self record empty turns with voice prompt say again then check language`() = runTest(timeout = 30.seconds) {
        rig(this, sdkInt = 32) {
            val turns = mutableListOf<FakeSelfTurn>()
            conversationStt = ConversationStt.SelfRecord { FakeSelfTurn().also { turns += it } }
            start()
            assertEquals(1, turns.size)

            // < 600 ms of voice: no prompt, listen again.
            turns[0].voicedMs = 599
            turns[0].result.complete(STTResult.Success(""))
            runCurrent()
            assertEquals(emptyList<String>(), system.started)
            assertEquals(emptyList<String>(), chat.sent)
            assertEquals(2, turns.size)

            // >= 600 ms (and >= 1 s): say again.
            turns[1].voicedMs = 1_200
            turns[1].result.complete(STTResult.Success(""))
            runCurrent()
            assertEquals(listOf("prompt:sayAgain"), system.started)
            advance(SENTENCE_MS + VoiceConversationConstants.POST_PLAYBACK_GUARD_MS + 10)
            assertEquals(3, turns.size)

            // Second miss >= 1 s: check language.
            turns[2].voicedMs = 1_000
            turns[2].result.complete(STTResult.Success(""))
            runCurrent()
            assertEquals(listOf("prompt:sayAgain", "prompt:checkLanguage"), system.started)
            assertEquals(emptyList<String>(), chat.sent)
        }
    }

    @Test
    fun `self record turn rms drives listening level`() = runTest(timeout = 30.seconds) {
        rig(this, sdkInt = 32) {
            val turns = mutableListOf<FakeSelfTurn>()
            conversationStt = ConversationStt.SelfRecord { FakeSelfTurn().also { turns += it } }
            start()
            assertEquals(ConversationStatusKey.LISTENING, status)
            turns[0].onRmsDb!!.invoke(4f)
            assertEquals(DictationLevelMeter.recognizerLevel(4f), controller.level.value, 0.001f)
            advance(70)
            turns[0].onRmsDb!!.invoke(10f)
            assertEquals(1f, controller.level.value, 0.001f)

            // Muted: the recognizer's rms no longer moves the level.
            controller.toggleMute()
            runCurrent()
            advance(70)
            turns[0].onRmsDb?.invoke(-2f)
            assertEquals(1f, controller.level.value, 0.001f)
            controller.toggleMute()
            runCurrent()
            assertEquals(2, turns.size)

            // Not listening (thinking): no update either.
            turns[1].result.complete(STTResult.Success("\u4f60\u597d"))
            runCurrent()
            assertEquals(0f, controller.level.value, 0.001f)
            advance(70)
            turns[1].onRmsDb?.invoke(10f)
            assertEquals(0f, controller.level.value, 0.001f)
        }
    }

    @Test
    fun `tap while speaking stops playback but keeps generating`() = runTest(timeout = 30.seconds) {
        rig(this) {
            intoSpeaking()
            controller.tapOrb()
            runCurrent()
            assertEquals(1, system.cancelled)
            assertEquals(0, chat.cancels)
            reply(VoiceReplyEvent.Text("\u4eca\u5929\u5929\u6c14\u5f88\u597d。\u4e0b\u5348\u6709\u96e8。"))
            reply(VoiceReplyEvent.Completed())
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d。"), system.started)
            assertEquals(ConversationStatusKey.LISTENING, status)
        }
    }

    @Test
    fun `level publishes the window peak at most fifteen times per second`() = runTest(timeout = 30.seconds) {
        rig(this) {
            start()
            val floor = VoiceConversationConstants.FLOOR_INIT_DB
            audio.frames(-30.0, 1)
            runCurrent()
            assertEquals(ConversationFrames.levelFromDb(-30.0, floor), controller.level.value, 0.001f)
            // Within the 67 ms window nothing is published; the loudest frame is kept.
            audio.frames(-20.0, 1)
            audio.frames(-35.0, 4)
            runCurrent()
            assertEquals(ConversationFrames.levelFromDb(-30.0, floor), controller.level.value, 0.001f)
            advance(70)
            audio.frames(-35.0, 1)
            runCurrent()
            assertEquals(ConversationFrames.levelFromDb(-20.0, floor), controller.level.value, 0.001f)
            // The window was cleared: the next one only has quieter frames.
            advance(70)
            audio.frames(-35.0, 1)
            runCurrent()
            assertEquals(ConversationFrames.levelFromDb(-35.0, floor), controller.level.value, 0.001f)

            // One second of 20 ms frames with a rising level: every window peak differs, still ≤ 15 per second.
            val seen = mutableListOf<Float>()
            val job = scope.launch { controller.level.collect { seen += it } }
            runCurrent()
            seen.clear()
            for (i in 0 until 50) {
                advance(20)
                audio.frames(-34.0 + i * 0.3, 1)
                runCurrent()
            }
            assertTrue("published ${seen.size}", seen.size in 12..15)
            job.cancel()
        }
    }

    @Test
    fun `listening level follows the VAD floor`() = runTest(timeout = 30.seconds) {
        rig(this) {
            start()
            // Quiet room: the floor drifts from −50 toward −70.
            audio.frames(-70.0, 150)
            runCurrent()
            advance(70)
            audio.frames(-40.0, 1)
            runCurrent()
            assertEquals(ConversationFrames.levelFromDb(-40.0, -70.0), controller.level.value, 0.01f)
            assertTrue(controller.level.value > ConversationFrames.levelFromDb(-40.0, -50.0) + 0.5f)
        }
    }

    private companion object {
        const val SENTENCE_MS = 1_000L

        /** Reply speech gate: this long after the sentence-end vadSpeechEnd before reply speech starts playing. */
        const val GATE_AFTER_SPEECH_END_MS =
            VoiceConversationConstants.REPLY_AUDIO_GATE_MS - VoiceConversationConstants.VAD_END_SILENCE_MS

        /** One 20 ms frame of 16 kHz samples; the fake preroll is 300 ms marked with [PREROLL_MARK]. */
        const val FRAME_SAMPLES = 320
        const val PREROLL_SAMPLES = 15 * FRAME_SAMPLES
        const val PREROLL_MARK: Short = 7
    }

    // ── Telemetry, message playback, screen reader ──

    @Test
    fun `started and ended telemetry carry entry route engines turns duration reason and barge-in`() = runTest(timeout = 30.seconds) {
        rig(this) {
            val t0 = currentTime
            controller.start(chat, ai.oriveo.community.core.voice.VoiceTelemetry.ConversationEntry.Home)
            runCurrent()
            val started = tracked.single().second
            assertEquals(ai.oriveo.community.core.telemetry.TelemetryEvent.VoiceConversationStarted, tracked.single().first)
            assertEquals(
                mapOf(
                    "listen_engine" to "system",
                    "speak_engine" to "system",
                    "entry" to "home",
                    "route" to "speaker",
                    "provider_kind" to "system",
                ),
                started,
            )
            stt.results += STTResult.Success("\u4f60\u597d")
            say()
            advance(GATE_AFTER_SPEECH_END_MS)
            reply(VoiceReplyEvent.Text("\u597d\u7684。"))
            reply(VoiceReplyEvent.Completed())
            advance(SENTENCE_MS + 10)
            advance(3_000)
            controller.end(EndReason.SYSTEM, ai.oriveo.community.core.voice.VoiceTelemetry.ConversationEndReason.Navigation)
            runCurrent()
            val (event, ended) = tracked.last()
            assertEquals(ai.oriveo.community.core.telemetry.TelemetryEvent.VoiceConversationEnded, event)
            assertEquals("home", ended["entry"])
            assertEquals("navigation", ended["end_reason"])
            assertEquals(ai.oriveo.community.core.voice.VoiceTelemetry.turnCountBucket(1), ended["turn_count_bucket"])
            assertEquals(ai.oriveo.community.core.voice.VoiceTelemetry.conversationSecondsBucket((currentTime - t0) / 1000.0), ended["duration_seconds_bucket"])
            assertEquals("on", ended["speaker_barge_in"])
            assertEquals(2, tracked.size)
        }
    }

    // Old behaviour: counted at SendMessage, so a round that failed after sending also counted in turn_count (here it would be 2-3).
    @Test
    fun `turn count only counts completed replies`() = runTest(timeout = 30.seconds) {
        rig(this) {
            start()
            cascadeRound("\u4f60\u597d")
            stt.results += STTResult.Success("\u518d\u6765")
            say()
            advance(150)
            assertEquals(listOf("\u4f60\u597d", "\u518d\u6765"), chat.sent)
            reply(VoiceReplyEvent.Failed("boom"))
            val (event, ended) = tracked.last()
            assertEquals(ai.oriveo.community.core.telemetry.TelemetryEvent.VoiceConversationEnded, event)
            assertEquals(ai.oriveo.community.core.voice.VoiceTelemetry.turnCountBucket(1), ended["turn_count_bucket"])
        }
    }

    // Old behaviour: a reply that was interrupted (Interrupted) also sent Completed and counted in turn_count (here it would be 2).
    @Test
    fun `interrupted reply not counted`() = runTest(timeout = 30.seconds) {
        rig(this) {
            start()
            cascadeRound("\u4f60\u597d")
            stt.results += STTResult.Success("\u518d\u6765")
            say()
            advance(150)
            reply(VoiceReplyEvent.Text("\u597d\u7684。"))
            reply(VoiceReplyEvent.Completed(delivered = false))
            advance(SENTENCE_MS * 2 + 10)
            assertEquals(ConversationStatusKey.LISTENING, status)
            controller.end(EndReason.SYSTEM, ai.oriveo.community.core.voice.VoiceTelemetry.ConversationEndReason.Navigation)
            runCurrent()
            val (event, ended) = tracked.last()
            assertEquals(ai.oriveo.community.core.telemetry.TelemetryEvent.VoiceConversationEnded, event)
            assertEquals(ai.oriveo.community.core.voice.VoiceTelemetry.turnCountBucket(1), ended["turn_count_bucket"])
        }
    }

    // Regression: stopping playback (here, ending via barge-in) cleared the whole queue and dropped the approval prompt queued ahead of the next sentence.
    @Test
    fun `approval prompt survives stop playback`() = runTest(timeout = 30.seconds) {
        rig(this) {
            intoSpeaking()
            reply(VoiceReplyEvent.Text("\u4eca\u5929\u5929\u6c14\u5f88\u597d。\u4e0b\u5348\u6709\u96e8。\u665a"))
            reply(VoiceReplyEvent.ApprovalPending(true))
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d。"), system.started)
            audio.listener.onInterruption(began = true)
            runCurrent()
            audio.listener.onInterruption(began = false)
            runCurrent()
            advance(SENTENCE_MS + 10)
            // The reply sentence is stopped, and the prompt is still spoken.
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d。", "prompt:approvalNeeded"), system.started)
            assertEquals(listOf("prompt:approvalNeeded"), system.finished)
            advance(SENTENCE_MS + 10)
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d。", "prompt:approvalNeeded"), system.started)
        }
    }

    // Old behaviour: not_speaker was decided by "had ever been on speaker", so a locally remembered off was recorded as off_auto.
    @Test
    fun `speaker barge in reported from end state`() = runTest(timeout = 30.seconds) {
        rig(this) {
            start()
            audio.listener.onRouteChanged(ConversationRoute.HEADPHONES, privateRouteRemoved = false)
            runCurrent()
            controller.end()
            runCurrent()
            assertEquals("not_speaker", tracked.last().second["speaker_barge_in"])
        }
        rig(this) {
            audio.route = ConversationRoute.HEADPHONES
            start()
            audio.listener.onRouteChanged(ConversationRoute.SPEAKER, privateRouteRemoved = false)
            runCurrent()
            controller.end()
            runCurrent()
            assertEquals("on", tracked.last().second["speaker_barge_in"])
        }
        rig(this) {
            memory.conversationEnded(fellBackToTap = true, exercisedSpeakerBargeIn = true)
            memory.conversationEnded(fellBackToTap = true, exercisedSpeakerBargeIn = true)
            start()
            controller.end()
            runCurrent()
            assertEquals("unavailable", tracked.last().second["speaker_barge_in"])
        }
        rig(this) {
            audio.echoCancellerAvailable = false
            start()
            controller.end()
            runCurrent()
            assertEquals("unavailable", tracked.last().second["speaker_barge_in"])
        }
    }

    // Old behaviour: after one cloud failure the whole conversation switched to the system voice, and later replies no longer tried the cloud.
    @Test
    fun `cloud fallback lasts one reply`() = runTest(timeout = 30.seconds) {
        rig(this) {
            useCloud = true
            cloud.fail = true
            intoSpeaking()
            runCurrent()
            reply(VoiceReplyEvent.Text("\u4eca\u5929\u5929\u6c14\u5f88\u597d。\u4e0b\u5348\u6709\u96e8。"))
            reply(VoiceReplyEvent.Completed())
            advance(SENTENCE_MS * 2 + 10)
            assertEquals(ConversationStatusKey.LISTENING, status)
            // The rest of the failed reply stays on the system voice.
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d。"), cloud.started)
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d。", "\u4e0b\u5348\u6709\u96e8。"), system.started)

            stt.results += STTResult.Success("\u518d\u6765")
            say()
            advance(GATE_AFTER_SPEECH_END_MS)
            // While streaming, a sentence-ending punctuation mark closes only once more text follows (stable-prefix split); the last sentence is held until Completed.
            reply(VoiceReplyEvent.Text("\u597d\u7684。\u518d"))
            runCurrent()
            // The next reply tries cloud again; the fallback notice stays once per conversation.
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d。", "\u597d\u7684。"), cloud.started)
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d。", "\u4e0b\u5348\u6709\u96e8。", "\u597d\u7684。"), system.started)
            assertEquals(1, events.count { it is VoiceConversationEvent.EngineFallback })
        }
    }

    // Regression: after transcription, turn / draft audio was deleted with a synchronous File.delete() on the main thread (the controller's Main.immediate scope).
    @Test
    fun segment_delete_off_main() = runTest(timeout = 30.seconds) {
        val ioExecutor = Executors.newSingleThreadExecutor { Thread(it, "conversation-io-test") }
        val io = ioExecutor.asCoroutineDispatcher()
        try {
            fun Rig.awaitDeleteOffMain(name: String, deleted: Semaphore) {
                assertTrue("$name never deleted", deleted.tryAcquire(5, TimeUnit.SECONDS))
                val (file, thread) = synchronized(deletes) { deletes.single() }
                assertEquals(name, file.name)
                // Coroutine debug mode appends " @coroutine#N" to the thread name, so only the prefix is compared
                assertTrue("$name deleted on ${thread.name}", thread.name.startsWith("conversation-io-test"))
            }
            rig(this, io = io) {
                val deleted = Semaphore(0)
                onDelete = { deleted.release() }
                start()
                stt.results += STTResult.Success("\u4f60\u597d")
                say()
                advance(150)
                assertEquals(listOf("\u4f60\u597d"), chat.sent)
                awaitDeleteOffMain("turn-1.aac", deleted)
            }
            // Speech still open when the conversation ends: it goes to a draft, transcribed then deleted.
            rig(this, immediate = true, io = io) {
                val deleted = Semaphore(0)
                onDelete = { deleted.release() }
                audio.writeDelayMs = 20
                start()
                stt.results += STTResult.Success("\u8349\u7a3f")
                audio.frames(-60.0, 10)
                audio.frames(-20.0, 30)
                runCurrent()
                controller.end()
                runCurrent()
                advance(200)
                awaitDeleteOffMain("draft-1.aac", deleted)
            }
        } finally {
            io.close()
        }
    }

    // Regression: on ✕ the draft and turn audio shared a directory, and close cleared the directory, deleting a half-written draft so DraftTranscript was never sent.
    @Test
    fun `close while speaking still delivers draft`() = runTest(timeout = 30.seconds) {
        rig(this, immediate = true) {
            audio.writeDelayMs = 20
            start()
            stt.results += STTResult.Success("\u8349\u7a3f")
            audio.frames(-60.0, 10)
            audio.frames(-20.0, 30)
            runCurrent()
            controller.end()
            runCurrent()
            assertEquals(1, audio.closed)
            advance(200)
            assertTrue(events.contains(VoiceConversationEvent.DraftTranscript("\u8349\u7a3f")))
        }
    }

    // Regression: speech discarded while thinking still opened a turn recording and was AAC-encoded after it ended.
    @Test
    fun `speech start queued while awaiting transcription records and after an empty result becomes u2`() =
        runTest(timeout = 30.seconds) {
            rig(this, immediate = true) {
                start()
                stt.results += STTResult.Success("")
                stt.results += STTResult.Success("\u5728\u5417")
                // First sentence ≥ 600 ms: an empty transcript would prompt "please say that again", but after the replay the system is already waiting on the u2 transcript, so no prompt is inserted.
                audio.frames(-60.0, 10)
                audio.frames(-20.0, 35)
                audio.frames(-60.0, 30)
                runCurrent()
                assertEquals(ConversationDisplayState.THINKING, display)
                assertEquals(1, audio.written.size)
                // Speaking before the transcript returns: the reducer queues it, and the host starts recording as usual.
                audio.frames(-60.0, 10)
                audio.frames(-20.0, 30)
                runCurrent()
                assertTrue(audio.turnOpen)
                audio.frames(-60.0, 30)
                runCurrent()
                // u1 transcript is empty: the queued replay's start and wrap-up happen while listening, and u2 still transcribes and emits as usual.
                advance(3_000)
                assertEquals(2, audio.written.size)
                assertEquals(listOf("\u5728\u5417"), chat.sent)
                assertFalse(system.started.contains("prompt:sayAgain"))
            }
        }

    @Test
    fun `two sentences spoken while the first is transcribing each keep their own recording`() =
        runTest(timeout = 30.seconds) {
            rig(this, immediate = true) {
                start()
                stt.results += STTResult.Success("\u4eca\u5929")
                stt.results += STTResult.Success("\u5929\u6c14")
                stt.results += STTResult.Success("\u600e\u4e48\u6837")
                say()
                assertEquals(ConversationDisplayState.THINKING, display)
                // Two segments spoken before the transcript returns: the first segment's wrap-up is queued and collected into turns immediately, and the second segment's start does not overwrite it.
                audio.frames(-20.0, 30)
                audio.frames(-60.0, 30)
                runCurrent()
                assertFalse(audio.turnOpen)
                audio.frames(-20.0, 30)
                audio.frames(-60.0, 30)
                runCurrent()
                advance(3_000)
                assertEquals(3, audio.written.size)
                assertTrue(stt.results.isEmpty())
                assertEquals(listOf("\u4eca\u5929"), chat.sent)
                assertEquals(listOf("\u5929\u6c14", "\u600e\u4e48\u6837"), chat.amended)
            }
        }

    @Test
    fun `a queued sentence dropped from the queue before replay has its recording discarded`() =
        runTest(timeout = 30.seconds) {
            rig(this, immediate = true) {
                useLive()
                start()
                say()
                assertEquals(ConversationDisplayState.THINKING, display)
                val first = lives.single()
                // One segment spoken before the transcript returns: its wrap-up is queued, and the recording and live session are collected into turns early;
                // the first sentence's live session holds the gate, so this segment's session is queued behind it and not yet opened.
                audio.frames(-20.0, 30)
                audio.frames(-60.0, 30)
                runCurrent()
                assertFalse(audio.turnOpen)
                // Screen-reader speech: abandonUtterance clears the queue, this segment is never transcribed again, and the recording and queued live session are dropped on the spot.
                controller.screenReaderSpeaking(true)
                runCurrent()
                // The first sentence's transcript arrives later and releases the gate: the dropped segment no longer opens a live session and is not transcribed.
                first.result.complete(STTResult.Success("\u4eca\u5929"))
                advance(3_000)
                assertEquals(1, lives.size)
                assertTrue(audio.written.isEmpty())
                assertTrue(chat.amended.isEmpty())
            }
        }

    @Test
    fun `caption heard while the sentence was queued shows as soon as it is replayed`() =
        runTest(timeout = 30.seconds) {
            rig(this, immediate = true) {
                useLive()
                // The first sentence's live session cannot open: fall back to file transcription (100 ms), and the gate is released on the spot.
                openLive = { null }
                stt.results += STTResult.Success("\u4eca\u5929")
                start()
                say()
                assertEquals(ConversationDisplayState.THINKING, display)
                // Speaking before the transcript returns: the start is queued; the host records and opens the live session as usual, and captions arrive while queued.
                val second = FakeLive()
                second.transcript.value = LiveTranscript(listOf("\u5929\u6c14"), "\u600e\u4e48")
                openLive = { second.also { lives += it } }
                audio.frames(-20.0, 30)
                runCurrent()
                assertTrue(audio.turnOpen)
                assertEquals(listOf(second), lives)
                assertEquals(ConversationDisplayState.THINKING, display)
                // The first transcript settles and the replay is now speaking: the caption that arrived while queued is filled in immediately, without waiting for the next change.
                advance(200)
                assertEquals(listOf("\u4eca\u5929"), chat.sent)
                assertEquals(ConversationStatusKey.CAPTION, status)
                assertEquals("\u5929\u6c14\u600e\u4e48", controller.caption.value)
            }
        }

    @Test
    fun `second half spoken after a pause while the first half is transcribing is not lost`() =
        runTest(timeout = 30.seconds) {
            rig(this, immediate = true) {
                start()
                stt.results += STTResult.Success("\u4eca\u5929")
                stt.results += STTResult.Success("\u5929\u6c14\u600e\u4e48\u6837")
                // First segment's end-of-speech decided, transcript not yet returned, and the speaker continues with the second half (real VAD frames).
                say()
                assertEquals(ConversationDisplayState.THINKING, display)
                audio.frames(-20.0, 30)
                audio.frames(-60.0, 30)
                runCurrent()
                advance(3_000)
                assertEquals(2, audio.written.size)
                assertEquals(listOf("\u4eca\u5929"), chat.sent)
                assertEquals(listOf("\u5929\u6c14\u600e\u4e48\u6837"), chat.amended)
            }
        }

    @Test
    fun `replayed continuation cancels the first half after it was sent and only the amended reply plays`() =
        runTest(timeout = 30.seconds) {
            rig(this) {
                chat.amendResult = true
                start()
                stt.results += STTResult.Success("\u4eca\u5929")
                stt.results += STTResult.Success("\u5929\u6c14\u600e\u4e48\u6837")
                // First segment still transcribing and the speaker continues: in the replay batch SendMessage is followed by CancelGeneration, and the cancel must land on the round just sent.
                say()
                audio.frames(-20.0, 30)
                audio.frames(-60.0, 30)
                runCurrent()
                advance(3_000)
                assertEquals(listOf("send:\u4eca\u5929", "cancel", "amend:\u5929\u6c14\u600e\u4e48\u6837"), chat.calls)
                reply(VoiceReplyEvent.Text("\u6674\u5929。\u4e0b"))
                assertEquals(listOf("\u6674\u5929。"), system.started)
                assertEquals(ConversationDisplayState.SPEAKING, display)
            }
        }

    @Test
    fun `a continuation cancelled before its amend went out is carried into the next amend`() =
        runTest(timeout = 30.seconds) {
            rig(this) {
                chat.amendResult = true
                start()
                stt.results += STTResult.Success("\u4eca\u5929")
                stt.results += STTResult.Success("\u5929\u6c14")
                stt.results += STTResult.Success("\u600e\u4e48\u6837")
                say()
                advance(3_000)
                assertEquals(listOf("send:\u4eca\u5929"), chat.calls)
                // u3 starts while u2's amend is still held by the host (waiting for u1 to settle): in the replay batch CancelGeneration intercepts u2, so no text is lost.
                chat.holdNextAmend = true
                say()
                audio.frames(-20.0, 30)
                audio.frames(-60.0, 30)
                runCurrent()
                advance(3_000)
                assertEquals(listOf("send:\u4eca\u5929", "cancel", "held:\u5929\u6c14", "cancel", "amend:\u5929\u6c14\u600e\u4e48\u6837"), chat.calls)
                reply(VoiceReplyEvent.Text("\u6674\u5929。\u4e0b"))
                assertEquals(listOf("\u6674\u5929。"), system.started)
            }
        }

    @Test
    fun `a continuation cancelled after its amend was delivered is not carried again`() =
        runTest(timeout = 30.seconds) {
            rig(this) {
                chat.amendResult = true
                start()
                stt.results += STTResult.Success("\u4eca\u5929")
                stt.results += STTResult.Success("\u5929\u6c14")
                stt.results += STTResult.Success("\u600e\u4e48\u6837")
                say()
                advance(3_000)
                assertEquals(listOf("send:\u4eca\u5929"), chat.calls)
                // The port has handed u2 to the page (user message replaced) and amend has not returned when u3 starts: u2 is already in the session, and the next supplement does not concatenate it again.
                chat.holdNextAmend = true
                chat.deliverHeldAmend = true
                say()
                audio.frames(-20.0, 30)
                audio.frames(-60.0, 30)
                runCurrent()
                advance(3_000)
                assertEquals(listOf("send:\u4eca\u5929", "cancel", "held:\u5929\u6c14", "cancel", "amend:\u600e\u4e48\u6837"), chat.calls)
            }
        }

    @Test
    fun `a continuation cancelled before its amend went out is regenerated when the next sentence is discarded`() =
        runTest(timeout = 30.seconds) {
            rig(this) {
                chat.amendResult = true
                start()
                stt.results += STTResult.Success("\u4eca\u5929")
                stt.results += STTResult.Success("\u5929\u6c14")
                stt.results += STTResult.Success("")
                say()
                advance(3_000)
                assertEquals(listOf("send:\u4eca\u5929"), chat.calls)
                chat.holdNextAmend = true
                say()
                audio.frames(-20.0, 30)
                audio.frames(-60.0, 30)
                runCurrent()
                advance(3_000)
                // u3 transcript is empty and takes the discard path: the regeneration carries the intercepted u2.
                assertEquals(listOf("send:\u4eca\u5929", "cancel", "held:\u5929\u6c14", "cancel", "amend:\u5929\u6c14"), chat.calls)
            }
        }

    @Test
    fun `user end reports user and a start failure reports nothing`() = runTest(timeout = 30.seconds) {
        rig(this) {
            foreground.started = false
            start()
            assertTrue(tracked.isEmpty())
        }
        rig(this) {
            start()
            controller.end()
            runCurrent()
            assertEquals("user", tracked.last().second["end_reason"])
        }
    }

    @Test
    fun `playing an old message pauses capture speaks it with the conversation voice and listens again`() = runTest(timeout = 30.seconds) {
        rig(this) {
            start()
            controller.playMessage("m1", "\u7b2c\u4e00\u53e5。\u7b2c\u4e8c\u53e5。")
            runCurrent()
            assertEquals(listOf("\u7b2c\u4e00\u53e5。"), system.started)
            advance(SENTENCE_MS * 2 + 10)
            assertEquals(listOf("\u7b2c\u4e00\u53e5。", "\u7b2c\u4e8c\u53e5。"), system.finished)
            assertEquals(ConversationStatusKey.LISTENING, status)
            // Ignored outside listening, like the reducer.
            stt.results += STTResult.Success("\u4f60\u597d")
            say()
            controller.playMessage("m2", "\u4e0d\u8be5\u64ad。")
            runCurrent()
            assertFalse(system.started.contains("\u4e0d\u8be5\u64ad。"))
        }
    }

    @Test
    fun `while the screen reader speaks captured speech is not a turn`() = runTest(timeout = 30.seconds) {
        rig(this) {
            start()
            controller.screenReaderSpeaking(true)
            runCurrent()
            say()
            assertEquals(ConversationDisplayState.LISTENING, display)
            assertEquals(0, stt.calls)
            controller.screenReaderSpeaking(false)
            runCurrent()
            stt.results += STTResult.Success("\u4f60\u597d")
            say()
            assertEquals(ConversationDisplayState.THINKING, display)
        }
    }

    /** One cascade round: speech → STT → send → one-sentence reply played to the end → listening again. */
    private fun Rig.cascadeRound(text: String) {
        stt.results += STTResult.Success(text)
        say()
        advance(150)
        reply(VoiceReplyEvent.Text("\u597d\u7684。"))
        reply(VoiceReplyEvent.Completed())
        advance(SENTENCE_MS * 2 + 10)
        assertEquals(ConversationStatusKey.LISTENING, status)
    }

    @Test
    fun `a recognition language change resolves again and applies from the next sentence`() = runTest(timeout = 30.seconds) {
        rig(this) {
            start()
            assertEquals(1, resolves)
            cascadeRound("\u7b2c\u4e00\u8f6e")
            conversationStt = ConversationStt.FromFile(stt, "en")
            controller.recognitionLanguageChanged()
            runCurrent()
            assertEquals(2, resolves)
            cascadeRound("second")
            assertEquals(listOf<String?>("zh-Hans", "en"), stt.languages)
            assertEquals(listOf("\u7b2c\u4e00\u8f6e", "second"), chat.sent)
        }
    }

    @Test
    fun `a recognition language change mid-sentence leaves that sentence on the old language`() = runTest(timeout = 30.seconds) {
        rig(this) {
            start()
            stt.results += STTResult.Success("\u4f60\u597d")
            audio.frames(-60.0, 10)
            audio.frames(-20.0, 30)
            runCurrent()
            conversationStt = ConversationStt.FromFile(stt, "en")
            controller.recognitionLanguageChanged()
            runCurrent()
            audio.frames(-60.0, 30)
            runCurrent()
            advance(150)
            assertEquals(listOf<String?>("zh-Hans"), stt.languages)
            assertEquals(listOf("\u4f60\u597d"), chat.sent)
            reply(VoiceReplyEvent.Text("\u597d\u7684。"))
            reply(VoiceReplyEvent.Completed())
            advance(SENTENCE_MS * 2 + 10)
            cascadeRound("next")
            assertEquals(listOf<String?>("zh-Hans", "en"), stt.languages)
        }
    }

    @Test
    fun `the language re-resolve waits behind the open live session`() = runTest(timeout = 30.seconds) {
        rig(this) {
            useLive()
            start()
            audio.frames(-60.0, 10)
            audio.frames(-20.0, 30)
            runCurrent()
            val live = lives.single()
            conversationStt = ConversationStt.FromFile(stt, "en")
            controller.recognitionLanguageChanged()
            runCurrent()
            // Serial gate: a live session that is already open is not re-resolved before it wraps up.
            assertEquals(1, resolves)
            live.result.complete(STTResult.Success("\u4f60\u597d"))
            audio.frames(-60.0, 30)
            advance(2_000)
            assertEquals(listOf("\u4f60\u597d"), chat.sent)
            assertEquals(2, resolves)
        }
    }

    @Test
    fun `cascade background keeps three rounds`() = runTest(timeout = 30.seconds) {
        rig(this) {
            start()
            assertEquals(true, audio.openedWithCapture)
            // Cascade does not hook app background at all (only SelfRecord pauses); deliver it if a hook exists.
            environment.background?.invoke(true)
            runCurrent()
            cascadeRound("\u7b2c\u4e00\u8f6e")
            cascadeRound("\u7b2c\u4e8c\u8f6e")
            cascadeRound("\u7b2c\u4e09\u8f6e")
            assertEquals(listOf("\u7b2c\u4e00\u8f6e", "\u7b2c\u4e8c\u8f6e", "\u7b2c\u4e09\u8f6e"), chat.sent)
            assertTrue(controller.active.value)
            assertEquals(0, audio.closed)
            assertFalse(audio.paused)
            assertEquals(0, foreground.stops)
            assertFalse(events.contains(VoiceConversationEvent.PausedInBackground))
            assertFalse(events.any { it is VoiceConversationEvent.Ended })
        }
    }

    @Test
    fun `screen reader five rounds no ghost`() = runTest(timeout = 30.seconds) {
        rig(this) {
            start()
            for (round in 1..5) {
                val callsBefore = stt.calls
                controller.screenReaderSpeaking(true)
                runCurrent()
                say()
                advance(150)
                assertEquals(ConversationDisplayState.LISTENING, display)
                assertEquals(callsBefore, stt.calls)
                assertEquals(round - 1, chat.sent.size)
                controller.screenReaderSpeaking(false)
                runCurrent()
                cascadeRound("\u7b2c${round}\u8f6e")
            }
            assertEquals(listOf("\u7b2c1\u8f6e", "\u7b2c2\u8f6e", "\u7b2c3\u8f6e", "\u7b2c4\u8f6e", "\u7b2c5\u8f6e"), chat.sent)
            assertEquals(5, stt.calls)
        }
    }

    // ── Turn host rules ──

    @Test
    fun `speech end keeps the turn open until the reducer transcribes`() = runTest(timeout = 30.seconds) {
        rig(this) {
            start()
            stt.results += STTResult.Success("\u4f60\u597d")
            audio.frames(-60.0, 10)
            audio.frames(-20.0, 30)
            runCurrent()
            assertTrue(audio.turnOpen)
            assertTrue(audio.written.isEmpty())
            audio.frames(-60.0, 30)
            runCurrent()
            // Finalize means Transcribe: only then is the segment closed and encoded.
            assertFalse(audio.turnOpen)
            advance(150)
            assertEquals(1, audio.written.size)
            assertEquals(listOf("\u4f60\u597d"), chat.sent)
        }
    }

    @Test
    fun `entering listening after playback opens the post playback guard`() = runTest(timeout = 30.seconds) {
        rig(this) {
            start()
            stt.results += STTResult.Success("\u4f60\u597d")
            say()
            advance(GATE_AFTER_SPEECH_END_MS)
            reply(VoiceReplyEvent.Text("\u597d\u7684。"))
            reply(VoiceReplyEvent.Completed())
            advance(SENTENCE_MS + 10)
            assertEquals(ConversationStatusKey.LISTENING, status)
            stt.results += STTResult.Success("\u660e\u5929\u89c1")

            // A 140 ms sound inside the aftersound window cannot start a segment (threshold 160 ms), and the lighter 200 ms that follows cannot join: no segment is formed.
            audio.frames(-20.0, 7)
            audio.frames(-50.0, 10)
            audio.frames(-60.0, 30)
            runCurrent()
            advance(150)
            assertEquals(ConversationStatusKey.LISTENING, status)
            assertEquals(1, stt.calls)

            // Past the aftersound window, the same sound starts a segment with the normal threshold (120 ms), and the lighter sound continues it: a segment is formed.
            audio.frames(-20.0, 7)
            audio.frames(-50.0, 10)
            audio.frames(-60.0, 30)
            runCurrent()
            advance(150)
            assertEquals(2, stt.calls)
            assertEquals(listOf("\u4f60\u597d", "\u660e\u5929\u89c1"), chat.sent)
        }
    }

    @Test
    fun `self record opens the mic only after the post playback guard`() = runTest(timeout = 30.seconds) {
        rig(this, sdkInt = 32) {
            val turns = mutableListOf<FakeSelfTurn>()
            conversationStt = ConversationStt.SelfRecord { FakeSelfTurn().also { turns += it } }
            start()
            assertEquals(1, turns.size)
            turns[0].result.complete(STTResult.Success("\u4f60\u597d"))
            runCurrent()
            advance(GATE_AFTER_SPEECH_END_MS)
            reply(VoiceReplyEvent.Text("\u597d\u7684。"))
            reply(VoiceReplyEvent.Completed())
            advance(SENTENCE_MS + 10)
            assertEquals(ConversationStatusKey.LISTENING, status)
            assertEquals(1, turns.size)
            advance(VoiceConversationConstants.POST_PLAYBACK_GUARD_MS - 30L)
            assertEquals(1, turns.size)
            advance(30)
            assertEquals(2, turns.size)
        }
    }

    @Test
    fun `self record turn that never returns fails as busy after the bound`() = runTest(timeout = 30.seconds) {
        rig(this, sdkInt = 32) {
            val turns = mutableListOf<FakeSelfTurn>()
            conversationStt = ConversationStt.SelfRecord { FakeSelfTurn().also { turns += it } }
            start()
            assertEquals(1, turns.size)
            advance(VoiceConversationController.SELF_RECORD_AWAIT_MS - 1)
            assertFalse(turns[0].interrupted)
            advance(1)
            assertTrue(turns[0].interrupted)
            // Timeout is handled as sttFailed: retry once; if it fails again, report that speech was not heard and return to listening.
            assertEquals(listOf("prompt:didNotCatch"), system.started)
            assertEquals(ConversationStatusKey.LISTENING, status)
            assertTrue(chat.sent.isEmpty())

            controller.end()
            runCurrent()
            val ended = tracked.last().second
            assertEquals("busy", ended["failure_kind"])
            assertFalse(ended.containsKey("recognizer_code"))
        }
    }

    @Test
    fun `ended telemetry carries the last counted recognizer failure`() = runTest(timeout = 30.seconds) {
        rig(this) {
            start()
            // First sentence: busy is recovered after an automatic retry and is not counted.
            stt.results += STTResult.Failed(DictationFailure.Recognizer(8), DictationPrimaryAction.Retry)
            stt.results += STTResult.Success("\u4f60\u597d")
            say()
            advance(300)
            assertEquals(listOf("\u4f60\u597d"), chat.sent)
            controller.end()
            runCurrent()
            val recovered = tracked.last().second
            assertFalse(recovered.containsKey("failure_kind"))
            assertFalse(recovered.containsKey("recognizer_code"))
        }
    }

    @Test
    fun `ended telemetry takes the last failure across utterances`() = runTest(timeout = 30.seconds) {
        rig(this) {
            start()
            val network = STTResult.Failed(DictationFailure.Recognizer(2), DictationPrimaryAction.Retry)
            stt.results += network
            stt.results += network
            say()
            advance(300)
            advance(SENTENCE_MS + 10)
            val language = STTResult.Failed(DictationFailure.Recognizer(13), DictationPrimaryAction.Retry)
            stt.results += language
            stt.results += language
            say()
            advance(300)
            assertEquals(4, stt.calls)
            controller.end()
            runCurrent()
            val ended = tracked.last().second
            assertEquals("language_unsupported", ended["failure_kind"])
            assertEquals(13, ended["recognizer_code"])
        }
    }

    @Test
    fun `a thrown file transcription counts as an other failure`() = runTest(timeout = 30.seconds) {
        rig(this) {
            start()
            stt.error = IllegalStateException("boom")
            say()
            advance(300)
            assertEquals(2, stt.calls)
            assertEquals(listOf("prompt:didNotCatch"), system.started)
            assertTrue(chat.sent.isEmpty())
            controller.end()
            runCurrent()
            val ended = tracked.last().second
            assertEquals("other", ended["failure_kind"])
            assertFalse(ended.containsKey("recognizer_code"))
        }
    }

    @Test
    fun `cloud listen engine reports no recognizer failure`() = runTest(timeout = 30.seconds) {
        rig(this) {
            conversationStt = ConversationStt.FromFile(stt, "zh-Hans", providerKind = "openAI")
            start()
            val timeout = STTResult.Failed(DictationFailure.Timeout, DictationPrimaryAction.Retry)
            stt.results += timeout
            stt.results += timeout
            say()
            advance(300)
            assertEquals(2, stt.calls)
            controller.end()
            runCurrent()
            assertFalse(tracked.last().second.containsKey("failure_kind"))
        }
    }

    @Test
    fun `tap orb force end keeps utterance`() = runTest(timeout = 30.seconds) {
        rig(this) {
            start()
            stt.results += STTResult.Success("\u4f60\u597d")
            // Tapping the orb mid-speech: forces this segment to end, and the recording goes to recognition instead of being discarded.
            audio.frames(-60.0, 10)
            audio.frames(-20.0, 30)
            runCurrent()
            controller.tapOrb()
            runCurrent()
            assertEquals(ConversationDisplayState.THINKING, display)
            advance(150)
            assertEquals(1, audio.written.size)
            assertEquals(1, stt.calls)
            assertEquals(listOf("\u4f60\u597d"), chat.sent)
        }
    }

    @Test
    fun `reopen right after close keeps new turn files`() = runTest(timeout = 30.seconds) {
        val dir = kotlin.io.path.createTempDirectory("turns").toFile()
        try {
            val old = File(dir, "turn-1.aac").apply { writeText("old") }
            val io = CoroutineScope(StandardTestDispatcher(testScheduler) + SupervisorJob())
            deleteTurnFilesUpTo(dir, lastTurn = 1, scope = io)
            // The new session has already written into the same directory before the deletion ran.
            val fresh = File(dir, "turn-2.aac").apply { writeText("new") }
            runCurrent()
            assertFalse(old.exists())
            assertTrue(fresh.exists())
            io.cancel()
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun `barge in memory written at end is read by next session`() = runTest(timeout = 30.seconds) {
        val prefs = TestSharedPreferences()
        // The dispatcher used for persistence never runs: the next conversation can only read from memory.
        val disk = TestCoroutineScheduler()
        val memory = SpeakerBargeInMemory({ prefs }, 34, io = StandardTestDispatcher(disk))
        assertFalse(memory.remembersNoSpeakerBargeIn())
        memory.conversationEnded(fellBackToTap = true, exercisedSpeakerBargeIn = true)
        memory.conversationEnded(fellBackToTap = true, exercisedSpeakerBargeIn = true)
        val loaded = async { memory.load() }
        runCurrent()
        assertTrue(loaded.isCompleted)
        assertTrue(loaded.getCompleted())
        assertFalse(prefs.getBoolean("noSpeakerBargeIn", false))
        disk.runCurrent()
        assertTrue(prefs.getBoolean("noSpeakerBargeIn", false))
        assertTrue(SpeakerBargeInMemory({ prefs }, 34, io = Dispatchers.Unconfined).remembersNoSpeakerBargeIn())

        // A conversation that ended before the first read is counted too.
        val early = SpeakerBargeInMemory({ TestSharedPreferences() }, 34, io = StandardTestDispatcher(disk))
        early.conversationEnded(fellBackToTap = true, exercisedSpeakerBargeIn = true)
        early.conversationEnded(fellBackToTap = true, exercisedSpeakerBargeIn = true)
        assertTrue(early.remembersNoSpeakerBargeIn())
    }

    @Test
    fun frames_after_close_not_recorded() {
        val live = AtomicBoolean(true)
        val recorder = TurnRecorder()
        val heard = mutableListOf<Long>()
        val listener = object : ConversationAudioListener {
            override fun onFrame(index: Long, db: Double) {
                heard += index
            }

            override fun onRouteChanged(route: ConversationRoute, privateRouteRemoved: Boolean) = Unit

            override fun onBecomingNoisy() = Unit

            override fun onInterruption(began: Boolean) = Unit

            override fun onFocusLost() = Unit

            override fun onCaptureFailed() = Unit
        }
        val chunker = liveFrameChunker(live, recorder, listener)
        val frame = ShortArray(ConversationFrames.FRAME_SAMPLES) { 1000 }
        recorder.begin(0)
        chunker.add(frame, frame.size)
        // close sets live to false; whole and partial frames the capture thread reads while winding down on IO no longer reach the recorder or call back
        chunker.add(frame, frame.size / 2)
        live.set(false)
        chunker.add(frame, frame.size / 2)
        chunker.add(frame, frame.size)
        assertEquals(listOf(0L), heard)
        assertEquals(ConversationFrames.FRAME_SAMPLES, recorder.end(Long.MAX_VALUE)?.size)
    }

    // ── live ──

    @Test
    fun `live opens on speech start with the preroll first and partials show as caption`() = runTest(timeout = 30.seconds) {
        rig(this) {
            useLive()
            start()
            audio.frames(-60.0, 10)
            audio.frames(-20.0, 30)
            runCurrent()
            val live = lives.single()
            // Before the session opens (including pre-recorded audio), backfill first; later frames go straight into the session.
            assertTrue(live.backlog.first().all { it == PREROLL_MARK })
            audio.frames(-20.0, 5)
            runCurrent()
            assertEquals(5 * FRAME_SAMPLES, live.liveSamples)

            live.transcript.value = LiveTranscript(listOf("\u4f60\u597d"), "\u4e16")
            runCurrent()
            assertEquals(ConversationStatusKey.CAPTION, status)
            // The assembled text is unchanged (the partial only added whitespace): no event is dispatched; the clock is read once per dispatch.
            val reads = clockReads
            live.transcript.value = LiveTranscript(listOf("\u4f60\u597d"), "\u4e16 ")
            runCurrent()
            assertEquals(reads, clockReads)

            live.result.complete(STTResult.Success("\u4f60\u597d\u4e16\u754c"))
            audio.frames(-60.0, 30)
            advance(2_000)
            assertTrue(live.stopped)
            assertEquals(listOf("\u4f60\u597d\u4e16\u754c"), chat.sent)
            assertEquals(0, stt.calls)
            assertTrue(audio.written.isEmpty())
        }
    }

    @Test
    fun `continued speech keeps the same live session and its audio`() = runTest(timeout = 30.seconds) {
        rig(this) {
            useLive()
            start()
            audio.frames(-60.0, 10)
            audio.frames(-20.0, 30)
            runCurrent()
            val live = lives.single()
            live.transcript.value = LiveTranscript(emptyList(), "\u6211\u60f3，")
            runCurrent()
            audio.frames(-60.0, 30)
            runCurrent()
            // Comma ending while waiting for the speaker to continue: this sentence has not yet been handed to recognition.
            assertFalse(live.stopped)
            val before = live.liveSamples
            audio.frames(-20.0, 20)
            runCurrent()
            assertEquals(1, lives.size)
            assertTrue(live.liveSamples > before)

            live.transcript.value = LiveTranscript(emptyList(), "\u6211\u60f3，\u660e\u5929\u53bb")
            live.result.complete(STTResult.Success("\u6211\u60f3，\u660e\u5929\u53bb"))
            audio.frames(-60.0, 30)
            advance(2_000)
            assertEquals(1, lives.size)
            assertEquals(listOf("\u6211\u60f3，\u660e\u5929\u53bb"), chat.sent)
            assertEquals(0, stt.calls)
        }
    }

    @Test
    fun `live result that dropped audio falls back to the same audio through the file`() = runTest(timeout = 30.seconds) {
        rig(this) {
            useLive()
            start()
            stt.results += STTResult.Success("\u4eca\u5929\u5929\u6c14\u4e0d\u9519")
            audio.frames(-60.0, 10)
            audio.frames(-20.0, 30)
            runCurrent()
            lives.single().result.complete(STTResult.Success("\u4eca\u5929\u5929\u6c14", droppedAudio = true))
            audio.frames(-60.0, 30)
            advance(2_000)
            assertTrue(lives.single().stopped)
            assertEquals(1, audio.written.size)
            assertEquals(1, stt.calls)
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u4e0d\u9519"), chat.sent)
        }
    }

    @Test
    fun `live result that dropped audio stays when the file is empty`() = runTest(timeout = 30.seconds) {
        rig(this) {
            useLive()
            start()
            stt.results += STTResult.Success("")
            audio.frames(-60.0, 10)
            audio.frames(-20.0, 30)
            runCurrent()
            lives.single().result.complete(STTResult.Success("\u4eca\u5929\u5929\u6c14", droppedAudio = true))
            audio.frames(-60.0, 30)
            advance(2_000)
            assertEquals(1, stt.calls)
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14"), chat.sent)
        }
    }

    @Test
    fun `empty live result falls back to the same audio through the file`() = runTest(timeout = 30.seconds) {
        rig(this) {
            useLive()
            start()
            stt.results += STTResult.Success("\u4f60\u597d")
            audio.frames(-60.0, 10)
            audio.frames(-20.0, 30)
            runCurrent()
            lives.single().result.complete(STTResult.Success(""))
            audio.frames(-60.0, 30)
            advance(150)
            assertTrue(lives.single().stopped)
            assertEquals(1, audio.written.size)
            assertEquals(1, stt.calls)
            assertEquals(listOf("\u4f60\u597d"), chat.sent)
        }
    }

    @Test
    fun `live that never answers is ended after the bound and the file transcribes`() = runTest(timeout = 30.seconds) {
        rig(this) {
            useLive()
            start()
            stt.results += STTResult.Success("\u4f60\u597d")
            say()
            val live = lives.single()
            assertTrue(live.stopped)
            advance(VoiceConversationController.LIVE_RESULT_TIMEOUT_MS - 10)
            assertEquals(0, stt.calls)
            advance(150)
            assertTrue(live.cancelled)
            assertEquals(1, stt.calls)
            assertEquals(listOf("\u4f60\u597d"), chat.sent)
        }
    }

    @Test
    fun `failed live open falls back to the file`() = runTest(timeout = 30.seconds) {
        rig(this) {
            useLive()
            openLive = { error("no recognizer") }
            start()
            stt.results += STTResult.Success("\u4f60\u597d")
            say()
            advance(150)
            assertEquals(1, stt.calls)
            assertEquals(listOf("\u4f60\u597d"), chat.sent)
        }
    }

    @Test
    fun `abandoned sentence ends its live session at once`() = runTest(timeout = 30.seconds) {
        rig(this) {
            useLive()
            start()
            // Too short and dropped (vadDiscarded).
            audio.frames(-60.0, 10)
            audio.frames(-20.0, 8)
            runCurrent()
            val discarded = lives.single()
            audio.frames(-60.0, 30)
            runCurrent()
            assertTrue(discarded.cancelled)
            assertFalse(discarded.stopped)

            // Speech ends halfway: end the conversation.
            audio.frames(-20.0, 30)
            runCurrent()
            val open = lives.last()
            assertEquals(2, lives.size)
            controller.end()
            runCurrent()
            // Ending does not wait for live results; the unfinished segment still goes through file recognition as a draft, as before.
            assertTrue(open.cancelled)
            assertFalse(open.stopped)
        }
    }

    // ── hostFeedback: haptic / light jitter executed by the host from the reducer; captions readable; prompt start and stop enter echo matching ──

    @Test
    fun `hostFeedback start heard and end effects reach the host as haptic events`() = runTest(timeout = 30.seconds) {
        rig(this) {
            start()
            assertEquals(listOf(VoiceConversationEvent.Haptic(HapticKind.LIGHT)), events.filterIsInstance<VoiceConversationEvent.Haptic>())
            stt.results += STTResult.Success("\u4f60\u597d")
            say()
            advance(150)
            assertEquals(listOf("\u4f60\u597d"), chat.sent)
            assertEquals(2, events.count { it is VoiceConversationEvent.Haptic })
            controller.end()
            runCurrent()
            assertEquals(3, events.count { it is VoiceConversationEvent.Haptic })
        }
    }

    @Test
    fun `hostFeedback ignored echo barge-in nudges the orb`() = runTest(timeout = 30.seconds) {
        rig(this) {
            intoSpeaking()
            assertTrue(events.none { it is VoiceConversationEvent.NudgeOrb })
            stt.results += STTResult.Success("\u4eca\u5929\u5929\u6c14\u5f88\u597d")
            bargeIn()
            advance(150)
            assertEquals(listOf("\u4f60\u597d"), chat.sent)
            assertEquals(1, events.count { it is VoiceConversationEvent.NudgeOrb })
        }
    }

    @Test
    fun `hostFeedback caption follows the live partial and clears after the turn`() = runTest(timeout = 30.seconds) {
        rig(this) {
            useLive()
            start()
            assertEquals("", controller.caption.value)
            audio.frames(-60.0, 10)
            audio.frames(-20.0, 30)
            runCurrent()
            val live = lives.single()
            live.transcript.value = LiveTranscript(listOf("\u4f60\u597d"), "\u4e16")
            runCurrent()
            assertEquals(ConversationStatusKey.CAPTION, status)
            assertEquals("\u4f60\u597d\u4e16", controller.caption.value)
            live.transcript.value = LiveTranscript(listOf("\u4f60\u597d"), "\u4e16\u754c")
            runCurrent()
            assertEquals("\u4f60\u597d\u4e16\u754c", controller.caption.value)

            live.result.complete(STTResult.Success("\u4f60\u597d\u4e16\u754c"))
            audio.frames(-60.0, 30)
            advance(2_000)
            assertEquals(listOf("\u4f60\u597d\u4e16\u754c"), chat.sent)
            assertEquals("", controller.caption.value)
        }
    }

    @Test
    fun `hostFeedback a spoken prompt joins the echo pool and its end opens the echo window`() = runTest(timeout = 30.seconds) {
        rig(this) {
            promptTexts[VoicePrompt.DidNotCatch] = "\u6211\u6ca1\u6709\u542c\u6e05\u695a\u8bf7\u518d\u8bf4\u4e00\u904d"
            start()
            val failed = STTResult.Failed(DictationFailure.Network, DictationPrimaryAction.Retry)
            stt.results += failed
            stt.results += failed
            say()
            advance(300)
            assertEquals(listOf("\u6211\u6ca1\u6709\u542c\u6e05\u695a\u8bf7\u518d\u8bf4\u4e00\u904d"), system.started)
            advance(SENTENCE_MS + 10)
            assertEquals(listOf("\u6211\u6ca1\u6709\u542c\u6e05\u695a\u8bf7\u518d\u8bf4\u4e00\u904d"), system.finished)
            assertFalse(audio.paused)

            // The prompt has just finished playing and the speaker picks up its own prompt: ignored as echo, no send, the orb gets a light jitter.
            stt.results += STTResult.Success("\u6211\u6ca1\u6709\u542c\u6e05\u695a\u8bf7\u518d\u8bf4\u4e00\u904d")
            say()
            advance(150)
            assertTrue(chat.sent.isEmpty())
            assertEquals(ConversationStatusKey.LISTENING, status)
            assertEquals(1, events.count { it is VoiceConversationEvent.NudgeOrb })
        }
    }

    // ── hostTiming: host timing from the fixture rules.host ──

    @Test
    fun `hostTiming the real playback end opens the echo guard`() = runTest(timeout = 30.seconds) {
        rig(this) {
            system.tailMs = 400
            start()
            stt.results += STTResult.Success("\u4f60\u597d")
            say()
            advance(GATE_AFTER_SPEECH_END_MS)
            reply(VoiceReplyEvent.Text("\u597d\u7684。"))
            reply(VoiceReplyEvent.Completed())
            advance(SENTENCE_MS + 10)
            assertEquals(ConversationStatusKey.LISTENING, status)
            stt.results += STTResult.Success("\u660e\u5929\u89c1")

            // After 900 ms, a 140 ms sound plus a 200 ms light sound: by the time speak returns the aftersound window has passed (a segment forms), but by actual speech end (400 ms later) it is still inside the window, so no segment forms.
            audio.frames(-60.0, 45)
            audio.frames(-20.0, 7)
            audio.frames(-50.0, 10)
            audio.frames(-60.0, 30)
            runCurrent()
            advance(150)
            assertEquals(ConversationStatusKey.LISTENING, status)
            assertEquals(1, stt.calls)
        }
    }

    @Test
    fun `hostTiming the gap between sentences stays a candidate and the next sentence opens no new grace`() =
        runTest(timeout = 30.seconds) {
            rig(this) {
                intoSpeaking("\u7b2c\u4e00\u53e5。")
                audio.frames(-60.0, 60) // The 1 s grace period from the first sentence start has elapsed
                advance(SENTENCE_MS + 10)
                assertEquals(listOf("\u7b2c\u4e00\u53e5。"), system.finished)
                assertEquals(ConversationDisplayState.SPEAKING, display)

                // The gap between sentences is still an interruption candidate: 200 ms is not enough for the candidate threshold (normally 120 ms is enough to speak).
                audio.frames(-20.0, 10)
                audio.frames(-60.0, 30)
                runCurrent()
                assertEquals(ConversationDisplayState.SPEAKING, display)
                assertEquals(1, stt.calls)

                // The next sentence's playback does not reopen the grace period: any speech starts a candidate.
                reply(VoiceReplyEvent.Text("\u7b2c\u4e00\u53e5。\u7b2c\u4e8c\u53e5。\u4e0b"))
                assertEquals(listOf("\u7b2c\u4e00\u53e5。", "\u7b2c\u4e8c\u53e5。"), system.started)
                audio.frames(-20.0, 20)
                audio.frames(-60.0, 30)
                runCurrent()
                assertEquals(1, system.pauses)
            }
        }

    @Test
    fun `hostTiming resuming playback opens a new grace`() = runTest(timeout = 30.seconds) {
        rig(this) {
            intoSpeaking()
            stt.results += STTResult.Success("\u4eca\u5929\u5929\u6c14\u5f88\u597d")
            bargeIn()
            assertEquals(1, system.pauses)
            advance(150)
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d。", "\u4eca\u5929\u5929\u6c14\u5f88\u597d。"), system.started)

            // Sound within 1 s after resumption lands in the new grace period.
            audio.frames(-20.0, 20)
            audio.frames(-60.0, 30)
            runCurrent()
            assertEquals(1, system.pauses)

            // The same sound after the grace period is a candidate.
            audio.frames(-20.0, 20)
            audio.frames(-60.0, 30)
            runCurrent()
            assertEquals(2, system.pauses)
        }
    }

    @Test
    fun `hostTiming two prompts go after the current sentence first in first out`() = runTest(timeout = 30.seconds) {
        rig(this) {
            intoSpeaking()
            reply(VoiceReplyEvent.Text("\u4eca\u5929\u5929\u6c14\u5f88\u597d。\u4e0b\u5348\u6709\u96e8。\u665a"))
            promptTexts[VoicePrompt.ApprovalNeeded] = "\u63d0\u793a\u4e00"
            reply(VoiceReplyEvent.ApprovalPending(true))
            reply(VoiceReplyEvent.ApprovalPending(false))
            promptTexts[VoicePrompt.ApprovalNeeded] = "\u63d0\u793a\u4e8c"
            reply(VoiceReplyEvent.ApprovalPending(true))
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d。"), system.started)
            repeat(3) { advance(SENTENCE_MS + 10) }
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d。", "\u63d0\u793a\u4e00", "\u63d0\u793a\u4e8c", "\u4e0b\u5348\u6709\u96e8。"), system.started)
        }
    }

    @Test
    fun `hostTiming speaking again after the screen reader starts is a new sentence`() = runTest(timeout = 30.seconds) {
        rig(this) {
            start()
            audio.frames(-60.0, 10)
            audio.frames(-20.0, 20)
            runCurrent()
            assertTrue(audio.turnOpen)

            controller.screenReaderSpeaking(true)
            runCurrent()
            assertFalse(audio.turnOpen)
            controller.screenReaderSpeaking(false)
            runCurrent()

            // The sentence before the screen reader is not merged in: speaking again starts a fresh segment, which is transcribed and emitted.
            stt.results += STTResult.Success("\u4f60\u597d")
            audio.frames(-20.0, 20)
            audio.frames(-60.0, 30)
            runCurrent()
            advance(150)
            assertEquals(listOf("\u4f60\u597d"), chat.sent)
        }
    }

    @Test
    fun `turn tap gets the preroll first then each frame until the turn ends`() {
        val recorder = TurnRecorder()
        val got = mutableListOf<Short>()
        val sink = PcmSink { samples, count -> repeat(count) { got += samples[it] } }
        recorder.onFrame(0, shortArrayOf(1))
        recorder.onFrame(1, shortArrayOf(2))
        recorder.begin(1)
        recorder.onFrame(2, shortArrayOf(3))
        recorder.tap(sink)
        recorder.onFrame(3, shortArrayOf(4))
        recorder.end(3)
        recorder.onFrame(4, shortArrayOf(5))
        assertEquals(listOf<Short>(2, 3, 4), got)
    }
}
