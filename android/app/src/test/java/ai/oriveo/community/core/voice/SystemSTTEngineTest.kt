package ai.oriveo.community.core.voice

import android.content.Intent
import android.media.AudioFormat
import android.os.Bundle
import android.os.Parcelable
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
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
        assertEquals("system", SystemSTTEngine(backend).engineName)
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

    private fun ShortArray.leBytes(): List<Byte> = flatMap { listOf(it.toByte(), (it.toInt() shr 8).toByte()) }

    private companion object {
        const val WAIT_SEC = 5L
    }
}
