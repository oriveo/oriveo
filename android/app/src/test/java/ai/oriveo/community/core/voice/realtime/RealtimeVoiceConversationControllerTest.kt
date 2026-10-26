package ai.oriveo.community.core.voice.realtime

import ai.oriveo.community.core.context.ContextConversation
import ai.oriveo.community.core.context.RealtimeSessionFingerprint
import ai.oriveo.community.core.context.RealtimeSessionInput
import ai.oriveo.community.core.context.assembleRealtimeSession
import ai.oriveo.community.core.data.repository.PlannedRealtimeSession
import ai.oriveo.community.core.data.repository.RealtimeTransportInput
import ai.oriveo.community.core.voice.conversation.ConversationDisplayState
import ai.oriveo.community.core.voice.conversation.ConversationStatusKey
import ai.oriveo.community.core.voice.conversation.EarconKind
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveSessionExpiredException
import ai.oriveo.community.core.voice.realtime.wire.RealtimeSessionControl
import ai.oriveo.community.core.voice.realtime.wire.RealtimeTransport
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.coroutines.ContinuationInterceptor
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.EmptyCoroutineContext
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.consumeAsFlow
import kotlinx.coroutines.job
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** RealtimeVoiceConversationController: fake connection + fake audio + real driver + real reducer. */
@OptIn(ExperimentalCoroutinesApi::class)
class RealtimeVoiceConversationControllerTest {

    private class FakeConnection : RealtimeTransport, RealtimeSessionControl {
        val events = Channel<RealtimeSessionEvent>(Channel.UNLIMITED)
        val sent = mutableListOf<ByteArray>()
        var closes = 0
        var onClose: (() -> Unit)? = null
        var opens = 0
        override val kind = RealtimeTransportKind.GeminiLive

        override fun openRealtimeSession(transport: RealtimeTransportInput): Flow<RealtimeSessionEvent> {
            opens++
            return events.consumeAsFlow()
        }

        override fun sendAudio(pcm: ByteArray) {
            sent += pcm
        }

        override fun truncate(itemId: String?, contentIndex: Int, playedMs: Double) = Unit

        override fun close() {
            onClose?.invoke()
            closes++
            events.close()
        }
    }

    private class FakeAudio : RealtimeAudioIO {
        val calls = mutableListOf<String>()
        var playing = false
        var onFrame: ((ByteArray) -> Unit)? = null
        var onInterruption: (() -> Unit)? = null
        private var drainedCallback: (() -> Unit)? = null
        val earcons = mutableListOf<EarconKind>()

        var starts = 0
        var stops = 0
        var stopThread: Thread? = null

        // Same as AndroidRealtimeAudio: single use, start after stop throws IllegalStateException
        override fun start(onFrame: (ByteArray) -> Unit, onInterruption: () -> Unit) {
            check(stops == 0) { "RealtimeAudioIO is single-use" }
            starts++
            calls += "start"
            this.onFrame = onFrame
            this.onInterruption = onInterruption
        }

        override fun enqueue(pcm16: ByteArray, itemId: String) {
            calls += "enqueue"
            playing = true
        }

        override fun playedMs(itemId: String): Long = 0L

        override val isPlaying: Boolean
            get() = playing

        override fun setOnDrained(onDrained: () -> Unit) {
            drainedCallback = onDrained
        }

        /** Simulates the player's drained callback (AudioTrack marker reached). */
        fun drain() {
            playing = false
            drainedCallback?.invoke()
        }

        override fun stopPlayback() {
            calls += "stopPlayback"
            playing = false
        }

        override fun stop() {
            stops++
            stopThread = Thread.currentThread()
            calls += "stop"
        }

        override suspend fun playEarcon(kind: EarconKind) {
            earcons += kind
        }
    }

    private class Sink : RealtimeConversationSink {
        val calls = mutableListOf<String>()

        override fun appendUser(text: String) {
            calls += "user:$text"
        }

        override fun appendAssistant(text: String) {
            calls += "assistant:$text"
        }
    }

    private val plan: PlannedRealtimeSession = PlannedRealtimeSession.from(
        assembleRealtimeSession(
            RealtimeSessionInput(
                contextWindow = 128_000,
                conversation = ContextConversation(id = "c1", useMemory = false),
                history = emptyList(),
            ),
        ),
    )!!

    private class Rig(
        val connection: FakeConnection,
        val audio: FakeAudio,
        val sink: Sink,
        val scope: CoroutineScope,
        val controller: RealtimeVoiceConversationController<FakeConnection>,
    ) {
        val errors = mutableListOf<String?>()
        val ended = mutableListOf<Pair<RealtimeEndReason, String?>>()
        var clockReads = 0
    }

