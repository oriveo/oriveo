package ai.oriveo.community.core.voice.realtime

import ai.oriveo.community.core.context.ContextConversation
import ai.oriveo.community.core.context.RealtimeSessionFingerprint
import ai.oriveo.community.core.context.RealtimeSessionInput
import ai.oriveo.community.core.context.assembleRealtimeSession
import ai.oriveo.community.core.data.repository.PlannedRealtimeSession
import ai.oriveo.community.core.data.repository.RealtimeTransportInput
import ai.oriveo.community.core.voice.conversation.ConversationDisplayState
import ai.oriveo.community.core.voice.conversation.ConversationRoute
import ai.oriveo.community.core.voice.conversation.ConversationFrames
import ai.oriveo.community.core.voice.conversation.ConversationStatusKey
import ai.oriveo.community.core.voice.conversation.EarconKind
import ai.oriveo.community.core.voice.conversation.SpeechProbModel
import ai.oriveo.community.core.voice.conversation.SpeechProbSource
import ai.oriveo.community.core.voice.conversation.VoiceConversationConstants
import ai.oriveo.community.core.voice.conversation.VoiceConversationController
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveClosedException
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveSessionExpiredException
import ai.oriveo.community.core.voice.realtime.wire.RealtimeHandshakeException
import ai.oriveo.community.core.voice.realtime.wire.RealtimeSessionControl
import ai.oriveo.community.core.voice.realtime.wire.RealtimeSocketClosedException
import ai.oriveo.community.core.voice.realtime.wire.RealtimeTransport
import java.io.IOException
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
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** RealtimeVoiceConversationController: fake connection + fake audio + real driver + real reducer (controller items 1-6 of the contract card). */
@OptIn(ExperimentalCoroutinesApi::class)
class RealtimeVoiceConversationControllerTest {

