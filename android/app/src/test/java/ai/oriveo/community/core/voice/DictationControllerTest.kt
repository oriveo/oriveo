package ai.oriveo.community.core.voice

import android.speech.SpeechRecognizer
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.voice.conversation.CaptureTeardownGate
import ai.oriveo.community.testing.TestSharedPreferences
import java.io.File
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.Runnable
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Drives the production [DictationController] main flow with a real [RecordingStore] (temp dir) plus fake engines / capture / encoders. */
@OptIn(ExperimentalCoroutinesApi::class)
class DictationControllerTest {

    @get:Rule
    val temp = TemporaryFolder()

    /** Emits one 16-byte AU per 1024 samples. */
    private class FakeEncoder : AacEncoder {
        private var pending = 0

        /** Throws while flushing the tail frame on file close (simulates encoder / disk errors). */
        var failOnFinish = false
        override val encoderDelay: Int? = 2112

        override fun encode(samples: ShortArray, count: Int): List<AacEncodedUnit> {
            pending += count
            val out = mutableListOf<AacEncodedUnit>()
            while (pending >= 1024) {
                pending -= 1024
                out += AacEncodedUnit(ByteArray(16) { it.toByte() }, isCodecConfig = false)
            }
            return out
        }

        override fun finish(): List<AacEncodedUnit> {
            if (failOnFinish) throw java.io.IOException("encoder flush failed")
            if (pending == 0) return emptyList()
            pending = 0
            return listOf(AacEncodedUnit(ByteArray(16) { it.toByte() }, isCodecConfig = false))
        }

        override fun release() = Unit
    }

    private class FakeCapture(private val calls: MutableList<String>) : AudioCapture {
        var failOnStart = false
        var sinks: List<PcmSink> = emptyList()
        var stops = 0

        /** Report sink of the most recent start; kept after stop to simulate late reports. */
        var events: AudioCaptureEvents = AudioCaptureEvents.NONE

        override fun start(sinks: List<PcmSink>) {
            calls += "capture.start"
            if (failOnStart) throw AudioCaptureInitException("busy")
            this.sinks = sinks
        }

        override fun start(sinks: List<PcmSink>, events: AudioCaptureEvents) {
            start(sinks)
            this.events = events
        }

        /** Simulates a capture-thread read / sink error: capture already stopped and handed over PCM, then reports. */
        fun fail(error: Throwable) {
            sinks = emptyList()
            events.onFailure(error)
        }

        /** Simulates the system silencing this recording (incoming call, another app grabbing the mic). */
        fun silence() {
            sinks = emptyList()
            events.onInterrupted()
        }

        /** Tells whether we are currently running inside an io block; [stopsOnIo] records its result at each stop. */
        var onIo: () -> Boolean = { false }
        val stopsOnIo = mutableListOf<Boolean>()

        override fun stop() {
            stops++
            stopsOnIo += onIo()
            sinks = emptyList()
        }

        fun feed(samples: ShortArray) = sinks.forEach { it.onPcm(samples, samples.size) }
    }

    private class FakeEngine(override val engineName: String) : STTEngine {
        var result: STTResult = STTResult.Success("hello world")
        val segments = mutableListOf<STTSegment>()
        val languages = mutableListOf<String?>()
        var audioExistedOnCall = false

        /** When non-null, transcription suspends until it completes, simulating an in-flight request. */
        var gate: CompletableDeferred<Unit>? = null
        var cancelled = 0

        /** When true, waits on [gate] inside NonCancellable: simulates an engine that swallows cancellation and returns its result only after the discard. */
        var ignoreCancel = false

        override suspend fun transcribe(segment: STTSegment, language: String?): STTResult {
            segments += segment
            languages += language
            audioExistedOnCall = segment.aac.exists()
            if (ignoreCancel) {
                withContext(NonCancellable) { gate?.await() }
                return result
            }
            try {
                gate?.await()
            } catch (error: CancellationException) {
                cancelled++
                throw error
            }
            return result
        }
    }

    /** Fake recognizer handle: self-record session callbacks are triggered manually by tests via [callbacks]; calls to the recognizer are recorded. */
    private class FakeRecognizer : SystemSTTListening {
        lateinit var callbacks: SystemSTTCallbacks
        val calls = mutableListOf<String>()

        /** Opens a session like [SystemSTTEngine.startSelfRecordSession] (no Intent; unit tests do not run Robolectric). */
        fun startSession(): SystemSTTSelfRecordSession {
            calls += "startListening"
            val session = SystemSTTSelfRecordSession(sleeper = { _, then -> then() })
            callbacks = session
            session.attach(this)
            return session
        }

        override fun stopListening() {
            calls += "stopListening"
        }

        override fun restartListening() {
            calls += "restartListening"
        }

        override fun cancel() {
            calls += "cancel"
        }

        override fun destroy() {
            calls += "destroy"
        }
    }

    /** One fake engine each for system / cloud; records the cloud engine's constructor arguments. The self-record session is the production [SystemSTTSelfRecordSession] wired to a fake recognizer. */
    private class FakeEngineFactory(private val system: STTEngine, private val cloud: STTEngine) : DictationEngineFactory {
        var route: SystemSTTRoute = SystemSTTRoute.Pipe(SystemSTTRecognizer.DEFAULT, "zh-Hans")
        val cloudCalls = mutableListOf<Triple<VoiceSttEntry, String, String>>()
        val recognizer = FakeRecognizer()

        override fun system(): STTEngine = system

        override suspend fun startSelfRecord(route: SystemSTTRoute.SelfRecord): SystemSTTSelfRecordSession =
            recognizer.startSession()

        override suspend fun systemRoute(language: String?): SystemSTTRoute = route

        override fun cloud(entry: VoiceSttEntry, baseUrl: String, apiKey: String): STTEngine {
            cloudCalls += Triple(entry, baseUrl, apiKey)
            return cloud
        }
    }

    private class FakeCatalog : DictationCatalogSource {
        var cached: VoiceCatalog? = null
        var refreshed: VoiceCatalogState = VoiceCatalogState.LoadFailed
        var refreshes = 0

        /** When non-null, reading the cache suspends until it completes, simulating waiting for the catalog while choosing an engine. */
        var gate: CompletableDeferred<Unit>? = null

        override suspend fun loadCached(): VoiceCatalog? {
            gate?.await()
            return cached
        }

        /** When true, fetching never returns, simulating a hung network. */
        var refreshHangs = false

        override suspend fun refresh(): VoiceCatalogState {
            refreshes++
            if (refreshHangs) kotlinx.coroutines.awaitCancellation()
            return refreshed
        }
    }

    private class FakeEnvironment(private val calls: MutableList<String>) : DictationEnvironment {
        var onInterrupted: (() -> Unit)? = null

        override fun stopReadAloud() {
            calls += "stopReadAloud"
        }

        override fun recognitionLanguage(): String? = "zh-Hans"

        override fun observeInterruptions(onInterrupted: () -> Unit): AutoCloseable {
            this.onInterrupted = onInterrupted
            return AutoCloseable { this.onInterrupted = null }
        }

        /** Simulates the process going to the background (ProcessLifecycleOwner ON_STOP). */
        fun background() = onInterrupted?.invoke()
    }

    private val calls = mutableListOf<String>()
    private var granted = true

    /** When non-null, the permission request suspends until it completes, simulating the system permission dialog still being open. */
    private var permissionGate: CompletableDeferred<Unit>? = null
    private var lostReported = 0
    private var encoderFails = false
    private val encoders = mutableListOf<FakeEncoder>()
    private val dispatcher = UnconfinedTestDispatcher()
    private val store by lazy {
        RecordingStore(File(temp.root, "voice/pending"), clock = { 1_700_000_000_000L }, onLost = { lostReported += it })
    }
    private val capture = FakeCapture(calls)
    private val engine = FakeEngine(SystemSTTEngine.ENGINE_NAME)
    private val cloudEngine = FakeEngine(CloudSTTEngine.ENGINE_NAME)
    private val engines = FakeEngineFactory(engine, cloudEngine)
    private val prefs = TestSharedPreferences()
    private val settings = VoiceEngineSettings(prefsProvider = { prefs })

    /** Cloud disclosure consent record: consented by default (existing tests unaffected); individual tests set it to false before first using [controller]. */
    private var disclosureAccepted = true
    private val acceptedDisclosure = VoiceDisclosureStore { TestSharedPreferences() }.also {
        ProviderKind.entries.forEach { kind -> it.markAccepted(kind, VoiceDirection.Stt) }
    }
    private val catalog = FakeCatalog()
    private var providers: List<Provider> = emptyList()
    private val environment = FakeEnvironment(calls)
    private val controller by lazy { makeController() }

    /**
     * Holdable io: when [hold] is true the next io block is not run but stored in [held] and released by the test from another coroutine,
     * simulating the main thread handling other calls after io finishes but before the result returns to it. By default runs directly on the calling thread.
     */
    private class HoldableIo : CoroutineDispatcher() {
        var hold = false
        var held: Runnable? = null

        /** When true, all io blocks are queued into [queued] and released by [drain]. */
        var holdAll = false
        val queued = mutableListOf<Runnable>()

        override fun dispatch(context: CoroutineContext, block: Runnable) {
            if (holdAll) {
                queued += block
            } else if (hold) {
                hold = false
                held = block
            } else {
                block.run()
            }
        }

        /** Stops holding and releases later-queued blocks first: simulates two parallel io segments where the later one finishes first. */
        fun drainLatestFirst(scope: CoroutineScope) {
            holdAll = false
            scope.launch { while (queued.isNotEmpty()) queued.removeAt(queued.lastIndex).run() }
        }

        /** Currently releasing queued io blocks (true during [drain]). */
        var draining = false

        /** Stops holding and releases queued io blocks in order (blocks queued during release are released too). */
        fun drain(scope: CoroutineScope) {
            holdAll = false
            scope.launch {
                draining = true
                while (queued.isNotEmpty()) queued.removeAt(0).run()
                draining = false
            }
        }
    }

    /** The io used by the controller; same as the main dispatcher by default, individual tests swap in [HoldableIo] before first using [controller]. */
    private var io: CoroutineDispatcher = dispatcher

    /** Clock injected into the controller; only the level-throttling tests advance it. */
    private var now = 5_000L

    /** Test double for the process-wide stop-capture gate: tests park a stuck stop-capture on it, simulating a voice session that just closed. */
    private val teardownGate = CaptureTeardownGate()

    /** Creates a new controller on the same [store]: simulates a fresh process after a cold start. */
    private fun makeController() =
        DictationController(
            engines = engines,
            settings = settings,
            catalog = catalog,
            providers = { providers },
            capture = capture,
            store = store,
            encoderFactory = {
                if (encoderFails) throw IllegalStateException("codec unavailable")
                FakeEncoder().also { encoders += it }
            },
            permission = {
                calls += "permission"
                permissionGate?.await()
                granted
            },
            environment = environment,
            scope = CoroutineScope(dispatcher),
            io = io,
            clock = { now },
            disclosure = if (disclosureAccepted) acceptedDisclosure else settings.disclosure,
            awaitCaptureTeardowns = { teardownGate.awaitTeardowns() },
            beginCaptureTeardown = { teardownGate.beginTeardown() },
        )
    private val events by lazy { collectEvents(controller) }

    private fun collectEvents(target: DictationController): MutableList<DictationEvent> =
        mutableListOf<DictationEvent>().also { sink ->
            CoroutineScope(dispatcher).launch { target.events.collect { sink += it } }
        }

    /** 1 second of a ±3000 square wave (about -21 dBFS); passes the preflight check. */
    private val speech = ShortArray(16_000) { if (it % 2 == 0) 3000 else -3000 }

    /** 1 second of digital silence; the preflight check yields no_speech. */
    private val silence = ShortArray(16_000)

    private fun assertNoLostRecordings() {
        val sweep = store.sweepOnLaunch()
        assertEquals(0, sweep.lost)
        assertEquals(0, lostReported)
    }

    @Test
    fun dictation_start_waits_for_conversation_teardown() {
        events
        // Voice session just closed: its AudioRecord is still being released on io.
        val released = CompletableDeferred<Unit>()
        teardownGate.launchTeardown(CoroutineScope(dispatcher)) { released.await() }

        controller.start("conv-1")
        assertEquals(listOf("stopReadAloud", "permission"), calls)
        assertFalse(controller.state.value is DictationState.Recording)

        released.complete(Unit)
        assertEquals(listOf("stopReadAloud", "permission", "capture.start"), calls)
        assertEquals(DictationState.Recording("conv-1", 5_000L), controller.state.value)
        assertNoLostRecordings()
    }

    @Test
    fun conversation_start_waits_for_dictation_teardown() {
        val holdable = HoldableIo()
        io = holdable
        events
        recordSeconds("conv-1", 2)

        // Dictation interrupted: the stop-capture io block is held, AudioRecord has not stopped yet.
        holdable.hold = true
        controller.interrupt()
        val held = checkNotNull(holdable.held) { "dictation capture stop was not held" }
        assertEquals(0, capture.stops)

        // The voice session now starts capture: it waits on the same gate.
        val conversationStart = CompletableDeferred<Boolean>()
        CoroutineScope(dispatcher).launch { conversationStart.complete(teardownGate.awaitTeardowns()) }
        assertFalse(conversationStart.isCompleted)

        held.run()
        assertEquals(1, capture.stops)
        assertTrue(conversationStart.isCompleted)
        assertTrue(conversationStart.getCompleted())
        assertEquals(DictationState.Interrupted("conv-1"), controller.state.value)
        assertSlotKept("conv-1", RecordingSlotStatus.Interrupted)
        assertNoLostRecordings()
    }