    private fun TestScope.rig(
        reopen: (suspend () -> Pair<FakeConnection, PlannedRealtimeSession>)? = null,
        replan: (suspend () -> RealtimeSessionFingerprint?)? = null,
        replanContext: CoroutineContext = EmptyCoroutineContext,
    ): Rig {
        val connection = FakeConnection()
        val audio = FakeAudio()
        val sink = Sink()
        // Attached to backgroundScope: on an assertion failure it is cancelled with the test, so the test fails instead of hanging
        val scope = CoroutineScope(UnconfinedTestDispatcher(testScheduler) + Job(backgroundScope.coroutineContext.job))
        lateinit var rig: Rig
        val controller = RealtimeVoiceConversationController(
            connection = connection,
            audio = audio,
            plan = plan,
            sink = sink,
            scope = scope,
            onError = { rig.errors += it },
            onEnded = { reason, draft -> rig.ended += reason to draft },
            clock = {
                rig.clockReads++
                testScheduler.currentTime
            },
            reopen = reopen,
            replan = replan,
            replanContext = replanContext,
        )
        rig = Rig(connection, audio, sink, scope, controller)
        controller.start()
        testScheduler.runCurrent()
        return rig
    }

    private fun TestScope.send(r: Rig, vararg events: RealtimeSessionEvent) {
        events.forEach { r.connection.events.trySend(it) }
        testScheduler.runCurrent()
    }

    private val loud = RealtimePCM.toLittleEndian(ShortArray(480) { if (it % 2 == 0) 8000 else -8000 })

    /** How many [loud] frames fill one level window (1/15 s of audio, at the connection's uplink sample rate). */
    private fun framesPerLevelWindow(r: Rig): Int =
        (UplinkLevelWindow.windowSamples(r.connection.uplinkSampleRateHz) + 479) / 480

    @Test
    fun persist_calls_sink_in_order() = runTest {
        val r = rig()
        send(
            r,
            RealtimeSessionEvent.Ready,
            RealtimeSessionEvent.UserSpeechStarted(null),
            RealtimeSessionEvent.UserSpeechStopped(null),
            RealtimeSessionEvent.UserTranscript(null, "hello there", final = true),
            RealtimeSessionEvent.AssistantTranscript(null, "hi", final = true),
            RealtimeSessionEvent.AssistantTurnDone(null, RealtimeTurnStatus.Completed, "hi, how can I help"),
        )
        assertEquals(listOf("user:hello there", "assistant:hi, how can I help"), r.sink.calls)
        assertEquals(ConversationStatusKey.LISTENING, r.controller.statusKey.value)
        assertEquals(ConversationDisplayState.LISTENING, r.controller.displayState.value)
        r.scope.cancel()
    }

    @Test
    fun mute_gates_uplink_and_sends_silence() = runTest {
        val r = rig()
        send(r, RealtimeSessionEvent.Ready)
        val n = framesPerLevelWindow(r)
        // Levels accumulate per audio duration: nothing is published before the window is full, and after that the value is the RMS of the whole window (a constant-amplitude square wave equals a single frame).
        repeat(n - 1) { r.audio.onFrame!!(loud) }
        assertEquals(n - 1, r.connection.sent.size)
        assertEquals(0f, r.controller.level.value)
        r.audio.onFrame!!(loud)
        assertEquals(n, r.connection.sent.size)
        // ±8000 constant-amplitude square wave: RMS 8000/32768 ≈ −12.247 dBFS → (60 − 12.247) / 60.
        assertEquals(0.79588f, r.controller.level.value, 1e-5f)
        assertTrue(r.controller.level.value > 0f)

        // Muting while the user is speaking: first pad 1 s of 24 kHz zero PCM16, then close the uplink.
        send(r, RealtimeSessionEvent.UserSpeechStarted(null))
        r.controller.toggleMute()
        assertEquals(n + 1, r.connection.sent.size)
        assertArrayEquals(ByteArray(48_000), r.connection.sent[n])
        assertEquals(ConversationStatusKey.MUTED, r.controller.statusKey.value)
        assertEquals(ConversationDisplayState.MUTED, r.controller.displayState.value)
        assertEquals(0f, r.controller.level.value)
        r.audio.onFrame!!(loud)
        assertEquals(n + 1, r.connection.sent.size)

        r.controller.toggleMute()
        r.audio.onFrame!!(loud)
        assertEquals(n + 2, r.connection.sent.size)
        assertEquals(ConversationStatusKey.LISTENING, r.controller.statusKey.value)
        r.scope.cancel()
    }

