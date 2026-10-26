package ai.oriveo.community.core.voice

import android.content.Context
import android.content.Intent
import android.media.AudioFormat
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.Parcelable
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.core.content.ContextCompat
import java.io.IOException
import java.io.OutputStream
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.withContext

/** Recognizer callbacks (a subset of RecognitionListener); production implementations call back on the main thread. */
interface SystemSTTCallbacks {
    /** Preferred text of one recognition result in a segmented session (pipe route); null when the recognizer gave no text. */
    fun onSegmentResult(text: String?)

    /** Preferred text when a listening round ends in a non-segmented session (self-record route); null when the recognizer gave no text. */
    fun onResults(text: String?)

    /** Preferred text of the latest partial result of the current round in a non-segmented session (self-record route); null when the recognizer gave no text. */
    fun onPartialResult(text: String?)

    fun onEndOfSegmentedSession()

    /** [error] is a SpeechRecognizer.ERROR_* code. */
    fun onError(error: Int)

    /** Input volume (dB) reported by the recognizer; on the pipe route the app computes volume from its own capture, so this is ignored by default. */
    fun onRmsChanged(rmsdB: Float) = Unit
}

/** Audio pipe feeding the recognizer: [source] goes into the intent's EXTRA_AUDIO_SOURCE (the read-end PFD in production); the engine writes to and closes the write end. */
interface SystemSTTPipe {
    val source: Parcelable

    /** May block; throws IOException when the write end is closed or the recognizer side is gone. */
    @Throws(IOException::class)
    fun write(bytes: ByteArray, offset: Int, length: Int)

    fun closeSink()

    fun closeSource()
}

/** Recognizer handle within one recognition session. */
interface SystemSTTListening {
    fun stopListening()

    /** Starts another listening round with the same recognizer and intent (used after a round ends on the self-record route); calls onError if it cannot start. */
    fun restartListening()

    /** Discards the current round; no more results are delivered. */
    fun cancel()

    fun destroy()
}

/** Delayed execution (wait a moment before restarting when the recognizer is busy on self-record restart); production posts to the main thread. */
fun interface SystemSTTSleeper {
    fun sleep(millis: Long, then: () -> Unit)
}

/** Production [SystemSTTSleeper]: delayed post on a main-thread Handler, without blocking the recognizer callback thread. */
object MainThreadSTTSleeper : SystemSTTSleeper {
    private val handler by lazy { Handler(Looper.getMainLooper()) }

    override fun sleep(millis: Long, then: () -> Unit) {
        handler.postDelayed(then, millis)
    }
}

/** Platform capabilities used by system recognition sessions; production uses [AndroidSystemSTTSessionBackend], tests use a fake backend. */
interface SystemSTTSessionBackend {
    @Throws(IOException::class)
    fun createPipe(): SystemSTTPipe

    /** Whether the system default recognition service (DEFAULT) is available: decides whether to fall back when the on-device recognizer reports a missing language at session start. */
    fun isDefaultRecognitionAvailable(): Boolean

    /** Creates [recognizer] and starts listening; callbacks go to [callbacks]. */
    suspend fun startListening(
        recognizer: SystemSTTRecognizer,
        intent: Intent,
        callbacks: SystemSTTCallbacks,
    ): SystemSTTListening
}

/**
 * System dictation engine (see [SystemSTTRouter] for routing): on the pipe route the app records and streams PCM to the recognizer through a pipe in real time (SDK 33+);
 * on the self-record route the recognizer opens the microphone itself, bypassing [AudioCapture] and producing no recording file.
 */