    private class FakeConnection(
        override val kind: RealtimeTransportKind = RealtimeTransportKind.GeminiLive,
    ) : RealtimeTransport, RealtimeSessionControl {
        val events = Channel<RealtimeSessionEvent>(Channel.UNLIMITED)
        val sent = mutableListOf<ByteArray>()
        var closes = 0
        var onClose: (() -> Unit)? = null
        var opens = 0

        /** Called after each uplink send: the "server VAD" stand-in that reproduces self-excitation listens to frames here. */
        var onSend: ((ByteArray) -> Unit)? = null

        override fun openRealtimeSession(transport: RealtimeTransportInput): Flow<RealtimeSessionEvent> {
            opens++
            return events.consumeAsFlow()
        }

        override fun sendAudio(pcm: ByteArray) {
            sent += pcm
            onSend?.invoke(pcm)
        }

        override fun truncate(itemId: String?, contentIndex: Int, playedMs: Double) = Unit

        val routes = mutableListOf<ConversationRoute>()
        val texts = mutableListOf<String>()

        override fun updateOutputRoute(route: ConversationRoute) {
            routes += route
        }

        override fun sendUserText(text: String) {
            texts += text
        }

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
        private var playbackLevel: ((Double?, Int) -> Unit)? = null
        val earcons = mutableListOf<EarconKind>()

        // Capture tap: 16 kHz microphone frames (before resampling), called by the test before the corresponding uplink frame
        var onCapture: ((ShortArray) -> Unit)? = null

        // Default loudspeaker output (same as AndroidRealtimeAudio when no device is known)
        override var route: ConversationRoute = ConversationRoute.SPEAKER

        // Downlink PCM queued but not yet written out, segmented per item (used only by playNext20ms)
        private val queued = ArrayDeque<Pair<String, ByteArray>>()

        // Bytes of each item already dequeued (written out): playedMs derives from it at 24 kHz 16-bit; frozen after stopPlayback, not cleared
        private val dequeuedBytes = mutableMapOf<String, Long>()

        // Items queried by each playedMs call; the test uses them to check the pace of progress
        val playedQueries = mutableListOf<String>()

        var starts = 0
        var stops = 0
        var stopThread: Thread? = null

        // Same as AndroidRealtimeAudio: single use, start after stop throws IllegalStateException (contract card C item 5)
        override fun start(onFrame: (ByteArray) -> Unit, onInterruption: () -> Unit) {
            check(stops == 0) { "RealtimeAudioIO is single-use" }
            starts++
            calls += "start"
            this.onFrame = onFrame
            this.onInterruption = onInterruption
        }

        override fun startPlayback(onInterruption: () -> Unit, onActivationFailed: (Throwable) -> Unit) {
            check(stops == 0) { "RealtimeAudioIO is single-use" }
            starts++
            calls += "startPlayback"
            this.onInterruption = onInterruption
        }

        override fun startCapture(onFrame: (ByteArray) -> Unit, uplinkRateHz: Int) {
            calls += "startCapture"
            this.onFrame = onFrame
        }

        override fun enqueue(pcm16: ByteArray, itemId: String) {
            calls += "enqueue"
            queued.addLast(itemId to pcm16)
            playing = true
        }

        override fun playedMs(itemId: String): Long {
            playedQueries += itemId
            return (dequeuedBytes[itemId] ?: 0L) * 1000 / (RealtimePCM.OUTPUT_RATE * 2)
        }

        override val isPlaying: Boolean
            get() = playing

        override fun setOnDrained(onDrained: () -> Unit) {
            drainedCallback = onDrained
        }

        override fun setOnPlaybackLevel(onBlock: (db: Double?, samples: Int) -> Unit) {
            playbackLevel = onBlock
        }

        override fun setOnCaptureFrame(onFrame: (ShortArray) -> Unit) {
            onCapture = onFrame
        }

        // Route change callback: the test simulates the audio layer being notified when devices are added or removed
        var routeListener: ((ConversationRoute) -> Unit)? = null

        override fun setOnRouteChanged(onChange: (ConversationRoute) -> Unit) {
            routeListener = onChange
        }

        // Downlink reference sequence: each gate dequeues one reference (the test queues it per frame); empty = not playing, same behavior as when unset
        val refs = ArrayDeque<Double?>()

        override fun playbackReferenceDb(): Double? = refs.removeFirstOrNull()

        /** Simulates writing downlink PCM16 into an AudioTrack in 20 ms blocks: the block level goes through production RealtimePCM.blockDb. */
        fun play(pcm16: ByteArray) {
            val slice = RealtimePCM.frameBytes(RealtimePCM.OUTPUT_RATE)
            var offset = 0
            while (offset < pcm16.size) {
                val size = minOf(slice, pcm16.size - offset)
                playbackLevel?.invoke(RealtimePCM.blockDb(pcm16, offset, size), size / 2)
                offset += size
            }
        }

        /**
         * Simulates the player writing out queued 20 ms of downlink: returns the written block (null when not playing or the queue is empty); writing empty sets idle and calls back as finished.
         */
        fun playNext20ms(): ByteArray? {
            if (!playing || queued.isEmpty()) return null
            var want = RealtimePCM.frameBytes(RealtimePCM.OUTPUT_RATE)
            var chunk = ByteArray(0)
            while (want > 0 && queued.isNotEmpty()) {
                val (item, bytes) = queued.removeFirst()
                val size = minOf(want, bytes.size)
                chunk += bytes.copyOfRange(0, size)
                dequeuedBytes[item] = (dequeuedBytes[item] ?: 0L) + size
                if (size < bytes.size) queued.addFirst(item to bytes.copyOfRange(size, bytes.size))
                want -= size
            }
            play(chunk)
            if (queued.isEmpty()) drain()
            return chunk
        }

        /** A late "finished playing" callback from the previous cycle: a new cycle is already playing, so isPlaying is unchanged. */
        fun staleDrain() {
            drainedCallback?.invoke()
        }

        /** Simulates the player's finished-playing callback (AudioTrack marker reached). */
        fun drain() {
            playing = false
            drainedCallback?.invoke()
        }

        override fun stopPlayback() {
            calls += "stopPlayback"
            queued.clear()
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
        var ensures = 0

        override suspend fun ensureConversation(): Boolean {
            ensures++
            return true
        }

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
        speechProbs: SpeechProbSource? = null,
        maxSessionSec: Long? = null,
        catalogHasModel: suspend () -> Boolean? = { null },
        capture: Boolean = true,
        kind: RealtimeTransportKind = RealtimeTransportKind.GeminiLive,
    ): Rig {
        val connection = FakeConnection(kind)
        val audio = FakeAudio()
        val sink = Sink()
        // Attached to backgroundScope: if an assertion fails it is cancelled with the test, so it reports red instead of hanging (contract card D item 4)
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
            speechProbs = speechProbs,
            maxSessionSec = maxSessionSec,
            catalogHasModel = catalogHasModel,
            capture = capture,
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

    /** Frames of [loud] needed to fill one level window (1/15 s of audio, counted at the connection's uplink sample rate). */
    private fun framesPerLevelWindow(r: Rig): Int =
        (PeakLevelWindow.windowSamples(r.connection.uplinkSampleRateHz) + 479) / 480

    /** Downlink PCM16 LE of a constant-amplitude square wave (±[amp]) for [ms] milliseconds at 24 kHz. */
    private fun downlink(ms: Int, amp: Short): ByteArray =
        RealtimePCM.toLittleEndian(ShortArray(RealtimePCM.OUTPUT_RATE * ms / 1000) { if (it % 2 == 0) amp else (-amp).toShort() })

    /** Realtime level mapping: dBFS relative to a fixed noise floor of −50 dB. */
    private fun mapped(db: Double): Float = ConversationFrames.levelFromDb(db, ConversationFrames.AI_LEVEL_FLOOR_DB)

    private fun ampDb(amp: Int): Double = 20 * kotlin.math.log10(amp / 32768.0)

    @Test
    fun output_route_change_updates_session_live() = runTest {
        val r = rig()
        send(r, RealtimeSessionEvent.Ready)
        // Loudspeaker playing: the noise-floor frame is held by the gate
        send(r, RealtimeSessionEvent.AssistantAudio("r1", 0, b64(downlink(3000, 4000)), RealtimePCM.OUTPUT_RATE))
        assertTrue(r.audio.playing)
        (1..10).forEach { r.audio.onFrame!!(square(ambientAmp, tag = it)) }
        assertEquals(0, r.connection.sent.size)
        val notify = checkNotNull(r.audio.routeListener)
        notify(ConversationRoute.HEADPHONES)
        testScheduler.runCurrent()
        // Device change during a session: handed to the current connection on the spot, no reopen
        assertEquals(listOf(ConversationRoute.HEADPHONES), r.connection.routes)
        assertEquals(1, r.connection.opens)
        // switching to headphones within the same playback cycle; the gate lets through on the spot on the new route, without waiting for the cycle to end
        val after = (11..20).map { square(ambientAmp, tag = it) }
        after.forEach { r.audio.onFrame!!(it) }
        assertEquals(after.map { it.toList() }, r.connection.sent.map { it.toList() })
        r.controller.end()
        testScheduler.runCurrent()
        notify(ConversationRoute.SPEAKER)
        testScheduler.runCurrent()
        assertEquals(listOf(ConversationRoute.HEADPHONES), r.connection.routes)
        r.scope.cancel()
    }

    /** Session opened by typing: ready only starts playback and does not start capture; text is still sent; switching back to voice starts capture and uplink frames, without reopening the connection. */
    @Test
    fun playback_only_session_starts_capture_later_on_same_connection() = runTest {
        val r = rig(capture = false)
        send(r, RealtimeSessionEvent.Ready)
        assertEquals(listOf("startPlayback"), r.audio.calls.filter { it.startsWith("start") })
        assertNull(r.audio.onFrame)
        r.controller.sendUserText("hello")
        testScheduler.runCurrent()
        assertEquals(listOf("hello"), r.connection.texts)

        r.controller.startCapture()
        r.controller.startCapture()
        assertEquals(listOf("startPlayback", "startCapture"), r.audio.calls.filter { it.startsWith("start") })
        checkNotNull(r.audio.onFrame)(loud)
        testScheduler.runCurrent()
        assertTrue(r.connection.sent.isNotEmpty())
        assertEquals(1, r.connection.opens)
        r.controller.end()
        testScheduler.runCurrent()
    }

    @Test
    fun send_user_text_sends_and_persists_as_user_turn() = runTest {
        val r = rig()
        send(r, RealtimeSessionEvent.Ready)
        r.controller.sendUserText("  what time is it ")
        r.controller.sendUserText("   ")
        testScheduler.runCurrent()
        assertEquals(listOf("what time is it"), r.connection.texts)
        // Fixture rt_typed_text_idle_persists_once: speak -> stop (thinking) -> the final transcript is persisted once
        assertEquals(listOf("user:what time is it"), r.sink.calls)
        assertEquals(ConversationStatusKey.THINKING, r.controller.statusKey.value)
        send(
            r,
            RealtimeSessionEvent.AssistantTranscript(null, "noon", final = true),
            RealtimeSessionEvent.AssistantTurnDone(null, RealtimeTurnStatus.Completed, "noon"),
        )
        // Persisted through the same path as the user words from transcription; the reply still lands after it
        assertEquals(listOf("user:what time is it", "assistant:noon"), r.sink.calls)
        r.scope.cancel()
    }

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
        // Levels accumulate per audio duration: nothing is published before the window is full; after that the value is the loudest 20 ms frame in the window.
        repeat(n - 1) { r.audio.onFrame!!(loud) }
        assertEquals(n - 1, r.connection.sent.size)
        assertEquals(0f, r.controller.level.value)
        r.audio.onFrame!!(loud)
        assertEquals(n, r.connection.sent.size)
        // ±8000 constant-amplitude square wave: RMS 8000/32768 ≈ −12.247 dBFS, more than 36 dB above the −50 dB noise floor -> full scale.
        assertEquals(1f, r.controller.level.value, 1e-5f)

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

        // Screen reader announcement: uplink paused, the status word stays listening, and it does not count as muted.
        r.controller.screenReaderSpeaking(true)
        r.audio.onFrame!!(loud)
        assertEquals(1, r.connection.sent.size)
        assertEquals(ConversationStatusKey.LISTENING, r.controller.statusKey.value)

        // Muting during an announcement and then unmuting: only the mute is cleared; the uplink opens only after the announcement ends.
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
        // While speaking, the level comes from the really written downlink PCM: it is 0 until a full window has been written, not a hard-coded constant.
        assertEquals(0f, r.controller.level.value)
        r.audio.play(downlink(80, 1000))
        assertEquals(mapped(ampDb(1000)), r.controller.level.value, 1e-4f)
        r.controller.tapOrb()
        assertEquals(listOf("start", "enqueue", "stopPlayback"), r.audio.calls)
        assertEquals(ConversationStatusKey.LISTENING, r.controller.statusKey.value)
        assertEquals(0f, r.controller.level.value)

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
        // Reply still playing: persisted only once it has finished playing
        assertEquals(emptyList<String>(), r.sink.calls)
        assertEquals(ConversationStatusKey.SPEAKING, r.controller.statusKey.value)
        r.audio.play(downlink(80, 2000))
        assertEquals(mapped(ampDb(2000)), r.controller.level.value, 1e-4f)
        // Does not poll isPlaying: the player is empty but no callback arrived, so it is still speaking
        r.audio.playing = false
        testScheduler.advanceTimeBy(10_000)
        assertEquals(ConversationStatusKey.SPEAKING, r.controller.statusKey.value)
        assertEquals(emptyList<String>(), r.sink.calls)
        r.audio.drain()
        testScheduler.runCurrent()
        assertEquals(listOf("assistant:done talking"), r.sink.calls)
        assertEquals(ConversationStatusKey.LISTENING, r.controller.statusKey.value)
        assertEquals(0f, r.controller.level.value)
        r.scope.cancel()
    }

    @Test
    fun speaking_reports_progress_at_most_every_100ms_and_stops_after() = runTest {
        val r = rig()
        send(r, RealtimeSessionEvent.Ready, RealtimeSessionEvent.AssistantAudio("a1", 0, b64(downlink(1000, 1000)), 24_000))
        assertEquals(ConversationStatusKey.SPEAKING, r.controller.statusKey.value)
        val atStart = r.audio.playedQueries.size
        // Read the played progress at least once every 100 ms (only items that received audio this round)
        repeat(5) { step ->
            testScheduler.advanceTimeBy(RealtimeVoiceConversationController.PROGRESS_INTERVAL_MS)
            testScheduler.runCurrent()
            assertTrue("Progress was not read within the ${step + 1}th 100 ms", r.audio.playedQueries.size > atStart + step)
        }
        assertEquals(setOf("a1"), r.audio.playedQueries.toSet())
        // Leaving speaking (a tap to interrupt) stops it; it does not stay resident
        r.controller.tapOrb()
        assertEquals(ConversationStatusKey.LISTENING, r.controller.statusKey.value)
        val afterLeave = r.audio.playedQueries.size
        testScheduler.advanceTimeBy(10_000)
        testScheduler.runCurrent()
        assertEquals(afterLeave, r.audio.playedQueries.size)
        r.scope.cancel()
    }

    @Test
    fun barge_in_reports_progress_before_freeze() = runTest {
        val r = rig()
        send(
            r,
            RealtimeSessionEvent.Ready,
            RealtimeSessionEvent.AssistantAudio("a1", 0, b64(downlink(1000, 1000)), 24_000),
            RealtimeSessionEvent.AssistantTranscript("a1", "one two three four", false),
        )
        // Audio written halfway without advancing time: the timer had no chance to report progress, only the catch-up before the interruption can carry it
        repeat(25) { r.audio.playNext20ms() }
        assertEquals(500L, r.audio.playedMs("a1"))
        send(r, RealtimeSessionEvent.UserSpeechStarted("u1"), RealtimeSessionEvent.UserTranscript("u1", "wait", true))
        assertEquals(listOf("assistant:one two", "user:wait"), r.sink.calls)
        r.scope.cancel()
    }

    @Test
    fun tap_orb_reports_progress_before_freeze() = runTest {
        val r = rig()
        send(
            r,
            RealtimeSessionEvent.Ready,
            RealtimeSessionEvent.AssistantAudio("a1", 0, b64(downlink(1000, 1000)), 24_000),
            RealtimeSessionEvent.AssistantTurnDone("a1", RealtimeTurnStatus.Completed, "one two three four"),
        )
        assertEquals(emptyList<String>(), r.sink.calls)
        repeat(25) { r.audio.playNext20ms() }
        r.controller.tapOrb()
        assertEquals(listOf("assistant:one two"), r.sink.calls)
        r.scope.cancel()
    }

    /** The reply is halfway through playing (500/1000 ms) and the timer had no chance to report progress; [done] means generation has finished (waiting for playback to end). Returns the base of progress queries. */
    private fun TestScope.speakingHalfPlayed(r: Rig, done: Boolean = true): Int {
        send(
            r,
            RealtimeSessionEvent.Ready,
            RealtimeSessionEvent.AssistantAudio("a1", 0, b64(downlink(1000, 1000)), 24_000),
            if (done) {
                RealtimeSessionEvent.AssistantTurnDone("a1", RealtimeTurnStatus.Completed, "one two three four")
            } else {
                RealtimeSessionEvent.AssistantTranscript("a1", "one two three four", false)
            },
        )
        repeat(25) { r.audio.playNext20ms() }
        return r.audio.playedQueries.size
    }

    @Test
    fun end_reports_progress_before_freeze() = runTest {
        val r = rig()
        val base = speakingHalfPlayed(r)
        r.controller.end()
        testScheduler.runCurrent()
        assertEquals(listOf("assistant:one two"), r.sink.calls)
        // The same input is only reported once more
        assertEquals(base + 1, r.audio.playedQueries.size)
        r.scope.cancel()
    }

    @Test
    fun system_interruption_reports_progress_before_freeze() = runTest {
        val r = rig()
        val base = speakingHalfPlayed(r)
        r.controller.systemInterruption()
        testScheduler.runCurrent()
        assertEquals(listOf("assistant:one two"), r.sink.calls)
        assertEquals(base + 1, r.audio.playedQueries.size)
        r.scope.cancel()
    }

    @Test
    fun interrupted_event_reports_progress_before_freeze() = runTest {
        val r = rig()
        val base = speakingHalfPlayed(r)
        send(r, RealtimeSessionEvent.Interrupted)
        r.controller.end()
        testScheduler.runCurrent()
        assertEquals(listOf("assistant:one two"), r.sink.calls)
        assertEquals(base + 1, r.audio.playedQueries.size)
        r.scope.cancel()
    }

    @Test
    fun typed_text_while_speaking_reports_progress_before_freeze() = runTest {
        val r = rig()
        speakingHalfPlayed(r, done = false)
        // Typed interruption: the catch-up report lands before the user begins speaking and freezes at the half already played
        r.controller.sendUserText("wait")
        testScheduler.runCurrent()
        assertEquals(listOf("assistant:one two", "user:wait"), r.sink.calls)
        r.scope.cancel()
    }

    @Test
    fun caption_user_appears_on_first_transcript() = runTest {
        val r = rig()
        send(r, RealtimeSessionEvent.Ready, RealtimeSessionEvent.UserSpeechStarted("u1"))
        // No text yet: no placeholder, only the status word is shown
        assertEquals("", r.controller.caption.value)
        send(r, RealtimeSessionEvent.UserTranscript("u1", "hello", false))
        assertEquals("hello", r.controller.caption.value)
        send(r, RealtimeSessionEvent.UserTranscript("u1", "hello there", false))
        assertEquals("hello there", r.controller.caption.value)
        r.scope.cancel()
    }

    @Test
    fun caption_assistant_reveals_by_played_ratio() = runTest {
        val r = rig()
        send(
            r,
            RealtimeSessionEvent.Ready,
            RealtimeSessionEvent.AssistantAudio("a1", 0, b64(downlink(1000, 1000)), 24_000),
            RealtimeSessionEvent.AssistantTranscript("a1", "one two three four", false),
        )
        assertEquals(ConversationStatusKey.SPEAKING, r.controller.statusKey.value)
        // Not a single word played: the AI caption is empty
        assertEquals("", r.controller.caption.value)
        // Half played: with the next played-progress report (≤ 100 ms), half is revealed
        repeat(25) { r.audio.playNext20ms() }
        testScheduler.advanceTimeBy(RealtimeVoiceConversationController.PROGRESS_INTERVAL_MS)
        testScheduler.runCurrent()
        assertEquals("one two", r.controller.caption.value)
        r.scope.cancel()
    }

    @Test
    fun caption_barge_in_starts_empty() = runTest {
        val r = rig()
        send(
            r,
            RealtimeSessionEvent.Ready,
            RealtimeSessionEvent.AssistantAudio("a1", 0, b64(downlink(1000, 1000)), 24_000),
            RealtimeSessionEvent.AssistantTranscript("a1", "one two three four", false),
        )
        repeat(25) { r.audio.playNext20ms() }
        testScheduler.advanceTimeBy(RealtimeVoiceConversationController.PROGRESS_INTERVAL_MS)
        testScheduler.runCurrent()
        assertEquals("one two", r.controller.caption.value)
        // Interruption: the AI caption is not kept, the new round starts empty and waits for your words to have text
        send(r, RealtimeSessionEvent.UserSpeechStarted("u1"))
        assertEquals("", r.controller.caption.value)
        send(r, RealtimeSessionEvent.UserTranscript("u1", "wait", false))
        assertEquals("wait", r.controller.caption.value)
        r.scope.cancel()
    }

    @Test
    fun drafts_user_and_assistant_published_separately() = runTest {
        val r = rig()
        send(r, RealtimeSessionEvent.Ready, RealtimeSessionEvent.UserSpeechStarted("u1"))
        // No text yet: neither of the two temporary bubbles is rendered
        assertEquals(RealtimeDrafts(), r.controller.drafts.value)
        send(r, RealtimeSessionEvent.UserTranscript("u1", "hello", false))
        assertEquals(RealtimeDrafts(user = "hello"), r.controller.drafts.value)
        send(
            r,
            RealtimeSessionEvent.AssistantAudio("a1", 0, b64(downlink(1000, 1000)), 24_000),
            RealtimeSessionEvent.AssistantTranscript("a1", "one two three four", false),
        )
        // The AI has not played a single word: only your words
        assertEquals(RealtimeDrafts(user = "hello"), r.controller.drafts.value)
        repeat(25) { r.audio.playNext20ms() }
        testScheduler.advanceTimeBy(RealtimeVoiceConversationController.PROGRESS_INTERVAL_MS)
        testScheduler.runCurrent()
        // Each side publishes on its own: the stage line is your unfinalized words (user takes priority in stageLine), and the AI's revealed words in the list continue as normal
        assertEquals("hello", r.controller.caption.value)
        assertEquals(RealtimeDrafts(user = "hello", assistant = "one two"), r.controller.drafts.value)
        r.scope.cancel()
    }

    @Test
    fun drafts_cleared_after_persist() = runTest {
        val r = rig()
        send(
            r,
            RealtimeSessionEvent.Ready,
            RealtimeSessionEvent.UserSpeechStarted("u1"),
            RealtimeSessionEvent.UserTranscript("u1", "what time", false),
        )
        assertEquals(RealtimeDrafts(user = "what time"), r.controller.drafts.value)
        send(r, RealtimeSessionEvent.UserTranscript("u1", "what time is it", true))
        // Your words are persisted: the user side is cleared and the formal message takes over
        assertEquals(listOf("user:what time is it"), r.sink.calls)
        assertEquals(RealtimeDrafts(userPersisted = 1, userPersistedText = "what time is it"), r.controller.drafts.value)
        send(
            r,
            RealtimeSessionEvent.AssistantAudio("a1", 0, b64(downlink(100, 1000)), 24_000),
            RealtimeSessionEvent.AssistantTranscript("a1", "it is noon", false),
        )
        repeat(5) { r.audio.playNext20ms() }
        testScheduler.advanceTimeBy(RealtimeVoiceConversationController.PROGRESS_INTERVAL_MS)
        testScheduler.runCurrent()
        assertEquals(RealtimeDrafts(assistant = "it is noon", userPersisted = 1, userPersistedText = "what time is it"), r.controller.drafts.value)
        // Generation finished and fully played, so it is persisted: the AI side is cleared
        send(r, RealtimeSessionEvent.AssistantTurnDone("a1", RealtimeTurnStatus.Completed, "it is noon"))
        assertEquals(listOf("user:what time is it", "assistant:it is noon"), r.sink.calls)
        // The persisted count and the clear are published with the same value: the list uses this to wait for the formal message to appear before removing the temporary bubble
        assertEquals(RealtimeDrafts(
                userPersisted = 1,
                assistantPersisted = 1,
                userPersistedText = "what time is it",
                assistantPersistedText = "it is noon",
            ), r.controller.drafts.value)
        r.scope.cancel()
    }

    @Test
    fun reply_persists_only_after_played_out() = runTest {
        val r = rig()
        send(
            r,
            RealtimeSessionEvent.Ready,
            RealtimeSessionEvent.AssistantAudio("a1", 0, b64(downlink(100, 1000)), 24_000),
            RealtimeSessionEvent.AssistantTurnDone("a1", RealtimeTurnStatus.Completed, "all of it"),
        )
        testScheduler.advanceTimeBy(1_000)
        testScheduler.runCurrent()
        assertEquals(emptyList<String>(), r.sink.calls)
        // Written up to the last block, which triggers the finished-playing callback
        repeat(5) { r.audio.playNext20ms() }
        testScheduler.runCurrent()
        assertEquals(listOf("assistant:all of it"), r.sink.calls)
        assertEquals(ConversationStatusKey.LISTENING, r.controller.statusKey.value)
        r.scope.cancel()
    }

    @Test
    fun stalled_tail_after_turn_done_persists_full_text() = runTest {
        val r = rig()
        send(
            r,
            RealtimeSessionEvent.Ready,
            RealtimeSessionEvent.AssistantAudio("a1", 0, b64(downlink(100, 1000)), 24_000),
            RealtimeSessionEvent.AssistantTurnDone("a1", RealtimeTurnStatus.Completed, "all of it"),
        )
        // After 80 ms the playback head stops and the finished-playing callback never comes (Samsung A16: the last 100 ms stalls in the track)
        repeat(4) { r.audio.playNext20ms() }
        testScheduler.advanceTimeBy(RealtimeVoiceConversationController.PROGRESS_INTERVAL_MS)
        testScheduler.runCurrent()
        testScheduler.advanceTimeBy(RealtimeVoiceConversationController.DRAIN_STALL_MS)
        testScheduler.runCurrent()
        assertEquals(emptyList<String>(), r.sink.calls)
        testScheduler.advanceTimeBy(RealtimeVoiceConversationController.PROGRESS_INTERVAL_MS)
        testScheduler.runCurrent()
        // A stall lasting DRAIN_STALL_MS counts as finished: the full text is persisted, not truncated by the played ratio
        assertEquals(listOf("assistant:all of it"), r.sink.calls)
        assertEquals(ConversationStatusKey.LISTENING, r.controller.statusKey.value)
        r.scope.cancel()
    }

    @Test
    fun failed_stream_shows_error_and_ends() = runTest {
        val r = rig()
        send(r, RealtimeSessionEvent.Ready)
        r.connection.events.close(IllegalStateException("wss://api.example.com/v1?key=sk-secret"))
        testScheduler.runCurrent()
        // The exception type name is no longer used as the code: no signal -> unknown 
        assertEquals(listOf<String?>("unknown"), r.errors)
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
        // Contract card F items 2a and 3: during speech, 1008 -> does not end, reopens once, and statusKey stays thinking until the new connection is ready
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

        // Conversation continues on the new connection
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
        // Contract card F item 2a: after reopening, only ready (which does not count as progress) and then expiry -> ends with sessionExpired, no further reopen
        second.events.close(GeminiLiveSessionExpiredException("Gemini Live session expired (1008)"))
        testScheduler.runCurrent()
        assertEquals(1, reopens)
        // Contract card B item 2: sends sessionExpired rather than failed (a failed code would be the exception type name)
        assertEquals(listOf<String?>(RealtimeConversationLogic.SESSION_EXPIRED_CODE), r.errors)
        assertEquals(listOf<Pair<RealtimeEndReason, String?>>(RealtimeEndReason.ERROR to null), r.ended)
        assertEquals(ConversationStatusKey.ERROR, r.controller.statusKey.value)
        // Contract card C item 6: ending on an error -> inner stop exactly once
        assertEquals(1, r.audio.starts)
        assertEquals(1, r.audio.stops)
        r.scope.cancel()
    }

    @Test
    fun unexpected_close_reopens_once_with_history() = runTest {
        val second = FakeConnection(RealtimeTransportKind.OpenAiRealtime)
        var reopens = 0
        var sinkAtReopen: List<String> = emptyList()
        lateinit var r: Rig
        r = rig(kind = RealtimeTransportKind.OpenAiRealtime, reopen = {
            reopens++
            sinkAtReopen = r.sink.calls.toList()
            second to plan
        })
        send(
            r,
            RealtimeSessionEvent.Ready,
            RealtimeSessionEvent.UserSpeechStarted(null),
            RealtimeSessionEvent.UserSpeechStopped(null),
            RealtimeSessionEvent.UserTranscript(null, "hello there", final = true),
            RealtimeSessionEvent.AssistantTurnDone(null, RealtimeTurnStatus.Completed, "hi, how can I help"),
        )
        // Design 6.6: unexpected drop after connecting (network switch) -> no failure card; send sessionExpired to the reducer with the history and reopen once
        // During reopen the phase is connecting (statusKey thinking)
        r.connection.events.close(IOException("socket reset"))
        testScheduler.runCurrent()
        assertEquals(1, reopens)
        assertEquals(1, second.opens)
        assertEquals(listOf("user:hello there", "assistant:hi, how can I help"), sinkAtReopen)
        // Replies completed before the drop were already persisted; reopen does not persist them again
        assertEquals(listOf("user:hello there", "assistant:hi, how can I help"), r.sink.calls)
        assertEquals(emptyList<String?>(), r.errors)
        assertEquals(emptyList<Pair<RealtimeEndReason, String?>>(), r.ended)
        assertEquals(ConversationStatusKey.THINKING, r.controller.statusKey.value)
        assertEquals(0, r.audio.stops)

        second.events.trySend(RealtimeSessionEvent.Ready)
        testScheduler.runCurrent()
        r.audio.onFrame!!(loud)
        assertArrayEquals(loud, second.sent.last())
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
        // A user-initiated end does not trigger a reopen
        r.controller.end()
        testScheduler.runCurrent()
        assertEquals(1, reopens)
        assertEquals(listOf<Pair<RealtimeEndReason, String?>>(RealtimeEndReason.USER to null), r.ended)
        assertEquals(emptyList<String?>(), r.errors)
        r.scope.cancel()
    }

    @Test
    fun unexpected_close_while_speaking_lands_reply_and_leaves_speaking() = runTest {
        val second = FakeConnection(RealtimeTransportKind.OpenAiRealtime)
        var reopens = 0
        val r = rig(kind = RealtimeTransportKind.OpenAiRealtime, reopen = { reopens++; second to plan })
        send(
            r,
            RealtimeSessionEvent.Ready,
            RealtimeSessionEvent.AssistantAudio("a1", 0, b64(downlink(1000, 1000)), 24_000),
            RealtimeSessionEvent.AssistantTranscript("a1", "one two three four", false),
            RealtimeSessionEvent.AssistantTurnDone("a1", RealtimeTurnStatus.Completed, "one two three four"),
        )
        repeat(25) { r.audio.playNext20ms() }
        testScheduler.advanceTimeBy(RealtimeVoiceConversationController.PROGRESS_INTERVAL_MS)
        testScheduler.runCurrent()
        assertEquals(ConversationStatusKey.SPEAKING, r.controller.statusKey.value)
        // Drop during playback: the reducer lands the already-played part per sessionExpired and moves to connecting to wait for the new connection, instead of stopping at speaking
        r.connection.events.close(IOException("socket reset"))
        testScheduler.runCurrent()
        assertEquals(1, reopens)
        assertEquals(listOf("assistant:one two"), r.sink.calls)
        assertEquals(ConversationStatusKey.THINKING, r.controller.statusKey.value)
        second.events.trySend(RealtimeSessionEvent.Ready)
        testScheduler.runCurrent()
        assertEquals(ConversationStatusKey.LISTENING, r.controller.statusKey.value)
        assertEquals(emptyList<String?>(), r.errors)
        r.scope.cancel()
    }

    @Test
    fun unexpected_close_reopen_fails_is_network() = runTest {
        // The reopened connection fails before reaching Ready -> reopenFailed -> network
        val second = FakeConnection(RealtimeTransportKind.XaiRealtime)
        var catalogCalls = 0
        val failing = rig(
            kind = RealtimeTransportKind.XaiRealtime,
            reopen = { second to plan },
            catalogHasModel = { catalogCalls++; null },
        )
        send(failing, RealtimeSessionEvent.Ready)
        failing.connection.events.close(IOException("socket reset"))
        testScheduler.runCurrent()
        assertEquals(1, second.opens)
        assertEquals(emptyList<String?>(), failing.errors)
        second.events.close(IOException("socket reset"))
        testScheduler.runCurrent()
        assertEquals(listOf<String?>("network"), failing.errors)
        assertEquals(listOf<Pair<RealtimeEndReason, String?>>(RealtimeEndReason.ERROR to null), failing.ended)
        // This call had reached Ready before: a reopen handshake failure does not refetch the catalog
        assertEquals(0, catalogCalls)

        // The reopener gets no new connection -> network
        val unavailable = rig(kind = RealtimeTransportKind.OpenAiRealtime, reopen = { throw IllegalStateException("offline") })
        send(unavailable, RealtimeSessionEvent.Ready)
        unavailable.connection.events.close()
        testScheduler.runCurrent()
        assertEquals(listOf<String?>("network"), unavailable.errors)
        assertEquals(listOf<Pair<RealtimeEndReason, String?>>(RealtimeEndReason.ERROR to null), unavailable.ended)

        failing.scope.cancel()
        unavailable.scope.cancel()
    }

    @Test
    fun second_unexpected_close_without_progress_after_reopen_ends_unknown() = runTest {
        // The reopened connection only reaches Ready (no progress) and drops again: afterDrop decides end, ends as unknown, no further reopen
        val second = FakeConnection(RealtimeTransportKind.OpenAiRealtime)
        var reopens = 0
        val r = rig(kind = RealtimeTransportKind.OpenAiRealtime, reopen = { reopens++; second to plan })
        send(r, RealtimeSessionEvent.Ready)
        r.connection.events.close(IOException("socket reset"))
        testScheduler.runCurrent()
        assertEquals(1, reopens)
        second.events.trySend(RealtimeSessionEvent.Ready)
        testScheduler.runCurrent()
        second.events.close(IOException("socket reset"))
        testScheduler.runCurrent()
        assertEquals(1, reopens)
        assertEquals(listOf<String?>("unknown"), r.errors)
        assertEquals(listOf<Pair<RealtimeEndReason, String?>>(RealtimeEndReason.ERROR to null), r.ended)
        assertEquals(1, r.audio.stops)
        r.scope.cancel()
    }

    @Test
    fun second_unexpected_close_after_progress_reopens_again() = runTest {
        // After reopening there has been conversation progress and the guard is cleared: a further drop still reopens with the history
        val second = FakeConnection(RealtimeTransportKind.OpenAiRealtime)
        val third = FakeConnection(RealtimeTransportKind.OpenAiRealtime)
        val next = ArrayDeque(listOf(second, third))
        var reopens = 0
        val r = rig(kind = RealtimeTransportKind.OpenAiRealtime, reopen = { reopens++; next.removeFirst() to plan })
        send(r, RealtimeSessionEvent.Ready)
        r.connection.events.close(IOException("socket reset"))
        testScheduler.runCurrent()
        assertEquals(1, reopens)
        listOf(
            RealtimeSessionEvent.Ready,
            RealtimeSessionEvent.UserSpeechStarted(null),
            RealtimeSessionEvent.UserSpeechStopped(null),
            RealtimeSessionEvent.UserTranscript(null, "go on", final = true),
            RealtimeSessionEvent.AssistantTurnDone(null, RealtimeTurnStatus.Completed, "sure"),
        ).forEach { second.events.trySend(it) }
        testScheduler.runCurrent()
        second.events.close(IOException("socket reset"))
        testScheduler.runCurrent()
        assertEquals(2, reopens)
        assertEquals(1, third.opens)
        assertEquals(emptyList<String?>(), r.errors)
        assertEquals(emptyList<Pair<RealtimeEndReason, String?>>(), r.ended)
        assertEquals(0, r.audio.stops)
        third.events.trySend(RealtimeSessionEvent.Ready)
        testScheduler.runCurrent()
        r.audio.onFrame!!(loud)
        assertArrayEquals(loud, third.sent.last())
        r.controller.end()
        testScheduler.runCurrent()
        assertEquals(2, reopens)
        assertEquals(listOf<Pair<RealtimeEndReason, String?>>(RealtimeEndReason.USER to null), r.ended)
        assertEquals(emptyList<String?>(), r.errors)
        r.scope.cancel()
    }

    @Test
    fun reopen_without_ready_then_close_is_network() = runTest {
        // The reopened connection finishes normally before Ready -> reopenFailed -> network, no further reopen
        val second = FakeConnection(RealtimeTransportKind.OpenAiRealtime)
        var reopens = 0
        var catalogCalls = 0
        val r = rig(
            kind = RealtimeTransportKind.OpenAiRealtime,
            reopen = { reopens++; second to plan },
            catalogHasModel = { catalogCalls++; null },
        )
        send(r, RealtimeSessionEvent.Ready)
        r.connection.events.close()
        testScheduler.runCurrent()
        assertEquals(1, second.opens)
        assertEquals(emptyList<String?>(), r.errors)
        second.events.close()
        testScheduler.runCurrent()
        assertEquals(1, reopens)
        assertEquals(listOf<String?>("network"), r.errors)
        assertEquals(listOf<Pair<RealtimeEndReason, String?>>(RealtimeEndReason.ERROR to null), r.ended)
        assertEquals(1, r.audio.stops)
        assertEquals(0, catalogCalls)
        r.scope.cancel()
    }

    @Test
    fun unexpected_close_with_quota_error_ends_without_reopen() = runTest {
        // The drop itself is classified as quota (not network/unknown): ends directly by category, no reopen, audio stops as usual
        var reopens = 0
        val r = rig(
            kind = RealtimeTransportKind.OpenAiRealtime,
            reopen = { reopens++; FakeConnection(RealtimeTransportKind.OpenAiRealtime) to plan },
        )
        send(r, RealtimeSessionEvent.Ready, RealtimeSessionEvent.Error("insufficient_quota", "quota"))
        r.connection.events.close(IOException("socket reset"))
        testScheduler.runCurrent()
        assertEquals(0, reopens)
        assertEquals(listOf<String?>("quota"), r.errors)
        assertEquals(listOf<Pair<RealtimeEndReason, String?>>(RealtimeEndReason.ERROR to null), r.ended)
        assertEquals(1, r.audio.stops)
        r.scope.cancel()
    }

    @Test
    fun unexpected_close_after_max_session_is_max_duration() = runTest {
        val r = rig(
            kind = RealtimeTransportKind.OpenAiRealtime,
            maxSessionSec = 60,
            reopen = { throw IllegalStateException("offline") },
        )
        send(r, RealtimeSessionEvent.Ready)
        testScheduler.advanceTimeBy(60_000)
        testScheduler.runCurrent()
        r.connection.events.close(IOException("socket reset"))
        testScheduler.runCurrent()
        assertEquals(listOf<String?>("max_duration"), r.errors)

        // Even with a reopener, no reopen: the drop itself was classified as max_duration, so it ends directly by category
        val second = FakeConnection(RealtimeTransportKind.OpenAiRealtime)
        val reopened = rig(kind = RealtimeTransportKind.OpenAiRealtime, maxSessionSec = 60, reopen = { second to plan })
        send(reopened, RealtimeSessionEvent.Ready)
        testScheduler.advanceTimeBy(61_000)
        testScheduler.runCurrent()
        reopened.connection.events.close(IOException("socket reset"))
        testScheduler.runCurrent()
        assertEquals(0, second.opens)
        assertEquals(listOf<String?>("max_duration"), reopened.errors)
        assertEquals(1, reopened.audio.stops)
        r.scope.cancel()
        reopened.scope.cancel()
    }

    @Test
    fun typed_barge_in_persists_interrupted_reply_first() = runTest {
        val r = rig(kind = RealtimeTransportKind.OpenAiRealtime)
        send(
            r,
            RealtimeSessionEvent.Ready,
            RealtimeSessionEvent.AssistantAudio("a1", 0, b64(downlink(1000, 1000)), 24_000),
            RealtimeSessionEvent.AssistantTranscript("a1", "one two three four", false),
        )
        repeat(25) { r.audio.playNext20ms() }
        assertEquals(500L, r.audio.playedMs("a1"))
        // Typing while the AI has not finished speaking: same order as a voice interruption -- first the catch-up progress report freezes the played part, then the user's words are persisted
        r.controller.sendUserText("wait")
        testScheduler.runCurrent()
        assertEquals(listOf("wait"), r.connection.texts)
        assertEquals(listOf("assistant:one two", "user:wait"), r.sink.calls)
        // Starting to speak triggers the barge-in once (only stops playback once), and stopping once enters thinking (fixture rt_typed_text_while_speaking_barges_in)
        assertEquals(1, r.audio.calls.count { it == "stopPlayback" })
        assertEquals(ConversationStatusKey.THINKING, r.controller.statusKey.value)
        r.scope.cancel()
    }

    /** Text typed while the connection is not ready: no conversation is created, no reducer event is dispatched, nothing is sent; only after Ready is the conversation created, persisted once, and then sent. */
    @Test
    fun typed_before_ready_waits_unreduced_until_ready() = runTest {
        val r = rig()
        testScheduler.runCurrent()
        r.controller.sendUserText("hi")
        r.controller.sendUserText("there")
        testScheduler.runCurrent()
        assertEquals(0, r.sink.ensures)
        assertTrue(r.connection.texts.isEmpty())
        assertTrue(r.sink.calls.isEmpty())
        send(r, RealtimeSessionEvent.Ready)
        assertEquals(1, r.sink.ensures)
        assertEquals(listOf("hi", "there"), r.connection.texts)
        assertEquals(listOf("user:hi", "user:there"), r.sink.calls)
        r.scope.cancel()
    }

    /** text typed during a reopen is queued and not persisted; the reopen history does not contain it; after the new connection is Ready it is flushed in order to the new connection. */
    @Test
    fun typed_while_reopening_waits_for_new_ready() = runTest {
        val second = FakeConnection(RealtimeTransportKind.OpenAiRealtime)
        var sinkAtReopen: List<String> = emptyList()
        lateinit var r: Rig
        r = rig(kind = RealtimeTransportKind.OpenAiRealtime, reopen = {
            sinkAtReopen = r.sink.calls.toList()
            second to plan
        })
        send(r, RealtimeSessionEvent.Ready)
        r.controller.sendUserText("first")
        testScheduler.runCurrent()
        send(r, RealtimeSessionEvent.AssistantTurnDone(null, RealtimeTurnStatus.Completed, "ok"))
        r.connection.events.close(IOException("socket reset"))
        testScheduler.runCurrent()
        r.controller.sendUserText("second")
        testScheduler.runCurrent()
        assertEquals(listOf("first"), r.connection.texts)
        assertTrue(second.texts.isEmpty())
        assertEquals(listOf("user:first", "assistant:ok"), sinkAtReopen)
        assertEquals(listOf("user:first", "assistant:ok"), r.sink.calls)

        second.events.trySend(RealtimeSessionEvent.Ready)
        testScheduler.runCurrent()
        assertEquals(listOf("second"), second.texts)
        assertEquals(listOf("first"), r.connection.texts)
        assertEquals(listOf("user:first", "assistant:ok", "user:second"), r.sink.calls)
        r.scope.cancel()
    }

    /** text typed while dormant is only queued; it is persisted and sent only after unmuting, reopening, and the new connection is Ready. */
    @Test
    fun typed_while_dormant_wakes_reopen_keeps_mute_and_sends_on_ready() = runTest {
        // Typing while dormant reopens right away (like unmute) but leaves mute on; the text waits for Ready.
        val second = FakeConnection()
        var reopens = 0
        val r = rig(reopen = { reopens++; second to plan })
        send(r, RealtimeSessionEvent.Ready)
        r.controller.toggleMute()
        r.connection.events.close(GeminiLiveSessionExpiredException("Gemini Live session expired (1008)"))
        testScheduler.runCurrent()
        assertEquals(0, reopens)
        r.controller.sendUserText("still here")
        testScheduler.runCurrent()
        assertEquals(1, reopens)
        assertEquals(1, second.opens)
        assertEquals(ConversationStatusKey.THINKING, r.controller.statusKey.value)
        assertTrue(r.connection.texts.isEmpty())
        assertTrue(second.texts.isEmpty())
        assertTrue(r.sink.calls.isEmpty())

        second.events.trySend(RealtimeSessionEvent.Ready)
        testScheduler.runCurrent()
        assertEquals(1, reopens)
        assertEquals(listOf("still here"), second.texts)
        assertEquals(listOf("user:still here"), r.sink.calls)
        assertTrue(r.connection.texts.isEmpty())
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

        // Contract card B item 4: unmute -> the reopener is called once, and ready is delivered by the new connection
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

        // Ending goes through the new connection
        r.controller.end()
        testScheduler.runCurrent()
        assertEquals(1, second.closes)
        assertEquals(listOf<Pair<RealtimeEndReason, String?>>(RealtimeEndReason.USER to null), r.ended)
        r.scope.cancel()
    }

    @Test
    fun openai_muted_unexpected_close_sleeps_until_unmute() = runTest {
        val second = FakeConnection(RealtimeTransportKind.OpenAiRealtime)
        var reopens = 0
        val r = rig(kind = RealtimeTransportKind.OpenAiRealtime, reopen = { reopens++; second to plan })
        send(r, RealtimeSessionEvent.Ready)
        r.controller.toggleMute()
        // Unexpected drop while muted: afterDrop decides dormant, the reducer goes dormant, no reopen, no error, audio does not stop
        r.connection.events.close(IOException("socket reset"))
        testScheduler.runCurrent()
        assertEquals(0, reopens)
        assertEquals(emptyList<String?>(), r.errors)
        assertEquals(emptyList<Pair<RealtimeEndReason, String?>>(), r.ended)
        assertEquals(ConversationStatusKey.MUTED, r.controller.statusKey.value)
        assertEquals(0, r.audio.stops)

        // Reopens only after unmuting, and ready is delivered by the new connection
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

        r.controller.end()
        testScheduler.runCurrent()
        assertEquals(1, second.closes)
        assertEquals(listOf<Pair<RealtimeEndReason, String?>>(RealtimeEndReason.USER to null), r.ended)
        assertEquals(emptyList<String?>(), r.errors)
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

        // Contract card D item 2: once expired, the uplink callback is unbound; frames during dormancy and reopen do not enter any connection
        r.audio.onFrame!!(loud)
        r.controller.toggleMute()
        testScheduler.runCurrent()
        assertEquals(1, second.opens)
        r.audio.onFrame!!(loud)
        assertEquals(oldSent, r.connection.sent.size)
        assertEquals(0, second.sent.size)

        // After the new driver is Ready, rebind; frames go to the new connection
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
        // Contract card C items 1 and 4: the microphone device stays open during dormancy
        assertEquals(0, r.audio.stops)

        r.controller.toggleMute()
        testScheduler.runCurrent()
        second.events.trySend(RealtimeSessionEvent.Ready)
        testScheduler.runCurrent()
        // Contract card C item 2: the Ready from the reopen only swaps the callback and does not call inner start again
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

        // Contract card C item 3: at the end, inner stop is called exactly once
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
        // Automatic reopen fails -> network (reopenFailed)
        assertEquals(listOf<String?>("network"), r.errors)
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
        // No reopener injected = automatic reopen fails -> network
        assertEquals(listOf<String?>("network"), r.errors)
        assertEquals(listOf<Pair<RealtimeEndReason, String?>>(RealtimeEndReason.ERROR to null), r.ended)
        r.scope.cancel()
    }

    /** Classify failures before connecting: returns errors, and records the number of catalog queries. */
    private fun TestScope.failBeforeReady(error: Throwable, catalog: Boolean? = null): Pair<Rig, Int> {
        var catalogCalls = 0
        val r = rig(catalogHasModel = {
            catalogCalls++
            catalog
        })
        r.connection.events.close(error)
        testScheduler.runCurrent()
        return r to catalogCalls
    }

    @Test
    fun failure_handshake_401_is_auth() = runTest {
        val (r, catalogCalls) = failBeforeReady(RealtimeHandshakeException(401, "ProtocolException"), catalog = true)
        assertEquals(listOf<String?>("auth"), r.errors)
        assertEquals(listOf<Pair<RealtimeEndReason, String?>>(RealtimeEndReason.ERROR to null), r.ended)
        assertEquals(ConversationStatusKey.ERROR, r.controller.statusKey.value)
        // Only ask the catalog when the connection fails, and ask once
        assertEquals(1, catalogCalls)
        r.scope.cancel()
    }

    @Test
    fun failure_handshake_429_is_quota() = runTest {
        val (r, _) = failBeforeReady(RealtimeHandshakeException(429, "ProtocolException"))
        assertEquals(listOf<String?>("quota"), r.errors)
        r.scope.cancel()
    }

    @Test
    fun failure_handshake_404_is_model_gone() = runTest {
        val (r, _) = failBeforeReady(RealtimeHandshakeException(404, "ProtocolException"), catalog = true)
        assertEquals(listOf<String?>("model_gone"), r.errors)
        // Handshake failure without an HTTP status = connectError -> network; the catalog says the model is gone -> model_gone
        assertEquals(listOf<String?>("network"), failBeforeReady(RealtimeHandshakeException(null, "UnknownHostException")).first.errors)
        val (gone, calls) = failBeforeReady(
            GeminiLiveClosedException("Gemini Live connection failed to open", connectFailed = true),
            catalog = false,
        )
        assertEquals(listOf<String?>("model_gone"), gone.errors)
        assertEquals(1, calls)
        r.scope.cancel()
    }

    @Test
    fun failure_connect_timeout_is_network() = runTest {
        val r = rig()
        testScheduler.advanceTimeBy(RealtimeModel.CONNECT_TIMEOUT_MS - 1)
        testScheduler.runCurrent()
        assertEquals(emptyList<String?>(), r.errors)
        testScheduler.advanceTimeBy(1)
        testScheduler.runCurrent()
        assertEquals(listOf<String?>("network"), r.errors)
        assertEquals(listOf<Pair<RealtimeEndReason, String?>>(RealtimeEndReason.ERROR to null), r.ended)
        assertEquals(1, r.connection.closes)

        // After Ready the timer is void: no error even after another 10 s
        val ready = rig()
        send(ready, RealtimeSessionEvent.Ready)
        testScheduler.advanceTimeBy(RealtimeModel.CONNECT_TIMEOUT_MS * 2)
        testScheduler.runCurrent()
        assertEquals(emptyList<String?>(), ready.errors)
        r.scope.cancel()
        ready.scope.cancel()
    }

    @Test
    fun failure_reopen_failed_is_network() = runTest {
        val second = FakeConnection()
        var catalogCalls = 0
        val r = rig(reopen = { second to plan }, catalogHasModel = { catalogCalls++; null })
        send(r, RealtimeSessionEvent.Ready)
        // Unmuted expiry -> auto reopen once with the history; the reopened connection fails before reaching Ready
        r.connection.events.close(GeminiLiveSessionExpiredException("Gemini Live session expired (1008)"))
        testScheduler.runCurrent()
        assertEquals(1, second.opens)
        second.events.close(IOException("socket reset"))
        testScheduler.runCurrent()
        assertEquals(listOf<String?>("network"), r.errors)
        assertEquals(listOf<Pair<RealtimeEndReason, String?>>(RealtimeEndReason.ERROR to null), r.ended)
        assertEquals(0, catalogCalls)

        // Gemini handle reconnect exhausted: also records reopenFailed
        val exhausted = rig()
        send(exhausted, RealtimeSessionEvent.Ready)
        val error = GeminiLiveClosedException("Gemini Live connection closed unexpectedly")
        error.reconnectsExhausted = true
        exhausted.connection.events.close(error)
        testScheduler.runCurrent()
        assertEquals(listOf<String?>("network"), exhausted.errors)
        r.scope.cancel()
        exhausted.scope.cancel()
    }

    @Test
    fun failure_uplink_backlog_over_8s_is_network() = runTest {
        val over = rig()
        send(over, RealtimeSessionEvent.Ready)
        over.connection.events.close(GeminiLiveClosedException("Gemini Live uplink stalled", uplinkBacklogMs = 8_001.0))
        testScheduler.runCurrent()
        assertEquals(listOf<String?>("network"), over.errors)

        // Exactly 8000 ms is not counted as backlog
        val at = rig()
        send(at, RealtimeSessionEvent.Ready)
        at.connection.events.close(GeminiLiveClosedException("Gemini Live uplink stalled", uplinkBacklogMs = 8_000.0))
        testScheduler.runCurrent()
        assertEquals(listOf<String?>("unknown"), at.errors)
        over.scope.cancel()
        at.scope.cancel()
    }

    @Test
    fun failure_elapsed_reaches_max_session_is_max_duration() = runTest {
        var catalogCalls = 0
        val r = rig(maxSessionSec = 60, catalogHasModel = {
            catalogCalls++
            null
        })
        send(r, RealtimeSessionEvent.Ready)
        testScheduler.advanceTimeBy(60_000)
        testScheduler.runCurrent()
        r.connection.events.close(IOException("socket reset"))
        testScheduler.runCurrent()
        assertEquals(listOf<String?>("max_duration"), r.errors)
        // A failure after connecting does not query the catalog
        assertEquals(0, catalogCalls)

        // Below the limit -> no signal -> unknown
        val early = rig(maxSessionSec = 60)
        send(early, RealtimeSessionEvent.Ready)
        testScheduler.advanceTimeBy(59_000)
        testScheduler.runCurrent()
        early.connection.events.close(IOException("socket reset"))
        testScheduler.runCurrent()
        assertEquals(listOf<String?>("unknown"), early.errors)
        r.scope.cancel()
        early.scope.cancel()
    }

    @Test
    fun failure_last_error_code_used_on_close() = runTest {
        val r = rig()
        send(
            r,
            RealtimeSessionEvent.Ready,
            RealtimeSessionEvent.Error("invalid_request_error", "first"),
            RealtimeSessionEvent.Error("insufficient_quota", "second"),
        )
        // A mid-session error is not fatal
        assertEquals(emptyList<String?>(), r.errors)
        assertEquals(emptyList<Pair<RealtimeEndReason, String?>>(), r.ended)
        r.connection.events.close(RealtimeSocketClosedException(1011, "server error"))
        testScheduler.runCurrent()
        // The subsequent close uses the code of the most recent error
        assertEquals(listOf<String?>("quota"), r.errors)
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
        // Microphone frames that still arrive when the connection closes must not uplink again: Close shuts the uplink first, then closes.
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
        // 1 s of audio is split into 50 frames of 20 ms, amplitude increasing per frame (all within the mapped 0…1): each window's level differs, so publishing once adds one more value.
        repeat(50) { k ->
            val amp = (220 + 100 * k).toShort()
            r.audio.onFrame!!(RealtimePCM.toLittleEndian(ShortArray(frameSamples) { if (it % 2 == 0) amp else (-amp).toShort() }))
        }
        assertEquals(50, r.connection.sent.size)
        val published = seen.drop(1)
        assertTrue("published ${published.size} levels for 1 s of audio", published.size <= 15)
        val framesPerWindow = (PeakLevelWindow.windowSamples(rate) + frameSamples - 1) / frameSamples
        assertEquals(50 / framesPerWindow, published.size)
        assertEquals(published.sorted(), published)
        assertEquals(published.last(), r.controller.level.value)
        collecting.cancel()
        r.scope.cancel()
    }

    @Test
    fun uplink_level_is_window_peak_not_mean() = runTest {
        val r = rig()
        send(r, RealtimeSessionEvent.Ready)
        val rate = r.connection.uplinkSampleRateHz
        val frameSamples = rate / 50
        val framesPerWindow = (PeakLevelWindow.windowSamples(rate) + frameSamples - 1) / frameSamples
        fun frame(amp: Int) = RealtimePCM.toLittleEndian(ShortArray(frameSamples) { if (it % 2 == 0) amp.toShort() else (-amp).toShort() })
        // Only one frame in a window is loud: the level is that frame's, not averaged down by quiet frames.
        repeat(framesPerWindow - 1) { r.audio.onFrame!!(frame(300)) }
        r.audio.onFrame!!(frame(1500))
        assertEquals(mapped(ampDb(1500)), r.controller.level.value, 1e-4f)
        // An all-silent window is 0.
        repeat(framesPerWindow) { r.audio.onFrame!!(ByteArray(frameSamples * 2)) }
        assertEquals(0f, r.controller.level.value)
        r.scope.cancel()
    }

    @Test
    fun speaking_level_from_downlink_pcm_peak_at_most_15hz() = runTest {
        val r = rig()
        send(r, RealtimeSessionEvent.Ready, RealtimeSessionEvent.AssistantAudio(null, 0, "AQA=", 24_000))
        assertEquals(ConversationStatusKey.SPEAKING, r.controller.statusKey.value)
        val seen = mutableListOf<Float>()
        val collecting = r.scope.launch { r.controller.level.collect { seen += it } }
        // 1 s of downlink, 20 ms per block, amplitude increasing per block: one publish per window, ≤ 15 times per second.
        val pcm = (0 until 50).map { k -> downlink(20, (220 + 100 * k).toShort()) }
        pcm.forEach { r.audio.play(it) }
        val published = seen.drop(1)
        assertTrue("published ${published.size} levels for 1 s of playback", published.size <= 15)
        val framesPerWindow = (PeakLevelWindow.windowSamples(RealtimePCM.OUTPUT_RATE) + 479) / 480
        assertEquals(50 / framesPerWindow, published.size)
        assertEquals(published.sorted(), published)
        // Within the window the peak is taken: the level of the last full window is that of its last (loudest) block.
        val lastFull = 50 / framesPerWindow * framesPerWindow - 1
        assertEquals(mapped(ampDb(220 + 100 * lastFull)), r.controller.level.value, 1e-4f)
        // Silent blocks: first finish the previous window (the last two blocks still have sound); afterwards a fully digital-silent window is level 0.
        r.audio.play(downlink(200, 0))
        assertEquals(0f, r.controller.level.value)
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
        // No wake-ups before the deadline: the one-shot timer fires only when idleEndMs is reached
        testScheduler.advanceTimeBy(RealtimeConversationConstants.IDLE_END_MS - 1)
        testScheduler.runCurrent()
        assertEquals(readsAfterReady, r.clockReads)
        assertTrue(r.ended.isEmpty())
        testScheduler.advanceTimeBy(1)
        testScheduler.runCurrent()
        assertEquals(listOf<Pair<RealtimeEndReason, String?>>(RealtimeEndReason.IDLE to null), r.ended)
        // No timers are scheduled after ending
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
        r.audio.play(downlink(80, 2000))
        assertTrue(r.controller.level.value > 0f)
        r.controller.end()
        testScheduler.runCurrent()
        assertEquals(listOf<Pair<RealtimeEndReason, String?>>(RealtimeEndReason.USER to null), r.ended)
        assertEquals(0f, r.controller.level.value)
        // A block written late on the write thread after ending does not publish a level
        r.audio.play(downlink(80, 2000))
        assertEquals(0f, r.controller.level.value)
        val statusAfterEnd = r.controller.statusKey.value
        val callsAfterEnd = r.audio.calls.toList()
        // A finished-playing marker that arrives late after stop is not folded into the ended session
        r.audio.drain()
        testScheduler.runCurrent()
        assertEquals(statusAfterEnd, r.controller.statusKey.value)
        assertEquals(callsAfterEnd, r.audio.calls)
        assertEquals(listOf<Pair<RealtimeEndReason, String?>>(RealtimeEndReason.USER to null), r.ended)
        assertEquals(0f, r.controller.level.value)
        r.scope.cancel()
    }

    @Test
    fun late_downlink_block_on_writer_thread_after_end_publishes_no_level() = runTest {
        val r = rig()
        send(r, RealtimeSessionEvent.Ready, RealtimeSessionEvent.AssistantAudio(null, 0, "AQA=", 24_000))
        assertEquals(ConversationStatusKey.SPEAKING, r.controller.statusKey.value)
        r.audio.play(downlink(80, 2000))
        assertTrue(r.controller.level.value > 0f)
        r.controller.end()
        testScheduler.runCurrent()
        assertEquals(0f, r.controller.level.value)
        val seen = mutableListOf<Float>()
        val collecting = r.scope.launch { r.controller.level.collect { seen += it } }
        testScheduler.runCurrent()
        // Downlink blocks that arrive late on the AudioTrack write thread after ending (a full window or more) do not publish a level.
        val writer = Thread { r.audio.play(downlink(200, 3000)) }
        writer.start()
        writer.join()
        testScheduler.runCurrent()
        assertEquals(listOf(0f), seen)
        assertEquals(0f, r.controller.level.value)
        collecting.cancel()
        r.scope.cancel()
    }

    @Test
    fun end_does_not_join_capture_on_main() = runTest {
        val r = rig()
        send(r, RealtimeSessionEvent.Ready)
        val caller = Thread.currentThread()
        r.controller.end()
        testScheduler.runCurrent()
        // The controller calls stop synchronously on the calling thread (it only initiates teardown and does not wait)
        assertEquals(1, r.audio.stops)
        assertSame(caller, r.audio.stopThread)
        // AndroidRealtimeAudio.stop hands the blocking step to launchTeardown: the caller returns immediately and the step runs to completion on the IO thread
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
        // NonCancellable: teardown still runs to completion even if the scope is cancelled
        io.cancel()
        var ranAfterCancel = false
        runBlocking { launchTeardown(io) { ranAfterCancel = true }.join() }
        assertTrue(ranAfterCancel)
        r.scope.cancel()
    }

    // ---- realtime-session.v1: replan at turn boundaries; reopen only if the fingerprint changed ----

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
        // Old connection closed, new connection swapped in; the shared audio does not stop (one-shot)
        assertEquals(1, r.connection.closes)
        assertEquals(1, second.opens)
        assertEquals(0, r.audio.stops)
        assertEquals(ConversationStatusKey.THINKING, r.controller.statusKey.value)
        second.events.trySend(RealtimeSessionEvent.Ready)
        testScheduler.runCurrent()
        assertEquals(ConversationStatusKey.LISTENING, r.controller.statusKey.value)
        // The ready of the new connection does not trigger a replan again; teardown of the old connection does not send systemInterruption
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
        // Exactly one replan per turn boundary; the same fingerprint does not reopen
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
        // A new turn started before the result arrived: the result is discarded and does not reopen
        send(r, RealtimeSessionEvent.UserSpeechStarted(null))
        result.complete(changed)
        testScheduler.runCurrent()
        assertEquals(0, reopens)
        assertEquals(0, r.connection.closes)
        r.scope.cancel()
    }