    @Test
    fun screen_reader_speaking_gates_uplink_without_mute() = runTest {
        val r = rig()
        send(r, RealtimeSessionEvent.Ready)
        r.audio.onFrame!!(loud)
        assertEquals(1, r.connection.sent.size)

        // Screen reader announcement: uplink pauses, the status word stays listening, and it does not count as muted.
        r.controller.screenReaderSpeaking(true)
        r.audio.onFrame!!(loud)
        assertEquals(1, r.connection.sent.size)
        assertEquals(ConversationStatusKey.LISTENING, r.controller.statusKey.value)

        // Mute then unmute during an announcement: only the mute is cleared, and the uplink opens once the announcement ends.
        r.controller.toggleMute()
        r.controller.toggleMute()
        assertEquals(ConversationStatusKey.LISTENING, r.controller.statusKey.value)
        r.audio.onFrame!!(loud)
        assertEquals(1, r.connection.sent.size)

        r.controller.screenReaderSpeaking(false)
        r.audio.onFrame!!(loud)
        assertEquals(2, r.connection.sent.size)
        r.scope.cancel()
    }

    @Test
    fun tap_orb_calls_interrupt_playback() = runTest {
        val r = rig()
        send(r, RealtimeSessionEvent.Ready, RealtimeSessionEvent.AssistantAudio(null, 0, "AQA=", 24_000))
        assertEquals(ConversationStatusKey.SPEAKING, r.controller.statusKey.value)
        assertEquals(0.5f, r.controller.level.value)
        r.controller.tapOrb()
        assertEquals(listOf("start", "enqueue", "stopPlayback"), r.audio.calls)
        assertEquals(ConversationStatusKey.LISTENING, r.controller.statusKey.value)

        // Tap while not playing: the driver does nothing.
        r.controller.tapOrb()
        assertEquals(listOf("start", "enqueue", "stopPlayback"), r.audio.calls)
        r.scope.cancel()
    }

    @Test
    fun playback_drained_from_audio_idle() = runTest {
        val r = rig()
        send(
            r,
            RealtimeSessionEvent.Ready,
            RealtimeSessionEvent.AssistantAudio(null, 0, "AQA=", 24_000),
            RealtimeSessionEvent.AssistantTurnDone(null, RealtimeTurnStatus.Completed, "done talking"),
        )
        assertEquals(listOf("assistant:done talking"), r.sink.calls)
        assertEquals(ConversationStatusKey.SPEAKING, r.controller.statusKey.value)
        // isPlaying is not polled: the player is empty but no callback arrived, so it is still speaking
        r.audio.playing = false
        testScheduler.advanceTimeBy(10_000)
        assertEquals(ConversationStatusKey.SPEAKING, r.controller.statusKey.value)
        r.audio.drain()
        testScheduler.runCurrent()
        assertEquals(ConversationStatusKey.LISTENING, r.controller.statusKey.value)
        assertEquals(0f, r.controller.level.value)
        r.scope.cancel()
    }

    @Test
    fun failed_stream_shows_error_and_ends() = runTest {
        val r = rig()
        send(r, RealtimeSessionEvent.Ready)
        r.connection.events.close(IllegalStateException("wss://api.example.com/v1?key=sk-secret"))
        testScheduler.runCurrent()
        assertEquals(listOf<String?>("IllegalStateException"), r.errors)
        assertEquals(listOf<Pair<RealtimeEndReason, String?>>(RealtimeEndReason.ERROR to null), r.ended)
        assertEquals(ConversationStatusKey.ERROR, r.controller.statusKey.value)
        assertEquals(ConversationDisplayState.ERROR, r.controller.displayState.value)
        assertEquals(1, r.connection.closes)
        assertEquals("stop", r.audio.calls.last())
        r.scope.cancel()
    }