    @Test
    fun `mic tap stops read aloud before asking permission and starts recording`() {
        events
        controller.start("conv-1")

        assertEquals(listOf("stopReadAloud", "permission", "capture.start"), calls)
        assertEquals(DictationState.Recording("conv-1", 5_000L), controller.state.value)
        assertTrue(store.isOccupied("conv-1"))
        assertEquals(RecordingSlotStatus.Recording, store.read("conv-1")?.status)
        assertTrue(events.isEmpty())
    }

    @Test
    fun `denied microphone ends in Denied without slot`() {
        events
        granted = false
        controller.start("conv-1")

        assertEquals(listOf("stopReadAloud", "permission"), calls)
        assertEquals(DictationState.Denied, controller.state.value)
        assertFalse(store.isOccupied("conv-1"))
        assertTrue(events.isEmpty())
        assertNoLostRecordings()
    }

    @Test
    fun `capture init failure emits RecordingUnavailable returns Idle and leaves no slot`() {
        events
        capture.failOnStart = true
        controller.start("conv-1")

        assertEquals(DictationState.Idle, controller.state.value)
        assertEquals(listOf<DictationEvent>(DictationEvent.RecordingUnavailable("conv-1")), events)
        assertFalse(store.isOccupied("conv-1"))
        assertFalse(store.audioFile("conv-1").exists())
        assertFalse(store.sidecarFile("conv-1").exists())
        assertNoLostRecordings()
    }

    private fun assertUnavailableWithoutSlot(slotKey: String) {
        assertEquals(DictationState.Idle, controller.state.value)
        assertEquals(listOf<DictationEvent>(DictationEvent.RecordingUnavailable(slotKey)), events)
        assertFalse(calls.contains("capture.start"))
        assertFalse(store.isOccupied(slotKey))
        assertNull(environment.onInterrupted)
        assertNoLostRecordings()
    }

    @Test
    fun `encoder factory failure emits RecordingUnavailable returns Idle and leaves no slot`() {
        events
        encoderFails = true
        controller.start("conv-1")

        assertUnavailableWithoutSlot("conv-1")
    }

    @Test
    fun `sidecar write failure on open emits RecordingUnavailable returns Idle and leaves no slot`() {
        events
        // The sidecar temp file path is occupied by a directory: store.open throws when writing the sidecar.
        assertTrue(File(store.sidecarFile("conv-1").path + ".tmp").mkdirs())
        controller.start("conv-1")

        assertUnavailableWithoutSlot("conv-1")
        assertFalse(store.audioFile("conv-1").exists())
    }

    @Test
    fun `close failure on interrupt still goes Interrupted and keeps the audio`() {
        events
        recordSeconds("conv-1", 2)
        encoders.last().failOnFinish = true
        controller.interrupt()

        assertEquals(DictationState.Interrupted("conv-1"), controller.state.value)
        assertEquals(1, capture.stops)
        assertSlotKept("conv-1", RecordingSlotStatus.Interrupted)
        assertEquals(2.0, store.read("conv-1")!!.durationSec, 0.01)
        assertNull(environment.onInterrupted)
        assertTrue(events.isEmpty())
        assertNoLostRecordings()
    }

    @Test
    fun `close failure on finish goes Failed with retry and keeps the audio`() {
        events
        recordSeconds("conv-1", 2)
        encoders.last().failOnFinish = true
        controller.finish(DictationSubmit.Insert)

        assertEquals(DictationState.Failed("conv-1", DictationFailedAction.Retry), controller.state.value)
        assertEquals(1, capture.stops)
        assertSlotKept("conv-1", RecordingSlotStatus.Failed)
        assertEquals(2.0, store.read("conv-1")!!.durationSec, 0.01)
        assertTrue(engine.segments.isEmpty())
        assertTrue(events.isEmpty())
        assertNoLostRecordings()
    }

    @Test
    fun `capture failure mid recording interrupts and keeps the written audio`() {
        events
        recordSeconds("conv-1", 2)
        capture.fail(java.io.IOException("AudioRecord.read failed: -3"))

        assertEquals(DictationState.Interrupted("conv-1"), controller.state.value)
        assertEquals(1, capture.stops)
        assertSlotKept("conv-1", RecordingSlotStatus.Interrupted)
        assertEquals(2.0, store.read("conv-1")!!.durationSec, 0.01)
        assertNull(environment.onInterrupted)

        // Reports arriving after finalization are ignored.
        capture.fail(IllegalStateException("late"))
        assertEquals(DictationState.Interrupted("conv-1"), controller.state.value)
        assertEquals(1, capture.stops)
        assertTrue(events.isEmpty())
        assertNoLostRecordings()
    }

    @Test
    fun `capture silenced by the system interrupts and keeps the written audio`() {
        events
        recordSeconds("conv-1", 1)
        capture.silence()

        assertEquals(DictationState.Interrupted("conv-1"), controller.state.value)
        assertEquals(1, capture.stops)
        assertSlotKept("conv-1", RecordingSlotStatus.Interrupted)
        assertEquals(1.0, store.read("conv-1")!!.durationSec, 0.01)
        assertNull(environment.onInterrupted)
        assertTrue(events.isEmpty())
        assertNoLostRecordings()
    }

    @Test
    fun `level meter publishes while recording and clears after`() {
        events
        assertEquals(emptyList<Float>(), controller.levelMeter.value)
        controller.start("conv-1")
        assertEquals(emptyList<Float>(), controller.levelMeter.value)

        // One 0.1 s ±3000 square-wave block every 100 ms: every block is published, only the latest 24 are kept.
        val chunk = speech.copyOf(1_600)
        repeat(30) {
            capture.feed(chunk)
            now += 100
        }
        val expected = DictationLevelMeter.level(chunk, chunk.size)
        assertTrue(expected > 0.5f && expected < 0.8f)
        assertEquals(List(24) { expected }, controller.levelMeter.value)

        controller.finish(DictationSubmit.Insert)
        assertFalse(controller.state.value is DictationState.Recording)
        assertEquals(emptyList<Float>(), controller.levelMeter.value)

        // Recognizer self-record has no PCM: the list stays empty while recording.
        now = 5_000L
        controller.bind("conv-2")
        startSelfRecord("conv-2")
        assertEquals(emptyList<Float>(), controller.levelMeter.value)
    }

    @Test
    fun `self record rms drives level meter`() {
        events
        startSelfRecord("conv-1")
        assertEquals(emptyList<Float>(), controller.levelMeter.value)

        // Recognizer range of −2…10 dB maps linearly to 0…1, clamped at both ends; blocks less than 66 ms after the last publish are dropped.
        val rms = engines.recognizer.callbacks
        rms.onRmsChanged(4f)
        now += 10
        rms.onRmsChanged(10f)
        listOf(-2f, 10f, -8f, 25f).forEach {
            now += DictationLevelMeter.MIN_INTERVAL_MILLIS
            rms.onRmsChanged(it)
        }
        assertEquals(listOf(0.5f, 0f, 1f, 0f, 1f), controller.levelMeter.value)

        controller.finish(DictationSubmit.Insert)
        assertEquals(emptyList<Float>(), controller.levelMeter.value)
        engines.recognizer.callbacks.onRmsChanged(-15f)
        assertEquals(emptyList<Float>(), controller.levelMeter.value)
    }

    @Test
    fun `convert to text success inserts transcript and deletes slot`() {
        events
        controller.start("conv-1")
        capture.feed(speech)
        controller.finish(DictationSubmit.Insert)

        assertEquals(DictationState.Idle, controller.state.value)
        assertEquals(listOf<DictationEvent>(DictationEvent.Insert("conv-1", "hello world")), events)
        assertEquals(1, capture.stops)
        assertTrue(engine.audioExistedOnCall)
        assertEquals(listOf<String?>("zh-Hans"), engine.languages)
        assertFalse(store.isOccupied("conv-1"))
        assertNoLostRecordings()
    }

    @Test
    fun `transcribe segment carries envelope and priming frames from sidecar`() {
        events
        controller.start("conv-1")
        capture.feed(speech)
        val audio = store.audioFile("conv-1")
        controller.finish(DictationSubmit.Insert)

        val segment = engine.segments.single()
        assertEquals(audio, segment.aac)
        assertNull(segment.range)
        assertEquals(2112, segment.primingFrames)
        assertEquals(20, segment.envelope.size)
        assertTrue(segment.envelope.all { it != null && it > DictationRules.SPEECH_THRESHOLD_DBFS })
    }

    @Test
    fun `send success emits Send and deletes slot`() {
        events
        engine.result = STTResult.Success("ship it")
        controller.start("conv-1")
        capture.feed(speech)
        controller.finish(DictationSubmit.Send)

        assertEquals(DictationState.Idle, controller.state.value)
        assertEquals(listOf<DictationEvent>(DictationEvent.Send("conv-1", "ship it")), events)
        assertFalse(store.isOccupied("conv-1"))
        assertNoLostRecordings()
    }

    @Test
    fun `silent recording emits NoSpeech deletes recording and never calls engine`() {
        events
        controller.start("conv-1")
        capture.feed(silence)
        controller.finish(DictationSubmit.Send)

        assertEquals(DictationState.Idle, controller.state.value)
        assertEquals(listOf<DictationEvent>(DictationEvent.NoSpeech("conv-1")), events)
        assertTrue(engine.segments.isEmpty())
        assertFalse(store.isOccupied("conv-1"))
        assertNoLostRecordings()
    }

    @Test
    fun `slot freed after success allows a new recording on the same key`() {
        events
        controller.start("conv-1")
        capture.feed(speech)
        controller.finish(DictationSubmit.Insert)
        controller.start("conv-1")

        assertEquals(DictationState.Recording("conv-1", 5_000L), controller.state.value)
        assertNotNull(store.read("conv-1"))
    }

    /** Computes the primary button for a failure result using production rules; attempt is large enough to skip the automatic retry. */
    private fun failure(failure: DictationFailure): STTResult.Failed =
        STTResult.Failed(failure, DictationRules.failureDecision(failure, Int.MAX_VALUE).primaryAction!!)

    private fun recordSeconds(slotKey: String, seconds: Int) {
        controller.start(slotKey)
        repeat(seconds) { capture.feed(speech) }
    }

    private fun assertSlotKept(slotKey: String, status: RecordingSlotStatus) {
        assertTrue(store.audioFile(slotKey).exists())
        assertTrue(store.audioFile(slotKey).length() > 0)
        assertEquals(status, store.read(slotKey)?.status)
    }

    @Test
    fun `401 and 403 fail with check connection and keep recording`() {
        events
        for (status in listOf(401, 403)) {
            val key = "conv-$status"
            engine.result = failure(DictationFailure.Http(status))
            recordSeconds(key, 1)
            controller.finish(DictationSubmit.Insert)

            assertEquals(DictationState.Failed(key, DictationFailedAction.CheckConnection), controller.state.value)
            assertSlotKept(key, RecordingSlotStatus.Failed)
            controller.discard()
        }
        assertTrue(events.isEmpty())
        assertNoLostRecordings()
    }

    @Test
    fun `other failures fail with retry and keep recording`() {
        events
        val failures = listOf(DictationFailure.Http(500), DictationFailure.Network, DictationFailure.InvalidResponse)
        failures.forEachIndexed { index, item ->
            val key = "conv-$index"
            engine.result = failure(item)
            recordSeconds(key, 1)
            controller.finish(DictationSubmit.Send)

            assertEquals(DictationState.Failed(key, DictationFailedAction.Retry), controller.state.value)
            assertSlotKept(key, RecordingSlotStatus.Failed)
            controller.discard()
        }
        assertTrue(events.isEmpty())
        assertNoLostRecordings()
    }

    @Test
    fun `system file unsupported keeps recording and emits system unavailable`() {
        events
        engine.result = STTResult.Failed(
            DictationFailure.Recognizer(SystemSTTEngine.FILE_UNSUPPORTED_ERROR),
            DictationPrimaryAction.Retry,
        )
        recordSeconds("conv-1", 1)
        controller.finish(DictationSubmit.Insert)

        assertEquals(DictationState.Failed("conv-1", DictationFailedAction.Retry), controller.state.value)
        assertSlotKept("conv-1", RecordingSlotStatus.Failed)
        assertEquals(listOf<DictationEvent>(DictationEvent.SystemUnavailable("conv-1")), events)
        assertNoLostRecordings()
    }

    @Test
    fun `other recognizer failure does not emit system unavailable`() {
        events
        engine.result = STTResult.Failed(
            DictationFailure.Recognizer(SpeechRecognizer.ERROR_NETWORK),
            DictationPrimaryAction.Retry,
        )
        recordSeconds("conv-1", 1)
        controller.finish(DictationSubmit.Insert)

        assertEquals(DictationState.Failed("conv-1", DictationFailedAction.Retry), controller.state.value)
        assertSlotKept("conv-1", RecordingSlotStatus.Failed)
        assertTrue(events.isEmpty())
        assertNoLostRecordings()
    }