    // ───────────── Loudspeaker uplink gate (contract items 2 and 3) ─────────────

    /** 20 ms square wave at 24 kHz (±[amp]); [tag] is written into the first sample so each frame's bytes are distinguishable (negligible effect on RMS). */
    private fun square(amp: Int, tag: Int? = null): ByteArray =
        RealtimePCM.toLittleEndian(
            ShortArray(RealtimePCM.OUTPUT_RATE / 50) { i ->
                if (i == 0 && tag != null) tag.toShort() else if (i % 2 == 0) amp.toShort() else (-amp).toShort()
            },
        )

    /** Room noise floor of about −52 dBFS: the server stand-in (> −50) cannot hear it. */
    private val ambientAmp = 82

    /** Echo frame = a copy of the downlink block attenuated by gain to [db] dBFS (uplink and downlink are both 24 kHz, 20 ms). */
    private fun echoOf(chunk: ByteArray, db: Double): ByteArray {
        val gain = Math.pow(10.0, (db - RealtimePCM.blockDb(chunk)!!) / 20)
        val samples = ShortArray(chunk.size / 2) { i ->
            val v = ((chunk[2 * i + 1].toInt() shl 8) or (chunk[2 * i].toInt() and 0xff)).toShort()
            Math.round(v * gain).toInt().toShort()
        }
        return RealtimePCM.toLittleEndian(samples)
    }