    @Test
    fun unmuted_session_expired_reopens_and_continues() = runTest {
        val second = FakeConnection()
        var reopens = 0
        var sinkAtReopen: List<String> = emptyList()
        lateinit var r: Rig
        r = rig(reopen = { reopens++; sinkAtReopen = r.sink.calls.toList(); second to plan })
        send(
            r,
            RealtimeSessionEvent.Ready,
            RealtimeSessionEvent.UserSpeechStarted(null),
            RealtimeSessionEvent.UserSpeechStopped(null),
            RealtimeSessionEvent.UserTranscript(null, "hello there", final = true),
            RealtimeSessionEvent.AssistantTurnDone(null, RealtimeTurnStatus.Completed, "hi, how can I help"),
            RealtimeSessionEvent.UserSpeechStarted(null),
        )
        // 1008 while speaking → does not end, reopens once, and statusKey is thinking until the new connection is ready
        r.connection.events.close(GeminiLiveSessionExpiredException("Gemini Live session expired (1008)"))
        testScheduler.runCurrent()
        assertEquals(emptyList<String?>(), r.errors)
        assertEquals(emptyList<Pair<RealtimeEndReason, String?>>(), r.ended)
        assertEquals(1, reopens)
        assertEquals(1, second.opens)
        // On reopen, the transcripts already persisted are the new session's text history
        assertEquals(listOf("user:hello there", "assistant:hi, how can I help"), sinkAtReopen)
        assertEquals(ConversationStatusKey.THINKING, r.controller.statusKey.value)
        assertEquals(0, r.audio.stops)

        second.events.trySend(RealtimeSessionEvent.Ready)
        testScheduler.runCurrent()
        assertEquals(ConversationStatusKey.LISTENING, r.controller.statusKey.value)
        val oldSent = r.connection.sent.size
        r.audio.onFrame!!(loud)
        assertArrayEquals(loud, second.sent.last())
        assertEquals(oldSent, r.connection.sent.size)

        // The conversation continues on the new connection
        listOf(
            RealtimeSessionEvent.UserSpeechStarted(null),
            RealtimeSessionEvent.UserSpeechStopped(null),
            RealtimeSessionEvent.UserTranscript(null, "go on", final = true),
            RealtimeSessionEvent.AssistantTurnDone(null, RealtimeTurnStatus.Completed, "sure"),
        ).forEach { second.events.trySend(it) }
        testScheduler.runCurrent()
        assertEquals(
            listOf("user:hello there", "assistant:hi, how can I help", "user:go on", "assistant:sure"),
            r.sink.calls,
        )
        r.controller.end()
        testScheduler.runCurrent()
        assertEquals(1, second.closes)
        assertEquals(listOf<Pair<RealtimeEndReason, String?>>(RealtimeEndReason.USER to null), r.ended)
        assertEquals(1, r.audio.starts)
        assertEquals(1, r.audio.stops)
        r.scope.cancel()
    }

    @Test
    fun reopen_expired_again_without_progress_ends_error() = runTest {
        val second = FakeConnection()
        var reopens = 0
        val r = rig(reopen = { reopens++; second to plan })
        send(r, RealtimeSessionEvent.Ready)
        r.connection.events.close(GeminiLiveSessionExpiredException("Gemini Live session expired (1008)"))
        testScheduler.runCurrent()
        assertEquals(1, reopens)
        second.events.trySend(RealtimeSessionEvent.Ready)
        testScheduler.runCurrent()
        // Only ready (not progress) after reopening and then expiring again → ends with sessionExpired and does not reopen
        second.events.close(GeminiLiveSessionExpiredException("Gemini Live session expired (1008)"))
        testScheduler.runCurrent()
        assertEquals(1, reopens)
        // Sends sessionExpired rather than failed (a failed code would be the exception type name)
        assertEquals(listOf<String?>(RealtimeConversationLogic.SESSION_EXPIRED_CODE), r.errors)
        assertEquals(listOf<Pair<RealtimeEndReason, String?>>(RealtimeEndReason.ERROR to null), r.ended)
        assertEquals(ConversationStatusKey.ERROR, r.controller.statusKey.value)
        // Ending on an error → inner stop exactly once
        assertEquals(1, r.audio.starts)
        assertEquals(1, r.audio.stops)
        r.scope.cancel()
    }

    @Test
    fun session_expired_while_muted_stays_dormant_without_ended() = runTest {
        val r = rig()
        send(r, RealtimeSessionEvent.Ready)
        r.controller.toggleMute()
        r.connection.events.close(GeminiLiveSessionExpiredException("Gemini Live session expired (1008)"))
        testScheduler.runCurrent()
        assertEquals(emptyList<String?>(), r.errors)
        assertEquals(emptyList<Pair<RealtimeEndReason, String?>>(), r.ended)
        assertEquals(ConversationStatusKey.MUTED, r.controller.statusKey.value)
        r.scope.cancel()
    }