class SystemSTTEngine(
    private val backend: SystemSTTSessionBackend,
    private val decoder: AacDecoder = MediaCodecAacDecoder(),
    /** Routing used when re-recognizing a file (production passes [SystemSTTRouter.route]); unavailable by default. */
    private val routeFor: suspend (language: String?) -> SystemSTTRoute = { SystemSTTRoute.Unavailable },
    private val sleeper: SystemSTTSleeper = MainThreadSTTSleeper,
    /** Scope used to reopen the recognizer when falling back to DEFAULT (recognizer callbacks run on the main thread; start in place without switching threads). */
    private val fallbackScope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
) : STTEngine {
    override val engineName: String = ENGINE_NAME

    /**
     * Re-recognition of a slot file: only the pipe route supports it (the self-record route and unavailable return a recognizer failure with a retry primary action, without throwing or decoding).
     * The slot .aac is decoded to PCM and fed to the recognizer through a pipe session, the pipe is closed after writing, and segment results are joined with [DictationRules.join]; a decode error ends as a remux failure.
     */
    override suspend fun transcribe(segment: STTSegment, language: String?): STTResult {
        val route = routeFor(language) as? SystemSTTRoute.Pipe
            ?: return STTResult.Failed(DictationFailure.Recognizer(FILE_UNSUPPORTED_ERROR), DictationPrimaryAction.Retry)
        return transcribeFile(segment, route)
    }

    private suspend fun transcribeFile(segment: STTSegment, route: SystemSTTRoute.Pipe): STTResult {
        val session = startPipeSession(route)
        try {
            val decoded = try {
                // Decoding and enqueueing may both block (waiting for the writer thread when the queue is full); the thread is interrupted when the coroutine is cancelled.
                runInterruptible(Dispatchers.IO) { decoder.decode(segment.aac, segment.range, session::offerFilePcm) }
                true
            } catch (_: IOException) {
                false
            }
            if (decoded) {
                session.stop()
            } else {
                session.end(STTResult.Failed(DictationFailure.ExportFailed, DictationPrimaryAction.Retry))
            }
            return session.await()
        } finally {
            // On cancellation, close the pipe and destroy the recognizer; no-op when a result already exists.
            session.end(STTResult.Success(""))
        }
    }

    /** Starts a session for the route: the pipe route returns a [SystemSTTPipeSession] (the caller attaches it to [AudioCapture]), the self-record route returns a [SystemSTTSelfRecordSession]. */
    suspend fun startSession(route: SystemSTTRoute): SystemSTTSession = when (route) {
        is SystemSTTRoute.Pipe -> startPipeSession(route)
        is SystemSTTRoute.SelfRecord -> startSelfRecordSession(route)
        SystemSTTRoute.Unavailable -> throw IllegalArgumentException("no speech recognition service")
    }

    /**
     * Starts a pipe session: the returned session is attached to [AudioCapture] as a [PcmSink]; after recording stops call [SystemSTTPipeSession.stop],
     * then [SystemSTTPipeSession.await] for the result. If listening fails to start, the pipe is closed and the error is thrown.
     */
    suspend fun startPipeSession(route: SystemSTTRoute.Pipe): SystemSTTPipeSession {
        val pipe = backend.createPipe()
        val reopen = if (canFallBack(route.recognizer)) {
            SystemSTTPipeSession.Reopen(fallbackScope) { session ->
                val next = backend.createPipe()
                val handle = try {
                    backend.startListening(SystemSTTRecognizer.DEFAULT, pipeIntent(route.languageTag, next.source), session)
                } catch (error: Throwable) {
                    runCatching { next.closeSink() }
                    runCatching { next.closeSource() }
                    throw error
                }
                next to handle
            }
        } else {
            null
        }
        val session = SystemSTTPipeSession(pipe, reopen = reopen)
        val listening = try {
            backend.startListening(route.recognizer, pipeIntent(route.languageTag, pipe.source), session)
        } catch (error: Throwable) {
            session.abandon()
            throw error
        }
        session.attach(listening)
        return session
    }

    /** Starts a self-record session: after the recognizer ends a round on silence it restarts and accumulates text until [SystemSTTSelfRecordSession.stop]. Throws if listening fails to start. */
    suspend fun startSelfRecordSession(
        route: SystemSTTRoute.SelfRecord,
        singleRound: Boolean = false,
    ): SystemSTTSelfRecordSession {
        val reopen = if (canFallBack(route.recognizer)) {
            SystemSTTSelfRecordSession.Reopen(fallbackScope) { session ->
                backend.startListening(SystemSTTRecognizer.DEFAULT, selfRecordIntent(route.languageTag), session)
            }
        } else {
            null
        }
        val session = SystemSTTSelfRecordSession(sleeper, singleRound, reopen)
        val listening = backend.startListening(route.recognizer, selfRecordIntent(route.languageTag), session)
        session.attach(listening)
        return session
    }

    /** For a session opened by the on-device recognizer when the DEFAULT recognition service is available: a missing-language error at session start can be retried once with DEFAULT. */
    private fun canFallBack(recognizer: SystemSTTRecognizer): Boolean =
        recognizer == SystemSTTRecognizer.ON_DEVICE && backend.isDefaultRecognitionAvailable()

    internal companion object {
        const val ENGINE_NAME = "system"

        /** Pipe recognition intent: the segmented session ends when the audio source ends; audio is 16 kHz mono PCM_16BIT. */
        fun pipeIntent(languageTag: String, source: Parcelable): Intent =
            Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                .putExtra(RecognizerIntent.EXTRA_LANGUAGE, languageTag)
                .putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, source)
                .putExtra(RecognizerIntent.EXTRA_SEGMENTED_SESSION, RecognizerIntent.EXTRA_AUDIO_SOURCE)
                .putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
                .putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
                .putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, AudioRecordCapture.SAMPLE_RATE)

        /** Self-record recognition intent: the recognizer opens the microphone itself, with no audio source or segmented session, and partial results are requested. */
        fun selfRecordIntent(languageTag: String): Intent =
            Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                .putExtra(RecognizerIntent.EXTRA_LANGUAGE, languageTag)
                .putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)

        /** Recognizer error code to dictation failure: always a recognizer failure (no automatic retry; the primary button retries). */
        fun failureFor(error: Int): DictationFailure = DictationFailure.Recognizer(error)

        /** No match / no speech: not a failure, finish with the text assembled so far (if all empty, the controller decides nothing was heard). */
        fun isNoSpeech(error: Int): Boolean =
            error == SpeechRecognizer.ERROR_NO_MATCH || error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT

        /**
         * Recognizer error code reported by file re-recognition when the route is not the pipe (self-record / unavailable): the client side cannot recognize the file.
         * A dedicated value outside the platform code range, so a real ERROR_CLIENT from the pipe route is not mistaken for "system unavailable".
         */
        const val FILE_UNSUPPORTED_ERROR = -1

        /** Recognizer lacks the language (unsupported / model unavailable): fall back to DEFAULT when the on-device recognizer reports it at session start. */
        fun isLanguageMissing(error: Int): Boolean =
            error == SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED || error == SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE

        /** When a self-record restart hits a busy recognizer, wait this long and restart once more. */
        const val BUSY_RESTART_DELAY_MS = 300L
    }
}