    private fun b64(pcm: ByteArray): String = java.util.Base64.getEncoder().encodeToString(pcm)

    private class EchoLoopResult(
        val replies: Int,
        val sentWhilePlaying: Int,
        val interrupts: Int,
        val lastReplyStatuses: Set<ConversationStatusKey?>,
    )

    /**
     * Loudspeaker self-excitation reproduced: every 20 ms a downlink block is written, and the microphone picks up a copy attenuated to [echoDb] (it is noise floor when not playing). Server VAD stand-in:
     * when a frame above −50 dBFS is heard during playback, it replies with userSpeechStarted / userSpeechStopped / final userTranscript (a fragment of the reply's text),
     * then gives the next segment of the reply; if nothing is heard it gives the next segment 1.5 s after playback ends. [replies] segments of reply in total.
     */
    private fun TestScope.echoLoop(echoDb: Double, replies: Int = 5): EchoLoopResult {
        val r = rig()
        send(r, RealtimeSessionEvent.Ready)
        val text = "the weather today is sunny and warm with a light breeze"
        val fragment = "the weather today is sunny and warm"
        val reply = downlink(2000, 4000)
        var sentWhilePlaying = 0
        var heard = false
        r.connection.onSend = { pcm ->
            if (r.audio.playing) {
                sentWhilePlaying++
                if ((RealtimePCM.blockDb(pcm) ?: -120.0) > -50.0) heard = true
            }
        }
        var count = 0
        var cycleOpen = false
        val lastStatuses = mutableSetOf<ConversationStatusKey?>()
        fun nextReply() {
            count++
            heard = false
            cycleOpen = true
            val id = "r$count"
            send(
                r,
                RealtimeSessionEvent.AssistantAudio(id, 0, b64(reply), RealtimePCM.OUTPUT_RATE),
                RealtimeSessionEvent.AssistantTranscript(id, text, true),
                RealtimeSessionEvent.AssistantTurnDone(id, RealtimeTurnStatus.Completed, text),
            )
        }
        var nextReplyAt: Int? = 25
        var endAt: Int? = null
        var step = 0
        while (step < 3000 && (endAt == null || step < endAt)) {
            if (nextReplyAt == step) {
                nextReplyAt = null
                nextReply()
            }
            val chunk = r.audio.playNext20ms()
            if (count == replies && r.audio.playing) lastStatuses += r.controller.statusKey.value
            r.audio.onFrame!!(chunk?.let { echoOf(it, echoDb) } ?: square(ambientAmp))
            testScheduler.advanceTimeBy(20)
            testScheduler.runCurrent()
            if (heard) {
                heard = false
                val id = "u$count"
                send(
                    r,
                    RealtimeSessionEvent.UserSpeechStarted(id),
                    RealtimeSessionEvent.UserSpeechStopped(id),
                    RealtimeSessionEvent.UserTranscript(id, fragment, true),
                )
                if (count < replies) nextReply()
            }
            if (cycleOpen && !r.audio.playing) {
                cycleOpen = false
                if (count < replies) nextReplyAt = step + 75 else endAt = step + 75
            }
            step++
        }
        val interrupts = r.audio.calls.count { it == "stopPlayback" }
        assertTrue("loop did not finish", endAt != null)
        r.scope.cancel()
        return EchoLoopResult(count, sentWhilePlaying, interrupts, lastStatuses)
    }