    @Test
    fun muted_session_expired_reopens_on_unmute() = runTest {
        val second = FakeConnection()
        var reopens = 0
        val r = rig(reopen = { reopens++; second to plan })
        send(r, RealtimeSessionEvent.Ready)
        r.controller.toggleMute()
        r.connection.events.close(GeminiLiveSessionExpiredException("Gemini Live session expired (1008)"))
        testScheduler.runCurrent()
        assertEquals(0, reopens)
        assertEquals(emptyList<Pair<RealtimeEndReason, String?>>(), r.ended)

        // Unmute → the reopener is called once, and ready is delivered by the new connection
        r.controller.toggleMute()
        testScheduler.runCurrent()
        assertEquals(1, reopens)
        assertEquals(1, second.opens)
        second.events.trySend(RealtimeSessionEvent.Ready)
        testScheduler.runCurrent()
        assertEquals(ConversationStatusKey.LISTENING, r.controller.statusKey.value)

        val oldSent = r.connection.sent.size
        r.audio.onFrame!!(loud)
        assertArrayEquals(loud, second.sent.last())
        assertEquals(oldSent, r.connection.sent.size)
        assertEquals(1, r.connection.opens)
        assertEquals(emptyList<String?>(), r.errors)
        assertEquals(emptyList<Pair<RealtimeEndReason, String?>>(), r.ended)

        // Teardown goes through the new connection
        r.controller.end()
        testScheduler.runCurrent()
        assertEquals(1, second.closes)
        assertEquals(listOf<Pair<RealtimeEndReason, String?>>(RealtimeEndReason.USER to null), r.ended)
        r.scope.cancel()
    }

    @Test
    fun expired_unbinds_uplink_until_reopened_ready() = runTest {
        val second = FakeConnection()
        val r = rig(reopen = { second to plan })
        send(r, RealtimeSessionEvent.Ready)
        r.controller.toggleMute()
        r.connection.events.close(GeminiLiveSessionExpiredException("Gemini Live session expired (1008)"))
        testScheduler.runCurrent()
        val oldSent = r.connection.sent.size

        // Expiry unbinds the uplink callback, so frames during dormancy and reopening go to no connection
        r.audio.onFrame!!(loud)
        r.controller.toggleMute()
        testScheduler.runCurrent()
        assertEquals(1, second.opens)
        r.audio.onFrame!!(loud)
        assertEquals(oldSent, r.connection.sent.size)
        assertEquals(0, second.sent.size)

        // After the new driver is Ready it rebinds, and frames go to the new connection
        second.events.trySend(RealtimeSessionEvent.Ready)
        testScheduler.runCurrent()
        r.audio.onFrame!!(loud)
        assertEquals(oldSent, r.connection.sent.size)
        assertEquals(1, second.sent.size)
        assertArrayEquals(loud, second.sent.last())
        r.scope.cancel()
    }

    @Test
    fun reopen_keeps_audio_running_and_rebinds_uplink() = runTest {
        val second = FakeConnection()
        val r = rig(reopen = { second to plan })
        send(r, RealtimeSessionEvent.Ready)
        r.controller.toggleMute()
        r.connection.events.close(GeminiLiveSessionExpiredException("Gemini Live session expired (1008)"))
        testScheduler.runCurrent()
        // The microphone device stays open during dormancy
        assertEquals(0, r.audio.stops)

        r.controller.toggleMute()
        testScheduler.runCurrent()
        second.events.trySend(RealtimeSessionEvent.Ready)
        testScheduler.runCurrent()
        // The reopened Ready only swaps the callback and does not call inner start again
        assertEquals(1, r.audio.starts)
        assertEquals(0, r.audio.stops)
        assertEquals(emptyList<String?>(), r.errors)
        assertEquals(ConversationStatusKey.LISTENING, r.controller.statusKey.value)

        val oldSent = r.connection.sent.size
        r.audio.onFrame!!(loud)
        r.audio.onFrame!!(loud)
        assertEquals(2, second.sent.size)
        assertArrayEquals(loud, second.sent.last())
        assertEquals(oldSent, r.connection.sent.size)

        // On end, inner stop exactly once
        r.controller.end()
        testScheduler.runCurrent()
        assertEquals(listOf<Pair<RealtimeEndReason, String?>>(RealtimeEndReason.USER to null), r.ended)
        assertEquals(1, r.audio.starts)
        assertEquals(1, r.audio.stops)
        r.scope.cancel()
    }

    @Test
    fun reopen_failure_ends_with_error() = runTest {
        val r = rig(reopen = { throw IllegalStateException("wss://api.example.com/v1?key=sk-secret") })
        send(r, RealtimeSessionEvent.Ready)
        r.controller.toggleMute()
        r.connection.events.close(GeminiLiveSessionExpiredException("Gemini Live session expired (1008)"))
        testScheduler.runCurrent()
        r.controller.toggleMute()
        testScheduler.runCurrent()
        assertEquals(listOf<String?>("IllegalStateException"), r.errors)
        assertEquals(listOf<Pair<RealtimeEndReason, String?>>(RealtimeEndReason.ERROR to null), r.ended)
        assertEquals(ConversationStatusKey.ERROR, r.controller.statusKey.value)
        r.scope.cancel()
    }