/** One system recognition session: the user stops it with [stop], then [await] returns the result. */
sealed interface SystemSTTSession {
    fun stop()

    suspend fun await(): STTResult
}

/**
 * One pipe recognition session: recorded PCM is written to the pipe as-is in little-endian 16-bit, and segment results are joined into one text with [DictationRules.join].
 *
 * Pipe writes happen on a dedicated writer thread: the recording thread only enqueues into a bounded queue (about [maxQueuedBytes] bytes, 2 s of audio by default).
 * When the recognizer reads slowly and the queue is full, the oldest chunk is dropped and counted in [droppedChunks]; this only affects recognition and never stalls recording or disk writes.
 * Stop = stop accepting PCM; the writer thread drains the queue, closes the write end (the recognizer reads end of stream), then calls stopListening.
 * When the session ends or fails, the queue is cleared immediately, both pipe ends are closed and the recognizer is destroyed.
 */
class SystemSTTPipeSession internal constructor(
    private var pipe: SystemSTTPipe,
    private val maxQueuedBytes: Int = MAX_QUEUED_BYTES,
    /** Reopen with DEFAULT (new pipe + new recognizer) when the on-device recognizer reports a missing language at session start; null means no fallback. */
    private val reopen: Reopen? = null,
) : SystemSTTSession, PcmSink, SystemSTTCallbacks {
    /** For fallback: creates a new pipe in [scope] and starts listening with the DEFAULT recognizer, with callbacks routed back to this session. */
    internal class Reopen(
        val scope: CoroutineScope,
        val open: suspend (SystemSTTPipeSession) -> Pair<SystemSTTPipe, SystemSTTListening>,
    )

    private val outcome = CompletableDeferred<STTResult>()
    private val lock = ReentrantLock()
    private val changed = lock.newCondition()

    // All state below is guarded by lock.
    private val queue = ArrayDeque<ByteArray>()
    private var queuedBytes = 0

    /** Chunks most recently sent into the old pipe before fallback (oldest first, total not exceeding [maxQueuedBytes]): replayed into the new pipe on fallback so the start is not lost. */
    private val sent = ArrayDeque<ByteArray>()
    private var sentBytes = 0
    private var accepting = true
    private var stopRequested = false
    private var writerDone = false
    private var shutDown = false
    private var sinkClosed = false
    private var listening: SystemSTTListening? = null
    private val segments = mutableListOf<String>()
    private var dropped = 0

    /** A segment result has been received (later errors do not fall back). */
    private var gotResult = false

    /** Already fell back once. */
    private var fellBack = false

    /** Reopening with DEFAULT: the writer thread pauses while PCM is still enqueued. */
    private var reopening = false

    /** Number of PCM chunks dropped when the queue was full (the recognizer reads too slowly). */
    val droppedChunks: Int get() = lock.withLock { dropped }

    /** Bytes pending replay on fallback (for tests). */
    internal val replayBufferedBytes: Int get() = lock.withLock { sentBytes }

    init {
        startWriter()
    }

    private fun startWriter() {
        Thread(::writeLoop, WRITER_THREAD_NAME).apply {
            isDaemon = true
            start()
        }
    }

    /** Called on the recording thread; only enqueues without blocking; discarded after stop or finish. */
    override fun onPcm(samples: ShortArray, count: Int) {
        if (count <= 0) return
        val bytes = ByteArray(count * 2)
        for (index in 0 until count) {
            val sample = samples[index].toInt()
            bytes[index * 2] = sample.toByte()
            bytes[index * 2 + 1] = (sample shr 8).toByte()
        }
        lock.withLock {
            if (!accepting) return
            queue.addLast(bytes)
            queuedBytes += bytes.size
            while (queuedBytes > maxQueuedBytes && queue.size > 1) {
                queuedBytes -= queue.removeFirst().size
                dropped += 1
            }
            changed.signalAll()
        }
    }

    /**
     * Feeds PCM for file re-recognition: when the queue is full it waits for the writer thread to free space (no chunk is dropped); may block and must not be called on the recording thread.
     * Returns false when the session has stopped or finished and accepts nothing (the caller stops decoding).
     */
    internal fun offerFilePcm(bytes: ByteArray): Boolean {
        if (bytes.isEmpty()) return true
        lock.withLock {
            while (accepting && queuedBytes > 0 && queuedBytes + bytes.size > maxQueuedBytes) changed.await()
            if (!accepting) return false
            queue.addLast(bytes)
            queuedBytes += bytes.size
            changed.signalAll()
        }
        return true
    }

    /** User stop: stop accepting PCM; after the queue is drained, close the write end so the recognizer can wrap up, then stopListening. The result is still obtained from [await]. */
    override fun stop() {
        val stopNow = lock.withLock {
            if (stopRequested) return
            accepting = false
            stopRequested = true
            changed.signalAll()
            writerDone
        }
        // The writer thread already exited early (pipe broken): close the write end and call stopListening here.
        if (stopNow) closeSinkThenStopListening()
    }

    override suspend fun await(): STTResult = outcome.await()

    override fun onSegmentResult(text: String?) {
        lock.withLock {
            gotResult = true
            if (text != null) segments += text
        }
    }

    /** Segmented session results all go through [onSegmentResult]. */
    override fun onResults(text: String?) = Unit

    /** The pipe intent does not request partial results. */
    override fun onPartialResult(text: String?) = Unit

    override fun onEndOfSegmentedSession() {
        finish(STTResult.Success(joined()))
    }

    override fun onError(error: Int) {
        if (SystemSTTEngine.isNoSpeech(error)) {
            finish(STTResult.Success(joined()))
        } else if (!fallBack(error)) {
            finish(STTResult.Failed(SystemSTTEngine.failureFor(error), DictationPrimaryAction.Retry))
        }
    }

    /**
     * The on-device recognizer reports a missing language at session start (no result yet, user has not stopped): destroy the old recognizer, close the old pipe, and reopen with a new pipe and the DEFAULT recognizer,
     * falling back only once; the writer thread pauses during reopen while PCM is still enqueued. A failed reopen ends with the original error. Returns false when fallback does not apply.
     */
    private fun fallBack(error: Int): Boolean {
        val reopen = reopen ?: return false
        val (oldPipe, oldHandle) = lock.withLock {
            if (outcome.isCompleted || fellBack || gotResult || stopRequested || !SystemSTTEngine.isLanguageMissing(error)) {
                return false
            }
            fellBack = true
            reopening = true
            // Put the chunks most recently sent into the old pipe back at the front of the queue in their original order (total still within the limit), so the new pipe receives them before the queued data.
            while (sent.isNotEmpty() && queuedBytes + sent.last().size <= maxQueuedBytes) {
                val chunk = sent.removeLast()
                queue.addFirst(chunk)
                queuedBytes += chunk.size
            }
            clearSentLocked()
            val handle = listening
            listening = null
            pipe to handle
        }
        oldHandle?.destroy()
        runCatching { oldPipe.closeSink() }
        runCatching { oldPipe.closeSource() }
        reopen.scope.launch(start = CoroutineStart.UNDISPATCHED) {
            val (nextPipe, handle) = try {
                reopen.open(this@SystemSTTPipeSession)
            } catch (cause: Throwable) {
                finish(STTResult.Failed(SystemSTTEngine.failureFor(error), DictationPrimaryAction.Retry))
                if (cause is CancellationException) throw cause
                return@launch
            }
            val (finished, restartWriter) = lock.withLock {
                reopening = false
                if (outcome.isCompleted) {
                    changed.signalAll()
                    true to false
                } else {
                    pipe = nextPipe
                    sinkClosed = false
                    listening = handle
                    val restart = writerDone
                    if (restart) {
                        writerDone = false
                        accepting = !stopRequested
                    }
                    changed.signalAll()
                    false to restart
                }
            }
            if (finished) {
                // Finished during reopen: the new pipe and recognizer are no longer used.
                runCatching { nextPipe.closeSink() }
                runCatching { nextPipe.closeSource() }
                handle.destroy()
            } else if (restartWriter) {
                startWriter()
            }
        }
        return true
    }

    internal fun attach(handle: SystemSTTListening) {
        val finished = lock.withLock {
            listening = handle
            outcome.isCompleted
        }
        // An end / error callback already arrived while listening was starting: the handle only arrives now, so destroy it.
        if (finished) handle.destroy()
    }

    /** Finish early with [result]: clear the queue, close both ends, destroy the recognizer; no-op when a result already exists. */
    internal fun end(result: STTResult) = finish(result)

    /** Listening failed to start: stop the writer thread and close both ends without producing a result. */
    internal fun abandon() {
        shutDownWriter()
        closeSink()
        closeSource()
    }

    private fun writeLoop() {
        while (true) {
            val next = lock.withLock {
                while (!shutDown && (reopening || (queue.isEmpty() && !stopRequested))) changed.await()
                if (shutDown) {
                    null
                } else {
                    queue.removeFirstOrNull()?.let {
                        queuedBytes -= it.size
                        // Chunks taken out before fallback count as sent (including failed writes) and are replayed on fallback; once a result has arrived there is no more fallback, so stop recording them.
                        if (!fellBack && !gotResult) rememberSentLocked(it)
                        // Space freed: wake file re-recognition waiting to enqueue.
                        changed.signalAll()
                        it to pipe
                    }
                }
            } ?: break
            val (chunk, target) = next
            try {
                target.write(chunk, 0, chunk.size)
            } catch (_: IOException) {
                // Fallback to DEFAULT swapped the pipe: drop this chunk and keep writing to the new pipe.
                val swapped = lock.withLock { reopening || pipe !== target }
                if (swapped) continue
                // The recognizer side is gone: stop writing and wait for the recognizer callbacks for the result.
                break
            }
        }
        val stopNow = lock.withLock {
            writerDone = true
            accepting = false
            queue.clear()
            queuedBytes = 0
            changed.signalAll()
            stopRequested
        }
        if (stopNow) closeSinkThenStopListening() else closeSink()
    }

    private fun closeSinkThenStopListening() {
        closeSink()
        val current = lock.withLock { if (outcome.isCompleted) null else listening }
        current?.stopListening()
    }

    private fun joined(): String = lock.withLock { DictationRules.join(segments) }

    private fun finish(result: STTResult) {
        val handle = lock.withLock {
            if (outcome.isCompleted) return
            outcome.complete(result)
            listening
        }
        shutDownWriter()
        closeSink()
        closeSource()
        handle?.destroy()
    }

    private fun rememberSentLocked(chunk: ByteArray) {
        sent.addLast(chunk)
        sentBytes += chunk.size
        while (sentBytes > maxQueuedBytes) sentBytes -= sent.removeFirst().size
    }

    private fun clearSentLocked() {
        sent.clear()
        sentBytes = 0
    }

    /** Clear the queue and replay buffer and let the writer thread exit; if the writer is blocked writing to the pipe, it exits via IOException after both ends are closed. */
    private fun shutDownWriter() {
        lock.withLock {
            accepting = false
            queue.clear()
            queuedBytes = 0
            clearSentLocked()
            shutDown = true
            changed.signalAll()
        }
    }

    private fun closeSink() {
        val current = lock.withLock {
            if (sinkClosed) return
            sinkClosed = true
            pipe
        }
        runCatching { current.closeSink() }
    }

    private fun closeSource() {
        val current = lock.withLock { pipe }
        runCatching { current.closeSource() }
    }


    internal companion object {
        /** 2 s of 16 kHz mono 16-bit PCM. */
        const val MAX_QUEUED_BYTES = AudioRecordCapture.SAMPLE_RATE * 2 * 2
        private const val WRITER_THREAD_NAME = "oriveo-stt-pipe-writer"
    }
}