    @Test
    fun speaker_echo_never_reaches_server() = runTest {
        // −45 dBFS residual echo: local voice detection does not let it through; during playback and within one frame of the tail window nothing is uplinked, so the server does not hear it and does not interrupt.
        val result = echoLoop(-45.0)
        assertEquals(5, result.replies)
        assertEquals(0, result.sentWhilePlaying)
        assertEquals(0, result.interrupts)
    }

    @Test
    fun speaker_loud_echo_loop_bounded_by_false_barge_ins() = runTest {
        // −30 dBFS residual echo: the gate lets it through as voice, and the server hears a fragment of the reply back; after 2 false interruptions interruption is turned off and it is no longer interrupted by echo.
        val result = echoLoop(-30.0)
        assertEquals(5, result.replies)
        assertTrue("interrupts ${result.interrupts}", result.interrupts in 1..2)
        assertEquals(setOf<ConversationStatusKey?>(ConversationStatusKey.SPEAKING_TAP_TO_INTERRUPT), result.lastReplyStatuses)
    }

    @Test
    fun speaker_barge_in_opens_with_preroll() = runTest {
        val r = rig()
        send(r, RealtimeSessionEvent.Ready)
        val injected = mutableListOf<ByteArray>()
        fun inject(amp: Int) {
            val frame = square(amp, tag = injected.size + 1)
            injected += frame
            r.audio.onFrame!!(frame)
        }
        // Not armed: pass-through
        repeat(25) { inject(ambientAmp) }
        assertEquals(25, r.connection.sent.size)
        send(r, RealtimeSessionEvent.AssistantAudio("r1", 0, b64(downlink(3000, 4000)), RealtimePCM.OUTPUT_RATE))
        assertTrue(r.audio.playing)
        val pb = injected.size
        // Speech is only allowed after the 1 s playback start grace period
        repeat(60) { inject(ambientAmp) }
        val speechStart = injected.size
        repeat(14) { inject(2000) }
        assertEquals(25, r.connection.sent.size)
        // The 15th voice frame (300 ms) holds: the current frame passes, and the held frames from [runStart − 15 pre-roll frames, current frame] are sent in order; earlier held frames are dropped
        inject(2000)
        val flushFrom = maxOf(pb, speechStart - VoiceConversationConstants.PREROLL_FRAMES)
        assertEquals(
            injected.subList(flushFrom, injected.size).map { it.toList() },
            r.connection.sent.drop(25).map { it.toList() },
        )
        // Pass-through after letting through
        inject(2000)
        assertArrayEquals(injected.last(), r.connection.sent.last())
        assertEquals(25 + injected.size - flushFrom, r.connection.sent.size)
        r.scope.cancel()
    }