    @Test
    fun `pipe recognizer client error does not emit system unavailable`() {
        events
        engine.result = STTResult.Failed(
            DictationFailure.Recognizer(SpeechRecognizer.ERROR_CLIENT),
            DictationPrimaryAction.Retry,
        )
        recordSeconds("conv-1", 1)
        controller.finish(DictationSubmit.Insert)

        assertEquals(DictationState.Failed("conv-1", DictationFailedAction.Retry), controller.state.value)
        assertTrue(events.isEmpty())
    }

    @Test
    fun `empty transcript fails with no transcript and keeps recording`() {
        events
        engine.result = STTResult.Success(" \u3000\n")
        recordSeconds("conv-1", 1)
        controller.finish(DictationSubmit.Send)

        assertEquals(DictationState.Failed("conv-1", DictationFailedAction.NoTranscript), controller.state.value)
        assertSlotKept("conv-1", RecordingSlotStatus.Failed)
        assertTrue(events.isEmpty())
        assertNoLostRecordings()
    }

    @Test
    fun `retry on Failed transcribes the kept recording again and only inserts`() {
        events
        engine.result = failure(DictationFailure.Network)
        recordSeconds("conv-1", 1)
        controller.finish(DictationSubmit.Send)
        assertEquals(DictationState.Failed("conv-1", DictationFailedAction.Retry), controller.state.value)

        engine.result = STTResult.Success("second try")
        controller.retry()

        assertEquals(2, engine.segments.size)
        assertEquals(engine.segments[0].aac, engine.segments[1].aac)
        assertTrue(engine.audioExistedOnCall)
        assertEquals(DictationState.Idle, controller.state.value)
        assertEquals(listOf<DictationEvent>(DictationEvent.Insert("conv-1", "second try")), events)
        assertFalse(store.isOccupied("conv-1"))
        assertNoLostRecordings()
    }

    @Test
    fun `transcribeSaved from failed retry inserts`() {
        events
        engine.result = failure(DictationFailure.Network)
        recordSeconds("conv-1", 1)
        controller.finish(DictationSubmit.Insert)
        assertEquals(DictationState.Failed("conv-1", DictationFailedAction.Retry), controller.state.value)

        engine.result = STTResult.Success("second try")
        controller.transcribeSaved(DictationSubmit.Insert)

        assertEquals(2, engine.segments.size)
        assertEquals(engine.segments[0].aac, engine.segments[1].aac)
        assertEquals(DictationState.Idle, controller.state.value)
        assertEquals(listOf<DictationEvent>(DictationEvent.Insert("conv-1", "second try")), events)
        assertFalse(store.isOccupied("conv-1"))
        assertNoLostRecordings()
    }

    @Test
    fun `transcribeSaved from failed noTranscript inserts`() {
        events
        engine.result = STTResult.Success(" \u3000\n")
        recordSeconds("conv-1", 1)
        controller.finish(DictationSubmit.Insert)
        assertEquals(DictationState.Failed("conv-1", DictationFailedAction.NoTranscript), controller.state.value)

        engine.result = STTResult.Success("second try")
        controller.transcribeSaved(DictationSubmit.Insert)

        assertEquals(2, engine.segments.size)
        assertEquals(DictationState.Idle, controller.state.value)
        assertEquals(listOf<DictationEvent>(DictationEvent.Insert("conv-1", "second try")), events)
        assertFalse(store.isOccupied("conv-1"))
        assertNoLostRecordings()
    }

    @Test
    fun `retry never sends even after send attempt`() {
        events
        // "↑" tapped when the recording ended: the retry after the first failure only inserts.
        engine.result = failure(DictationFailure.Network)
        recordSeconds("conv-1", 1)
        controller.finish(DictationSubmit.Send)
        assertEquals(DictationState.Failed("conv-1", DictationFailedAction.Retry), controller.state.value)
        engine.result = STTResult.Success("first")
        controller.retry()
        assertEquals(listOf<DictationEvent>(DictationEvent.Insert("conv-1", "first")), events)
        assertFalse(store.isOccupied("conv-1"))

        // Retry after "↑" failed on a retained recording: also insert only.
        engine.result = failure(DictationFailure.Timeout)
        recordSeconds("conv-2", 1)
        controller.interrupt()
        controller.transcribeSaved(DictationSubmit.Send)
        assertEquals(DictationState.Failed("conv-2", DictationFailedAction.Retry), controller.state.value)
        engine.result = STTResult.Success("second")
        controller.retry()

        assertEquals(DictationState.Idle, controller.state.value)
        assertEquals(
            listOf<DictationEvent>(DictationEvent.Insert("conv-1", "first"), DictationEvent.Insert("conv-2", "second")),
            events,
        )
        assertTrue(events.none { it is DictationEvent.Send })
        assertFalse(store.isOccupied("conv-2"))
        assertNoLostRecordings()
    }

    @Test
    fun `detach right after success still delivers insert or keeps recording`() {
        val holdable = HoldableIo()
        io = holdable
        events
        val gate = CompletableDeferred<Unit>()
        engine.gate = gate
        controller.bind("conv-1")
        recordSeconds("conv-1", 2)
        controller.finish(DictationSubmit.Insert)
        assertEquals(DictationState.Transcribing("conv-1", DictationSubmit.Insert), controller.state.value)

        // Hold the first io segment after a successful transcription (deleting the recording); the host leaves after release but before the result returns to the main thread.
        holdable.hold = true
        engine.result = STTResult.Success("hello")
        gate.complete(Unit)
        val held = checkNotNull(holdable.held) { "io after success was not held" }
        CoroutineScope(dispatcher).launch {
            held.run()
            controller.detach("conv-1")
        }

        val delivered = events == listOf<DictationEvent>(DictationEvent.Insert("conv-1", "hello"))
        if (delivered) {
            // Recording deleted: the text must be delivered and the state returns to Idle.
            assertFalse(store.isOccupied("conv-1"))
            assertFalse(store.audioFile("conv-1").exists())
            assertEquals(DictationState.Idle, controller.state.value)
        } else {
            // Not delivered: the recording must still exist, kept as Interrupted until the host returns.
            assertTrue(events.isEmpty())
            assertSlotKept("conv-1", RecordingSlotStatus.Interrupted)
            assertEquals(DictationState.Interrupted("conv-1"), controller.state.value)
        }
        assertNoLostRecordings()
    }

    @Test
    fun `retry that fails again stays Failed with recording kept`() {
        events
        engine.result = failure(DictationFailure.Http(401))
        recordSeconds("conv-1", 1)
        controller.finish(DictationSubmit.Insert)
        engine.result = failure(DictationFailure.Timeout)
        controller.retry()

        assertEquals(2, engine.segments.size)
        assertEquals(DictationState.Failed("conv-1", DictationFailedAction.Retry), controller.state.value)
        assertSlotKept("conv-1", RecordingSlotStatus.Failed)
        assertTrue(events.isEmpty())
        assertNoLostRecordings()
    }

    @Test
    fun `interrupt closes the file synchronously and marks the slot interrupted`() {
        events
        recordSeconds("conv-1", 2)
        controller.interrupt()

        assertEquals(DictationState.Interrupted("conv-1"), controller.state.value)
        assertEquals(1, capture.stops)
        assertSlotKept("conv-1", RecordingSlotStatus.Interrupted)
        assertEquals(2.0, store.read("conv-1")!!.durationSec, 0.01)
        assertTrue(AdtsFormat.parse(store.audioFile("conv-1").readBytes()).frames.isNotEmpty())
        assertTrue(engine.segments.isEmpty())
        assertTrue(events.isEmpty())
        assertNoLostRecordings()
        assertEquals(RecordingSlotStatus.Interrupted, store.read("conv-1")?.status)
    }

    @Test
    fun `going to background while recording interrupts and keeps the file`() {
        events
        recordSeconds("conv-1", 1)
        assertNotNull(environment.onInterrupted)
        environment.background()

        assertEquals(DictationState.Interrupted("conv-1"), controller.state.value)
        assertEquals(1, capture.stops)
        assertSlotKept("conv-1", RecordingSlotStatus.Interrupted)
        assertNull(environment.onInterrupted)
        assertTrue(events.isEmpty())
        assertNoLostRecordings()
    }

    @Test
    fun background_interrupt_does_not_stop_capture_on_main() {
        val holdable = HoldableIo()
        io = holdable
        capture.onIo = { holdable.draining }
        events
        recordSeconds("conv-1", 1)

        // Going to the background: state switches away synchronously; stop-capture / file close are queued on io and not yet done on the main thread when the callback returns.
        holdable.holdAll = true
        environment.background()
        assertEquals(DictationState.Interrupted("conv-1"), controller.state.value)
        assertEquals(0, capture.stops)
        assertTrue(holdable.queued.isNotEmpty())

        holdable.drain(CoroutineScope(dispatcher))
        assertEquals(listOf(true), capture.stopsOnIo)
        assertSlotKept("conv-1", RecordingSlotStatus.Interrupted)
        assertNull(environment.onInterrupted)
        assertNoLostRecordings()
    }

    @Test
    fun `background observer is released once recording finishes`() {
        events
        recordSeconds("conv-1", 1)
        controller.finish(DictationSubmit.Insert)

        assertNull(environment.onInterrupted)
        assertEquals(DictationState.Idle, controller.state.value)
        assertNoLostRecordings()
    }

    @Test
    fun `discard over five seconds moves to bin offers undo and undo returns Interrupted`() {
        events
        recordSeconds("conv-1", 6)
        controller.discard()

        assertEquals(DictationState.Idle, controller.state.value)
        assertEquals(listOf<DictationEvent>(DictationEvent.DiscardUndoable("conv-1")), events)
        assertFalse(store.isOccupied("conv-1"))
        assertNull(environment.onInterrupted)

        assertTrue(controller.undoDiscard("conv-1"))
        assertEquals(DictationState.Interrupted("conv-1"), controller.state.value)
        assertSlotKept("conv-1", RecordingSlotStatus.Interrupted)
        assertEquals(6.0, store.read("conv-1")!!.durationSec, 0.01)
        assertNoLostRecordings()
    }

    @Test
    fun `discard of a failed recording over five seconds can be undone back to Interrupted`() {
        events
        engine.result = failure(DictationFailure.Network)
        recordSeconds("conv-1", 6)
        controller.finish(DictationSubmit.Insert)
        controller.discard()

        assertEquals(listOf<DictationEvent>(DictationEvent.DiscardUndoable("conv-1")), events)
        assertTrue(controller.undoDiscard("conv-1"))
        assertEquals(DictationState.Interrupted("conv-1"), controller.state.value)
        assertSlotKept("conv-1", RecordingSlotStatus.Interrupted)
        assertNoLostRecordings()
    }

    @Test
    fun `committed discard can no longer be undone`() {
        events
        recordSeconds("conv-1", 6)
        controller.discard()
        controller.commitDiscard("conv-1")

        assertFalse(controller.undoDiscard("conv-1"))
        assertEquals(DictationState.Idle, controller.state.value)
        assertFalse(store.isOccupied("conv-1"))
        assertNoLostRecordings()
    }

    @Test
    fun `discard at five seconds or less deletes directly without undo`() {
        events
        recordSeconds("conv-1", 5)
        controller.discard()

        assertEquals(DictationState.Idle, controller.state.value)
        assertTrue(events.isEmpty())
        assertFalse(store.isOccupied("conv-1"))
        assertFalse(store.audioFile("conv-1").exists())
        assertFalse(controller.undoDiscard("conv-1"))
        assertEquals(DictationState.Idle, controller.state.value)
        assertNoLostRecordings()
    }

    @Test
    fun `discard of an interrupted recording deletes it`() {
        events
        recordSeconds("conv-1", 1)
        controller.interrupt()
        controller.discard()

        assertEquals(DictationState.Idle, controller.state.value)
        assertFalse(store.isOccupied("conv-1"))
        assertTrue(events.isEmpty())
        assertNoLostRecordings()
    }

    // ---- Engine selection ----

    private val sttEntry = VoiceSttEntry(
        model = "gpt-transcribe",
        transport = VoiceTransport.OpenAITranscriptions,
        path = "/v1/audio/transcriptions",
        maxBytes = 25_000_000,
        maxDurationSec = 600,
        languageField = "language",
        isDefault = true,
    )
    private val voiceCatalog = VoiceCatalog(providers = mapOf(ProviderKind.OpenAI to VoiceProviderCatalog(stt = listOf(sttEntry))))
    private val cloudSelection = VoiceEngineSelection.Cloud(
        providerKind = ProviderKind.OpenAI,
        connectionId = "conn-openai",
        model = "gpt-transcribe",
    )
    private val openAI = Provider(
        id = "conn-openai",
        kind = ProviderKind.OpenAI,
        apiKey = "sk-live",
        baseUrlText = "https://api.openai.com/v1",
    )

    private fun dictate(slotKey: String) {
        controller.start(slotKey)
        capture.feed(speech)
        controller.finish(DictationSubmit.Insert)
    }