/**
 * One self-record recognition session: after the recognizer ends a round on silence (onResults / no match / no speech) it restarts immediately, and the text of each round is joined into one text with
 * [DictationRules.join]. Stop = stopListening, finishing once the last round's result is merged; interrupted = cancel, merging the latest partial result of the current round
 * into the accumulated text before finishing;
 * any other recognizer error finishes as a recognizer failure, with the accumulated text available via [transcript]. When a restart hits a busy recognizer (ERROR_RECOGNIZER_BUSY),
 * it waits [SystemSTTEngine.BUSY_RESTART_DELAY_MS] and restarts once more; only if still busy does it finish as a failure.
 *
 * Calls on the recognizer handle are issued inside the lock (production only posts to the main thread), so restart and stop reach the recognizer in the order they happened.
 */
class SystemSTTSelfRecordSession internal constructor(
    private val sleeper: SystemSTTSleeper = MainThreadSTTSleeper,
    /** One round of a voice conversation: finish as soon as the recognizer decides the user is done and there is text, without restarting (a round with no text restarts and keeps listening as usual). */
    private val singleRound: Boolean = false,
    /** Reopen with DEFAULT when the on-device recognizer reports a missing language at session start; null means no fallback. */
    private val reopen: Reopen? = null,
) : SystemSTTSession, SystemSTTCallbacks {
    /** For fallback: starts listening with the DEFAULT recognizer in [scope], with callbacks routed back to this session. */
    internal class Reopen(
        val scope: CoroutineScope,
        val open: suspend (SystemSTTSelfRecordSession) -> SystemSTTListening,
    )

    private val outcome = CompletableDeferred<STTResult>()
    private val lock = ReentrantLock()

    // All state below is guarded by lock.
    private var listening: SystemSTTListening? = null
    private var stopRequested = false

    /** A round ended before the handle arrived: the recognizer is idle; restart or finish when [attach] is called. */
    private var roundEndedBeforeAttach = false

    /** A restart has been issued (a busy recognizer afterwards is handled as a busy restart). */
    private var restarted = false

    /** This restart already retried once because the recognizer was busy; reset after a round ends normally. */
    private var busyRetried = false

    /** Waiting for a delayed restart: the recognizer is idle with no round in progress. */
    private var busyWaiting = false
    private val segments = mutableListOf<String>()

    /** Latest partial result of the current round (a partial result without text does not overwrite it); cleared when a round ends. */
    private var latestPartial: String? = null

    /** A result has been received (a round-end result or a partial result with text; later errors do not fall back). */
    private var gotResult = false

    /** Already fell back once. */
    private var fellBack = false

    /** Text accumulated so far (kept on failure as well). */
    val transcript: String get() = lock.withLock { DictationRules.join(segments) }

    /** Receiver of the input volume (dB) reported by the recognizer; invoked on the recognizer callback thread (the main thread). */
    @Volatile
    var onLevel: ((Float) -> Unit)? = null

    override fun onRmsChanged(rmsdB: Float) {
        onLevel?.invoke(rmsdB)
    }

    /** User stop: let the recognizer end this round and finish once the last round's result is merged. The result is still obtained from [await]. */
    override fun stop() {
        lock.withLock {
            if (outcome.isCompleted || stopRequested) return
            stopRequested = true
            // While waiting for a delayed restart the recognizer is not listening and will not call back: finish with the accumulated text.
            if (busyWaiting) {
                finishLocked(STTResult.Success(DictationRules.join(segments)))
            } else {
                listening?.stopListening()
            }
        }
    }

    /** Interrupted (incoming call, app sent to background, etc.): cancel the current round, merge its latest partial result into the accumulated text and finish. */
    fun interrupt() {
        lock.withLock {
            if (outcome.isCompleted) return
            listening?.cancel()
            latestPartial?.let { segments += it }
            latestPartial = null
            finishLocked(STTResult.Success(DictationRules.join(segments)))
        }
    }

    override suspend fun await(): STTResult = outcome.await()

    override fun onResults(text: String?) {
        lock.withLock {
            if (outcome.isCompleted) return
            gotResult = true
            if (text != null) segments += text
            roundEndedLocked()
        }
    }

    override fun onPartialResult(text: String?) {
        lock.withLock {
            if (outcome.isCompleted || text == null) return
            gotResult = true
            latestPartial = text
        }
    }

    override fun onError(error: Int) {
        lock.withLock {
            if (outcome.isCompleted) return
            when {
                SystemSTTEngine.isNoSpeech(error) -> roundEndedLocked()
                error == SpeechRecognizer.ERROR_RECOGNIZER_BUSY && restarted && !busyRetried && !stopRequested -> {
                    busyRetried = true
                    busyWaiting = true
                    sleeper.sleep(SystemSTTEngine.BUSY_RESTART_DELAY_MS, ::restartAfterBusy)
                }
                fallBackLocked(error) -> Unit
                else -> finishLocked(STTResult.Failed(SystemSTTEngine.failureFor(error), DictationPrimaryAction.Retry))
            }
        }
    }

    /**
     * The on-device recognizer reports a missing language at session start (no result yet, user has not stopped): destroy the old recognizer and reopen with DEFAULT, falling back only once;
     * the new handle is connected via [attach] (a stop / interrupt in between is applied by attach). A failed reopen ends with the original error. Returns false when fallback does not apply.
     */
    private fun fallBackLocked(error: Int): Boolean {
        val reopen = reopen ?: return false
        if (fellBack || gotResult || stopRequested || !SystemSTTEngine.isLanguageMissing(error)) return false
        fellBack = true
        listening?.destroy()
        listening = null
        reopen.scope.launch(start = CoroutineStart.UNDISPATCHED) {
            val handle = try {
                reopen.open(this@SystemSTTSelfRecordSession)
            } catch (cause: Throwable) {
                lock.withLock {
                    if (!outcome.isCompleted) {
                        finishLocked(STTResult.Failed(SystemSTTEngine.failureFor(error), DictationPrimaryAction.Retry))
                    }
                }
                if (cause is CancellationException) throw cause
                return@launch
            }
            attach(handle)
        }
        return true
    }

    private fun restartAfterBusy() {
        lock.withLock {
            if (outcome.isCompleted || !busyWaiting) return
            busyWaiting = false
            listening?.restartListening()
        }
    }

    /** Self-record does not use segmented sessions. */
    override fun onSegmentResult(text: String?) = Unit

    override fun onEndOfSegmentedSession() = Unit

    internal fun attach(handle: SystemSTTListening) {
        lock.withLock {
            listening = handle
            when {
                outcome.isCompleted -> handle.destroy()
                roundEndedBeforeAttach -> {
                    roundEndedBeforeAttach = false
                    roundEndedLocked()
                }
                stopRequested -> handle.stopListening()
            }
        }
    }

    private fun roundEndedLocked() {
        latestPartial = null
        val handle = listening
        when {
            stopRequested || (singleRound && segments.isNotEmpty()) ->
                finishLocked(STTResult.Success(DictationRules.join(segments)))
            handle == null -> roundEndedBeforeAttach = true
            else -> {
                restarted = true
                busyRetried = false
                handle.restartListening()
            }
        }
    }

    private fun finishLocked(result: STTResult) {
        outcome.complete(result)
        listening?.destroy()
    }
}

