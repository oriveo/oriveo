package ai.oriveo.community.core.voice

import android.content.Context
import android.content.Intent
import android.media.AudioFormat
import android.os.Bundle
import android.os.Looper
import android.os.Parcelable
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.test.core.app.ApplicationProvider
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * Drives the production [SystemSTTEngine] with a fake recognizer backend: pipe sessions (intent, PCM written to the pipe as-is, segment joining, stop and errors),
 * self-record sessions (restart and accumulation after a silent round ends, stop, errors, interruption, busy restart), and slot file re-recognition (fake decoder).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class SystemSTTEngineTest {

    private class FakePipe(private val blockWrites: CountDownLatch? = null) : SystemSTTPipe {
        override val source: Parcelable = Bundle()
        private val written = ByteArrayOutputStream()
        val firstWriteEntered = CountDownLatch(1)

        @Volatile
        var sinkClosed = false

        @Volatile
        var sourceClosed = false

        override fun write(bytes: ByteArray, offset: Int, length: Int) {
            firstWriteEntered.countDown()
            blockWrites?.await(WAIT_SEC, TimeUnit.SECONDS)
            if (sinkClosed) throw IOException("sink closed")
            synchronized(written) {
                written.write(bytes, offset, length)
                (written as Object).notifyAll()
            }
        }

        fun bytes(): List<Byte> = synchronized(written) { written.toByteArray().toList() }

        /** Waits for the writer thread to write [size] cumulative bytes into this pipe. */
        fun awaitSize(size: Int) {
            val deadline = System.currentTimeMillis() + WAIT_SEC * 1_000
            synchronized(written) {
                while (written.size() < size && System.currentTimeMillis() < deadline) {
                    (written as Object).wait(50)
                }
                assertEquals(size, written.size())
            }
        }

        override fun closeSink() {
            sinkClosed = true
        }

        override fun closeSource() {
            sourceClosed = true
        }
    }

    private class FakeBackend(
        private val blockWrites: CountDownLatch? = null,
        private val defaultAvailable: Boolean = true,
        /** When true, the second startListening (fallback reopen) throws IOException. */
        private val failReopen: Boolean = false,
    ) : SystemSTTSessionBackend, SystemSTTListening {
        val pipe = FakePipe(blockWrites)

        /** The first call gets [pipe]; afterwards (on fallback to DEFAULT) a new one is created each time. */
        val pipes = mutableListOf<FakePipe>()
        var recognizer: SystemSTTRecognizer? = null
        var intent: Intent? = null
        lateinit var callbacks: SystemSTTCallbacks
        private val log = mutableListOf<String>()
        val stopped = CountDownLatch(1)

        /** Recognizer used for each startListening, in order. */
        val started = mutableListOf<SystemSTTRecognizer>()

        @Volatile
        var pipesCreated = 0

        val calls: List<String> get() = synchronized(log) { log.toList() }

        override fun createPipe(): SystemSTTPipe {
            pipesCreated += 1
            return (if (pipes.isEmpty()) pipe else FakePipe(blockWrites)).also { pipes += it }
        }

        override fun isDefaultRecognitionAvailable(): Boolean = defaultAvailable

        override suspend fun startListening(
            recognizer: SystemSTTRecognizer,
            intent: Intent,
            callbacks: SystemSTTCallbacks,
        ): SystemSTTListening {
            if (failReopen && started.isNotEmpty()) {
                started += recognizer
                throw IOException("reopen failed")
            }
            this.recognizer = recognizer
            this.intent = intent
            this.callbacks = callbacks
            started += recognizer
            return this
        }

        override fun stopListening() {
            val current = pipes.lastOrNull() ?: pipe
            synchronized(log) { log += "stopListening(sinkClosed=${current.sinkClosed})" }
            stopped.countDown()
        }

        override fun restartListening() {
            synchronized(log) { log += "restart" }
        }

        override fun cancel() {
            synchronized(log) { log += "cancel" }
        }

        override fun destroy() {
            synchronized(log) { log += "destroy" }
        }

        /** After stop the writer thread drains the queue, closes the write end and calls stopListening. */
        fun awaitStopped() {
            assertTrue("stopListening not reached", stopped.await(WAIT_SEC, TimeUnit.SECONDS))
        }
    }

    /** Emits PCM in the given chunks and stops when the sink stops accepting; afterwards throws [failure] if set. */
    private class FakeDecoder(
        private val chunks: List<ByteArray>,
        private val failure: IOException? = null,
    ) : AacDecoder {
        private val log = mutableListOf<Pair<File, ClosedFloatingPointRange<Double>?>>()

        val calls: List<Pair<File, ClosedFloatingPointRange<Double>?>> get() = synchronized(log) { log.toList() }

        override fun decode(file: File, range: ClosedFloatingPointRange<Double>?, sink: (ByteArray) -> Boolean) {
            synchronized(log) { log += file to range }
            for (chunk in chunks) if (!sink(chunk)) return
            failure?.let { throw it }
        }
    }

    /** Records the delay and defers the action until [fire]. */
    private class FakeSleeper : SystemSTTSleeper {
        val delays = mutableListOf<Long>()
        private var pending: (() -> Unit)? = null

        override fun sleep(millis: Long, then: () -> Unit) {
            delays += millis
            pending = then
        }

        fun fire() {
            val action = pending!!
            pending = null
            action()
        }
    }

    private val route = SystemSTTRoute.Pipe(SystemSTTRecognizer.ON_DEVICE, "de-DE")

    @Test
    fun `pipe intent carries audio source segmented session pcm format and language`() = runTest {
        val backend = FakeBackend()

        SystemSTTEngine(backend).startPipeSession(route)

        val intent = backend.intent!!
        assertEquals(SystemSTTRecognizer.ON_DEVICE, backend.recognizer)
        assertEquals(RecognizerIntent.ACTION_RECOGNIZE_SPEECH, intent.action)
        @Suppress("DEPRECATION")
        assertSame(backend.pipe.source, intent.getParcelableExtra<Parcelable>(RecognizerIntent.EXTRA_AUDIO_SOURCE))
        assertEquals(RecognizerIntent.EXTRA_AUDIO_SOURCE, intent.getStringExtra(RecognizerIntent.EXTRA_SEGMENTED_SESSION))
        assertEquals(1, intent.getIntExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, -1))
        assertEquals(AudioFormat.ENCODING_PCM_16BIT, intent.getIntExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, -1))
        assertEquals(16_000, intent.getIntExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, -1))
        assertEquals("de-DE", intent.getStringExtra(RecognizerIntent.EXTRA_LANGUAGE))
        assertTrue(intent.getBooleanExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, false))
        assertEquals("system", SystemSTTEngine(backend).engineName)
    }

    @Test
    fun `pipe session streams partials and appends each segment as a final clearing the partial`() = runTest {
        val backend = FakeBackend()
        val session = SystemSTTEngine(backend).startPipeSession(route)

        assertEquals(LiveTranscript(), session.live.value)
        backend.callbacks.onPartialResult("  Hal ")
        assertEquals(LiveTranscript(emptyList(), "Hal"), session.live.value)
        backend.callbacks.onPartialResult(null)
        assertEquals(LiveTranscript(emptyList(), "Hal"), session.live.value)
        backend.callbacks.onSegmentResult("Hallo")
        assertEquals(LiveTranscript(listOf("Hallo"), ""), session.live.value)
        backend.callbacks.onSegmentResult(null)
        // No live text: an empty final does not change the state.
        assertEquals(LiveTranscript(listOf("Hallo"), ""), session.live.value)
        backend.callbacks.onPartialResult("Wel")
        backend.callbacks.onSegmentResult(null)
        // A final without text promotes the current live text to this segment.
        assertEquals(LiveTranscript(listOf("Hallo", "Wel"), ""), session.live.value)
        backend.callbacks.onPartialResult("Welt")
        backend.callbacks.onSegmentResult("Welt.")
        assertEquals(LiveTranscript(listOf("Hallo", "Wel", "Welt."), ""), session.live.value)

        session.stop()
        backend.awaitStopped()
        backend.callbacks.onEndOfSegmentedSession()
        assertEquals(STTResult.Success("Hallo Wel Welt."), session.await())
        backend.callbacks.onPartialResult("late")
        assertEquals(LiveTranscript(listOf("Hallo", "Wel", "Welt."), ""), session.live.value)
    }

    @Test
    fun `pipe partial with text counts as a result so a later language error does not fall back`() = runTest {
        val backend = FakeBackend()
        val session = SystemSTTEngine(backend).startPipeSession(route)

        backend.callbacks.onPartialResult("Guten")
        backend.callbacks.onError(SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE)

        val failure = DictationFailure.Recognizer(SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE)
        assertEquals(STTResult.Failed(failure, DictationPrimaryAction.Retry), session.await())
        assertEquals(listOf(SystemSTTRecognizer.ON_DEVICE), backend.started)
    }

    @Test
    fun `pipe session without a result 1500 ms after stop times out and releases the recognizer`() = runTest {
        val backend = FakeBackend()
        val session = SystemSTTEngine(backend).startPipeSession(route)
        session.onPcm(shortArrayOf(1, 2), 2)

        session.stop()
        backend.awaitStopped()
        val result = session.await()

        assertEquals(SystemSTTEngine.TIMEOUT_RESULT, result)
        assertEquals(STTResult.Failed(DictationFailure.Timeout, DictationPrimaryAction.Retry), result)
        assertEquals(1_500L, currentTime)
        assertTrue(backend.pipe.sinkClosed)
        assertTrue(backend.pipe.sourceClosed)
        assertEquals(listOf("stopListening(sinkClosed=true)", "destroy"), backend.calls)
        // A result arriving after the timeout does not change the outcome.
        backend.callbacks.onEndOfSegmentedSession()
        assertEquals(SystemSTTEngine.TIMEOUT_RESULT, session.await())
    }

    @Test
    fun `awaiting before stop has no time limit and the stop limit starts at stop`() = runTest {
        val backend = FakeBackend()
        val session = SystemSTTEngine(backend).startPipeSession(route)

        val pending = async { session.await() }
        advanceTimeBy(60_000)
        runCurrent()
        assertFalse(pending.isCompleted)

        session.stop()
        backend.awaitStopped()
        runCurrent()
        advanceTimeBy(1_400)
        runCurrent()
        assertFalse(pending.isCompleted)
        backend.callbacks.onSegmentResult("spät")
        backend.callbacks.onEndOfSegmentedSession()

        assertEquals(STTResult.Success("spät"), pending.await())
    }

    @Test
    fun `self record session exposes finals and the trimmed partial of the current round`() = runTest {
        val backend = FakeBackend()
        val session = SystemSTTEngine(backend).startSelfRecordSession(selfRoute)

        backend.callbacks.onPartialResult(" Bon ")
        assertEquals(LiveTranscript(emptyList(), "Bon"), session.live.value)
        backend.callbacks.onResults("Bonjour")
        assertEquals(LiveTranscript(listOf("Bonjour"), ""), session.live.value)
        backend.callbacks.onPartialResult("tout")
        backend.callbacks.onError(SpeechRecognizer.ERROR_NO_MATCH)
        assertEquals(LiveTranscript(listOf("Bonjour"), ""), session.live.value)
        backend.callbacks.onPartialResult("le monde ")
        session.interrupt()

        assertEquals(LiveTranscript(listOf("Bonjour", "le monde "), ""), session.live.value)
        assertEquals(STTResult.Success("Bonjour le monde"), session.await())
    }

    @Test
    fun `self record without a result 1500 ms after stop times out and destroys the recognizer`() = runTest {
        val backend = FakeBackend()
        val session = SystemSTTEngine(backend).startSelfRecordSession(selfRoute)
        backend.callbacks.onResults("Bonjour")

        session.stop()
        val result = session.await()

        assertEquals(SystemSTTEngine.TIMEOUT_RESULT, result)
        assertEquals(1_500L, currentTime)
        assertEquals(listOf("restart", "stopListening(sinkClosed=false)", "destroy"), backend.calls)
        assertEquals("Bonjour", session.transcript)
    }

    @Test
    fun `file transcription without a result times out at duration times 1_5 plus grace`() = runTest {
        val backend = FakeBackend()
        val decoder = FakeDecoder(listOf(ByteArray(3200) { it.toByte() }))
        val engine = SystemSTTEngine(backend, decoder, routeFor = { route }, fileTimeoutGraceMs = 200)
        val segment = STTSegment(File("slot.aac"), range = 0.0..0.2)

        val startedNs = System.nanoTime()
        val result = engine.transcribe(segment, "de-DE")
        val elapsedMs = (System.nanoTime() - startedNs) / 1_000_000

        assertEquals(SystemSTTEngine.TIMEOUT_RESULT, result)
        // Limit 0.2 s × 1.5 + 0.2 s = 0.5 s; the 1.5 s limit after stop does not apply to file recognition.
        assertTrue("elapsed $elapsedMs ms", elapsedMs in 500L until 1_500L)
        assertTrue(backend.pipe.sinkClosed)
        assertTrue(backend.pipe.sourceClosed)
        assertEquals(listOf("stopListening(sinkClosed=true)", "destroy"), backend.calls)
    }

    @Test
    fun `recognizer gate makes a new recognizer wait for the previous one to be destroyed`() = runTest {
        val gate = SystemSTTRecognizerGate()
        val first = gate.enqueue()
        first.awaitTurn()
        val second = gate.enqueue()

        val turn = async { second.awaitTurn() }
        advanceTimeBy(1_000)
        runCurrent()
        assertFalse(turn.isCompleted)
        first.release()
        runCurrent()

        turn.await()
        assertEquals(1_000L, currentTime)
    }

    @Test
    fun `recognizer gate never times out and waits until the previous one is destroyed`() = runTest {
        val gate = SystemSTTRecognizerGate()
        val first = gate.enqueue()
        val second = gate.enqueue()

        val turn = async { second.awaitTurn() }
        advanceTimeBy(10 * 60_000L)
        runCurrent()
        assertFalse(turn.isCompleted)

        first.release()
        runCurrent()
        assertTrue(turn.isCompleted)
        assertEquals(10 * 60_000L, currentTime)
    }

    @Test
    fun `recognizer gate completion is transitive when a later ticket releases first`() = runTest {
        val gate = SystemSTTRecognizerGate()
        val first = gate.enqueue()
        val second = gate.enqueue()
        val third = gate.enqueue()

        // Second instance cancelled while waiting and released first: the third must still wait for the first instance to be destroyed.
        second.release()
        val turn = async { third.awaitTurn() }
        runCurrent()
        assertFalse(turn.isCompleted)

        first.release()
        runCurrent()
        assertTrue(turn.isCompleted)
    }

    @Test
    fun `production session backend destroys the created recognizer and releases when startListening is cancelled`() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            val gate = SystemSTTRecognizerGate()
            val created = mutableListOf<SpeechRecognizer>()
            lateinit var caller: Job
            val recognizers = AndroidSystemSTTBackend(context(), gate) {
                SpeechRecognizer.createSpeechRecognizer(context()).also {
                    created += it
                    // Cancelled after creation but before startListening returns.
                    caller.cancel()
                }
            }
            val backend = AndroidSystemSTTSessionBackend(context(), recognizers)
            caller = launch {
                backend.startListening(SystemSTTRecognizer.DEFAULT, Intent(), NoopCallbacks)
                fail("startListening should be cancelled")
            }
            caller.join()

            assertTrue(caller.isCancelled)
            assertEquals(1, created.size)
            assertTrue(shadowOf(created.single()).isDestroyed)
            // Instance released: the next one gets its turn immediately.
            val next = async { gate.enqueue().awaitTurn() }
            runCurrent()
            assertTrue(next.isCompleted)
        } finally {
            Dispatchers.resetMain()
        }
    }

    @Test
    fun `production model download during a live session waits until the session recognizer is destroyed`() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            val gate = SystemSTTRecognizerGate()
            val created = mutableListOf<SpeechRecognizer>()
            val recognizers = AndroidSystemSTTBackend(context(), gate) {
                // The first instance must be destroyed before the second is created.
                assertTrue(created.all { shadowOf(it).isDestroyed })
                SpeechRecognizer.createSpeechRecognizer(context()).also { created += it }
            }
            val listening = AndroidSystemSTTSessionBackend(context(), recognizers)
                .startListening(SystemSTTRecognizer.DEFAULT, Intent(), NoopCallbacks)
            assertEquals(1, created.size)

            recognizers.triggerModelDownload(SystemSTTRecognizer.DEFAULT, "fr-FR")
            advanceTimeBy(10 * 60_000L)
            runCurrent()
            assertEquals(1, created.size)

            listening.destroy()
            shadowOf(Looper.getMainLooper()).idle()
            runCurrent()

            assertEquals(2, created.size)
            val download = shadowOf(created[1])
            assertEquals("fr-FR", download.latestModelDownloadIntent?.getStringExtra(RecognizerIntent.EXTRA_LANGUAGE))
            assertTrue(download.isDestroyed)
        } finally {
            Dispatchers.resetMain()
        }
    }

    @Test
    fun `file transcription routes through the router cache and checks support once`() = runTest {
        val routeBackend = object : SystemSTTBackend {
            val checks = mutableListOf<Pair<SystemSTTRecognizer, String>>()
            override fun isRecognitionAvailable() = true
            override fun isOnDeviceRecognitionAvailable() = true
            override fun hasEnabledRecognitionService() = true
            override suspend fun checkSupport(recognizer: SystemSTTRecognizer, languageTag: String): SystemSTTSupport {
                checks += recognizer to languageTag
                return SystemSTTSupport()
            }
            override fun triggerModelDownload(recognizer: SystemSTTRecognizer, languageTag: String) = Unit
            override fun uiLocale(): Locale = Locale.FRANCE
        }
        val router = SystemSTTRouter(routeBackend, sdkInt = 34)
        val engine = SystemSTTEngine(FakeBackend(), FakeDecoder(emptyList()), routeFor = router::route)

        repeat(2) { engine.transcribe(STTSegment(File("slot.aac")), "fr-FR") }

        assertEquals(
            listOf(SystemSTTRecognizer.ON_DEVICE to "fr-FR", SystemSTTRecognizer.DEFAULT to "fr-FR"),
            routeBackend.checks,
        )
    }

    @Test
    fun `pcm is written to the pipe as little-endian bytes and segments are joined`() = runTest {
        val backend = FakeBackend()
        val session = SystemSTTEngine(backend).startPipeSession(route)

        session.onPcm(shortArrayOf(0x0102, -2, 0x7FFF, 99), 3)
        session.onPcm(shortArrayOf(-32768), 1)
        session.stop()
        backend.awaitStopped()
        backend.callbacks.onSegmentResult("  Hallo ")
        backend.callbacks.onSegmentResult(null)
        backend.callbacks.onSegmentResult("Welt.")
        backend.callbacks.onSegmentResult("\u4f60\u597d")
        backend.callbacks.onEndOfSegmentedSession()

        val expected = byteArrayOf(0x02, 0x01, 0xFE.toByte(), 0xFF.toByte(), 0xFF.toByte(), 0x7F, 0x00, 0x80.toByte())
        assertEquals(expected.toList(), backend.pipe.bytes())
        assertEquals(STTResult.Success("Hallo Welt.\u4f60\u597d"), session.await())
        assertTrue(backend.pipe.sinkClosed)
        assertTrue(backend.pipe.sourceClosed)
        assertEquals(listOf("stopListening(sinkClosed=true)", "destroy"), backend.calls)
    }

    @Test
    fun `stop drains the queue in order then closes the pipe before stopListening and drops later pcm`() = runTest {
        val backend = FakeBackend()
        val session = SystemSTTEngine(backend).startPipeSession(route)
        val chunks = (1..50).map { chunk -> ShortArray(320) { (chunk * 1000 + it).toShort() } }
        chunks.forEach { session.onPcm(it, it.size) }

        session.stop()
        session.onPcm(shortArrayOf(2), 1)
        backend.awaitStopped()
        backend.callbacks.onSegmentResult("last words")
        backend.callbacks.onEndOfSegmentedSession()

        assertTrue(backend.pipe.sinkClosed)
        assertEquals(chunks.flatMap { it.leBytes() }, backend.pipe.bytes())
        assertEquals(0, session.droppedChunks)
        assertEquals(listOf("stopListening(sinkClosed=true)", "destroy"), backend.calls)
        assertEquals(STTResult.Success("last words"), session.await())
    }

    @Test
    fun `blocked pipe writes never block the capture thread and keep the newest two seconds`() = runTest {
        val release = CountDownLatch(1)
        val backend = FakeBackend(blockWrites = release)
        val session = SystemSTTEngine(backend).startPipeSession(route)
        val disk = mutableListOf<Short>()
        val diskSink = PcmSink { samples, count -> repeat(count) { disk += samples[it] } }
        val sinks = listOf(diskSink, session)
        // Each chunk is 20 ms (320 samples = 640 bytes); the 2 s queue limit = 100 chunks.
        val chunks = (0 until 151).map { chunk -> ShortArray(320) { (chunk * 7 + it).toShort() } }

        backend.callbacks.onReadyForSpeech()
        sinks.forEach { it.onPcm(chunks[0], 320) }
        assertTrue(backend.pipe.firstWriteEntered.await(WAIT_SEC, TimeUnit.SECONDS))
        val capture = Thread { chunks.drop(1).forEach { chunk -> sinks.forEach { it.onPcm(chunk, 320) } } }
        capture.start()
        capture.join(WAIT_SEC * 1000)

        assertFalse("capture thread blocked by pipe writes", capture.isAlive)
        assertEquals(chunks.flatMap { it.toList() }, disk)
        assertEquals(50, session.droppedChunks)

        release.countDown()
        session.stop()
        backend.awaitStopped()

        val kept = listOf(chunks[0]) + chunks.takeLast(100)
        assertEquals(kept.flatMap { it.leBytes() }, backend.pipe.bytes())
        // Chunk dropped: the session result is marked droppedAudio, so dictation / conversation switch to the recording file.
        backend.callbacks.onSegmentResult("\u4ECA\u5929\u5929\u6C14")
        backend.callbacks.onEndOfSegmentedSession()
        assertEquals(STTResult.Success("\u4ECA\u5929\u5929\u6C14", droppedAudio = true), session.await())
    }

    @Test
    fun `before the recognizer is ready the queue keeps ten seconds without dropping then drops to two seconds`() = runTest {
        val release = CountDownLatch(1)
        val backend = FakeBackend(blockWrites = release)
        val session = SystemSTTEngine(backend).startPipeSession(route)
        // Each chunk is 20 ms (640 bytes): the limit before ready is 10 s = 500 chunks; after ready, 2 s = 100 chunks.
        val chunks = (0 until 503).map { chunk -> ShortArray(320) { (chunk * 7 + it).toShort() } }

        session.onPcm(chunks[0], 320)
        assertTrue(backend.pipe.firstWriteEntered.await(WAIT_SEC, TimeUnit.SECONDS))
        chunks.subList(1, 501).forEach { session.onPcm(it, 320) }
        assertEquals(0, session.droppedChunks)
        session.onPcm(chunks[501], 320)
        assertEquals(1, session.droppedChunks)

        backend.callbacks.onReadyForSpeech()
        session.onPcm(chunks[502], 320)
        assertEquals(1 + 401, session.droppedChunks)

        release.countDown()
        session.stop()
        backend.awaitStopped()
        val kept = listOf(chunks[0]) + chunks.takeLast(100)
        assertEquals(kept.flatMap { it.leBytes() }, backend.pipe.bytes())
    }

    @Test
    fun `writer blocked on a stuck recognizer exits within one second after the session ends`() {
        val writeEntered = CountDownLatch(1)
        val pipe = object : SystemSTTPipe {
            override val source: Parcelable = Bundle()

            // Recognition service hangs: closing the write end does not unblock the write; only interrupting the write thread returns.
            override fun write(bytes: ByteArray, offset: Int, length: Int) {
                writeEntered.countDown()
                try {
                    Thread.sleep(Long.MAX_VALUE)
                } catch (interrupted: InterruptedException) {
                    throw java.io.InterruptedIOException("interrupted")
                }
            }

            override fun closeSink() = Unit

            override fun closeSource() = Unit
        }
        val session = SystemSTTPipeSession(pipe)
        session.onPcm(ShortArray(320), 320)
        assertTrue(writeEntered.await(WAIT_SEC, TimeUnit.SECONDS))
        val writer = session.writerThread!!

        session.end(STTResult.Success(""))
        writer.join(1_000)

        assertFalse("writer thread still alive 1 s after the session ended", writer.isAlive)
    }

    @Test
    fun `recognizer error fails the session as a recognizer failure and closes the pipe`() = runTest {
        val backend = FakeBackend()
        val session = SystemSTTEngine(backend).startPipeSession(route)
        backend.callbacks.onSegmentResult("partial")

        backend.callbacks.onError(SpeechRecognizer.ERROR_NETWORK)
        session.onPcm(shortArrayOf(5), 1)

        val failure = DictationFailure.Recognizer(SpeechRecognizer.ERROR_NETWORK)
        assertEquals(STTResult.Failed(failure, DictationPrimaryAction.Retry), session.await())
        assertTrue(backend.pipe.sinkClosed)
        assertTrue(backend.pipe.sourceClosed)
        assertEquals(emptyList<Byte>(), backend.pipe.bytes())
        assertEquals(listOf("destroy"), backend.calls)
        assertEquals(
            DictationFailureDecision(autoRetry = false, primaryAction = DictationPrimaryAction.Retry),
            DictationRules.failureDecision(failure, attempt = 1),
        )
    }

    @Test
    fun `all empty segments give an empty transcript`() = runTest {
        val backend = FakeBackend()
        val session = SystemSTTEngine(backend).startPipeSession(route)
        backend.callbacks.onSegmentResult(" ")
        backend.callbacks.onSegmentResult("")

        session.stop()
        backend.awaitStopped()
        backend.callbacks.onEndOfSegmentedSession()

        assertEquals(STTResult.Success(""), session.await())
    }

    @Test
    fun `no match after stop ends with the joined text instead of failing`() = runTest {
        val backend = FakeBackend()
        val session = SystemSTTEngine(backend).startPipeSession(route)
        backend.callbacks.onSegmentResult("kurz")

        session.stop()
        backend.awaitStopped()
        backend.callbacks.onError(SpeechRecognizer.ERROR_NO_MATCH)

        assertEquals(STTResult.Success("kurz"), session.await())
    }

    private val selfRoute = SystemSTTRoute.SelfRecord(SystemSTTRecognizer.DEFAULT, "fr-FR")

    @Test
    fun `self record intent has language and partial results but no audio source and opens no pipe`() = runTest {
        val backend = FakeBackend()

        val session = SystemSTTEngine(backend).startSession(selfRoute)

        val intent = backend.intent!!
        assertTrue(session is SystemSTTSelfRecordSession)
        assertFalse("self record must not take PCM from AudioCapture", session is PcmSink)
        assertEquals(0, backend.pipesCreated)
        assertEquals(SystemSTTRecognizer.DEFAULT, backend.recognizer)
        assertEquals(RecognizerIntent.ACTION_RECOGNIZE_SPEECH, intent.action)
        assertEquals("fr-FR", intent.getStringExtra(RecognizerIntent.EXTRA_LANGUAGE))
        assertTrue(intent.getBooleanExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, false))
        assertFalse(intent.hasExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE))
        assertFalse(intent.hasExtra(RecognizerIntent.EXTRA_SEGMENTED_SESSION))
    }

    @Test
    fun `start session dispatches the pipe route to a pipe session`() = runTest {
        val backend = FakeBackend()

        val session = SystemSTTEngine(backend).startSession(route)

        assertTrue(session is SystemSTTPipeSession)
        assertEquals(1, backend.pipesCreated)
    }

    @Test
    fun `self record restarts after each round and accumulates results until stop`() = runTest {
        val backend = FakeBackend()
        val session = SystemSTTEngine(backend).startSelfRecordSession(selfRoute)

        backend.callbacks.onResults(" Bonjour ")
        backend.callbacks.onError(SpeechRecognizer.ERROR_NO_MATCH)
        backend.callbacks.onResults(null)
        backend.callbacks.onError(SpeechRecognizer.ERROR_SPEECH_TIMEOUT)
        backend.callbacks.onResults("le monde.")
        assertEquals(listOf("restart", "restart", "restart", "restart", "restart"), backend.calls)
        assertEquals("Bonjour le monde.", session.transcript)

        session.stop()
        backend.callbacks.onResults("\u4f60\u597d")

        assertEquals(STTResult.Success("Bonjour le monde.\u4f60\u597d"), session.await())
        assertEquals(List(5) { "restart" } + listOf("stopListening(sinkClosed=false)", "destroy"), backend.calls)
        assertEquals(0, backend.pipesCreated)
    }

    @Test
    fun `self record stop with only empty rounds gives an empty transcript`() = runTest {
        val backend = FakeBackend()
        val session = SystemSTTEngine(backend).startSelfRecordSession(selfRoute)
        backend.callbacks.onResults(" ")
        backend.callbacks.onError(SpeechRecognizer.ERROR_SPEECH_TIMEOUT)

        session.stop()
        backend.callbacks.onError(SpeechRecognizer.ERROR_NO_MATCH)

        assertEquals(STTResult.Success(""), session.await())
        assertEquals(listOf("restart", "restart", "stopListening(sinkClosed=false)", "destroy"), backend.calls)
    }

    @Test
    fun `self record recognizer error fails with a recognizer failure and keeps the accumulated text`() = runTest {
        val backend = FakeBackend()
        val session = SystemSTTEngine(backend).startSelfRecordSession(selfRoute)
        backend.callbacks.onResults("déjà dit")

        backend.callbacks.onError(SpeechRecognizer.ERROR_NETWORK)
        backend.callbacks.onResults("trop tard")

        val failure = DictationFailure.Recognizer(SpeechRecognizer.ERROR_NETWORK)
        assertEquals(STTResult.Failed(failure, DictationPrimaryAction.Retry), session.await())
        assertEquals("déjà dit", session.transcript)
        assertEquals(listOf("restart", "destroy"), backend.calls)
    }

    @Test
    fun `self record interruption cancels and ends with the accumulated text`() = runTest {
        val backend = FakeBackend()
        val session = SystemSTTEngine(backend).startSelfRecordSession(selfRoute)
        backend.callbacks.onResults("avant")
        backend.callbacks.onResults("l'appel")

        session.interrupt()
        backend.callbacks.onResults("ignoré")
        session.stop()

        assertEquals(STTResult.Success("avant l'appel"), session.await())
        assertEquals(listOf("restart", "restart", "cancel", "destroy"), backend.calls)
    }

    @Test
    fun `self record interruption joins the latest partial of the current round`() = runTest {
        val backend = FakeBackend()
        val session = SystemSTTEngine(backend).startSelfRecordSession(selfRoute)
        backend.callbacks.onPartialResult("ava")
        backend.callbacks.onResults("avant")
        backend.callbacks.onPartialResult("l'ap")
        backend.callbacks.onPartialResult("l'appel en")
        backend.callbacks.onPartialResult(null)

        session.interrupt()
        backend.callbacks.onPartialResult("ignoré")

        assertEquals(STTResult.Success("avant l'appel en"), session.await())
        assertEquals("avant l'appel en", session.transcript)
        assertEquals(listOf("restart", "cancel", "destroy"), backend.calls)
    }

    @Test
    fun `self record partial of a finished round is not joined again on interruption`() = runTest {
        val backend = FakeBackend()
        val session = SystemSTTEngine(backend).startSelfRecordSession(selfRoute)
        backend.callbacks.onPartialResult("bonj")
        backend.callbacks.onResults("bonjour")
        backend.callbacks.onPartialResult("perdu")
        backend.callbacks.onError(SpeechRecognizer.ERROR_NO_MATCH)

        session.interrupt()

        assertEquals(STTResult.Success("bonjour"), session.await())
    }

    @Test
    fun `self record round ending before the handle arrives restarts on attach`() = runTest {
        val listening = FakeBackend()
        val session = SystemSTTSelfRecordSession()
        session.onResults("tôt")

        session.attach(listening)

        assertEquals(listOf("restart"), listening.calls)
        assertEquals("tôt", session.transcript)
        assertNull(listening.intent)
    }

    @Test
    fun `single round with voice but no text ends empty with the voiced duration`() = runTest {
        val listening = FakeBackend()
        var now = 1_000L
        val session = SystemSTTSelfRecordSession(singleRound = true, clock = { now })
        session.attach(listening)

        session.onBeginningOfSpeech()
        now = 1_400L
        session.onBeginningOfSpeech()
        now = 1_850L
        session.onEndOfSpeech()
        now = 2_300L
        session.onError(SpeechRecognizer.ERROR_NO_MATCH)

        assertEquals(STTResult.Success(""), session.await())
        assertEquals(850, session.voicedMs)
        assertEquals(listOf("destroy"), listening.calls)
    }

    @Test
    fun `single round without voice restarts and the text round carries its voiced duration`() = runTest {
        val listening = FakeBackend()
        var now = 0L
        val session = SystemSTTSelfRecordSession(singleRound = true, clock = { now })
        session.attach(listening)

        session.onError(SpeechRecognizer.ERROR_SPEECH_TIMEOUT)
        session.onResults(null)
        assertEquals(listOf("restart", "restart"), listening.calls)

        // No onEndOfSpeech: the end time is the time the result arrives.
        now = 5_000L
        session.onBeginningOfSpeech()
        now = 6_200L
        session.onResults("bonjour")

        assertEquals(STTResult.Success("bonjour"), session.await())
        assertEquals(1_200, session.voicedMs)
        assertEquals(listOf("restart", "restart", "destroy"), listening.calls)
    }

    @Test
    fun `dictation self record keeps restarting after a voiced empty round`() = runTest {
        val listening = FakeBackend()
        val session = SystemSTTSelfRecordSession(clock = { 0L })
        session.attach(listening)

        session.onBeginningOfSpeech()
        session.onEndOfSpeech()
        session.onError(SpeechRecognizer.ERROR_NO_MATCH)

        assertEquals(listOf("restart"), listening.calls)
    }

    @Test
    fun `file transcription writes decoded pcm to the pipe unchanged then closes it and joins segments`() = runTest {
        val backend = FakeBackend()
        // 5 s of audio (0.1 s per chunk), exceeding the 2 s queue limit, must still not drop chunks.
        val chunks = (0 until 50).map { chunk -> ByteArray(3200) { (chunk * 31 + it).toByte() } }
        val decoder = FakeDecoder(chunks)
        val segment = STTSegment(File("slot.aac"), range = 1.0..6.0)
        val engine = SystemSTTEngine(backend, decoder, routeFor = { language ->
            SystemSTTRoute.Pipe(SystemSTTRecognizer.ON_DEVICE, language!!)
        })

        val result = async(Dispatchers.Default) { engine.transcribe(segment, "de-DE") }
        backend.awaitStopped()
        backend.callbacks.onSegmentResult(" Hallo ")
        backend.callbacks.onSegmentResult(null)
        backend.callbacks.onSegmentResult("Welt.")
        backend.callbacks.onEndOfSegmentedSession()

        assertEquals(STTResult.Success("Hallo Welt."), result.await())
        assertEquals(chunks.flatMap { it.toList() }, backend.pipe.bytes())
        assertEquals(listOf(segment.aac to segment.range), decoder.calls)
        assertEquals("de-DE", backend.intent!!.getStringExtra(RecognizerIntent.EXTRA_LANGUAGE))
        assertTrue(backend.pipe.sinkClosed)
        assertTrue(backend.pipe.sourceClosed)
        assertEquals(listOf("stopListening(sinkClosed=true)", "destroy"), backend.calls)
    }

    @Test
    fun `file transcription on the self record and unavailable routes fails with retry without decoding`() = runTest {
        for (fileRoute in listOf(selfRoute, SystemSTTRoute.Unavailable)) {
            val backend = FakeBackend()
            val decoder = FakeDecoder(listOf(byteArrayOf(1, 2)))
            val engine = SystemSTTEngine(backend, decoder, routeFor = { fileRoute })

            val result = runCatching { engine.transcribe(STTSegment(File("slot.aac")), "fr-FR") }

            assertEquals(
                "$fileRoute",
                // A dedicated value outside the platform code range, not to be confused with a real ERROR_CLIENT reported by the pipe route.
                STTResult.Failed(
                    DictationFailure.Recognizer(SystemSTTEngine.FILE_UNSUPPORTED_ERROR),
                    DictationPrimaryAction.Retry,
                ),
                result.getOrThrow(),
            )
            assertEquals(emptyList<Pair<File, ClosedFloatingPointRange<Double>?>>(), decoder.calls)
            assertEquals(0, backend.pipesCreated)
            assertNull(backend.intent)
        }
    }

    @Test
    fun `file transcription decoder error fails and closes the pipe`() = runTest {
        val backend = FakeBackend()
        val decoder = FakeDecoder(listOf(ByteArray(640) { it.toByte() }), failure = IOException("corrupt frame"))
        val engine = SystemSTTEngine(backend, decoder, routeFor = { route })

        val result = engine.transcribe(STTSegment(File("slot.aac")), "de-DE")

        assertEquals(STTResult.Failed(DictationFailure.ExportFailed, DictationPrimaryAction.Retry), result)
        assertTrue(backend.pipe.sinkClosed)
        assertTrue(backend.pipe.sourceClosed)
        assertEquals(listOf("destroy"), backend.calls)
    }

    @Test
    fun `self record restart hitting a busy recognizer waits 300 ms and restarts once before failing`() = runTest {
        val backend = FakeBackend()
        val sleeper = FakeSleeper()
        val session = SystemSTTEngine(backend, sleeper = sleeper).startSelfRecordSession(selfRoute)
        backend.callbacks.onResults("eins")

        backend.callbacks.onError(SpeechRecognizer.ERROR_RECOGNIZER_BUSY)
        assertEquals(listOf(300L), sleeper.delays)
        assertEquals(listOf("restart"), backend.calls)

        sleeper.fire()
        assertEquals(listOf("restart", "restart"), backend.calls)

        backend.callbacks.onError(SpeechRecognizer.ERROR_RECOGNIZER_BUSY)

        val failure = DictationFailure.Recognizer(SpeechRecognizer.ERROR_RECOGNIZER_BUSY)
        assertEquals(STTResult.Failed(failure, DictationPrimaryAction.Retry), session.await())
        assertEquals("eins", session.transcript)
        assertEquals(listOf(300L), sleeper.delays)
        assertEquals(listOf("restart", "restart", "destroy"), backend.calls)
    }

    @Test
    fun `on-device language unavailable at start falls back to default`() = runTest {
        val backend = FakeBackend()
        val session = SystemSTTEngine(backend).startSession(route) as SystemSTTPipeSession

        backend.callbacks.onError(SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE)

        assertEquals(listOf(SystemSTTRecognizer.ON_DEVICE, SystemSTTRecognizer.DEFAULT), backend.started)
        assertEquals(2, backend.pipesCreated)
        val first = backend.pipes[0]
        val second = backend.pipes[1]
        assertTrue(first.sinkClosed)
        assertTrue(first.sourceClosed)
        @Suppress("DEPRECATION")
        assertSame(second.source, backend.intent!!.getParcelableExtra<Parcelable>(RecognizerIntent.EXTRA_AUDIO_SOURCE))
        assertEquals("de-DE", backend.intent!!.getStringExtra(RecognizerIntent.EXTRA_LANGUAGE))
        assertEquals(listOf("destroy"), backend.calls)

        session.onPcm(shortArrayOf(7, 8), 2)
        session.stop()
        backend.awaitStopped()
        backend.callbacks.onSegmentResult("Guten Tag")
        backend.callbacks.onEndOfSegmentedSession()

        assertEquals(STTResult.Success("Guten Tag"), session.await())
        assertEquals(shortArrayOf(7, 8).leBytes(), second.bytes())
        assertEquals(listOf("destroy", "stopListening(sinkClosed=true)", "destroy"), backend.calls)
    }

    @Test
    fun `on-device language error after the user stopped fails without fallback`() = runTest {
        val backend = FakeBackend()
        val session = SystemSTTEngine(backend).startSession(route)

        session.stop()
        backend.awaitStopped()
        backend.callbacks.onError(SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE)

        val failure = DictationFailure.Recognizer(SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE)
        assertEquals(STTResult.Failed(failure, DictationPrimaryAction.Retry), session.await())
        assertEquals(listOf(SystemSTTRecognizer.ON_DEVICE), backend.started)
        assertEquals(1, backend.pipesCreated)
    }

    @Test
    fun `fallback reopen failure fails with the original error`() = runTest {
        val backend = FakeBackend(failReopen = true)
        val session = SystemSTTEngine(backend).startSession(route)

        backend.callbacks.onError(SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE)

        val failure = DictationFailure.Recognizer(SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE)
        assertEquals(STTResult.Failed(failure, DictationPrimaryAction.Retry), session.await())
        assertEquals(listOf(SystemSTTRecognizer.ON_DEVICE, SystemSTTRecognizer.DEFAULT), backend.started)
        assertTrue(backend.pipes[0].sinkClosed)
        assertTrue(backend.pipes[0].sourceClosed)
        assertEquals(listOf("destroy"), backend.calls)
    }

    @Test
    fun `self record on-device language not supported falls back to default`() = runTest {
        val backend = FakeBackend()
        val session = SystemSTTEngine(backend)
            .startSession(SystemSTTRoute.SelfRecord(SystemSTTRecognizer.ON_DEVICE, "fr-FR")) as SystemSTTSelfRecordSession

        backend.callbacks.onError(SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED)

        assertEquals(listOf(SystemSTTRecognizer.ON_DEVICE, SystemSTTRecognizer.DEFAULT), backend.started)
        assertEquals("fr-FR", backend.intent!!.getStringExtra(RecognizerIntent.EXTRA_LANGUAGE))
        assertEquals(0, backend.pipesCreated)

        backend.callbacks.onResults("Bonjour")
        session.stop()
        backend.callbacks.onResults("encore")

        assertEquals(STTResult.Success("Bonjour encore"), session.await())
        assertEquals(listOf("destroy", "restart", "stopListening(sinkClosed=false)", "destroy"), backend.calls)
    }

    @Test
    fun `fallback happens once and default error still fails`() = runTest {
        val backend = FakeBackend()
        val session = SystemSTTEngine(backend).startSession(route)

        backend.callbacks.onError(SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE)
        backend.callbacks.onError(SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE)

        val failure = DictationFailure.Recognizer(SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE)
        assertEquals(STTResult.Failed(failure, DictationPrimaryAction.Retry), session.await())
        assertEquals(listOf(SystemSTTRecognizer.ON_DEVICE, SystemSTTRecognizer.DEFAULT), backend.started)
        assertTrue(backend.pipes[1].sinkClosed)
        assertTrue(backend.pipes[1].sourceClosed)
    }

    @Test
    fun `on-device error after a result does not fall back`() = runTest {
        val backend = FakeBackend()
        val pipeSession = SystemSTTEngine(backend).startSession(route)
        backend.callbacks.onSegmentResult("schon")
        backend.callbacks.onError(SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE)

        val unavailable = DictationFailure.Recognizer(SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE)
        assertEquals(STTResult.Failed(unavailable, DictationPrimaryAction.Retry), pipeSession.await())
        assertEquals(listOf(SystemSTTRecognizer.ON_DEVICE), backend.started)

        val selfBackend = FakeBackend()
        val selfSession = SystemSTTEngine(selfBackend)
            .startSession(SystemSTTRoute.SelfRecord(SystemSTTRecognizer.ON_DEVICE, "fr-FR"))
        selfBackend.callbacks.onResults("déjà")
        selfBackend.callbacks.onError(SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED)

        val notSupported = DictationFailure.Recognizer(SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED)
        assertEquals(STTResult.Failed(notSupported, DictationPrimaryAction.Retry), selfSession.await())
        assertEquals(listOf(SystemSTTRecognizer.ON_DEVICE), selfBackend.started)
    }

    @Test
    fun `default route language error does not fall back`() = runTest {
        val backend = FakeBackend()
        val session = SystemSTTEngine(backend).startSession(SystemSTTRoute.Pipe(SystemSTTRecognizer.DEFAULT, "de-DE"))

        backend.callbacks.onError(SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE)

        val failure = DictationFailure.Recognizer(SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE)
        assertEquals(STTResult.Failed(failure, DictationPrimaryAction.Retry), session.await())
        assertEquals(listOf(SystemSTTRecognizer.DEFAULT), backend.started)
        assertEquals(1, backend.pipesCreated)
    }

    @Test
    fun `fallback replays recently written pcm into default pipe in order`() = runTest {
        val backend = FakeBackend()
        val session = SystemSTTEngine(backend).startSession(route) as SystemSTTPipeSession
        val chunkSamples = 1_600
        val chunkBytes = chunkSamples * 2
        val total = SystemSTTPipeSession.MAX_QUEUED_BYTES / chunkBytes * 2
        val chunks = List(total) { index -> ShortArray(chunkSamples) { (index + 1).toShort() } }
        // Wait chunk by chunk for writes into the old pipe so no chunk is dropped from a full queue: the old pipe receives twice the limit in audio.
        chunks.forEachIndexed { index, chunk ->
            session.onPcm(chunk, chunkSamples)
            backend.pipe.awaitSize((index + 1) * chunkBytes)
        }

        backend.callbacks.onError(SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE)
        assertEquals(0, session.replayBufferedBytes)
        // After fallback the queue holds exactly the limit in replay chunks: a new chunk arriving before the writer thread takes any would push out the oldest replay chunk.
        // First wait for the whole replay to be written into the new pipe (sync point) before the new chunk follows, so it does not depend on the writer thread being scheduled before the recording thread.
        val replayed = chunks.takeLast(SystemSTTPipeSession.MAX_QUEUED_BYTES / chunkBytes)
        val second = backend.pipes[1]
        second.awaitSize(replayed.size * chunkBytes)
        val tail = shortArrayOf(-5, 6)
        session.onPcm(tail, tail.size)
        session.stop()
        backend.awaitStopped()
        backend.callbacks.onEndOfSegmentedSession()

        // The new pipe first receives the old pipe's most recent limit-sized bytes (in original order), then the new chunks after fallback.
        val expected = replayed.flatMap { it.leBytes() } + tail.leBytes()
        assertEquals(expected, second.bytes())
        assertTrue(second.bytes().size - tail.size * 2 <= SystemSTTPipeSession.MAX_QUEUED_BYTES)
        assertEquals(0, session.droppedChunks)
        assertEquals(STTResult.Success(""), session.await())
    }

    @Test
    fun `replay buffer is cleared after session ends`() = runTest {
        val backend = FakeBackend()
        val session = SystemSTTEngine(backend).startSession(route) as SystemSTTPipeSession
        session.onPcm(shortArrayOf(1, 2, 3), 3)
        backend.pipe.awaitSize(6)
        assertEquals(6, session.replayBufferedBytes)

        backend.callbacks.onSegmentResult("fertig")
        backend.callbacks.onEndOfSegmentedSession()

        assertEquals(STTResult.Success("fertig"), session.await())
        assertEquals(0, session.replayBufferedBytes)
    }

    @Test
    fun `pcm written after a result is not kept for replay`() = runTest {
        val backend = FakeBackend()
        val session = SystemSTTEngine(backend).startSession(route) as SystemSTTPipeSession
        session.onPcm(shortArrayOf(1, 2, 3), 3)
        backend.pipe.awaitSize(6)
        assertEquals(6, session.replayBufferedBytes)

        // Once a result has arrived there is no more fallback: chunks written afterwards do not enter the replay buffer.
        backend.callbacks.onSegmentResult("hallo")
        session.onPcm(shortArrayOf(4, 5), 2)
        backend.pipe.awaitSize(10)
        assertTrue(session.replayBufferedBytes <= 6)

        backend.callbacks.onEndOfSegmentedSession()
        assertEquals(STTResult.Success("hallo"), session.await())
    }

    @Test
    fun `no default service keeps the failure`() = runTest {
        val backend = FakeBackend(defaultAvailable = false)
        val session = SystemSTTEngine(backend)
            .startSession(SystemSTTRoute.SelfRecord(SystemSTTRecognizer.ON_DEVICE, "fr-FR"))

        backend.callbacks.onError(SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED)

        val failure = DictationFailure.Recognizer(SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED)
        assertEquals(STTResult.Failed(failure, DictationPrimaryAction.Retry), session.await())
        assertEquals(listOf(SystemSTTRecognizer.ON_DEVICE), backend.started)
        assertEquals(listOf("destroy"), backend.calls)
    }

    @Test
    fun `live result cases from fixture`() = runTest {
        val fixture = Json.parseToJsonElement(workspaceFile("shared/voice-contracts/dictation.v1.json").readText()).jsonObject
        val cases = fixture["liveResultCases"]!!.jsonArray.map { it.jsonObject }
        assertTrue(cases.size >= 10)
        for (case in cases) {
            val id = case["id"]!!.jsonPrimitive.content
            val events = case["input"]!!.jsonObject["events"]!!.jsonArray.map { it.jsonObject }
            val expected = case["expected"]!!.jsonObject
            val finals = expected["finals"]!!.jsonArray.map { it.jsonPrimitive.content }
            val partial = expected["partial"]!!.jsonPrimitive.content

            // Pipe session: the final goes through onSegmentResult.
            val pipeBackend = FakeBackend()
            val pipe = SystemSTTEngine(pipeBackend).startPipeSession(route)
            for (event in events) {
                val text = event.text()
                if (event["isFinal"]!!.jsonPrimitive.boolean) {
                    pipeBackend.callbacks.onSegmentResult(text)
                } else {
                    pipeBackend.callbacks.onPartialResult(text)
                }
            }
            assertEquals("$id pipe", LiveTranscript(finals, partial), pipe.live.value)

            // Self-recording session: the final goes through onResults (restart after each turn).
            val selfBackend = FakeBackend()
            val self = SystemSTTEngine(selfBackend).startSelfRecordSession(selfRoute)
            for (event in events) {
                val text = event.text()
                if (event["isFinal"]!!.jsonPrimitive.boolean) {
                    selfBackend.callbacks.onResults(text)
                } else {
                    selfBackend.callbacks.onPartialResult(text)
                }
            }
            assertEquals("$id self-record", LiveTranscript(finals, partial), self.live.value)
        }
    }

    @Test
    fun `empty final promotes the current partial into the session result`() = runTest {
        val pipeBackend = FakeBackend()
        val pipe = SystemSTTEngine(pipeBackend).startPipeSession(route)
        pipeBackend.callbacks.onPartialResult(" Hallo ")
        pipeBackend.callbacks.onSegmentResult(null)
        pipeBackend.callbacks.onSegmentResult("")
        pipeBackend.callbacks.onSegmentResult("Welt.")
        pipe.stop()
        pipeBackend.awaitStopped()
        pipeBackend.callbacks.onEndOfSegmentedSession()
        assertEquals(STTResult.Success("Hallo Welt."), pipe.await())

        val selfBackend = FakeBackend()
        val self = SystemSTTEngine(selfBackend).startSelfRecordSession(selfRoute)
        selfBackend.callbacks.onPartialResult("Bonjour")
        selfBackend.callbacks.onResults(" ")
        selfBackend.callbacks.onPartialResult("monde")
        selfBackend.callbacks.onResults("monde")
        self.interrupt()
        assertEquals(LiveTranscript(listOf("Bonjour", "monde"), ""), self.live.value)
        assertEquals(STTResult.Success("Bonjour monde"), self.await())
    }

    private fun JsonObject.text(): String? = this["text"].let { if (it == null || it is JsonNull) null else it.jsonPrimitive.content }

    private fun workspaceFile(relative: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("not found: $relative")
    }

    private fun context(): Context = ApplicationProvider.getApplicationContext()

    private object NoopCallbacks : SystemSTTCallbacks {
        override fun onSegmentResult(text: String?) = Unit
        override fun onResults(text: String?) = Unit
        override fun onPartialResult(text: String?) = Unit
        override fun onEndOfSegmentedSession() = Unit
        override fun onError(error: Int) = Unit
    }

    private fun ShortArray.leBytes(): List<Byte> = flatMap { listOf(it.toByte(), (it.toInt() shr 8).toByte()) }

    private companion object {
        const val WAIT_SEC = 5L
    }
}