    @Test
    fun `valid cloud selection records and transcribes with cloud engine at connection origin plus entry path`() {
        events
        settings.setSelection(VoiceDirection.Stt, cloudSelection)
        catalog.cached = voiceCatalog
        providers = listOf(openAI)

        controller.start("conv-1")
        assertEquals("openAI/gpt-transcribe", store.read("conv-1")?.engine)
        capture.feed(speech)
        controller.finish(DictationSubmit.Insert)

        val (entry, baseUrl, apiKey) = engines.cloudCalls.single()
        assertEquals(sttEntry, entry)
        assertEquals("https://api.openai.com/v1/audio/transcriptions", DictationRules.requestUrl(baseUrl, entry))
        assertEquals("sk-live", apiKey)
        assertEquals(1, cloudEngine.segments.size)
        assertTrue(engine.segments.isEmpty())
        assertEquals(listOf<DictationEvent>(DictationEvent.Insert("conv-1", "hello world")), events)
        assertEquals(cloudSelection, settings.selection(VoiceDirection.Stt))
        assertEquals(0, catalog.refreshes)
        assertNoLostRecordings()
    }

    @Test
    fun `cloud selection without consent uses system without rewrite`() {
        disclosureAccepted = false
        events
        settings.setSelection(VoiceDirection.Stt, cloudSelection)
        catalog.cached = voiceCatalog
        providers = listOf(openAI)

        controller.start("conv-1")
        assertEquals(SystemSTTEngine.ENGINE_NAME, store.read("conv-1")?.engine)
        capture.feed(speech)
        controller.finish(DictationSubmit.Insert)

        assertTrue(engines.cloudCalls.isEmpty())
        assertTrue(cloudEngine.segments.isEmpty())
        assertEquals(1, engine.segments.size)
        assertEquals(listOf<DictationEvent>(DictationEvent.Insert("conv-1", "hello world")), events)
        assertEquals(cloudSelection, settings.selection(VoiceDirection.Stt))
        assertNull(settings.takePendingNotice(VoiceDirection.Stt, VoiceNoticeSite.Settings))
        assertNoLostRecordings()
    }

    /** Fallback: this run uses the system engine, the setting reverts to system, EngineFallback is emitted once (the second dictation does not prompt again). */
    private fun assertFallsBackOnce(reason: VoiceFallbackReason) {
        events
        settings.setSelection(VoiceDirection.Stt, cloudSelection)

        controller.start("conv-1")
        assertEquals(SystemSTTEngine.ENGINE_NAME, store.read("conv-1")?.engine)
        capture.feed(speech)
        controller.finish(DictationSubmit.Insert)
        assertEquals(VoiceEngineSelection.System, settings.selection(VoiceDirection.Stt))
        dictate("conv-2")

        assertTrue(engines.cloudCalls.isEmpty())
        assertEquals(2, engine.segments.size)
        assertTrue(cloudEngine.segments.isEmpty())
        assertEquals(
            listOf(
                DictationEvent.EngineFallback("conv-1", reason),
                DictationEvent.Insert("conv-1", "hello world"),
                DictationEvent.Insert("conv-2", "hello world"),
            ),
            events,
        )
        assertEquals(VoiceEngineSelection.System, settings.selection(VoiceDirection.Stt))
        assertNoLostRecordings()
    }

    @Test
    fun `deleted connection falls back to system once and resets selection`() {
        catalog.cached = voiceCatalog
        providers = emptyList()
        assertFallsBackOnce(VoiceFallbackReason.ConnectionMissing)
    }

    @Test
    fun `cleared key falls back to system once and resets selection`() {
        catalog.cached = voiceCatalog
        providers = listOf(openAI.copy(apiKey = ""))
        assertFallsBackOnce(VoiceFallbackReason.KeyMissing)
    }

    @Test
    fun `removed catalog entry falls back to system once and resets selection`() {
        catalog.cached = VoiceCatalog(providers = mapOf(ProviderKind.OpenAI to VoiceProviderCatalog()))
        providers = listOf(openAI)
        assertFallsBackOnce(VoiceFallbackReason.EntryRemoved)
    }

    @Test
    fun `fallback at use shows notice once`() {
        events
        settings.setSelection(VoiceDirection.Stt, cloudSelection)
        catalog.cached = voiceCatalog
        providers = emptyList()

        // Discovered at the point of use first: prompt once there, leaving one for the settings page.
        dictate("conv-1")
        dictate("conv-2")
        assertEquals(
            VoiceFallbackReason.ConnectionMissing,
            settings.takePendingNotice(VoiceDirection.Stt, VoiceNoticeSite.Settings),
        )

        // Discovered on the settings page first: the point of use prompts once more, then never again.
        settings.setSelection(VoiceDirection.Stt, cloudSelection)
        val settingsResolution = VoiceEngineResolver.resolve(
            catalog = voiceCatalog,
            direction = VoiceDirection.Stt,
            selection = settings.selection(VoiceDirection.Stt),
            connections = emptyList(),
        )
        assertEquals(
            VoiceFallbackReason.ConnectionMissing,
            settings.applyResolution(VoiceDirection.Stt, settingsResolution, VoiceNoticeSite.Settings),
        )
        dictate("conv-3")
        dictate("conv-4")

        assertTrue(engines.cloudCalls.isEmpty())
        assertEquals(
            listOf(
                DictationEvent.EngineFallback("conv-1", VoiceFallbackReason.ConnectionMissing),
                DictationEvent.Insert("conv-1", "hello world"),
                DictationEvent.Insert("conv-2", "hello world"),
                DictationEvent.EngineFallback("conv-3", VoiceFallbackReason.ConnectionMissing),
                DictationEvent.Insert("conv-3", "hello world"),
                DictationEvent.Insert("conv-4", "hello world"),
            ),
            events,
        )
        assertNull(settings.takePendingNotice(VoiceDirection.Stt, VoiceNoticeSite.Use))
        assertNoLostRecordings()
    }

    private fun assertCatalogMissingUsesSystemSilently(refreshed: VoiceCatalogState) {
        events
        settings.setSelection(VoiceDirection.Stt, cloudSelection)
        catalog.cached = null
        catalog.refreshed = refreshed
        providers = listOf(openAI)

        dictate("conv-1")

        assertEquals(1, catalog.refreshes)
        assertTrue(engines.cloudCalls.isEmpty())
        assertEquals(1, engine.segments.size)
        assertEquals(listOf<DictationEvent>(DictationEvent.Insert("conv-1", "hello world")), events)
        assertEquals(cloudSelection, settings.selection(VoiceDirection.Stt))
        assertNoLostRecordings()
    }

    @Test
    fun `no cached catalog and load failure uses system this time without notice or reset`() {
        assertCatalogMissingUsesSystemSilently(VoiceCatalogState.LoadFailed)
    }

    @Test
    fun `no cached catalog and 404 uses system this time without notice or reset`() {
        assertCatalogMissingUsesSystemSilently(VoiceCatalogState.Unavailable)
    }

    @Test
    fun `catalog refresh that never returns times out like a fetch failure`() {
        events
        settings.setSelection(VoiceDirection.Stt, cloudSelection)
        catalog.cached = null
        catalog.refreshHangs = true
        providers = listOf(openAI)

        controller.start("conv-1")
        assertEquals(1, catalog.refreshes)
        assertEquals(DictationState.Idle, controller.state.value)
        advance(DictationController.CATALOG_REFRESH_TIMEOUT_MILLIS - 1)
        assertEquals(DictationState.Idle, controller.state.value)
        advance(1)
        assertTrue(controller.state.value is DictationState.Recording)
        capture.feed(speech)
        controller.finish(DictationSubmit.Insert)

        assertTrue(engines.cloudCalls.isEmpty())
        assertEquals(1, engine.segments.size)
        assertEquals(listOf<DictationEvent>(DictationEvent.Insert("conv-1", "hello world")), events)
        assertEquals(cloudSelection, settings.selection(VoiceDirection.Stt))
        assertNull(settings.takePendingNotice(VoiceDirection.Stt, VoiceNoticeSite.Use))
        assertNoLostRecordings()
    }

    @Test
    fun `catalog cache read blocked by another refresh times out like a fetch failure`() {
        events
        settings.setSelection(VoiceDirection.Stt, cloudSelection)
        // Reading the cache waits for another stuck refresh to release the lock and never returns.
        catalog.gate = CompletableDeferred()
        catalog.cached = voiceCatalog
        providers = listOf(openAI)

        controller.start("conv-1")
        advance(DictationController.CATALOG_REFRESH_TIMEOUT_MILLIS - 1)
        assertEquals(DictationState.Idle, controller.state.value)
        advance(1)
        assertTrue(controller.state.value is DictationState.Recording)
        capture.feed(speech)
        controller.finish(DictationSubmit.Insert)

        assertTrue(engines.cloudCalls.isEmpty())
        assertEquals(1, engine.segments.size)
        assertEquals(listOf<DictationEvent>(DictationEvent.Insert("conv-1", "hello world")), events)
        assertEquals(cloudSelection, settings.selection(VoiceDirection.Stt))
        assertNull(settings.takePendingNotice(VoiceDirection.Stt, VoiceNoticeSite.Use))
        assertNoLostRecordings()
    }

    @Test
    fun `start after timed out catalog refresh is not dropped`() {
        events
        settings.setSelection(VoiceDirection.Stt, cloudSelection)
        catalog.cached = null
        catalog.refreshHangs = true
        providers = listOf(openAI)

        controller.start("conv-1")
        // Taps while hung are ignored (a session is in progress); after the timeout recording starts as usual.
        controller.start("conv-1")
        advance(DictationController.CATALOG_REFRESH_TIMEOUT_MILLIS)
        capture.feed(speech)
        controller.finish(DictationSubmit.Insert)
        assertEquals(DictationState.Idle, controller.state.value)

        controller.start("conv-1")
        assertEquals(2, catalog.refreshes)
        advance(DictationController.CATALOG_REFRESH_TIMEOUT_MILLIS)
        assertTrue(controller.state.value is DictationState.Recording)
        capture.feed(speech)
        controller.finish(DictationSubmit.Insert)

        assertEquals(2, engine.segments.size)
        assertEquals(
            listOf<DictationEvent>(DictationEvent.Insert("conv-1", "hello world"), DictationEvent.Insert("conv-1", "hello world")),
            events,
        )
        assertEquals(cloudSelection, settings.selection(VoiceDirection.Stt))
        assertNoLostRecordings()
    }

    @Test
    fun `unavailable system route emits SystemUnavailable returns Idle and never records`() {
        events
        engines.route = SystemSTTRoute.Unavailable

        controller.start("conv-1")

        assertEquals(DictationState.Idle, controller.state.value)
        assertEquals(listOf<DictationEvent>(DictationEvent.SystemUnavailable("conv-1")), events)
        assertEquals(listOf("stopReadAloud", "permission"), calls)
        assertFalse(store.isOccupied("conv-1"))
        assertTrue(engine.segments.isEmpty())
        assertNoLostRecordings()
    }

    // ---- Transcription entry for saved recordings and slot conflicts ----

    /** Simulates an interrupted recording left by the previous session (the controller is Idle after a process restart). */
    private fun seedInterruptedSlot(slotKey: String, seconds: Int) {
        val seeded = store.open(slotKey, SystemSTTEngine.ENGINE_NAME, FakeEncoder())
        repeat(seconds) { seeded.write(speech) }
        seeded.finish(RecordingSlotStatus.Interrupted)
    }

    @Test
    fun `convert to text on Interrupted transcribes the saved recording and inserts`() {
        events
        recordSeconds("conv-1", 2)
        controller.interrupt()
        val audio = store.audioFile("conv-1")
        controller.transcribeSaved(DictationSubmit.Insert)

        val segment = engine.segments.single()
        assertEquals(audio, segment.aac)
        assertEquals(2112, segment.primingFrames)
        assertEquals(40, segment.envelope.size)
        assertTrue(engine.audioExistedOnCall)
        assertEquals(DictationState.Idle, controller.state.value)
        assertEquals(listOf<DictationEvent>(DictationEvent.Insert("conv-1", "hello world")), events)
        assertFalse(store.isOccupied("conv-1"))
        assertNoLostRecordings()
    }

    @Test
    fun `send on Interrupted transcribes the saved recording and sends`() {
        events
        engine.result = STTResult.Success("ship it")
        recordSeconds("conv-1", 1)
        controller.interrupt()
        controller.transcribeSaved(DictationSubmit.Send)

        assertEquals(1, engine.segments.size)
        assertEquals(DictationState.Idle, controller.state.value)
        assertEquals(listOf<DictationEvent>(DictationEvent.Send("conv-1", "ship it")), events)
        assertFalse(store.isOccupied("conv-1"))
        assertNoLostRecordings()
    }

    @Test
    fun `failed saved transcription goes Failed keeps recording and retry only inserts`() {
        events
        engine.result = failure(DictationFailure.Network)
        recordSeconds("conv-1", 1)
        controller.interrupt()
        controller.transcribeSaved(DictationSubmit.Send)

        assertEquals(DictationState.Failed("conv-1", DictationFailedAction.Retry), controller.state.value)
        assertSlotKept("conv-1", RecordingSlotStatus.Failed)
        assertTrue(events.isEmpty())

        engine.result = STTResult.Success("second try")
        controller.retry()
        assertEquals(listOf<DictationEvent>(DictationEvent.Insert("conv-1", "second try")), events)
        assertFalse(store.isOccupied("conv-1"))
        assertNoLostRecordings()
    }

