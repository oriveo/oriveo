package ai.oriveo.community.core.voice.conversation

import ai.oriveo.community.core.voice.DictationFailure
import ai.oriveo.community.core.voice.DictationLevelMeter
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
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
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
        val earcons = mutableListOf<EarconKind>()
        val written = mutableListOf<Int>()
        var writeDelayMs = 0L

        // Like the real session: close clears the turn files, drafts live elsewhere.
        private val turnFiles = mutableSetOf<File>()
        private val draftFiles = mutableSetOf<File>()

        fun alive(file: File) = file in turnFiles || file in draftFiles

        override fun open(listener: ConversationAudioListener, capture: Boolean) {
            this.listener = listener
            openedWithCapture = capture
        }

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
            return ShortArray(320)
        }

        override fun cancelTurn() {
            turnOpen = false
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
                if (!mutedNow && !paused) listener.onFrame(nextFrame++, db)
            }
        }
    }

    private class FakeStt : STTEngine {
        override val engineName = "fake"
        val results = ArrayDeque<STTResult>()
        var calls = 0
        var alive: (File) -> Boolean = { true }

        override suspend fun transcribe(segment: STTSegment, language: String?): STTResult {
            calls++
            delay(100)
            // A file deleted before it is read transcribes to nothing.
            if (!alive(segment.aac)) return STTResult.Success("")
            return results.removeFirstOrNull() ?: STTResult.Success("")
        }
    }

    private class FakeChat : VoiceConversationChatPort {
        val sent = mutableListOf<String>()
        var cancels = 0
        val flow = MutableSharedFlow<VoiceReplyEvent>(extraBufferCapacity = 64)
        override val replies: Flow<VoiceReplyEvent> = flow

        override suspend fun send(text: String): Boolean {
            sent += text
            return true
        }

        override fun cancel() {
            cancels++
        }
    }

    private class FakeTts(override val isCloud: Boolean, private val name: String) : ConversationTts {
        val started = mutableListOf<String>()
        val finished = mutableListOf<String>()
        var cancelled = 0
        var released = 0
        var fail = false

        override fun release() {
            released++
        }

        override suspend fun speak(text: String, onLevel: (Float) -> Unit): TtsOutcome {
            started += text
            if (fail) return TtsOutcome.FAILED
            try {
                onLevel(0.5f)
                delay(SENTENCE_MS)
            } catch (e: kotlinx.coroutines.CancellationException) {
                cancelled++
                throw e
            }
            finished += text
            return TtsOutcome.DONE
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
        override var onRmsDb: ((Float) -> Unit)? = null
        override suspend fun await(): STTResult = result.await()
        override fun interrupt() {
            interrupted = true
            result.complete(STTResult.Success(""))
        }
    }

    private class Rig(
        val test: TestScope,
        sdkInt: Int = 34,
        immediate: Boolean = false,
        io: CoroutineDispatcher? = null,
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

        init {
            stt.alive = audio::alive
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
        val controller = VoiceConversationController(
            audio = audio,
            sttSource = { conversationStt },
            ttsSource = {
                ConversationVoices(if (useCloud) cloud else system, system, providerDisplayName = "OpenAI")
            },
            foreground = foreground,
            environment = environment,
            memory = memory,
            prompt = { p ->
                when (p) {
                    VoicePrompt.DidNotCatch -> "prompt:didNotCatch"
                    VoicePrompt.ApprovalNeeded -> "prompt:approvalNeeded"
                    is VoicePrompt.Placeholder -> "prompt:${p.kind.rawValue}"
                }
            },
            scope = scope,
            clock = {
                clockReads++
                test.testScheduler.currentTime
            },
            io = io ?: dispatcher,
            deleteFile = { file ->
                synchronized(deletes) { deletes += file to Thread.currentThread() }
                onDelete()
            },
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
        block: Rig.() -> Unit,
    ) {
        val r = Rig(test, sdkInt, immediate, io)
        try {
            r.block()
        } finally {
            r.close()
        }
    }

    /** Speaking a reply with [sentence] in progress, on the speaker. */
    private fun Rig.intoSpeaking(sentence: String = "\u4eca\u5929\u5929\u6c14\u5f88\u597d\u3002") {
        start()
        stt.results += STTResult.Success("\u4f60\u597d")
        say()
        advance(150)
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

            reply(VoiceReplyEvent.Text("\u4eca\u5929\u5929\u6c14\u5f88\u597d\u3002\u4e0b"))
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d\u3002"), system.started)
            reply(VoiceReplyEvent.Text("\u4eca\u5929\u5929\u6c14\u5f88\u597d\u3002\u4e0b\u5348\u6709\u96e8\u3002"))
            reply(VoiceReplyEvent.Completed())
            advance(SENTENCE_MS * 2 + 10)
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d\u3002", "\u4e0b\u5348\u6709\u96e8\u3002"), system.finished)
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
            intoSpeaking("\u7b2c\u4e00\u53e5\u3002")
            reply(VoiceReplyEvent.Text("\u7b2c\u4e00\u53e5\u3002\u7b2c\u4e8c"))
            reply(VoiceReplyEvent.Text("\u7b2c\u4e00\u53e5\u3002\u7b2c\u4e8c\u53e5"))
            advance(SENTENCE_MS + 10)
            assertEquals(listOf("\u7b2c\u4e00\u53e5\u3002"), system.started)
            reply(VoiceReplyEvent.Text("\u7b2c\u4e00\u53e5\u3002\u7b2c\u4e8c\u53e5\u3002\u7b2c\u4e09"))
            reply(VoiceReplyEvent.Completed())
            advance(SENTENCE_MS * 3)
            assertEquals(listOf("\u7b2c\u4e00\u53e5\u3002", "\u7b2c\u4e8c\u53e5\u3002", "\u7b2c\u4e09"), system.started)
        }
    }

    @Test
    fun `echo barge-in resumes the sentence without sending`() = runTest(timeout = 30.seconds) {
        rig(this) {
            intoSpeaking()
            stt.results += STTResult.Success("\u4eca\u5929\u5929\u6c14\u5f88\u597d")
            bargeIn()
            assertEquals(1, system.cancelled)
            advance(150)
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d\u3002", "\u4eca\u5929\u5929\u6c14\u5f88\u597d\u3002"), system.started)
            assertEquals(listOf("\u4f60\u597d"), chat.sent)
            assertEquals(0, chat.cancels)
            assertEquals(ConversationStatusKey.SPEAKING, status)
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
            stt.results += STTResult.Success("\u7b49\u4e00\u4e0b\uff0c\u6362\u4e2a\u8bdd\u9898")
            bargeIn()
            advance(150)
            assertEquals(1, chat.cancels)
            assertEquals(listOf("\u4f60\u597d", "\u7b49\u4e00\u4e0b\uff0c\u6362\u4e2a\u8bdd\u9898"), chat.sent)
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
            reply(VoiceReplyEvent.Text("\u4eca\u5929\u5929\u6c14\u5f88\u597d\u3002\u4e0b\u5348\u6709\u96e8\u3002\u665a"))
            reply(VoiceReplyEvent.ApprovalPending(true))
            // The sentence being spoken is not interrupted, and the prompt does not start speaking at the same time.
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d\u3002"), system.started)
            assertEquals(0, system.cancelled)
            assertFalse(audio.paused)
            advance(SENTENCE_MS + 10)
            // The prompt is inserted before the next queued sentence.
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d\u3002"), system.finished)
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d\u3002", "prompt:approvalNeeded"), system.started)
            assertTrue(audio.paused)
            advance(SENTENCE_MS + 10)
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d\u3002", "prompt:approvalNeeded", "\u4e0b\u5348\u6709\u96e8\u3002"), system.started)
            assertFalse(audio.paused)
        }
    }

    @Test
    fun `synchronous speak failure does not wedge playback`() = runTest(timeout = 30.seconds) {
        rig(this, immediate = true) {
            system.fail = true
            intoSpeaking()
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d\u3002"), system.started)
            system.fail = false
            reply(VoiceReplyEvent.Text("\u4eca\u5929\u5929\u6c14\u5f88\u597d\u3002\u4e0b\u5348\u6709\u96e8\u3002\u665a"))
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d\u3002", "\u4e0b\u5348\u6709\u96e8\u3002"), system.started)
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
            assertEquals(emptyList<EarconKind>(), audio.earcons)
            advance(1)
            assertEquals(t0 + VoiceConversationConstants.IDLE_TIMEOUT_MS, currentTime)
            assertEquals(listOf(EarconKind.END), audio.earcons)
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
            assertEquals(listOf(EarconKind.END), audio.earcons)
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
            assertEquals(emptyList<EarconKind>(), audio.earcons)
            advance(1)
            assertEquals(activityAt + VoiceConversationConstants.IDLE_TIMEOUT_MS, currentTime)
            assertEquals(listOf(EarconKind.END), audio.earcons)
            assertEquals(VoiceConversationEvent.Ended(EndReason.IDLE, null), events.last())
        }
    }

    @Test
    fun `thinking earcon after three seconds`() = runTest(timeout = 30.seconds) {
        rig(this) {
            start()
            stt.results += STTResult.Success("\u4f60\u597d")
            say()
            advance(VoiceConversationConstants.THINKING_EARCON_MS - 1)
            assertEquals(emptyList<EarconKind>(), audio.earcons)
            advance(1)
            assertEquals(listOf(EarconKind.THINKING), audio.earcons)
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
            assertEquals(1, system.cancelled)
            assertTrue(audio.paused)
            audio.listener.onInterruption(began = false)
            reply(VoiceReplyEvent.Text("\u4eca\u5929\u5929\u6c14\u5f88\u597d\u3002\u4e0b\u5348\u6709\u96e8\u3002"))
            reply(VoiceReplyEvent.Completed())
            advance(SENTENCE_MS * 3)
            assertFalse(audio.paused)
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d\u3002"), system.started)
            assertEquals(ConversationStatusKey.LISTENING, status)
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
            reply(VoiceReplyEvent.Text("\u4eca\u5929\u5929\u6c14\u5f88\u597d\u3002\u4e0b\u5348\u6709\u96e8\u3002"))
            reply(VoiceReplyEvent.Completed())
            advance(SENTENCE_MS * 3)
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d\u3002"), system.started)
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
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d\u3002"), cloud.started)
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d\u3002"), system.started)
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
            reply(VoiceReplyEvent.Text("\u4eca\u5929\u5929\u6c14\u5f88\u597d\u3002\u4e0b"))
            assertEquals(ConversationStatusKey.SPEAKING_TAP_TO_INTERRUPT, status)
            assertEquals(1, turns.size)

            // Completing flushes the trailing unterminated text as a final sentence: two sentences play.
            reply(VoiceReplyEvent.Completed())
            advance(SENTENCE_MS * 2 + 10)
            assertEquals(ConversationStatusKey.LISTENING, status)
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
            reply(VoiceReplyEvent.Text("\u4eca\u5929\u5929\u6c14\u5f88\u597d\u3002\u4e0b\u5348\u6709\u96e8\u3002"))
            reply(VoiceReplyEvent.Completed())
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d\u3002"), system.started)
            assertEquals(ConversationStatusKey.LISTENING, status)
        }
    }

    @Test
    fun `level updates are throttled to fifteen per second`() = runTest(timeout = 30.seconds) {
        rig(this) {
            start()
            val seen = mutableListOf<Float>()
            val job = scope.launch { controller.level.collect { seen += it } }
            runCurrent()
            audio.frames(-30.0, 1)
            runCurrent()
            audio.frames(-10.0, 5)
            runCurrent()
            assertEquals(0.5f, controller.level.value, 0.001f)
            advance(70)
            audio.frames(-10.0, 1)
            runCurrent()
            assertEquals(ConversationFrames.levelFromDb(-10.0), controller.level.value, 0.001f)
            job.cancel()
        }
    }

    private companion object {
        const val SENTENCE_MS = 1_000L
    }

    // ── Message playback and screen reader ──

    // Regression: stopping playback (here, ending via barge-in) cleared the whole queue and dropped the approval prompt queued ahead of the next sentence.
    @Test
    fun `approval prompt survives stop playback`() = runTest(timeout = 30.seconds) {
        rig(this) {
            intoSpeaking()
            reply(VoiceReplyEvent.Text("\u4eca\u5929\u5929\u6c14\u5f88\u597d\u3002\u4e0b\u5348\u6709\u96e8\u3002\u665a"))
            reply(VoiceReplyEvent.ApprovalPending(true))
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d\u3002"), system.started)
            audio.listener.onInterruption(began = true)
            runCurrent()
            audio.listener.onInterruption(began = false)
            runCurrent()
            advance(SENTENCE_MS + 10)
            // The reply sentence is stopped, and the prompt is still spoken.
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d\u3002", "prompt:approvalNeeded"), system.started)
            assertEquals(listOf("prompt:approvalNeeded"), system.finished)
            advance(SENTENCE_MS + 10)
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d\u3002", "prompt:approvalNeeded"), system.started)
        }
    }

    // Regression: after one cloud failure the whole conversation switched to the system voice, and later replies no longer tried the cloud.
    @Test
    fun `cloud fallback lasts one reply`() = runTest(timeout = 30.seconds) {
        rig(this) {
            useCloud = true
            cloud.fail = true
            intoSpeaking()
            runCurrent()
            reply(VoiceReplyEvent.Text("\u4eca\u5929\u5929\u6c14\u5f88\u597d\u3002\u4e0b\u5348\u6709\u96e8\u3002"))
            reply(VoiceReplyEvent.Completed())
            advance(SENTENCE_MS * 2 + 10)
            assertEquals(ConversationStatusKey.LISTENING, status)
            // The rest of the failed reply stays on the system voice.
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d\u3002"), cloud.started)
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d\u3002", "\u4e0b\u5348\u6709\u96e8\u3002"), system.started)

            stt.results += STTResult.Success("\u518d\u6765")
            say()
            advance(150)
            // While streaming, a sentence only closes once text follows its ending punctuation (prefix-stable segmentation); the last sentence is spoken at Completed.
            reply(VoiceReplyEvent.Text("\u597d\u7684\u3002\u518d"))
            runCurrent()
            // The next reply tries cloud again; the fallback notice stays once per conversation.
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d\u3002", "\u597d\u7684\u3002"), cloud.started)
            assertEquals(listOf("\u4eca\u5929\u5929\u6c14\u5f88\u597d\u3002", "\u4e0b\u5348\u6709\u96e8\u3002", "\u597d\u7684\u3002"), system.started)
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
    fun `speech start dropped by reducer records nothing`() = runTest(timeout = 30.seconds) {
        rig(this, immediate = true) {
            start()
            stt.results += STTResult.Success("\u4f60\u597d")
            say()
            assertEquals(ConversationDisplayState.THINKING, display)
            assertEquals(1, audio.written.size)
            audio.frames(-60.0, 10)
            audio.frames(-20.0, 30)
            runCurrent()
            assertFalse(audio.turnOpen)
            audio.frames(-60.0, 30)
            runCurrent()
            assertEquals(1, audio.written.size)
        }
    }

    @Test
    fun `playing an old message pauses capture speaks it with the conversation voice and listens again`() = runTest(timeout = 30.seconds) {
        rig(this) {
            start()
            controller.playMessage("m1", "\u7b2c\u4e00\u53e5\u3002\u7b2c\u4e8c\u53e5\u3002")
            runCurrent()
            assertEquals(listOf("\u7b2c\u4e00\u53e5\u3002"), system.started)
            advance(SENTENCE_MS * 2 + 10)
            assertEquals(listOf("\u7b2c\u4e00\u53e5\u3002", "\u7b2c\u4e8c\u53e5\u3002"), system.finished)
            assertEquals(ConversationStatusKey.LISTENING, status)
            // Ignored outside listening, like the reducer.
            stt.results += STTResult.Success("\u4f60\u597d")
            say()
            controller.playMessage("m2", "\u4e0d\u8be5\u64ad\u3002")
            runCurrent()
            assertFalse(system.started.contains("\u4e0d\u8be5\u64ad\u3002"))
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
        reply(VoiceReplyEvent.Text("\u597d\u7684\u3002"))
        reply(VoiceReplyEvent.Completed())
        advance(SENTENCE_MS * 2 + 10)
        assertEquals(ConversationStatusKey.LISTENING, status)
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
}
