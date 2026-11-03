package ai.oriveo.community.core.voice

import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.audiofx.Visualizer
import ai.oriveo.community.core.voice.conversation.ConversationFrames
import ai.oriveo.community.core.model.ProviderKind
import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.network.sockets.ConnectTimeoutException
import io.ktor.client.plugins.HttpRequestTimeoutException
import io.ktor.client.plugins.expectSuccess
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.content.TextContent
import io.ktor.http.isSuccess
import java.io.File
import java.net.SocketTimeoutException
import java.util.Collections
import java.util.Locale
import kotlin.coroutines.cancellation.CancellationException
import kotlin.coroutines.resume
import kotlin.math.roundToLong
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json

/** Plays one chunk's audio file. */
interface ChunkPlayer {
    /** Suspends until playback finishes; returns false when the player reports an error. */
    suspend fun play(file: File): Boolean

    fun stop()

    /**
     * Holds playback at its position, including chunks played later on this player, until [resume].
     * false = this player can't hold a position (nothing changed).
     */
    fun pause(): Boolean = false

    fun resume() = Unit
}

/**
 * [ChunkPlayer] backed by MediaPlayer with prepareAsync; one MediaPlayer per chunk.
 * [audioAttributes] null keeps MediaPlayer's default (read aloud); the voice conversation passes USAGE_VOICE_COMMUNICATION.
 * [levelProbe] (voice conversation only) receives the measured playback level 0…1 about every 67 ms from a
 * [Visualizer] on the player's audio session; when the probe can't be built or started it gets 0 once (no level is
 * faked). A player released before or while its probe attaches reports nothing.
 */
class MediaChunkPlayer internal constructor(
    private val audioAttributes: AudioAttributes?,
    private val levelProbe: ((Float) -> Unit)?,
    private val probeFactory: PlaybackLevelProbeFactory,
    private val playerFactory: () -> MediaPlayer,
) : ChunkPlayer {
    constructor(audioAttributes: AudioAttributes? = null, levelProbe: ((Float) -> Unit)? = null) :
        this(audioAttributes, levelProbe, ::visualizerLevelProbe, ::MediaPlayer)

    private val lock = Any()
    private var current: MediaPlayer? = null

    // The current player once prepared (started unless held); a held player starts on resume.
    private var prepared: MediaPlayer? = null
    private var held = false

    // Owned by whoever takes it out of this field under [lock]; that side releases it exactly once.
    private var probe: PlaybackLevelProbe? = null

    override suspend fun play(file: File): Boolean = suspendCancellableCoroutine { cont ->
        val player = playerFactory()
        synchronized(lock) { current = player }
        fun finish(ok: Boolean) {
            release(player)
            if (cont.isActive) cont.resume(ok)
        }
        player.setOnPreparedListener(::onPrepared)
        player.setOnCompletionListener { finish(true) }
        player.setOnErrorListener { _, _, _ ->
            finish(false)
            true
        }
        cont.invokeOnCancellation { release(player) }
        try {
            audioAttributes?.let(player::setAudioAttributes)
            player.setDataSource(file.path)
            player.prepareAsync()
        } catch (e: Exception) {
            finish(false)
        }
    }

    override fun stop() {
        val player = synchronized(lock) { current } ?: return
        release(player)
    }

    override fun pause(): Boolean {
        synchronized(lock) {
            held = true
            prepared?.let { runCatching { it.pause() } }
        }
        return true
    }

    override fun resume() {
        synchronized(lock) {
            held = false
            prepared?.let { runCatching { it.start() } }
        }
    }

    /** MediaPlayer prepared callback: starts playback (unless held), then attaches the level probe. */
    internal fun onPrepared(player: MediaPlayer) {
        synchronized(lock) {
            if (current === player) prepared = player
            if (!held) player.start()
        }
        levelProbe?.let { startProbe(player, it) }
    }

    private fun release(player: MediaPlayer) {
        val attached = synchronized(lock) {
            if (current !== player) return
            current = null
            if (prepared === player) prepared = null
            probe.also { probe = null }
        }
        attached?.release()
        runCatching { player.reset() }
        runCatching { player.release() }
    }

    private fun startProbe(player: MediaPlayer, onLevel: (Float) -> Unit) {
        // Readings count only while this probe is the attached one (set before attaching, read under [lock]).
        var self: PlaybackLevelProbe? = null
        val built = try {
            probeFactory(player.audioSessionId) { measurement ->
                val live = synchronized(lock) { self != null && probe === self }
                if (live) onLevel(playbackLevelFromPeakRms(measurement))
            }
        } catch (e: Exception) {
            if (synchronized(lock) { current === player }) onLevel(0f)
            return
        }
        self = built
        val attached = synchronized(lock) {
            (current === player).also { if (it) probe = built }
        }
        if (!attached) {
            // The player was released before the probe attached: nobody else holds it.
            built.release()
            return
        }
        try {
            built.enable()
        } catch (e: Exception) {
            // Still ours: detach and fall back to 0. Otherwise release() already took and released it.
            val ours = synchronized(lock) {
                (probe === built).also { if (it) probe = null }
            }
            if (ours) {
                built.release()
                onLevel(0f)
            }
        }
    }
}