    @Test
    fun reopen_without_reopener_ends_with_error() = runTest {
        val r = rig()
        send(r, RealtimeSessionEvent.Ready)
        r.controller.toggleMute()
        r.connection.events.close(GeminiLiveSessionExpiredException("Gemini Live session expired (1008)"))
        testScheduler.runCurrent()
        r.controller.toggleMute()
        testScheduler.runCurrent()
        // Matches iOS: no reopener injected → the RealtimeReopenError type name
        assertEquals(listOf<String?>("RealtimeReopenError"), r.errors)
        assertEquals(listOf<Pair<RealtimeEndReason, String?>>(RealtimeEndReason.ERROR to null), r.ended)
        r.scope.cancel()
    }

    @Test
    fun end_user_writes_draft() = runTest {
        val r = rig()
        send(
            r,
            RealtimeSessionEvent.Ready,
            RealtimeSessionEvent.UserSpeechStarted(null),
            RealtimeSessionEvent.UserTranscript(null, "remind me to ", final = false),
        )
        r.controller.end()
        testScheduler.runCurrent()
        assertEquals(listOf<Pair<RealtimeEndReason, String?>>(RealtimeEndReason.USER to "remind me to"), r.ended)
        assertTrue(r.sink.calls.isEmpty())
        assertEquals(1, r.connection.closes)
        assertEquals(null, r.controller.statusKey.value)
        assertEquals(null, r.controller.displayState.value)
        assertEquals("stop", r.audio.calls.last())
        r.scope.cancel()
    }

    @Test
    fun close_gates_uplink_before_close() = runTest {
        val r = rig()
        send(r, RealtimeSessionEvent.Ready)
        r.audio.onFrame!!(loud)
        assertEquals(1, r.connection.sent.size)
        // Microphone frames still arriving while the connection closes must not be sent uplink: Close shuts the uplink first and then closes.
        var sentAtClose = -1
        r.connection.onClose = {
            sentAtClose = r.connection.sent.size
            r.audio.onFrame!!(loud)
        }
        r.controller.end()
        testScheduler.runCurrent()
        assertEquals(1, r.connection.closes)
        assertEquals(sentAtClose, r.connection.sent.size)
        r.scope.cancel()
    }

    @Test
    fun system_interruption_closes() = runTest {
        val r = rig()
        send(r, RealtimeSessionEvent.Ready)
        r.audio.onInterruption!!()
        testScheduler.runCurrent()
        assertEquals(listOf<Pair<RealtimeEndReason, String?>>(RealtimeEndReason.SYSTEM to null), r.ended)
        assertTrue(r.connection.closes >= 1)
        assertTrue("stop" in r.audio.calls)
        assertTrue(r.errors.isEmpty())
        r.scope.cancel()
    }

    @Test
    fun uplink_level_publishes_at_most_15hz() = runTest {
        val r = rig()
        send(r, RealtimeSessionEvent.Ready)
        val seen = mutableListOf<Float>()
        val collecting = r.scope.launch { r.controller.level.collect { seen += it } }
        val rate = r.connection.uplinkSampleRateHz
        val frameSamples = rate / 50
        // 1 s of audio is cut into fifty 20 ms frames with amplitude rising per frame: every window's level differs, so each publish adds one more value.
        repeat(50) { k ->
            val amp = (100 * (k + 1)).toShort()
            r.audio.onFrame!!(RealtimePCM.toLittleEndian(ShortArray(frameSamples) { if (it % 2 == 0) amp else (-amp).toShort() }))
        }
        assertEquals(50, r.connection.sent.size)
        val published = seen.drop(1)
        assertTrue("published ${published.size} levels for 1 s of audio", published.size <= 15)
        val framesPerWindow = (UplinkLevelWindow.windowSamples(rate) + frameSamples - 1) / frameSamples
        assertEquals(50 / framesPerWindow, published.size)
        assertEquals(published.sorted(), published)
        assertEquals(published.last(), r.controller.level.value)
        collecting.cancel()
        r.scope.cancel()
    }