    @Test
    fun `saved transcription with sidecar deleted externally returns Idle and clears the orphan audio`() {
        events
        recordSeconds("conv-1", 1)
        controller.interrupt()
        assertTrue(store.sidecarFile("conv-1").delete())
        controller.transcribeSaved(DictationSubmit.Insert)

        assertEquals(DictationState.Idle, controller.state.value)
        assertTrue(engine.segments.isEmpty())
        assertFalse(store.isOccupied("conv-1"))
        assertTrue(events.isEmpty())
        controller.start("conv-1")
        assertEquals(DictationState.Recording("conv-1", 5_000L), controller.state.value)
        assertNoLostRecordings()
    }

    @Test
    fun `retry with sidecar deleted externally returns Idle instead of Failed`() {
        events
        engine.result = failure(DictationFailure.Network)
        recordSeconds("conv-1", 1)
        controller.finish(DictationSubmit.Insert)
        assertEquals(DictationState.Failed("conv-1", DictationFailedAction.Retry), controller.state.value)
        assertTrue(store.sidecarFile("conv-1").delete())
        controller.retry()

        assertEquals(DictationState.Idle, controller.state.value)
        assertEquals(1, engine.segments.size)
        assertFalse(store.isOccupied("conv-1"))
        assertTrue(events.isEmpty())
        assertNoLostRecordings()
    }

    @Test
    fun `mic tap on an occupied slot goes SlotOccupied without touching the old recording`() {
        events
        seedInterruptedSlot("conv-1", 2)
        controller.start("conv-1")

        assertEquals(DictationState.SlotOccupied("conv-1"), controller.state.value)
        // Stop read-aloud first, then check the slot; if the slot is occupied, do not request permission or start capture.
        assertEquals(listOf("stopReadAloud"), calls)
        assertFalse(calls.contains("capture.start"))
        assertSlotKept("conv-1", RecordingSlotStatus.Interrupted)
        assertEquals(2.0, store.read("conv-1")!!.durationSec, 0.01)
        assertTrue(events.isEmpty())
        assertNoLostRecordings()
    }

    /** The stored cloud choice points at a deleted connection: resolving the engine reverts to system and emits EngineFallback. */
    private fun armFallbackSelection() {
        settings.setSelection(VoiceDirection.Stt, cloudSelection)
        catalog.cached = voiceCatalog
        providers = emptyList()
    }

    private fun assertMicTapAsksFirst(slotKey: String) {
        calls.clear()
        controller.start(slotKey)

        assertEquals(DictationState.SlotOccupied(slotKey), controller.state.value)
        assertEquals(listOf("stopReadAloud"), calls)
        assertEquals(cloudSelection, settings.selection(VoiceDirection.Stt))
        assertTrue(engines.cloudCalls.isEmpty())
        assertTrue(events.none { it is DictationEvent.EngineFallback })
    }

    @Test
    fun `mic tap on Interrupted goes SlotOccupied without permission engine resolution or fallback`() {
        events
        recordSeconds("conv-1", 2)
        controller.interrupt()
        armFallbackSelection()
        assertMicTapAsksFirst("conv-1")

        assertSlotKept("conv-1", RecordingSlotStatus.Interrupted)
        assertTrue(events.isEmpty())
        assertNoLostRecordings()
    }

    @Test
    fun `mic tap on Failed goes SlotOccupied without permission engine resolution or fallback`() {
        events
        engine.result = failure(DictationFailure.Network)
        recordSeconds("conv-1", 2)
        controller.finish(DictationSubmit.Insert)
        assertEquals(DictationState.Failed("conv-1", DictationFailedAction.Retry), controller.state.value)
        armFallbackSelection()
        assertMicTapAsksFirst("conv-1")

        assertSlotKept("conv-1", RecordingSlotStatus.Failed)
        assertTrue(events.isEmpty())
        assertNoLostRecordings()
    }

    @Test
    fun `discard on SlotOccupied over five seconds offers undo and undo returns Interrupted`() {
        events
        seedInterruptedSlot("conv-1", 6)
        controller.start("conv-1")
        assertEquals(DictationState.SlotOccupied("conv-1"), controller.state.value)
        controller.discard()

        assertEquals(DictationState.Idle, controller.state.value)
        assertEquals(listOf<DictationEvent>(DictationEvent.DiscardUndoable("conv-1")), events)
        assertFalse(store.isOccupied("conv-1"))
        assertTrue(controller.undoDiscard("conv-1"))
        assertEquals(DictationState.Interrupted("conv-1"), controller.state.value)
        assertSlotKept("conv-1", RecordingSlotStatus.Interrupted)
        assertEquals(6.0, store.read("conv-1")!!.durationSec, 0.01)
        assertNoLostRecordings()
    }

    @Test
    fun `discard on SlotOccupied at five seconds or less deletes directly without undo`() {
        events
        seedInterruptedSlot("conv-1", 2)
        controller.start("conv-1")
        controller.discard()

        assertEquals(DictationState.Idle, controller.state.value)
        assertTrue(events.isEmpty())
        assertFalse(store.isOccupied("conv-1"))
        assertFalse(controller.undoDiscard("conv-1"))
        assertNoLostRecordings()
    }

    @Test
    fun `transcribe first on SlotOccupied transcribes the old recording`() {
        events
        seedInterruptedSlot("conv-1", 2)
        val audio = store.audioFile("conv-1")
        controller.start("conv-1")
        controller.transcribeSaved(DictationSubmit.Insert)

        val segment = engine.segments.single()
        assertEquals(audio, segment.aac)
        assertEquals(40, segment.envelope.size)
        assertEquals(DictationState.Idle, controller.state.value)
        assertEquals(listOf<DictationEvent>(DictationEvent.Insert("conv-1", "hello world")), events)
        assertFalse(store.isOccupied("conv-1"))
        assertNoLostRecordings()
    }

    @Test
    fun `discard and re-record on SlotOccupied deletes the old recording and starts a new one`() {
        events
        seedInterruptedSlot("conv-1", 6)
        controller.start("conv-1")
        controller.discardAndRestart()

        assertEquals(DictationState.Recording("conv-1", 5_000L), controller.state.value)
        assertEquals(1, calls.count { it == "capture.start" })
        val fresh = store.read("conv-1")!!
        assertEquals(RecordingSlotStatus.Recording, fresh.status)
        assertEquals(0.0, fresh.durationSec, 0.0)
        assertFalse(controller.undoDiscard("conv-1"))
        assertTrue(events.isEmpty())

        capture.feed(speech)
        controller.finish(DictationSubmit.Insert)
        assertEquals(20, engine.segments.single().envelope.size)
        assertEquals(listOf<DictationEvent>(DictationEvent.Insert("conv-1", "hello world")), events)
        assertFalse(store.isOccupied("conv-1"))
        assertNoLostRecordings()
    }

    @Test
    fun `discard while transcribing over five seconds cancels transcription offers undo and undo returns Interrupted`() {
        events
        val gate = CompletableDeferred<Unit>()
        engine.gate = gate
        recordSeconds("conv-1", 6)
        controller.finish(DictationSubmit.Insert)
        assertEquals(DictationState.Transcribing("conv-1", DictationSubmit.Insert), controller.state.value)

        controller.discard()
        assertEquals(1, engine.cancelled)
        assertEquals(DictationState.Idle, controller.state.value)
        assertEquals(listOf<DictationEvent>(DictationEvent.DiscardUndoable("conv-1")), events)
        assertFalse(store.isOccupied("conv-1"))
        gate.complete(Unit)
        assertEquals(listOf<DictationEvent>(DictationEvent.DiscardUndoable("conv-1")), events)

        assertTrue(controller.undoDiscard("conv-1"))
        assertEquals(DictationState.Interrupted("conv-1"), controller.state.value)
        assertSlotKept("conv-1", RecordingSlotStatus.Interrupted)
        assertEquals(6.0, store.read("conv-1")!!.durationSec, 0.01)
        assertNoLostRecordings()
    }

    @Test
    fun `late success after discard while transcribing does not insert and keeps undo`() {
        events
        val gate = CompletableDeferred<Unit>()
        engine.gate = gate
        engine.ignoreCancel = true
        recordSeconds("conv-1", 6)
        controller.finish(DictationSubmit.Insert)
        assertEquals(DictationState.Transcribing("conv-1", DictationSubmit.Insert), controller.state.value)

        controller.discard()
        assertEquals(DictationState.Idle, controller.state.value)
        gate.complete(Unit)

        assertEquals(DictationState.Idle, controller.state.value)
        assertEquals(listOf<DictationEvent>(DictationEvent.DiscardUndoable("conv-1")), events)
        assertFalse(store.isOccupied("conv-1"))
        assertTrue(controller.undoDiscard("conv-1"))
        assertEquals(DictationState.Interrupted("conv-1"), controller.state.value)
        assertSlotKept("conv-1", RecordingSlotStatus.Interrupted)
        assertEquals(6.0, store.read("conv-1")!!.durationSec, 0.01)
        assertNoLostRecordings()
    }

    @Test
    fun `late empty transcript after discard while transcribing does not go Failed`() {
        events
        val gate = CompletableDeferred<Unit>()
        engine.gate = gate
        engine.ignoreCancel = true
        engine.result = STTResult.Success("   ")
        recordSeconds("conv-1", 6)
        controller.finish(DictationSubmit.Send)

        controller.discard()
        gate.complete(Unit)

        assertEquals(DictationState.Idle, controller.state.value)
        assertEquals(listOf<DictationEvent>(DictationEvent.DiscardUndoable("conv-1")), events)
        assertTrue(controller.undoDiscard("conv-1"))
        assertEquals(DictationState.Interrupted("conv-1"), controller.state.value)
        assertSlotKept("conv-1", RecordingSlotStatus.Interrupted)
        assertNoLostRecordings()
    }

    @Test
    fun `discard while transcribing at five seconds or less cancels and deletes directly`() {
        events
        engine.gate = CompletableDeferred()
        recordSeconds("conv-1", 5)
        controller.finish(DictationSubmit.Send)
        controller.discard()

        assertEquals(1, engine.cancelled)
        assertEquals(DictationState.Idle, controller.state.value)
        assertTrue(events.isEmpty())
        assertFalse(store.isOccupied("conv-1"))
        assertFalse(controller.undoDiscard("conv-1"))
        assertNoLostRecordings()
    }

    @Test
    fun `discard while transcribing a saved recording cancels and can be undone back to Interrupted`() {
        events
        engine.gate = CompletableDeferred()
        recordSeconds("conv-1", 6)
        controller.interrupt()
        controller.transcribeSaved(DictationSubmit.Send)
        assertEquals(DictationState.Transcribing("conv-1", DictationSubmit.Send), controller.state.value)
        controller.discard()

        assertEquals(1, engine.cancelled)
        assertEquals(listOf<DictationEvent>(DictationEvent.DiscardUndoable("conv-1")), events)
        assertTrue(controller.undoDiscard("conv-1"))
        assertEquals(DictationState.Interrupted("conv-1"), controller.state.value)
        assertSlotKept("conv-1", RecordingSlotStatus.Interrupted)

        engine.gate = null
        controller.transcribeSaved(DictationSubmit.Insert)
        assertEquals(listOf(DictationEvent.DiscardUndoable("conv-1"), DictationEvent.Insert("conv-1", "hello world")), events)
        assertFalse(store.isOccupied("conv-1"))
        assertNoLostRecordings()
    }

    private fun startSelfRecord(slotKey: String) {
        engines.route = SystemSTTRoute.SelfRecord(SystemSTTRecognizer.DEFAULT, "zh-Hans")
        controller.start(slotKey)
        assertEquals(DictationState.Recording(slotKey, 5_000L), controller.state.value)
    }

    /** The self-record path never opens app capture, leaves no slot files, and reports no losses. */
    private fun assertNoSelfRecordFiles(slotKey: String) {
        assertFalse(calls.contains("capture.start"))
        assertFalse(store.isOccupied(slotKey))
        assertFalse(store.audioFile(slotKey).exists())
        assertFalse(store.sidecarFile(slotKey).exists())
        assertNoLostRecordings()
    }

    @Test
    fun `self record convert to text inserts recognized text without a slot`() {
        events
        startSelfRecord("conv-1")
        assertNoSelfRecordFiles("conv-1")
        engines.recognizer.callbacks.onResults("hello")
        controller.finish(DictationSubmit.Insert)
        assertEquals(DictationState.Transcribing("conv-1", DictationSubmit.Insert), controller.state.value)
        assertTrue(events.isEmpty())
        engines.recognizer.callbacks.onResults("world")

        assertEquals(DictationState.Idle, controller.state.value)
        assertEquals(
            listOf<DictationEvent>(DictationEvent.Insert("conv-1", DictationRules.join(listOf("hello", "world")))),
            events,
        )
        assertEquals(listOf("startListening", "restartListening", "stopListening", "destroy"), engines.recognizer.calls)
        assertTrue(engine.segments.isEmpty())
        assertNoSelfRecordFiles("conv-1")
    }

    @Test
    fun `self record send sends recognized text`() {
        events
        startSelfRecord("conv-1")
        controller.finish(DictationSubmit.Send)
        engines.recognizer.callbacks.onResults("hello")

        assertEquals(DictationState.Idle, controller.state.value)
        assertEquals(listOf<DictationEvent>(DictationEvent.Send("conv-1", "hello")), events)
        assertNoSelfRecordFiles("conv-1")
    }