/** One attached playback level measurement; [enable] throws when it can't start (e.g. already released). */
internal interface PlaybackLevelProbe {
    fun enable()

    fun release()
}

/** Builds a probe on an audio session that hands each Peak/RMS reading to the callback; throws when unavailable. */
internal typealias PlaybackLevelProbeFactory =
    (audioSessionId: Int, onMeasurement: (Visualizer.MeasurementPeakRms) -> Unit) -> PlaybackLevelProbe

/** Orb level 0…1 from a Peak/RMS reading; mRms is in millibels (−9600…0). */
internal fun playbackLevelFromPeakRms(measurement: Visualizer.MeasurementPeakRms): Float =
    ConversationFrames.levelFromDb(measurement.mRms / 100.0, ConversationFrames.AI_LEVEL_FLOOR_DB)

/** About one reading per 67 ms (15 Hz), capped by the device's maximum capture rate. */
private const val PROBE_RATE_MILLIHERTZ = 1_000_000 / 67

/** [Visualizer] Peak/RMS measurement on [audioSessionId], read on each waveform capture. */
private fun visualizerLevelProbe(
    audioSessionId: Int,
    onMeasurement: (Visualizer.MeasurementPeakRms) -> Unit,
): PlaybackLevelProbe {
    val v = Visualizer(audioSessionId)
    try {
        check(v.setMeasurementMode(Visualizer.MEASUREMENT_MODE_PEAK_RMS) == Visualizer.SUCCESS)
        val measurement = Visualizer.MeasurementPeakRms()
        val rate = minOf(PROBE_RATE_MILLIHERTZ, Visualizer.getMaxCaptureRate())
        val listener = object : Visualizer.OnDataCaptureListener {
            override fun onWaveFormDataCapture(visualizer: Visualizer, waveform: ByteArray?, samplingRate: Int) {
                // A capture racing release() reads a released Visualizer: drop it.
                val ok = runCatching { visualizer.getMeasurementPeakRms(measurement) == Visualizer.SUCCESS }
                if (ok.getOrDefault(false)) onMeasurement(measurement)
            }

            override fun onFftDataCapture(visualizer: Visualizer, fft: ByteArray?, samplingRate: Int) = Unit
        }
        check(v.setDataCaptureListener(listener, rate, true, false) == Visualizer.SUCCESS)
    } catch (e: Exception) {
        v.release()
        throw e
    }
    return object : PlaybackLevelProbe {
        override fun enable() {
            check(v.setEnabled(true) == Visualizer.SUCCESS)
        }

        override fun release() {
            runCatching { v.setEnabled(false) }
            runCatching { v.release() }
        }
    }
}

/** One synthesized audio file; [temporary] files were not cached and must be deleted after use. */
class SynthesizedSpeech(val file: File, val temporary: Boolean)