    @Test
    fun zero_wait_not_armed() {
        // Same as iOS (fixture rules.timers): a wait of null or ≤ 0 schedules no timer and does not read the clock.
        val noClock = { error("clock read for an unarmed tick") }
        assertNull(RealtimeVoiceConversationController.tickDueAt(null, noClock))
        assertNull(RealtimeVoiceConversationController.tickDueAt(0L, noClock))
        assertNull(RealtimeVoiceConversationController.tickDueAt(-5L, noClock))
        assertEquals(1_250L, RealtimeVoiceConversationController.tickDueAt(250L) { 1_000L })
    }

    @Test
    fun idle_tick_ends() = runTest {
        val r = rig()
        send(r, RealtimeSessionEvent.Ready)
        testScheduler.advanceTimeBy(RealtimeConversationConstants.IDLE_END_MS - 1)
        testScheduler.runCurrent()
        assertTrue(r.ended.isEmpty())
        testScheduler.advanceTimeBy(1)
        testScheduler.runCurrent()
        assertEquals(listOf<Pair<RealtimeEndReason, String?>>(RealtimeEndReason.IDLE to null), r.ended)
        assertEquals(1, r.connection.closes)
        r.scope.cancel()
    }

    @Test
    fun no_periodic_tick_idle_ends_once_at_deadline() = runTest {
        val r = rig()
        send(r, RealtimeSessionEvent.Ready)
        val readsAfterReady = r.clockReads
        // No wakeups before the deadline: the one-shot timer fires only at idleEndMs
        testScheduler.advanceTimeBy(RealtimeConversationConstants.IDLE_END_MS - 1)
        testScheduler.runCurrent()
        assertEquals(readsAfterReady, r.clockReads)
        assertTrue(r.ended.isEmpty())
        testScheduler.advanceTimeBy(1)
        testScheduler.runCurrent()
        assertEquals(listOf<Pair<RealtimeEndReason, String?>>(RealtimeEndReason.IDLE to null), r.ended)
        // No timers are scheduled after the end
        val readsAtEnd = r.clockReads
        testScheduler.advanceTimeBy(RealtimeConversationConstants.IDLE_END_MS * 2)
        testScheduler.runCurrent()
        assertEquals(readsAtEnd, r.clockReads)
        assertEquals(1, r.ended.size)
        r.scope.cancel()
    }

    @Test
    fun stale_drained_callback_after_stop_ignored() = runTest {
        val r = rig()
        send(
            r,
            RealtimeSessionEvent.Ready,
            RealtimeSessionEvent.AssistantAudio(null, 0, "AQA=", 24_000),
            RealtimeSessionEvent.AssistantTurnDone(null, RealtimeTurnStatus.Completed, "done talking"),
        )
        assertEquals(ConversationStatusKey.SPEAKING, r.controller.statusKey.value)
        r.controller.end()
        testScheduler.runCurrent()
        assertEquals(listOf<Pair<RealtimeEndReason, String?>>(RealtimeEndReason.USER to null), r.ended)
        val statusAfterEnd = r.controller.statusKey.value
        val callsAfterEnd = r.audio.calls.toList()
        // A drained marker registered before stop arrives late: it is no longer folded into the ended session
        r.audio.drain()
        testScheduler.runCurrent()
        assertEquals(statusAfterEnd, r.controller.statusKey.value)
        assertEquals(callsAfterEnd, r.audio.calls)
        assertEquals(listOf<Pair<RealtimeEndReason, String?>>(RealtimeEndReason.USER to null), r.ended)
        assertEquals(0f, r.controller.level.value)
        r.scope.cancel()
    }

    @Test
    fun end_does_not_join_capture_on_main() = runTest {
        val r = rig()
        send(r, RealtimeSessionEvent.Ready)
        val caller = Thread.currentThread()
        r.controller.end()
        testScheduler.runCurrent()
        // The controller calls stop synchronously on the calling thread (it only starts the teardown and does not wait)
        assertEquals(1, r.audio.stops)
        assertSame(caller, r.audio.stopThread)
        // The blocking step AndroidRealtimeAudio.stop hands to launchTeardown: the caller returns immediately and the step finishes on an IO thread
        val io = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val gate = CountDownLatch(1)
        var captureStopThread: Thread? = null
        val job = launchTeardown(io) {
            captureStopThread = Thread.currentThread()
            gate.await(5, TimeUnit.SECONDS)
        }
        assertFalse(job.isCompleted)
        gate.countDown()
        runBlocking { job.join() }
        assertNotSame(caller, captureStopThread)
        // NonCancellable: Teardown still completes even if the scope is cancelled
        io.cancel()
        var ranAfterCancel = false
        runBlocking { launchTeardown(io) { ranAfterCancel = true }.join() }
        assertTrue(ranAfterCancel)
        r.scope.cancel()
    }