    /** Fake voice-activity probability model: gives [prob] per frame; after close, or inference failure from frame [failFrom] on, gives null (consistent with the Silero adapter). */
    private class FakeSpeechModel : SpeechProbModel {
        var prob = 0f
        var fed = 0
        @Volatile var closed = false
        var failFrom = Int.MAX_VALUE

        // Close may happen on the IO thread (a late model): let one through after closing
        val closedSignal = java.util.concurrent.Semaphore(0)

        override fun feed(frame: ShortArray): Float? {
            if (closed) return null
            fed++
            return if (fed >= failFrom) null else prob
        }

        override val lastInferenceNanos: Long = 0L

        override fun close() {
            closed = true
            closedSignal.release()
        }
    }

    /** Amplitude of the 20 ms square wave at −30 dBFS / −18 dBFS (the RMS of a square wave equals its amplitude). */
    private val echo30Amp = 1036
    private val voice18Amp = 4125

    /** Model-mode gate test bench: the capture tap first feeds 16 kHz frames (the model gives [prob]), then sends the uplink of the same frame. */
    private inner class ModelGateBench(val r: Rig, val model: FakeSpeechModel) {
        val injected = mutableListOf<ByteArray>()

        fun inject(amp: Int, prob: Float) {
            model.prob = prob
            val frame = square(amp, tag = injected.size + 1)
            injected += frame
            r.audio.onCapture!!(ShortArray(ConversationFrames.FRAME_SAMPLES))
            r.audio.onFrame!!(frame)
        }
    }