    @Test
    fun `self record with no recognized text emits NoSpeech`() {
        events
        startSelfRecord("conv-1")
        controller.finish(DictationSubmit.Send)
        engines.recognizer.callbacks.onError(SpeechRecognizer.ERROR_NO_MATCH)

        assertEquals(DictationState.Idle, controller.state.value)
        assertEquals(listOf<DictationEvent>(DictationEvent.NoSpeech("conv-1")), events)
        assertNoSelfRecordFiles("conv-1")
    }

    @Test
    fun `self record discard returns Idle at once without undo window`() {
        events
        startSelfRecord("conv-1")
        engines.recognizer.callbacks.onResults("hello")
        controller.discard()

        assertEquals(DictationState.Idle, controller.state.value)
        assertTrue(events.isEmpty())
        assertEquals(listOf("startListening", "restartListening", "cancel", "destroy"), engines.recognizer.calls)
        assertFalse(controller.undoDiscard("conv-1"))
        assertEquals(DictationState.Idle, controller.state.value)
        engines.recognizer.callbacks.onResults("late")
        assertTrue(events.isEmpty())
        assertNoSelfRecordFiles("conv-1")
    }

    @Test
    fun `self record discard while transcribing returns Idle without events`() {
        events
        startSelfRecord("conv-1")
        controller.finish(DictationSubmit.Insert)
        controller.discard()

        assertEquals(DictationState.Idle, controller.state.value)
        assertTrue(events.isEmpty())
        assertNoSelfRecordFiles("conv-1")
    }

    @Test
    fun `self record interrupted by background inserts recognized text and returns Idle`() {
        events
        startSelfRecord("conv-1")
        engines.recognizer.callbacks.onResults("hello")
        environment.background()

        assertEquals(DictationState.Idle, controller.state.value)
        assertEquals(listOf<DictationEvent>(DictationEvent.Insert("conv-1", "hello")), events)
        assertEquals(listOf("startListening", "restartListening", "cancel", "destroy"), engines.recognizer.calls)
        assertNull(environment.onInterrupted)
        assertNoSelfRecordFiles("conv-1")
    }

    @Test
    fun `self record interrupted without text returns to idle`() {
        events
        startSelfRecord("conv-1")
        now += 20_000
        environment.background()

        assertEquals(DictationState.Idle, controller.state.value)
    }

    @Test
    fun `self record recognizer error inserts recognized text then reports failure`() {
        events
        startSelfRecord("conv-1")
        engines.recognizer.callbacks.onResults("hello")
        engines.recognizer.callbacks.onError(SpeechRecognizer.ERROR_NETWORK)

        assertEquals(DictationState.Idle, controller.state.value)
        assertEquals(
            listOf(DictationEvent.Insert("conv-1", "hello"), DictationEvent.SystemRecognizerFailed("conv-1")),
            events,
        )
        assertNull(environment.onInterrupted)
        assertNoSelfRecordFiles("conv-1")
    }

    @Test
    fun `self record recognizer error after finish with no text only reports failure`() {
        events
        startSelfRecord("conv-1")
        controller.finish(DictationSubmit.Send)
        engines.recognizer.callbacks.onError(SpeechRecognizer.ERROR_NETWORK)

        assertEquals(DictationState.Idle, controller.state.value)
        assertEquals(listOf<DictationEvent>(DictationEvent.SystemRecognizerFailed("conv-1")), events)
        assertNoSelfRecordFiles("conv-1")
    }

    // ---- Slots across restarts and session switches, undo-window timing ----

    private val bin get() = File(store.root, RecordingStore.DISCARDED_DIR)

    private fun binIsEmpty() = bin.listFiles().isNullOrEmpty()

    /** The undo window is timed with coroutine virtual time: advances [millis] and runs tasks that are due. */
    private fun advance(millis: Long) {
        dispatcher.scheduler.advanceTimeBy(millis)
        dispatcher.scheduler.runCurrent()
    }

    @Test
    fun `interrupted recording shows Interrupted with its sidecar duration on a new controller after cold start`() {
        events
        controller.bind("conv-1")
        recordSeconds("conv-1", 2)
        controller.interrupt()

        store.sweepOnLaunch()
        val restarted = makeController()
        val restartedEvents = collectEvents(restarted)
        assertEquals(DictationState.Idle, restarted.state.value)
        restarted.bind("conv-1")

        assertEquals(DictationState.Interrupted("conv-1"), restarted.state.value)
        assertSlotKept("conv-1", RecordingSlotStatus.Interrupted)
        assertEquals(2.0, store.read("conv-1")!!.durationSec, 0.01)

        restarted.transcribeSaved(DictationSubmit.Insert)
        assertEquals(listOf<DictationEvent>(DictationEvent.Insert("conv-1", "hello world")), restartedEvents)
        assertEquals(DictationState.Idle, restarted.state.value)
        assertFalse(store.isOccupied("conv-1"))
        assertNoLostRecordings()
    }

    @Test
    fun `start during the first launch sweep is not dropped`() {
        val holdable = HoldableIo()
        io = holdable
        events
        // Hold the first-bind sweep (io block) so it does not run, simulating the user tapping start before the cold-start sweep has finished.
        holdable.hold = true
        controller.bind("conv-1")
        val held = checkNotNull(holdable.held) { "launch sweep was not held" }
        controller.start("conv-1")
        assertEquals(DictationState.Idle, controller.state.value)
        assertFalse(store.isOccupied("conv-1"))

        CoroutineScope(dispatcher).launch { held.run() }

        assertEquals(DictationState.Recording("conv-1", 5_000L), controller.state.value)
        assertEquals(listOf("stopReadAloud", "permission", "capture.start"), calls)
        assertEquals(RecordingSlotStatus.Recording, store.read("conv-1")?.status)
        assertTrue(events.isEmpty())
    }

    @Test
    fun `start during sweep that finds a saved recording follows the interrupted state`() {
        events
        controller.bind("conv-1")
        recordSeconds("conv-1", 2)
        controller.interrupt()

        // New controller after a cold start: the bind sweep / slot read is held, and start is tapped meanwhile.
        val holdable = HoldableIo()
        io = holdable
        val restarted = makeController()
        val restartedEvents = collectEvents(restarted)
        holdable.hold = true
        restarted.bind("conv-1")
        val held = checkNotNull(holdable.held) { "launch sweep was not held" }
        calls.clear()
        restarted.start("conv-1")
        assertEquals(DictationState.Idle, restarted.state.value)

        CoroutineScope(dispatcher).launch { held.run() }

        // Same as tapping start in the Interrupted state: enters SlotOccupied, only stops read-aloud, requests no permission and leaves the old recording alone.
        assertEquals(DictationState.SlotOccupied("conv-1"), restarted.state.value)
        assertEquals(listOf("stopReadAloud"), calls)
        assertSlotKept("conv-1", RecordingSlotStatus.Interrupted)
        assertTrue(restartedEvents.isEmpty())
    }

    @Test
    fun `failed recording sidecar shows Interrupted after cold start`() {
        events
        engine.result = failure(DictationFailure.Network)
        recordSeconds("conv-1", 3)
        controller.finish(DictationSubmit.Send)
        assertEquals(DictationState.Failed("conv-1", DictationFailedAction.Retry), controller.state.value)
        assertEquals(RecordingSlotStatus.Failed, store.read("conv-1")?.status)

        store.sweepOnLaunch()
        val restarted = makeController()
        restarted.bind("conv-1")

        assertEquals(DictationState.Interrupted("conv-1"), restarted.state.value)
        assertEquals(3.0, store.read("conv-1")!!.durationSec, 0.01)
        assertTrue(store.audioFile("conv-1").length() > 0)
        assertNoLostRecordings()
    }

    @Test
    fun `binding a key without a saved recording stays Idle`() {
        events
        controller.bind("conv-2")

        assertEquals(DictationState.Idle, controller.state.value)
        assertTrue(events.isEmpty())
        assertNoLostRecordings()
    }

    @Test
    fun `same key bind by second owner takes over`() {
        events
        val oldHost = Any()
        val newHost = Any()
        controller.bind("draft:home", oldHost)
        recordSeconds("draft:home", 2)

        // The home page and a new chat without a conversation share one key: the new page binds first and the old page detaches later; the binding is not cleared by the old page.
        controller.bind("draft:home", newHost)
        controller.detach("draft:home", oldHost)
        assertEquals(newHost, controller.boundOwner.value)
        assertTrue(controller.state.value is DictationState.Recording)
        assertEquals(0, capture.stops)

        controller.finish(DictationSubmit.Insert)
        assertEquals(listOf<DictationEvent>(DictationEvent.Insert("draft:home", "hello world")), events)
        assertEquals(DictationState.Idle, controller.state.value)
        assertFalse(store.isOccupied("draft:home"))
        assertNoLostRecordings()
    }

    @Test
    fun `detach by stale owner is ignored`() {
        events
        val host = Any()
        controller.bind("conv-1", host)
        recordSeconds("conv-1", 2)

        controller.detach("conv-1", Any())
        controller.detach("conv-1")
        assertTrue(controller.state.value is DictationState.Recording)
        assertEquals(host, controller.boundOwner.value)

        controller.detach("conv-1", host)
        assertNull(controller.boundOwner.value)
        assertEquals(DictationState.Interrupted("conv-1"), controller.state.value)
        assertSlotKept("conv-1", RecordingSlotStatus.Interrupted)
        assertTrue(events.isEmpty())
        assertNoLostRecordings()
    }

    @Test
    fun `start keeps current owner`() {
        events
        val host = Any()
        controller.bind("conv-1", host)
        controller.start("conv-1")

        assertTrue(controller.state.value is DictationState.Recording)
        assertEquals(host, controller.boundOwner.value)
        // Starting recording did not swap the host for the default identity: the default identity's detach has no effect, only the host's own does.
        controller.detach("conv-1")
        assertTrue(controller.state.value is DictationState.Recording)
        controller.detach("conv-1", host)
        assertEquals(DictationState.Interrupted("conv-1"), controller.state.value)
        assertNoLostRecordings()
    }

    @Test
    fun `boundOwner follows bind and detach`() {
        val first = Any()
        val second = Any()
        assertNull(controller.boundOwner.value)

        controller.bind("conv-1", first)
        assertEquals(first, controller.boundOwner.value)
        controller.bind("conv-2", second)
        assertEquals(second, controller.boundOwner.value)
        controller.detach("conv-1", second)
        controller.detach("conv-2", first)
        assertEquals(second, controller.boundOwner.value)
        controller.detach("conv-2", second)
        assertNull(controller.boundOwner.value)

        controller.bind("conv-1")
        assertEquals(DefaultDictationOwner, controller.boundOwner.value)
        controller.detach("conv-1")
        assertNull(controller.boundOwner.value)
    }

    @Test
    fun `cold start transcribes a saved recording with the still valid cloud selection`() {
        settings.setSelection(VoiceDirection.Stt, cloudSelection)
        catalog.cached = voiceCatalog
        providers = listOf(openAI)
        seedInterruptedSlot("conv-1", 2)
        val restarted = makeController()
        val restartedEvents = collectEvents(restarted)

        restarted.bind("conv-1")
        assertEquals(DictationState.Interrupted("conv-1"), restarted.state.value)
        restarted.transcribeSaved(DictationSubmit.Insert)

        assertEquals(1, cloudEngine.segments.size)
        assertTrue(engine.segments.isEmpty())
        assertEquals("sk-live", engines.cloudCalls.single().third)
        assertEquals(listOf<DictationEvent>(DictationEvent.Insert("conv-1", "hello world")), restartedEvents)
        assertEquals(cloudSelection, settings.selection(VoiceDirection.Stt))
        assertFalse(store.isOccupied("conv-1"))
        assertNoLostRecordings()
    }

    @Test
    fun `bind clears the selected engine so a saved recording falls back once when the cloud selection became invalid`() {
        events
        settings.setSelection(VoiceDirection.Stt, cloudSelection)
        catalog.cached = voiceCatalog
        providers = listOf(openAI)
        controller.bind("conv-1")
        recordSeconds("conv-1", 2)
        assertEquals("${ProviderKind.OpenAI.rawValue}/gpt-transcribe", store.read("conv-1")?.engine)
        controller.interrupt()
        controller.bind("conv-2")
        controller.bind("conv-1")
        assertEquals(DictationState.Interrupted("conv-1"), controller.state.value)

        // Connection deleted: after switching back, re-resolve per current settings instead of reusing the cloud engine from when recording started.
        providers = emptyList()
        controller.transcribeSaved(DictationSubmit.Insert)
        assertEquals(VoiceEngineSelection.System, settings.selection(VoiceDirection.Stt))
        dictate("conv-1")

        assertTrue(cloudEngine.segments.isEmpty())
        assertEquals(2, engine.segments.size)
        assertEquals(
            listOf(
                DictationEvent.EngineFallback("conv-1", VoiceFallbackReason.ConnectionMissing),
                DictationEvent.Insert("conv-1", "hello world"),
                DictationEvent.Insert("conv-1", "hello world"),
            ),
            events,
        )
        assertNoLostRecordings()
    }