    // ---- realtime-session.v1: re-plan at turn boundaries, reopen only when the fingerprint changed ----

    private val changed = RealtimeSessionFingerprint(instructionsSha256 = "changed", lastHistoryId = "other-device")

    private fun TestScope.oneTurn(r: Rig) = send(
        r,
        RealtimeSessionEvent.UserSpeechStarted(null),
        RealtimeSessionEvent.UserSpeechStopped(null),
        RealtimeSessionEvent.UserTranscript(null, "hello there", final = true),
        RealtimeSessionEvent.AssistantTurnDone(null, RealtimeTurnStatus.Completed, "hi, how can I help"),
    )

    @Test
    fun turn_boundary_fingerprint_change_reopens_once() = runTest {
        val second = FakeConnection()
        var reopens = 0
        var replans = 0
        val r = rig(reopen = { reopens++; second to plan }, replan = { replans++; changed })
        send(r, RealtimeSessionEvent.Ready)
        // The ready that opens the session is not a turn boundary
        assertEquals(0, replans)
        oneTurn(r)
        assertEquals(listOf("user:hello there", "assistant:hi, how can I help"), r.sink.calls)
        assertEquals(1, replans)
        assertEquals(1, reopens)
        // The old connection is closed and replaced by a new one; the shared audio keeps running (single use)
        assertEquals(1, r.connection.closes)
        assertEquals(1, second.opens)
        assertEquals(0, r.audio.stops)
        assertEquals(ConversationStatusKey.THINKING, r.controller.statusKey.value)
        second.events.trySend(RealtimeSessionEvent.Ready)
        testScheduler.runCurrent()
        assertEquals(ConversationStatusKey.LISTENING, r.controller.statusKey.value)
        // The new connection's ready no longer triggers re-planning; the old connection's teardown does not send systemInterruption
        assertEquals(1, replans)
        assertEquals(emptyList<Pair<RealtimeEndReason, String?>>(), r.ended)
        r.audio.onFrame!!(loud)
        assertArrayEquals(loud, second.sent.last())
        r.controller.end()
        testScheduler.runCurrent()
        assertEquals(listOf<Pair<RealtimeEndReason, String?>>(RealtimeEndReason.USER to null), r.ended)
        assertEquals(1, r.audio.starts)
        assertEquals(1, r.audio.stops)
        r.scope.cancel()
    }

    @Test
    fun same_fingerprint_no_reopen() = runTest {
        var reopens = 0
        var replans = 0
        val r = rig(reopen = { reopens++; FakeConnection() to plan }, replan = { replans++; plan.plan.fingerprint })
        send(r, RealtimeSessionEvent.Ready)
        oneTurn(r)
        oneTurn(r)
        // Exactly one re-plan per turn boundary; an identical fingerprint does not reopen
        assertEquals(2, replans)
        assertEquals(0, reopens)
        assertEquals(0, r.connection.closes)
        assertEquals(ConversationStatusKey.LISTENING, r.controller.statusKey.value)
        r.scope.cancel()
    }

    @Test
    fun replan_runs_off_main() = runTest {
        val io = RecordingDispatcher(StandardTestDispatcher(testScheduler))
        var ranOn: ContinuationInterceptor? = null
        val result = CompletableDeferred<RealtimeSessionFingerprint?>()
        var reopens = 0
        val r = rig(
            reopen = { reopens++; FakeConnection() to plan },
            replan = {
                ranOn = currentCoroutineContext()[ContinuationInterceptor]
                result.await()
            },
            replanContext = io,
        )
        send(r, RealtimeSessionEvent.Ready)
        oneTurn(r)
        assertSame(io, ranOn)
        assertTrue(io.dispatches > 0)
        // A new turn started before the result arrived: the result is discarded and nothing reopens
        send(r, RealtimeSessionEvent.UserSpeechStarted(null))
        result.complete(changed)
        testScheduler.runCurrent()
        assertEquals(0, reopens)
        assertEquals(0, r.connection.closes)
        r.scope.cancel()
    }

    /** A dispatcher that counts dispatches: asserts the re-plan runs in the injected IO context rather than on the controller's thread. */
    private class RecordingDispatcher(private val inner: CoroutineDispatcher) : CoroutineDispatcher() {
        var dispatches = 0

        override fun isDispatchNeeded(context: CoroutineContext): Boolean = true

        override fun dispatch(context: CoroutineContext, block: Runnable) {
            dispatches++
            inner.dispatch(context, block)
        }
    }
}