/** Production [SystemSTTSessionBackend]: pipes use ParcelFileDescriptor.createPipe, and recognizers are created and called only on the main thread. */
class AndroidSystemSTTSessionBackend(
    context: Context,
    private val recognizers: AndroidSystemSTTBackend = AndroidSystemSTTBackend(context),
) : SystemSTTSessionBackend {
    private val appContext = context.applicationContext

    override fun createPipe(): SystemSTTPipe {
        val (read, write) = ParcelFileDescriptor.createPipe()
        return ParcelPipe(read, write)
    }

    override fun isDefaultRecognitionAvailable(): Boolean = recognizers.isRecognitionAvailable()

    override suspend fun startListening(
        recognizer: SystemSTTRecognizer,
        intent: Intent,
        callbacks: SystemSTTCallbacks,
    ): SystemSTTListening = withContext(Dispatchers.Main.immediate) {
        val speech = recognizers.createRecognizer(recognizer)
        try {
            speech.setRecognitionListener(Listener(callbacks))
            speech.startListening(intent)
        } catch (error: Throwable) {
            speech.destroy()
            if (error is CancellationException) throw error
            throw IOException("startListening failed: ${error.message}", error)
        }
        MainThreadListening(speech, intent, callbacks)
    }

    private inner class MainThreadListening(
        private val speech: SpeechRecognizer,
        private val intent: Intent,
        private val callbacks: SystemSTTCallbacks,
    ) : SystemSTTListening {
        override fun stopListening() {
            ContextCompat.getMainExecutor(appContext).execute { runCatching { speech.stopListening() } }
        }

        override fun restartListening() {
            ContextCompat.getMainExecutor(appContext).execute {
                runCatching { speech.startListening(intent) }
                    .onFailure { callbacks.onError(SpeechRecognizer.ERROR_CLIENT) }
            }
        }

        override fun cancel() {
            ContextCompat.getMainExecutor(appContext).execute { runCatching { speech.cancel() } }
        }

        override fun destroy() {
            ContextCompat.getMainExecutor(appContext).execute { runCatching { speech.destroy() } }
        }
    }

    private class ParcelPipe(
        private val read: ParcelFileDescriptor,
        write: ParcelFileDescriptor,
    ) : SystemSTTPipe {
        private val sink: OutputStream = ParcelFileDescriptor.AutoCloseOutputStream(write)

        override val source: Parcelable get() = read

        override fun write(bytes: ByteArray, offset: Int, length: Int) = sink.write(bytes, offset, length)

        override fun closeSink() = sink.close()

        override fun closeSource() = read.close()
    }

    private class Listener(private val callbacks: SystemSTTCallbacks) : RecognitionListener {
        override fun onSegmentResults(segmentResults: Bundle) {
            callbacks.onSegmentResult(segmentResults.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull())
        }

        override fun onEndOfSegmentedSession() = callbacks.onEndOfSegmentedSession()

        override fun onError(error: Int) = callbacks.onError(error)

        override fun onReadyForSpeech(params: Bundle?) = Unit

        override fun onBeginningOfSpeech() = Unit

        override fun onRmsChanged(rmsdB: Float) = callbacks.onRmsChanged(rmsdB)

        override fun onBufferReceived(buffer: ByteArray?) = Unit

        override fun onEndOfSpeech() = Unit

        override fun onResults(results: Bundle?) {
            callbacks.onResults(results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull())
        }

        override fun onPartialResults(partialResults: Bundle?) {
            callbacks.onPartialResult(partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull())
        }

        override fun onEvent(eventType: Int, params: Bundle?) = Unit
    }
}