    @Test
    fun `saved recording uses system silently when the catalog cannot be loaded after cold start`() {
        settings.setSelection(VoiceDirection.Stt, cloudSelection)
        catalog.cached = null
        catalog.refreshed = VoiceCatalogState.LoadFailed
        providers = listOf(openAI)
        seedInterruptedSlot("conv-1", 2)
        val restarted = makeController()
        val restartedEvents = collectEvents(restarted)

        restarted.bind("conv-1")
        restarted.transcribeSaved(DictationSubmit.Send)

        assertEquals(1, catalog.refreshes)
        assertTrue(engines.cloudCalls.isEmpty())
        assertEquals(1, engine.segments.size)
        assertEquals(listOf<DictationEvent>(DictationEvent.Send("conv-1", "hello world")), restartedEvents)
        assertEquals(cloudSelection, settings.selection(VoiceDirection.Stt))
        assertNoLostRecordings()
    }

    @Test
    fun `mic tap on another occupied key without bind resolves the engine from current settings`() {
        events
        settings.setSelection(VoiceDirection.Stt, cloudSelection)
        catalog.cached = voiceCatalog
        providers = listOf(openAI)
        recordSeconds("conv-1", 2)
        assertEquals("${ProviderKind.OpenAI.rawValue}/gpt-transcribe", store.read("conv-1")?.engine)
        controller.interrupt()
        seedInterruptedSlot("conv-2", 2)

        // After the setting reverts to system, tap the microphone on conv-2 directly without bind: "transcribe first" does not reuse conv-1's cloud engine.
        settings.setSelection(VoiceDirection.Stt, VoiceEngineSelection.System)
        controller.start("conv-2")
        assertEquals(DictationState.SlotOccupied("conv-2"), controller.state.value)
        controller.transcribeSaved(DictationSubmit.Insert)

        assertTrue(cloudEngine.segments.isEmpty())
        assertEquals(1, engine.segments.size)
        assertEquals(store.audioFile("conv-2"), engine.segments.single().aac)
        assertEquals(listOf<DictationEvent>(DictationEvent.Insert("conv-2", "hello world")), events)
        assertFalse(store.isOccupied("conv-2"))
        assertSlotKept("conv-1", RecordingSlotStatus.Interrupted)
        assertNoLostRecordings()
    }

    @Test
    fun `sweep removes expired and missing-audio recordings`() {
        val weekOld = RecordingStore(store.root, clock = { 1_700_000_000_000L - 8L * 24 * 3_600_000 })
        listOf("conv-7", "conv-8").forEach { key ->
            weekOld.open(key, SystemSTTEngine.ENGINE_NAME, FakeEncoder()).apply {
                write(speech)
                finish(RecordingSlotStatus.Interrupted)
            }
        }
        listOf("conv-5", "conv-6", "conv-4").forEach { key ->
            seedInterruptedSlot(key, 1)
        }
        store.audioFile("conv-5").delete()
        store.audioFile("conv-6").delete()

        controller.bind("conv-1")
        controller.bind("conv-2")

        assertNotNull(store.read("conv-4"))
    }

    @Test
    fun `runtime missing audio drops the slot and expired audio is discarded`() {
        events
        controller.bind("conv-0")
        seedInterruptedSlot("conv-1", 1)
        store.audioFile("conv-1").delete()
        controller.bind("conv-1")
        assertEquals(DictationState.Interrupted("conv-1"), controller.state.value)

        controller.transcribeSaved(DictationSubmit.Insert)

        assertEquals(DictationState.Idle, controller.state.value)
        assertFalse(store.isOccupied("conv-1"))
        assertTrue(engine.segments.isEmpty())

        // An expired recording read at runtime is discarded as expired, not counted as lost.
        RecordingStore(store.root, clock = { 1_700_000_000_000L - 8L * 24 * 3_600_000 })
            .open("conv-2", SystemSTTEngine.ENGINE_NAME, FakeEncoder())
            .apply {
                write(speech)
                finish(RecordingSlotStatus.Interrupted)
            }
        controller.bind("conv-2")
        controller.transcribeSaved(DictationSubmit.Insert)

        assertEquals(DictationState.Idle, controller.state.value)
        assertFalse(store.isOccupied("conv-2"))
        assertTrue(events.isEmpty())
    }

    @Test
    fun `first bind sweeps the store once and later binds do not`() {
        // Slot opened 7 days ago: the first-bind sweep deletes it as expired.
        val weekOld = RecordingStore(store.root, clock = { 1_700_000_000_000L - 8L * 24 * 3_600_000 })
        weekOld.open("conv-9", SystemSTTEngine.ENGINE_NAME, FakeEncoder()).apply {
            write(speech)
            finish(RecordingSlotStatus.Interrupted)
        }
        bin.mkdirs()
        File(bin, "leftover.aac").writeBytes(ByteArray(4))

        controller.bind("conv-1")
        assertNull(store.read("conv-9"))
        assertFalse(store.audioFile("conv-9").exists())
        assertTrue(binIsEmpty())

        bin.mkdirs()
        File(bin, "leftover.aac").writeBytes(ByteArray(4))
        controller.bind("conv-2")
        controller.bind("conv-1")
        assertFalse(binIsEmpty())
        assertEquals(DictationState.Idle, controller.state.value)
        assertNoLostRecordings()
    }

    @Test
    fun `switching session while recording interrupts the old slot first and switching back shows Interrupted`() {
        events
        controller.bind("conv-1")
        recordSeconds("conv-1", 2)
        controller.bind("conv-2")

        assertEquals(DictationState.Idle, controller.state.value)
        assertEquals(1, capture.stops)
        assertNull(environment.onInterrupted)
        assertSlotKept("conv-1", RecordingSlotStatus.Interrupted)
        assertEquals(2.0, store.read("conv-1")!!.durationSec, 0.01)
        assertFalse(store.isOccupied("conv-2"))

        controller.bind("conv-1")
        assertEquals(DictationState.Interrupted("conv-1"), controller.state.value)
        assertTrue(engine.segments.isEmpty())
        assertTrue(events.isEmpty())
        assertNoLostRecordings()
    }

    @Test
    fun `switching session while transcribing cancels the transcription and keeps the old slot as Interrupted`() {
        events
        val gate = CompletableDeferred<Unit>()
        engine.gate = gate
        controller.bind("conv-1")
        recordSeconds("conv-1", 2)
        controller.finish(DictationSubmit.Send)
        assertEquals(DictationState.Transcribing("conv-1", DictationSubmit.Send), controller.state.value)

        controller.bind("conv-2")
        assertEquals(1, engine.cancelled)
        assertEquals(DictationState.Idle, controller.state.value)
        assertSlotKept("conv-1", RecordingSlotStatus.Interrupted)
        gate.complete(Unit)
        assertEquals(DictationState.Idle, controller.state.value)
        assertTrue(events.isEmpty())

        controller.bind("conv-1")
        assertEquals(DictationState.Interrupted("conv-1"), controller.state.value)
        assertEquals(2.0, store.read("conv-1")!!.durationSec, 0.01)
        assertNoLostRecordings()
    }

    @Test
    fun `switching session during self record inserts recognized text then switches`() {
        events
        controller.bind("conv-1")
        startSelfRecord("conv-1")
        engines.recognizer.callbacks.onResults("hello")
        controller.bind("conv-2")

        assertEquals(DictationState.Idle, controller.state.value)
        assertEquals(listOf<DictationEvent>(DictationEvent.Insert("conv-1", "hello")), events)
        assertNull(environment.onInterrupted)
        assertNoSelfRecordFiles("conv-1")

        controller.bind("conv-1")
        assertEquals(DictationState.Idle, controller.state.value)
        assertNoSelfRecordFiles("conv-1")
    }

    @Test
    fun `sidecar engine is system for the system engine`() {
        events
        controller.start("conv-1")

        assertEquals("system", store.read("conv-1")?.engine)
    }

    @Test
    fun `undo window commits the discard automatically after four seconds`() {
        events
        recordSeconds("conv-1", 6)
        controller.discard()
        assertEquals(listOf<DictationEvent>(DictationEvent.DiscardUndoable("conv-1")), events)
        assertFalse(binIsEmpty())

        advance(4_000)
        assertTrue(binIsEmpty())
        assertFalse(controller.undoDiscard("conv-1"))
        assertEquals(DictationState.Idle, controller.state.value)
        assertFalse(store.isOccupied("conv-1"))
        assertNoLostRecordings()
    }

    @Test
    fun `undo within four seconds restores the recording and cancels the timer`() {
        events
        recordSeconds("conv-1", 6)
        controller.discard()

        advance(3_999)
        assertTrue(controller.undoDiscard("conv-1"))
        assertEquals(DictationState.Interrupted("conv-1"), controller.state.value)

        advance(10_000)
        assertSlotKept("conv-1", RecordingSlotStatus.Interrupted)
        assertEquals(6.0, store.read("conv-1")!!.durationSec, 0.01)
        assertNoLostRecordings()
    }

    @Test
    fun `a new discard commits the previous undo window at once`() {
        events
        controller.bind("conv-1")
        recordSeconds("conv-1", 6)
        controller.discard()
        controller.bind("conv-2")
        recordSeconds("conv-2", 6)
        controller.discard()

        assertEquals(
            listOf(DictationEvent.DiscardUndoable("conv-1"), DictationEvent.DiscardUndoable("conv-2")),
            events,
        )
        assertFalse(controller.undoDiscard("conv-1"))
        assertTrue(controller.undoDiscard("conv-2"))
        assertEquals(DictationState.Interrupted("conv-2"), controller.state.value)
        assertFalse(store.isOccupied("conv-1"))
        assertSlotKept("conv-2", RecordingSlotStatus.Interrupted)
        assertTrue(binIsEmpty())
        assertNoLostRecordings()
    }

    @Test
    fun `undo window keeps running after switching session and commits on time`() {
        events
        controller.bind("conv-1")
        recordSeconds("conv-1", 6)
        controller.discard()
        controller.bind("conv-2")
        advance(3_999)
        assertFalse(binIsEmpty())

        advance(1)
        assertTrue(binIsEmpty())
        controller.bind("conv-1")
        assertEquals(DictationState.Idle, controller.state.value)
        assertFalse(controller.undoDiscard("conv-1"))
        assertFalse(store.isOccupied("conv-1"))
        assertNoLostRecordings()
    }

    @Test
    fun `undo after switching session restores the old recording without touching the current state`() {
        events
        controller.bind("conv-1")
        recordSeconds("conv-1", 6)
        controller.discard()
        seedInterruptedSlot("conv-2", 2)
        controller.bind("conv-2")
        assertEquals(DictationState.Interrupted("conv-2"), controller.state.value)

        assertTrue(controller.undoDiscard("conv-1"))
        assertEquals(DictationState.Interrupted("conv-2"), controller.state.value)
        assertSlotKept("conv-1", RecordingSlotStatus.Interrupted)
        assertEquals(6.0, store.read("conv-1")!!.durationSec, 0.01)
        assertSlotKept("conv-2", RecordingSlotStatus.Interrupted)

        advance(10_000)
        assertSlotKept("conv-1", RecordingSlotStatus.Interrupted)
        assertTrue(binIsEmpty())
        controller.bind("conv-1")
        assertEquals(DictationState.Interrupted("conv-1"), controller.state.value)
        assertNoLostRecordings()
    }

    // ---- Recording UI outputs ----

    @Test
    fun `dismissDenied returns to idle`() {
        events
        controller.dismissDenied()
        assertEquals(DictationState.Idle, controller.state.value)

        recordSeconds("conv-1", 1)
        controller.dismissDenied()
        assertEquals(DictationState.Recording("conv-1", 5_000L), controller.state.value)
        controller.interrupt()
        controller.dismissDenied()
        assertEquals(DictationState.Interrupted("conv-1"), controller.state.value)
        controller.discard()

        granted = false
        controller.start("conv-2")
        assertEquals(DictationState.Denied, controller.state.value)
        controller.dismissDenied()

        assertEquals(DictationState.Idle, controller.state.value)
        assertFalse(store.isOccupied("conv-2"))
        assertTrue(events.isEmpty())
    }

    @Test
    fun `engineInfo reports cloud provider name and id`() {
        events
        settings.setSelection(VoiceDirection.Stt, cloudSelection)
        catalog.cached = voiceCatalog
        providers = listOf(openAI.copy(customName = "Work OpenAI"))
        assertNull(controller.engineInfo.value)

        controller.start("conv-1")
        assertEquals(DictationEngineInfo("Work OpenAI", "conn-openai", true), controller.engineInfo.value)
        capture.feed(speech)
        controller.finish(DictationSubmit.Insert)

        assertEquals(DictationState.Idle, controller.state.value)
        assertNull(controller.engineInfo.value)
        assertEquals(listOf<DictationEvent>(DictationEvent.Insert("conv-1", "hello world")), events)
    }

    @Test
    fun `engineInfo for system engine has no name`() {
        events
        controller.start("conv-1")
        assertEquals(DictationEngineInfo(displayName = null, providerId = null, isCloud = false), controller.engineInfo.value)
        controller.interrupt()
        controller.discard()
        assertNull(controller.engineInfo.value)

        // Transcribing a retained recording after a cold start: resolved per current settings; the system engine likewise has no name.
        seedInterruptedSlot("conv-2", 1)
        engine.result = failure(DictationFailure.Http(401))
        val restarted = makeController()
        restarted.bind("conv-2")
        assertNull(restarted.engineInfo.value)
        restarted.transcribeSaved(DictationSubmit.Insert)

        assertEquals(DictationState.Failed::class, restarted.state.value::class)
        assertEquals(DictationEngineInfo(displayName = null, providerId = null, isCloud = false), restarted.engineInfo.value)
    }