    private fun TestScope.modelGateBench(model: FakeSpeechModel = FakeSpeechModel()): ModelGateBench {
        val r = rig(speechProbs = SpeechProbSource { model })
        send(r, RealtimeSessionEvent.Ready)
        return ModelGateBench(r, model)
    }

    /** One frame of the expanded fixture gate frame: near-end dB, model probability, downlink reference dB. */
    private data class GateFixtureFrame(val db: Double, val prob: Double?, val ref: Double?)

    private class GateFixtureCase(
        val frames: List<GateFixtureFrame>,
        val playbackStart: Int,
        val playbackEnded: Int,
        val expected: JsonObject,
    )

    private fun workspaceFile(relative: String): java.io.File {
        var dir: java.io.File? = java.io.File("").absoluteFile
        while (dir != null) {
            val candidate = java.io.File(dir, relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("could not find $relative")
    }

    /** The entry [id] in the contract fixture uplinkGateCases; frames are expanded as [db, n, prob, ref]. */
    private fun gateFixture(id: String): GateFixtureCase {
        val fixture = Json.parseToJsonElement(workspaceFile("shared/voice-contracts/realtime-conversation.v1.json").readText()).jsonObject
        val case = fixture["uplinkGateCases"]!!.jsonArray.map { it.jsonObject }.single { it["id"]!!.jsonPrimitive.content == id }
        val input = case["input"]!!.jsonObject
        val frames = input["frames"]!!.jsonArray.flatMap { el ->
            val a = el.jsonArray
            val prob = a[2].let { if (it is JsonNull) null else it.jsonPrimitive.double }
            val ref = a[3].let { if (it is JsonNull) null else it.jsonPrimitive.double }
            List(a[1].jsonPrimitive.int) { GateFixtureFrame(a[0].jsonPrimitive.double, prob, ref) }
        }
        val opts = input["opts"]!!.jsonObject
        return GateFixtureCase(
            frames,
            opts["playbackStartFrame"]!!.jsonPrimitive.int,
            opts["playbackEndedFrame"]!!.jsonPrimitive.int,
            case["expected"]!!.jsonObject,
        )
    }

    /**
     * 20 ms square-wave uplink frame with RMS exactly [db] dBFS: every sample has the same amplitude; the frame number [tag] is encoded only in the sign of the first 12 samples and does not change the level.
     */
    private fun levelFrame(db: Double, tag: Int): ByteArray {
        val amp = Math.round(32768 * Math.pow(10.0, db / 20)).toInt().coerceAtLeast(1)
        return RealtimePCM.toLittleEndian(
            ShortArray(RealtimePCM.OUTPUT_RATE / 50) { i ->
                val sign = if (i % 2 == 0) 1 else -1
                val flip = if (i < 12 && (tag shr i) and 1 == 1) -1 else 1
                (amp * sign * flip).toShort()
            },
        )
    }

    /**
     * Fixture frames are fed frame by frame through the fake audio to the controller: the reply is issued before frame playbackStartFrame (start of playback), and the finished-playing callback before frame playbackEndedFrame;
     * each frame first queues its downlink reference, then goes through the capture tap (the model gives prob) and the uplink. Feeds the frames [from, until] (inclusive) and returns those injected frames.
     */
    private fun TestScope.feedGateFixture(b: ModelGateBench, case: GateFixtureCase, from: Int, until: Int): List<ByteArray> {
        val injected = mutableListOf<ByteArray>()
        for (i in from..until) {
            val f = case.frames[i]
            if (i == case.playbackStart) {
                send(b.r, RealtimeSessionEvent.AssistantAudio("r1", 0, b64(downlink(12_000, 4000)), RealtimePCM.OUTPUT_RATE))
                assertTrue(b.r.audio.playing)
            }
            if (i == case.playbackEnded) {
                b.r.audio.drain()
                testScheduler.runCurrent()
            }
            b.model.prob = f.prob?.toFloat() ?: 0f
            b.r.audio.refs.addLast(f.ref)
            val frame = levelFrame(f.db, i + 1)
            injected += frame
            b.r.audio.onCapture!!(ShortArray(ConversationFrames.FRAME_SAMPLES))
            b.r.audio.onFrame!!(frame)
            // Take one reference per gate frame
            assertTrue("frame $i ref not consumed", b.r.audio.refs.isEmpty())
        }
        return injected
    }

    @Test
    fun speaker_echo_reference_correlated_echo_never_reaches_server() = runTest {
        // Loudspeaker AEC degrades: the echo rises and falls with the downlink reference, and the model judges voice (0.9). Reference-correlated echo frames are fed to the VAD with prob 0:
        // during playback and within one frame of the tail window nothing is uplinked; only when the tail window ends is it let through and the pre-roll is sent.
        val case = gateFixture("rt_gate_echo_ref_correlated_echo_held")
        val b = modelGateBench()
        val pb = case.playbackStart
        val openAt = case.expected["openAtFrame"]!!.jsonPrimitive.int
        val flushFrom = case.expected["flushFromFrame"]!!.jsonPrimitive.int
        val held = feedGateFixture(b, case, 0, openAt - 1)
        assertEquals(pb, b.r.connection.sent.size)
        val all = held + feedGateFixture(b, case, openAt, case.frames.size - 1)
        assertEquals(
            (all.subList(0, pb) + all.subList(flushFrom, all.size)).map { it.toList() },
            b.r.connection.sent.map { it.toList() },
        )
        b.r.scope.cancel()
    }

    @Test
    fun speaker_echo_reference_barge_in_opens() = runTest {
        // The user interrupts during playback: near end far above the reference (it does not follow): the echo is not judged, voice holds and the current frame passes, and the held frames from the pre-roll start are sent in order.
        val case = gateFixture("rt_gate_echo_ref_barge_in_louder_opens")
        val b = modelGateBench()
        val pb = case.playbackStart
        val openAt = case.expected["openAtFrame"]!!.jsonPrimitive.int
        val flushFrom = case.expected["flushFromFrame"]!!.jsonPrimitive.int
        assertEquals("speech", case.expected["openReason"]!!.jsonPrimitive.content)
        val injected = feedGateFixture(b, case, 0, openAt)
        assertTrue(b.r.audio.playing)
        assertEquals(
            (injected.subList(0, pb) + injected.subList(flushFrom, openAt + 1)).map { it.toList() },
            b.r.connection.sent.map { it.toList() },
        )
        b.r.scope.cancel()
    }

    @Test
    fun speaker_degraded_echo_low_prob_never_reaches_server() = runTest {
        // AEC degraded: −30 dBFS echo persists for the whole playback period and the model judges non-voice (0.1): no frame is uplinked during playback (energy mode lets it through after the grace period).
        val b = modelGateBench()
        repeat(25) { b.inject(ambientAmp, 0.02f) }
        assertEquals(25, b.r.connection.sent.size)
        send(b.r, RealtimeSessionEvent.AssistantAudio("r1", 0, b64(downlink(4000, 4000)), RealtimePCM.OUTPUT_RATE))
        assertTrue(b.r.audio.playing)
        repeat(150) { b.inject(echo30Amp, 0.1f) }
        assertTrue(b.r.audio.playing)
        assertEquals(25, b.r.connection.sent.size)
        assertEquals(175, b.model.fed)
        b.r.scope.cancel()
    }

    @Test
    fun speaker_barge_in_high_prob_opens_over_echo() = runTest {
        val b = modelGateBench()
        repeat(25) { b.inject(ambientAmp, 0.02f) }
        send(b.r, RealtimeSessionEvent.AssistantAudio("r1", 0, b64(downlink(4000, 4000)), RealtimePCM.OUTPUT_RATE))
        assertTrue(b.r.audio.playing)
        // −30 dBFS echo, low probability: held
        repeat(120) { b.inject(echo30Amp, 0.1f) }
        val speechStart = b.injected.size
        // −18 dBFS high-probability voice overpowers the echo: the 15th frame holds, the current frame passes, and held frames from 15 frames of pre-roll are sent
        repeat(14) { b.inject(voice18Amp, 0.95f) }
        assertEquals(25, b.r.connection.sent.size)
        b.inject(voice18Amp, 0.95f)
        val flushFrom = speechStart - VoiceConversationConstants.PREROLL_FRAMES
        assertEquals(
            b.injected.subList(flushFrom, b.injected.size).map { it.toList() },
            b.r.connection.sent.drop(25).map { it.toList() },
        )
        b.r.scope.cancel()
    }

    @Test
    fun speaker_model_inference_failed_falls_back_energy() = runTest {
        val model = FakeSpeechModel().apply { failFrom = 26 }
        val b = modelGateBench(model)
        // Inference fails from frame 26 on: the model is closed and no longer fed; the rest of the session falls back to the new energy VAD
        repeat(50) { b.inject(ambientAmp, 0.02f) }
        assertTrue(model.closed)
        assertEquals(26, model.fed)
        assertEquals(50, b.r.connection.sent.size)
        send(b.r, RealtimeSessionEvent.AssistantAudio("r1", 0, b64(downlink(4000, 4000)), RealtimePCM.OUTPUT_RATE))
        val pb = b.injected.size
        // −30 dBFS low probability (probability no longer participates): after the 50-frame playback start grace period, 15 consecutive frames by energy hold, and frame 65 passes
        repeat(64) { b.inject(echo30Amp, 0.1f) }
        assertEquals(50, b.r.connection.sent.size)
        b.inject(echo30Amp, 0.1f)
        assertTrue(b.r.connection.sent.size > 50)
        assertArrayEquals(b.injected.last(), b.r.connection.sent.last())
        assertTrue(b.r.connection.sent.drop(50).all { sent -> b.injected.indexOfFirst { it.contentEquals(sent) } >= pb })
        b.r.scope.cancel()
    }

    /** A model load blocked on IO: [loading] indicates it has started; after [release] it hands over [model]. */
    private class BlockedLoad(val model: FakeSpeechModel = FakeSpeechModel()) {
        val loading = CountDownLatch(1)
        val release = CountDownLatch(1)
        val source = SpeechProbSource {
            loading.countDown()
            release.await(5, TimeUnit.SECONDS)
            model
        }
    }

    @Test
    fun speaker_model_not_ready_energy_whole_session() = runTest {
        val load = BlockedLoad()
        val r = rig(replanContext = Dispatchers.IO, speechProbs = load.source)
        assertTrue(load.loading.await(5, TimeUnit.SECONDS))
        // Connecting does not wait for the model; capture waits for the session to open + the 500 ms deadline
        send(r, RealtimeSessionEvent.Ready)
        assertEquals(0, r.audio.starts)
        testScheduler.advanceTimeBy(VoiceConversationController.SPEECH_MODEL_WAIT_MS - 1)
        testScheduler.runCurrent()
        assertEquals(0, r.audio.starts)
        testScheduler.advanceTimeBy(1)
        testScheduler.runCurrent()
        assertEquals(1, r.audio.starts)
        // A model arriving after the deadline is not taken; it is closed on arrival
        load.release.countDown()
        assertTrue(load.model.closedSignal.tryAcquire(5, TimeUnit.SECONDS))
        // Energy-based criteria for this session: −30 dBFS low-probability echo is passed after 15 consecutive frames by energy once the playback start grace period has elapsed
        val b = ModelGateBench(r, load.model)
        repeat(25) { b.inject(ambientAmp, 0.02f) }
        assertEquals(25, r.connection.sent.size)
        send(r, RealtimeSessionEvent.AssistantAudio("r1", 0, b64(downlink(4000, 4000)), RealtimePCM.OUTPUT_RATE))
        assertTrue(r.audio.playing)
        repeat(64) { b.inject(echo30Amp, 0.1f) }
        assertEquals(25, r.connection.sent.size)
        b.inject(echo30Amp, 0.1f)
        assertArrayEquals(b.injected.last(), r.connection.sent.last())
        assertEquals(0, load.model.fed)
        r.scope.cancel()
    }

    @Test
    fun ended_while_loading_closes_model() = runTest {
        val load = BlockedLoad()
        val r = rig(replanContext = Dispatchers.IO, speechProbs = load.source)
        assertTrue(load.loading.await(5, TimeUnit.SECONDS))
        send(r, RealtimeSessionEvent.Ready)
        assertEquals(0, r.audio.starts)
        // Ended while waiting for the model: capture is not reopened, and a late model is closed on arrival
        r.controller.end()
        testScheduler.runCurrent()
        assertEquals(1, r.ended.size)
        load.release.countDown()
        assertTrue(load.model.closedSignal.tryAcquire(5, TimeUnit.SECONDS))
        testScheduler.advanceTimeBy(VoiceConversationController.SPEECH_MODEL_WAIT_MS)
        testScheduler.runCurrent()
        assertEquals(0, r.audio.starts)
        assertEquals(0, load.model.fed)
        r.scope.cancel()
    }

    @Test
    fun headphones_uplink_not_gated() = runTest {
        val r = rig()
        r.audio.route = ConversationRoute.HEADPHONES
        send(r, RealtimeSessionEvent.Ready)
        send(r, RealtimeSessionEvent.AssistantAudio("r1", 0, b64(downlink(2000, 4000)), RealtimePCM.OUTPUT_RATE))
        assertTrue(r.audio.playing)
        val injected = (1..80).map { square(2000, tag = it) }
        injected.forEach { r.audio.onFrame!!(it) }
        assertEquals(injected.map { it.toList() }, r.connection.sent.map { it.toList() })
        r.scope.cancel()
    }

    @Test
    fun muted_frames_never_flushed_after_unmute() = runTest {
        val r = rig()
        send(r, RealtimeSessionEvent.Ready)
        send(r, RealtimeSessionEvent.AssistantAudio("r1", 0, b64(downlink(3000, 4000)), RealtimePCM.OUTPUT_RATE))
        assertTrue(r.audio.playing)
        var tag = 0
        val before = (1..50).map { square(ambientAmp, tag = ++tag) }
        before.forEach { r.audio.onFrame!!(it) }
        assertEquals(0, r.connection.sent.size)
        // Frames recorded during muting still feed the gate but do not enter the held queue
        r.controller.toggleMute()
        val muted = (1..10).map { square(ambientAmp, tag = ++tag) }
        muted.forEach { r.audio.onFrame!!(it) }
        r.controller.toggleMute()
        val base = r.connection.sent.size
        // Speech right after unmuting: the pre-roll look-back reaches the muted segment and the pre-mute part, but only the held frames that were held while the uplink was open are sent
        val speech = (1..15).map { square(2000, tag = ++tag) }
        speech.forEach { r.audio.onFrame!!(it) }
        val after = r.connection.sent.drop(base).map { it.toList() }
        assertEquals(speech.map { it.toList() }, after)
        val forbidden = (before + muted).map { it.toList() }.toSet()
        assertTrue(r.connection.sent.none { it.toList() in forbidden })
        r.scope.cancel()
    }

    @Test
    fun stale_drained_does_not_end_new_cycle() = runTest {
        val r = rig()
        send(r, RealtimeSessionEvent.Ready)
        send(r, RealtimeSessionEvent.AssistantAudio("r1", 0, b64(downlink(200, 4000)), RealtimePCM.OUTPUT_RATE))
        r.audio.drain()
        testScheduler.runCurrent()
        // The same reply continues into the next segment: a new playback cycle starts
        send(r, RealtimeSessionEvent.AssistantAudio("r1", 0, b64(downlink(3000, 4000)), RealtimePCM.OUTPUT_RATE))
        assertTrue(r.audio.playing)
        val base = r.connection.sent.size
        // A finished-playing callback from the previous cycle arrives late: it must not be taken as the new cycle finishing; the tail window is not started, and the gate keeps holding
        r.audio.staleDrain()
        testScheduler.runCurrent()
        val guardFrames = VoiceConversationConstants.POST_PLAYBACK_GUARD_MS / VoiceConversationConstants.FRAME_MS
        repeat(guardFrames + 40) { r.audio.onFrame!!(square(ambientAmp, tag = it + 1)) }
        assertEquals(base, r.connection.sent.size)
        r.scope.cancel()
    }

    /** Scheduler that counts dispatches: asserts that the replan runs on the injected IO context rather than on the thread the controller is on. */
    private class RecordingDispatcher(private val inner: CoroutineDispatcher) : CoroutineDispatcher() {
        var dispatches = 0

        override fun isDispatchNeeded(context: CoroutineContext): Boolean = true

        override fun dispatch(context: CoroutineContext, block: Runnable) {
            dispatches++
            inner.dispatch(context, block)
        }
    }
}