/**
 * Cloud read aloud: splits sentences with [CloudReadAloudRules.ttsChunks], fetches each chunk (cache first),
 * plays chunks in order and prefetches only the next one. onStart reports the chunk's first sentence index.
 * Auto retry follows [CloudReadAloudRules.failureDecision]; when a chunk is no longer retried (or fails to play),
 * prefetch stops, [SpeechEngine.Listener.onFallback] fires once and a fresh engine from [fallbackFactory] continues
 * from that chunk's first sentence with the same locale; its onStart indices are offset back to the full list.
 * Without a [fallbackFactory] (voice preview) such a failure reports [SpeechError.FAILED] instead.
 */
class CloudSpeechEngine(
    private val httpClient: HttpClient,
    private val entry: VoiceTtsEntry,
    private val providerKind: ProviderKind,
    baseUrl: String,
    private val apiKey: String,
    voice: String?,
    private val slider: Float?,
    private val cache: SpeechAudioCache,
    private val playerFactory: () -> ChunkPlayer,
    private val fallbackFactory: (() -> SpeechEngine)?,
    val providerDisplayName: String,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
    private val sleeper: suspend (Long) -> Unit = { delay(it) },
    private val fileDeleter: (File) -> Unit = { it.delete() },
) : SpeechEngine {
    private val url: String? = CloudReadAloudRules.requestUrl(baseUrl, entry)
    private val voiceId: String = voice?.takeIf { id -> entry.voices.any { it.id == id } } ?: entry.defaultVoice.id

    private val lock = Any()
    private var job: Job? = null
    private var player: ChunkPlayer? = null
    private var fallback: SpeechEngine? = null
    private var session: Any? = null

    override val engineName: String = ENGINE_NAME

    override fun speak(utterances: List<String>, locale: Locale, listener: SpeechEngine.Listener) =
        speak(utterances, locale, List(utterances.size) { locale }, listener)

    /** Chunks are synthesized in [locale]; [segmentLocales] only matter for the system fallback. */
    override fun speak(
        utterances: List<String>,
        locale: Locale,
        segmentLocales: List<Locale>,
        listener: SpeechEngine.Listener,
    ) {
        stop()
        val chunks = CloudReadAloudRules.ttsChunks(utterances, entry.maxChars)
        if (chunks.isEmpty()) {
            listener.onDoneAll()
            return
        }
        val language = locale.toLanguageTag()
        val chunkPlayer = playerFactory()
        val token = Any()
        synchronized(lock) {
            session = token
            player = chunkPlayer
            job = scope.launch {
                run(token, utterances, locale, segmentLocales, chunks, language, chunkPlayer, listener)
            }
        }
    }

    override fun stop() {
        val (oldJob, oldPlayer, oldFallback) = synchronized(lock) {
            val triple = Triple(job, player, fallback)
            job = null
            player = null
            fallback = null
            session = null
            triple
        }
        oldJob?.cancel()
        oldPlayer?.stop()
        oldFallback?.stop()
    }

    private suspend fun run(
        token: Any,
        utterances: List<String>,
        locale: Locale,
        segmentLocales: List<Locale>,
        chunks: List<TtsChunk>,
        language: String,
        chunkPlayer: ChunkPlayer,
        listener: SpeechEngine.Listener,
    ) {
        // Temp files written by this session's fetches; whatever is left (prefetched but unplayed) is
        // deleted once the session ends, including on stop / cancellation.
        val temps: MutableSet<File> = Collections.synchronizedSet(mutableSetOf())
        try {
            play(token, utterances, locale, segmentLocales, chunks, language, chunkPlayer, listener, temps)
        } finally {
            deleteFiles(synchronized(temps) { temps.toList() })
        }
    }

    /** File deletes run on IO and still complete when the session is being cancelled. */
    private suspend fun deleteFiles(files: List<File>) {
        if (files.isEmpty()) return
        withContext(NonCancellable + Dispatchers.IO) { files.forEach(fileDeleter) }
    }

    private suspend fun play(
        token: Any,
        utterances: List<String>,
        locale: Locale,
        segmentLocales: List<Locale>,
        chunks: List<TtsChunk>,
        language: String,
        chunkPlayer: ChunkPlayer,
        listener: SpeechEngine.Listener,
        temps: MutableSet<File>,
    ): Unit = coroutineScope {
        var pending: Deferred<ChunkAudio?> = async { fetch(chunks[0].text, language, temps) }
        for ((index, chunk) in chunks.withIndex()) {
            val audio = pending.await()
            ensureActive()
            if (audio == null) {
                fallBack(token, utterances, locale, segmentLocales, chunk.firstSentenceIndex, listener)
                return@coroutineScope
            }
            // Prefetch only the next chunk, started once the current one is ready to play.
            val next = chunks.getOrNull(index + 1)?.let { async { fetch(it.text, language, temps) } }
            listener.onStart(chunk.firstSentenceIndex)
            val ok = try {
                chunkPlayer.play(audio.file)
            } finally {
                if (audio.temporary) deleteFiles(listOf(audio.file))
            }
            ensureActive()
            if (!ok) {
                next?.cancel()
                fallBack(token, utterances, locale, segmentLocales, chunk.firstSentenceIndex, listener)
                return@coroutineScope
            }
            pending = next ?: break
        }
        listener.onDoneAll()
    }

    /**
     * Hands the rest (from [offset]) to a fresh system engine, or reports failure when there is no fallback;
     * skipped when this session was already stopped.
     */
    private fun fallBack(
        token: Any,
        utterances: List<String>,
        locale: Locale,
        segmentLocales: List<Locale>,
        offset: Int,
        listener: SpeechEngine.Listener,
    ) {
        synchronized(lock) {
            if (session !== token) return
            val factory = fallbackFactory
            if (factory == null) {
                session = null
                job = null
                player = null
                listener.onError(SpeechError.FAILED)
                return
            }
            listener.onFallback(providerDisplayName)
            if (session !== token) return
            val system = factory()
            fallback = system
            // Started under the lock so a concurrent stop() cannot slip in before speak().
            system.speak(
                utterances.drop(offset),
                locale,
                segmentLocales.drop(offset),
                object : SpeechEngine.Listener {
                    override fun onStart(index: Int) = listener.onStart(index + offset)
                    override fun onDoneAll() = listener.onDoneAll()
                    override fun onError(error: SpeechError) = listener.onError(error)
                },
            )
        }
    }

    private class ChunkAudio(val file: File, val temporary: Boolean)

    /**
     * Synthesizes [text] without playing it (voice conversation): same chunking, cache, request and retry as
     * [speak], no fallback. Returns the chunk files in order (temporary ones are the caller's to delete), or null
     * when any chunk fails; files already written for this call are then deleted.
     */
    suspend fun synthesizeToFile(text: String, locale: Locale): List<SynthesizedSpeech>? {
        val chunks = CloudReadAloudRules.ttsChunks(listOf(text), entry.maxChars)
        if (chunks.isEmpty()) return emptyList()
        val language = locale.toLanguageTag()
        val temps: MutableSet<File> = Collections.synchronizedSet(mutableSetOf())
        val out = mutableListOf<SynthesizedSpeech>()
        try {
            for (chunk in chunks) {
                val audio = fetch(chunk.text, language, temps)
                if (audio == null) {
                    deleteFiles(synchronized(temps) { temps.toList() })
                    return null
                }
                out += SynthesizedSpeech(audio.file, audio.temporary)
            }
            return out
        } catch (e: CancellationException) {
            deleteFiles(synchronized(temps) { temps.toList() })
            throw e
        }
    }

    /** Cache hit plays directly; otherwise request with retry, write cache, or fall back to a temp file. */
    private suspend fun fetch(text: String, language: String, temps: MutableSet<File>): ChunkAudio? {
        val key = SpeechCacheKey(
            text = text,
            providerKind = providerKind,
            model = entry.model,
            voice = voiceId,
            effectiveSpeed = CloudReadAloudRules.effectiveSpeed(entry, slider),
            language = language,
            outputFormat = entry.outputFormat,
        )
        cache.read(key)?.let { return ChunkAudio(it, temporary = false) }
        val bytes = requestWithRetry(text, language) ?: return null
        cache.write(key, bytes)?.let { return ChunkAudio(it, temporary = false) }
        return withContext(Dispatchers.IO) {
            runCatching {
                val temp = cache.createAudioTempFile(".${entry.outputFormat}")
                temps += temp
                temp.writeBytes(bytes)
                ChunkAudio(temp, temporary = true)
            }.getOrNull()
        }
    }

    private suspend fun requestWithRetry(text: String, language: String): ByteArray? {
        var attempt = 1
        while (true) {
            val failure = when (val outcome = send(text, language)) {
                is Outcome.Ok -> return outcome.bytes
                is Outcome.Failed -> outcome.failure
            }
            val decision = CloudReadAloudRules.failureDecision(failure, attempt)
            if (!decision.autoRetry) return null
            val delaySec = decision.delaySec ?: DictationRules.DEFAULT_RETRY_DELAY_SEC
            sleeper((delaySec * MILLIS_PER_SECOND).roundToLong())
            attempt++
        }
    }

    private sealed interface Outcome {
        class Ok(val bytes: ByteArray) : Outcome
        class Failed(val failure: DictationFailure) : Outcome
    }

    private suspend fun send(text: String, language: String): Outcome {
        val url = url ?: return Outcome.Failed(DictationFailure.InvalidEndpoint)
        val body = CloudReadAloudRules.requestBody(entry, text, voiceId, slider, language).toString()
        return try {
            val first = withTimeout(REQUEST_TIMEOUT_MS) {
                val response: HttpResponse = httpClient.post(url) {
                    expectSuccess = false
                    val (name, value) = DictationRules.authorizationHeader(entry.transport, apiKey)
                    header(name, value)
                    setBody(TextContent(body, ContentType.Application.Json))
                }
                bytesOrFailure(response)
            }
            if (first !is Outcome.Ok || !CloudReadAloudRules.isJsonResponse(entry.transport)) return first
            // JSON responses are decoded to audio bytes before they are cached or played, off the main thread.
            val audio = withContext(Dispatchers.Default) {
                val json = runCatching { Json.parseToJsonElement(String(first.bytes, Charsets.UTF_8)) }.getOrNull()
                json?.let { CloudReadAloudRules.audioResponse(entry.transport, it) }
            }
            when (audio) {
                is TtsAudioResponse.Audio -> Outcome.Ok(audio.bytes)
                // Second hop (dashscope_tts): plain GET without the auth header, same timeout and status rules.
                is TtsAudioResponse.Download -> withTimeout(REQUEST_TIMEOUT_MS) {
                    bytesOrFailure(httpClient.get(audio.url) { expectSuccess = false })
                }
                null -> Outcome.Failed(DictationFailure.InvalidResponse)
            }
        } catch (_: TimeoutCancellationException) {
            Outcome.Failed(DictationFailure.Timeout)
        } catch (e: CancellationException) {
            throw e
        } catch (_: HttpRequestTimeoutException) {
            Outcome.Failed(DictationFailure.Timeout)
        } catch (_: ConnectTimeoutException) {
            Outcome.Failed(DictationFailure.Timeout)
        } catch (_: SocketTimeoutException) {
            Outcome.Failed(DictationFailure.Timeout)
        } catch (_: Exception) {
            Outcome.Failed(DictationFailure.Network)
        }
    }

    private suspend fun bytesOrFailure(response: HttpResponse): Outcome {
        if (!response.status.isSuccess()) {
            return Outcome.Failed(DictationFailure.Http(response.status.value, response.headers[HttpHeaders.RetryAfter]))
        }
        val bytes: ByteArray = response.body()
        return if (bytes.isEmpty()) Outcome.Failed(DictationFailure.InvalidResponse) else Outcome.Ok(bytes)
    }

    companion object {
        const val ENGINE_NAME = "cloud"
        const val REQUEST_TIMEOUT_MS = 30_000L
        private const val MILLIS_PER_SECOND = 1000.0
    }
}