    @Test
    fun `pendingDuration reads sidecar when interrupted or occupied`() {
        events
        assertNull(controller.pendingDurationSec.value)
        recordSeconds("conv-1", 2)
        assertNull(controller.pendingDurationSec.value)
        controller.interrupt()
        assertEquals(2.0, controller.pendingDurationSec.value!!, 0.01)
        controller.discard()
        assertNull(controller.pendingDurationSec.value)

        seedInterruptedSlot("conv-2", 3)
        controller.start("conv-2")
        assertEquals(DictationState.SlotOccupied("conv-2"), controller.state.value)
        assertEquals(3.0, controller.pendingDurationSec.value!!, 0.01)
        controller.discard()

        engine.result = failure(DictationFailure.Http(401))
        recordSeconds("conv-3", 1)
        controller.finish(DictationSubmit.Insert)
        assertEquals(DictationState.Failed("conv-3", DictationFailedAction.CheckConnection), controller.state.value)
        assertEquals(1.0, controller.pendingDurationSec.value!!, 0.01)

        controller.discard()
        assertNull(controller.pendingDurationSec.value)

        // null when the sidecar cannot be read (only audio remains).
        seedInterruptedSlot("conv-4", 1)
        assertTrue(store.sidecarFile("conv-4").delete())
        controller.start("conv-4")
        assertEquals(DictationState.SlotOccupied("conv-4"), controller.state.value)
        assertNull(controller.pendingDurationSec.value)
    }

    @Test
    fun `store io never runs on main`() {
        val holdable = HoldableIo()
        io = holdable
        events
        seedInterruptedSlot("conv-2", 6)
        controller.bind("conv-2")
        assertEquals(DictationState.Interrupted("conv-2"), controller.state.value)

        // The slot occupancy check runs on io: while held, SlotOccupied is not entered.
        holdable.holdAll = true
        controller.start("conv-2")
        assertEquals(DictationState.Interrupted("conv-2"), controller.state.value)
        assertTrue(holdable.queued.isNotEmpty())
        holdable.drain(CoroutineScope(dispatcher))
        assertEquals(DictationState.SlotOccupied("conv-2"), controller.state.value)

        controller.discard()
        assertEquals(listOf<DictationEvent>(DictationEvent.DiscardUndoable("conv-2")), events)

        // Moving the undone recording back runs on io: while held, the recording is not yet back in the slot.
        holdable.holdAll = true
        assertTrue(controller.undoDiscard("conv-2"))
        assertFalse(store.isOccupied("conv-2"))
        assertEquals(DictationState.Idle, controller.state.value)
        holdable.drain(CoroutineScope(dispatcher))
        assertEquals(DictationState.Interrupted("conv-2"), controller.state.value)
        assertSlotKept("conv-2", RecordingSlotStatus.Interrupted)

        controller.discard()
        val voiceRoot = File(temp.root, "voice")
        val binned = voiceRoot.walkTopDown().count { it.isFile }
        assertTrue(binned > 0)

        // Clearing the trash area runs on io: while held, the file still exists.
        holdable.holdAll = true
        controller.commitDiscard("conv-2")
        assertEquals(binned, voiceRoot.walkTopDown().count { it.isFile })
        holdable.drain(CoroutineScope(dispatcher))
        assertEquals(0, voiceRoot.walkTopDown().count { it.isFile })
        controller.undoDiscard("conv-2")
        assertEquals(DictationState.Idle, controller.state.value)
        assertFalse(store.isOccupied("conv-2"))
        assertNoLostRecordings()
    }

    @Test
    fun `bind after undo of other slot sees restored recording`() {
        val holdable = HoldableIo()
        io = holdable
        events
        recordSeconds("conv-1", 6)
        controller.discard()
        assertEquals(listOf<DictationEvent>(DictationEvent.DiscardUndoable("conv-1")), events)
        controller.bind("conv-2")
        assertEquals(DictationState.Idle, controller.state.value)

        // Switching back to a slot while undoing another slot's move-back is still on io: the bind's slot read must be ordered after the move-back.
        holdable.holdAll = true
        assertTrue(controller.undoDiscard("conv-1"))
        controller.bind("conv-1")
        holdable.drainLatestFirst(CoroutineScope(dispatcher))

        assertEquals(DictationState.Interrupted("conv-1"), controller.state.value)
        assertSlotKept("conv-1", RecordingSlotStatus.Interrupted)
        assertNoLostRecordings()
    }

    @Test
    fun `mic tap during discard io starts after it completes`() {
        val holdable = HoldableIo()
        io = holdable
        events
        recordSeconds("conv-1", 2)
        holdable.holdAll = true
        controller.discard()
        assertEquals(DictationState.Idle, controller.state.value)

        // Tap the microphone before the discard io has finished: wait for it, then start recording per the state at that time, without silently ignoring the tap.
        controller.start("conv-1")
        holdable.drain(CoroutineScope(dispatcher))

        assertTrue(controller.state.value is DictationState.Recording)
        assertTrue(store.isOccupied("conv-1"))
    }

    @Test
    fun `pending duration published after io read`() {
        val holdable = HoldableIo()
        io = holdable
        events
        recordSeconds("conv-1", 2)
        holdable.holdAll = true
        controller.interrupt()
        assertEquals(DictationState.Interrupted("conv-1"), controller.state.value)
        // The sidecar read is held on io: no duration is emitted before it finishes.
        assertNull(controller.pendingDurationSec.value)
        holdable.drain(CoroutineScope(dispatcher))
        assertEquals(2.0, controller.pendingDurationSec.value!!, 0.01)
    }

    // ---- Host leaving ----

    @Test
    fun `detach while recording keeps recording as interrupted`() {
        events
        controller.bind("conv-1")
        recordSeconds("conv-1", 2)
        controller.detach("conv-1")

        assertEquals(DictationState.Interrupted("conv-1"), controller.state.value)
        assertEquals(1, capture.stops)
        assertNull(environment.onInterrupted)
        assertSlotKept("conv-1", RecordingSlotStatus.Interrupted)
        assertEquals(2.0, store.read("conv-1")!!.durationSec, 0.01)
        assertTrue(engine.segments.isEmpty())
        assertTrue(events.isEmpty())

        // Host returns: shows Interrupted according to the retained recording.
        controller.bind("conv-1")
        assertEquals(DictationState.Interrupted("conv-1"), controller.state.value)
        controller.discard()

        // Recognizer self-record has no recording to keep: recognized text is emitted as Insert and the state returns to Idle; the event stays in the channel.
        controller.bind("conv-2")
        startSelfRecord("conv-2")
        engines.recognizer.callbacks.onResults("hello")
        controller.detach("conv-2")
        assertEquals(DictationState.Idle, controller.state.value)
        assertEquals(listOf<DictationEvent>(DictationEvent.Insert("conv-2", "hello")), events)
        assertNull(environment.onInterrupted)
        assertFalse(store.isOccupied("conv-2"))
        assertFalse(store.audioFile("conv-2").exists())
    }

    @Test
    fun `detach while transcribing keeps recording as interrupted`() {
        events
        val gate = CompletableDeferred<Unit>()
        engine.gate = gate
        controller.bind("conv-1")
        recordSeconds("conv-1", 2)
        controller.finish(DictationSubmit.Send)
        assertEquals(DictationState.Transcribing("conv-1", DictationSubmit.Send), controller.state.value)

        controller.detach("conv-1")
        assertEquals(1, engine.cancelled)
        assertEquals(DictationState.Interrupted("conv-1"), controller.state.value)
        assertSlotKept("conv-1", RecordingSlotStatus.Interrupted)
        assertEquals(2.0, controller.pendingDurationSec.value!!, 0.01)
        gate.complete(Unit)
        assertEquals(DictationState.Interrupted("conv-1"), controller.state.value)
        assertTrue(events.isEmpty())
        assertNoLostRecordings()

        // Leaving during transcription on the no-file branch: recognized text is emitted as Insert and the state returns to Idle.
        controller.bind("conv-1")
        controller.discard()
        controller.bind("conv-2")
        startSelfRecord("conv-2")
        engines.recognizer.callbacks.onResults("hello")
        controller.finish(DictationSubmit.Send)
        controller.detach("conv-2")
        assertEquals(DictationState.Idle, controller.state.value)
        assertEquals(listOf<DictationEvent>(DictationEvent.Insert("conv-2", "hello")), events)
        assertFalse(store.isOccupied("conv-2"))
        assertFalse(store.audioFile("conv-2").exists())
    }

    @Test
    fun `detach during permission request abandons start`() {
        events
        val gate = CompletableDeferred<Unit>()
        permissionGate = gate
        controller.start("conv-1")
        assertEquals(DictationState.Idle, controller.state.value)

        controller.detach("conv-1")
        gate.complete(Unit)

        assertEquals(DictationState.Idle, controller.state.value)
        assertEquals(listOf("stopReadAloud", "permission"), calls)
        assertFalse(store.isOccupied("conv-1"))
        assertNull(controller.engineInfo.value)
        assertNull(environment.onInterrupted)
        assertTrue(events.isEmpty())
        assertNoLostRecordings()
    }

    @Test
    fun `detach while resolving engine abandons start`() {
        events
        settings.setSelection(VoiceDirection.Stt, cloudSelection)
        catalog.cached = voiceCatalog
        providers = listOf(openAI)
        val gate = CompletableDeferred<Unit>()
        catalog.gate = gate
        controller.start("conv-1")
        assertEquals(DictationState.Idle, controller.state.value)

        controller.detach("conv-1")
        gate.complete(Unit)

        assertEquals(DictationState.Idle, controller.state.value)
        assertEquals(listOf("stopReadAloud", "permission"), calls)
        assertFalse(store.isOccupied("conv-1"))
        assertFalse(store.audioFile("conv-1").exists())
        assertNull(controller.engineInfo.value)
        assertNull(environment.onInterrupted)
        assertTrue(events.isEmpty())
        assertNoLostRecordings()
    }

    @Test
    fun `transcription finishing without bound host keeps recording`() {
        events
        controller.bind("conv-1")
        recordSeconds("conv-1", 2)
        controller.detach("conv-1")
        controller.transcribeSaved(DictationSubmit.Send)

        assertEquals(1, engine.segments.size)
        assertEquals(DictationState.Interrupted("conv-1"), controller.state.value)
        assertSlotKept("conv-1", RecordingSlotStatus.Interrupted)
        assertTrue(events.isEmpty())

        // Host returns and transcribes again: sends as usual and deletes the recording.
        controller.bind("conv-1")
        controller.transcribeSaved(DictationSubmit.Send)
        assertEquals(DictationState.Idle, controller.state.value)
        assertEquals(listOf<DictationEvent>(DictationEvent.Send("conv-1", "hello world")), events)
        assertFalse(store.isOccupied("conv-1"))
        assertNoLostRecordings()
    }

    @Test
    fun `binding another slot while transcribing interrupts it`() {
        events
        val gate = CompletableDeferred<Unit>()
        engine.gate = gate
        recordSeconds("conv-1", 2)
        controller.finish(DictationSubmit.Insert)

        controller.bind("conv-2")
        assertEquals(1, engine.cancelled)
        assertEquals(DictationState.Idle, controller.state.value)
        assertSlotKept("conv-1", RecordingSlotStatus.Interrupted)
        gate.complete(Unit)
        assertEquals(DictationState.Idle, controller.state.value)
        assertTrue(events.isEmpty())

        controller.bind("conv-1")
        assertEquals(DictationState.Interrupted("conv-1"), controller.state.value)
        assertNoLostRecordings()
    }

    @Test
    fun `start binds its slot`() {
        events
        controller.bind("conv-1")
        controller.start("conv-2")
        assertEquals(DictationState.Recording("conv-2", 5_000L), controller.state.value)
        capture.feed(speech)

        // Host has switched to conv-2: conv-1 leaving has no effect, and a same-key bind does not switch.
        controller.detach("conv-1")
        controller.bind("conv-2")
        assertEquals(DictationState.Recording("conv-2", 5_000L), controller.state.value)

        controller.detach("conv-2")
        assertEquals(DictationState.Interrupted("conv-2"), controller.state.value)
        assertSlotKept("conv-2", RecordingSlotStatus.Interrupted)
        assertTrue(events.isEmpty())
        assertNoLostRecordings()
    }

    @Test
    fun `detach of another slot is ignored`() {
        events
        controller.bind("conv-1")
        recordSeconds("conv-1", 1)
        controller.detach("conv-2")
        assertEquals(DictationState.Recording("conv-1", 5_000L), controller.state.value)
        assertEquals(0, capture.stops)
        assertNotNull(environment.onInterrupted)

        val gate = CompletableDeferred<Unit>()
        engine.gate = gate
        controller.finish(DictationSubmit.Insert)
        controller.detach("conv-2")
        assertEquals(DictationState.Transcribing("conv-1", DictationSubmit.Insert), controller.state.value)
        assertEquals(0, engine.cancelled)
        gate.complete(Unit)

        assertEquals(DictationState.Idle, controller.state.value)
        assertEquals(listOf<DictationEvent>(DictationEvent.Insert("conv-1", "hello world")), events)
        assertFalse(store.isOccupied("conv-1"))
        assertNoLostRecordings()
    }
}
