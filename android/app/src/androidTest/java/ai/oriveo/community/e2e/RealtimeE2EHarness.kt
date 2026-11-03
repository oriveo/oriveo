package ai.oriveo.community.e2e

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Rect
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import ai.oriveo.community.core.voice.AndroidAudioSessionCoordinator
import ai.oriveo.community.core.voice.realtime.AndroidRealtimeAudio
import ai.oriveo.community.core.voice.realtime.RealtimeAudioIO
import ai.oriveo.community.core.voice.realtime.RealtimePCM
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveSocket
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveSocketFactory
import ai.oriveo.community.core.voice.realtime.wire.RealtimeHandshakeException
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.Base64
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.sin
import kotlin.math.sqrt
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import org.koin.mp.KoinPlatform

/*
 * Realtime voice E2E harness: a closed-loop fake Gemini Live server,
 * an injected-PCM RealtimeAudioIO standing in for the microphone, per-step screenshots with soft assertions and
 * results.json, and the three layout criteria of shared/voice-contracts/e2e/realtime-e2e.v1.json. Test code only:
 * production code is untouched. Run through scripts/voice-e2e-android.sh (corpus push, e2eLocale / e2eAppearance).
 */

/** One corpus clip of the fixture (corpus.clips). */
internal data class E2EClip(val id: String, val lang: String, val segments: List<String>, val gapMs: Long) {
    /** What the fake server hears as the whole turn: zh segments join directly, en with a space. */
    val transcript: String get() = segments.joinToString(if (lang == "zh") "" else " ")
}

/** shared/voice-contracts/e2e/realtime-e2e.v1.json, packaged as an androidTest asset. */
internal object E2EFixture {
    private const val ASSET = "realtime-e2e.v1.json"

    val root: JsonObject by lazy {
        val assets = InstrumentationRegistry.getInstrumentation().context.assets
        Json.parseToJsonElement(assets.open(ASSET).use { it.readBytes().decodeToString() }).jsonObject
    }

    /** corpus.clips exactly as written in the fixture (key order kept: the corpus digest hashes it). */
    val clipsJson: JsonArray get() = root.obj("corpus")["clips"]!!.jsonArray

    val fakeServer: JsonObject get() = root.obj("fakeServer")

    val model: String get() = root.string("model")

    /** "{lang}-short" style ids resolve against the run locale. */
    fun clip(id: String): E2EClip {
        val resolved = id.replace("{lang}", E2EArgs.locale)
        val entry = clipsJson.map { it.jsonObject }.singleOrNull { it.string("id") == resolved }
            ?: error("no corpus clip $resolved in $ASSET")
        return E2EClip(
            id = resolved,
            lang = entry.string("lang"),
            segments = entry["segments"]!!.jsonArray.map { it.jsonPrimitive.content },
            gapMs = entry["gapMs"]?.jsonPrimitive?.content?.toLong() ?: 0L,
        )
    }

    /** fakeServer.reply.text for [lang] with {transcript} filled in. */
    fun replyText(lang: String, transcript: String): String =
        fakeServer.obj("reply").obj("text").string(lang).replace("{transcript}", transcript)
}

/** Instrumentation arguments set by scripts/voice-e2e-android.sh. */
internal object E2EArgs {
    val locale: String get() = InstrumentationRegistry.getArguments().getString("e2eLocale") ?: "zh"
    val appearance: String get() = InstrumentationRegistry.getArguments().getString("e2eAppearance") ?: "light"
}

/** Corpus WAVs pushed by the run script to getExternalFilesDir("e2e-corpus"). */
internal object E2ECorpus {
    val dir: File
        get() = requireNotNull(InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir("e2e-corpus")) {
            "external files dir unavailable"
        }

    /** Same fingerprint as scripts/voice-e2e-corpus.mjs: sha256(JSON.stringify(corpus.clips)), first 16 hex. */
    val fixtureDigest: String by lazy {
        MessageDigest.getInstance("SHA-256").digest(E2EFixture.clipsJson.toString().toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
            .take(16)
    }

    /** Fails when the pushed corpus is missing, stale (digest differs from the fixture) or incomplete. */
    fun verify() {
        val manifest = File(dir, "manifest.json")
        check(manifest.isFile) { "corpus manifest missing at $manifest: run through scripts/voice-e2e-android.sh" }
        val digest = Json.parseToJsonElement(manifest.readText()).jsonObject.string("digest")
        check(digest == fixtureDigest) { "corpus digest $digest does not match fixture $fixtureDigest: regenerate the corpus" }
        val missing = E2EFixture.clipsJson.map { it.jsonObject.string("id") }.filterNot { File(dir, "$it.wav").isFile }
        check(missing.isEmpty()) { "corpus clips missing: $missing" }
    }

    /** 16 kHz mono s16 samples of clip [id]. */
    fun samples(id: String): ShortArray = parseWav(File(dir, "$id.wav").readBytes())

    /** Walks RIFF chunks and returns the `data` chunk as samples (same rules as WavPcmSource). */
    private fun parseWav(wav: ByteArray): ShortArray {
        val bytes = ByteBuffer.wrap(wav).order(ByteOrder.LITTLE_ENDIAN)
        require(String(wav, 0, 4, Charsets.US_ASCII) == "RIFF" && String(wav, 8, 4, Charsets.US_ASCII) == "WAVE") {
            "not a WAVE file"
        }
        var at = 12
        while (at + 8 <= wav.size) {
            val id = String(wav, at, 4, Charsets.US_ASCII)
            val length = bytes.getInt(at + 4)
            val body = at + 8
            if (id == "fmt ") {
                val channels = bytes.getShort(body + 2).toInt()
                val rate = bytes.getInt(body + 4)
                val bits = bytes.getShort(body + 14).toInt()
                require(channels == 1 && rate == RealtimePCM.INPUT_RATE && bits == 16) {
                    "expected 16 kHz mono 16-bit, got $channels/$rate/$bits"
                }
            } else if (id == "data") {
                val count = minOf(length, wav.size - body) / 2
                return ShortArray(count) { bytes.getShort(body + it * 2) }
            }
            at = body + length + (length and 1)
        }
        error("no data chunk")
    }
}

/**
 * Closed-loop fake Gemini Live handed to the production GeminiLiveTransport as its socket factory. It listens to the
 * uplink PCM with the fixture's energy VAD (fakeServer.vad) and answers each turn the way the fixture says: one
 * inputTranscription per clip segment when that segment's speech ends, ACTIVITY_END at turn end, then three
 * outputTranscription chunks over a 24 kHz tone sent in 100 ms chunks on the real clock, then turnComplete. Speech
 * starting while a reply is still being sent is a barge-in: interrupted=true closes the reply. Frame shapes follow
 * shared/voice-contracts/recordings/gemini-live-home-two-turn.v1.json.
 *
 * Which text the server "recognizes" comes from [expect]: [E2EVoice.speak] queues the clip here and its PCM on the
 * injected source at the same time, so the next detected turn takes the next queued clip.
 */
internal class FakeGeminiServer(private val lang: String = E2EArgs.locale) : GeminiLiveSocketFactory {
    enum class Mode {
        Normal,

        /** The first connection throws an IO error (failure_connect_error_network), later ones are normal. */
        NetworkOnce,

        /** Every handshake answers HTTP 401 (failure_handshake_401_auth). */
        Auth,
    }

    @Volatile
    var mode: Mode = Mode.Normal

    /** Connection attempts, failed ones included. */
    val connections = AtomicInteger(0)

    /** Every server message sent to the app, all connections, in order. */
    val serverFrames = ConcurrentLinkedQueue<JsonObject>()

    /** Turns the VAD detected with no clip queued: nothing to recognize, so no reply was sent. */
    val unscriptedTurns = AtomicInteger(0)

    private val firstSetup = AtomicReference<JsonObject?>(null)
    private val uplinkMicros = AtomicLong(0)
    private val networkFailed = AtomicBoolean(false)
    private val script = ConcurrentLinkedQueue<E2EClip>()
    private val config = E2EFixture.fakeServer
    private val vad = config.obj("vad")
    private val frameMs = vad.long("frameMs")
    private val speechOnDbfs = vad.double("speechOnDbfs")
    private val speechOnMs = vad.long("speechOnMs")
    private val fragmentGapMs = vad.long("fragmentGapMs")
    private val turnEndSilenceMs = vad.long("turnEndSilenceMs")
    private val setupCompleteAfterMs = config.long("setupCompleteAfterMs")
    private val reply = config.obj("reply")
    private val chunkCount = reply.long("outputTranscriptionChunks").toInt()
    private val audioMs = reply.long("audioMs")
    private val audioMsAfterLongTurn = reply.long("audioMsAfterLongTurn")

    /** The first setup message the app sent (whole message, `setup` at the top). */
    val setup: JsonObject? get() = firstSetup.get()

    /** setup.inputAudioTranscription.languageCodes[0] of the first setup; null when the field is missing. */
    val setupLanguage: String?
        get() = (setup?.get("setup") as? JsonObject)
            ?.let { it["inputAudioTranscription"] as? JsonObject }
            ?.let { it["languageCodes"] as? JsonArray }
            ?.firstOrNull()?.jsonPrimitive?.content

    /** Milliseconds of uplink audio received over all connections. */
    val uplinkMs: Long get() = uplinkMicros.get() / 1000

    /** Texts of every inputTranscription frame sent, in order. */
    fun inputTranscriptions(): List<String> = serverFrames.mapNotNull { frame ->
        ((frame["serverContent"] as? JsonObject)?.get("inputTranscription") as? JsonObject)?.get("text")?.jsonPrimitive?.content
    }

    /** Queues [clip] as what the next detected turn says. */
    fun expect(clip: E2EClip) {
        script.add(clip)
    }

    override suspend fun connect(url: String): GeminiLiveSocket {
        connections.incrementAndGet()
        when (mode) {
            Mode.NetworkOnce -> if (networkFailed.compareAndSet(false, true)) throw IOException("fake network unreachable")
            Mode.Auth -> throw RealtimeHandshakeException(401, "FakeGeminiServer")
            Mode.Normal -> Unit
        }
        return Session()
    }

    private class Turn(val clip: E2EClip?) {
        var nextSegment = 0
    }

    private inner class Session : GeminiLiveSocket {
        private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        private val outgoing = Channel<String>(Channel.UNLIMITED)
        private val lock = Any()

        @Volatile
        private var closed = false
        private var historyPending = false

        // VAD state, guarded by [lock].
        private var pendingSamples = ShortArray(0)
        private var speechRunMs = 0L
        private var silenceRunMs = 0L
        private var inFragment = false
        private var turn: Turn? = null
        private var sessionUplinkMicros = 0L

        // Reply state, guarded by [lock]: [generation] changes when a reply is replaced or interrupted.
        private var generation = 0
        private var replyActive = false
        private var replyJob: Job? = null

        override suspend fun send(text: String) {
            if (closed) throw IOException("fake socket closed")
            val message = Json.parseToJsonElement(text).jsonObject
            (message["setup"] as? JsonObject)?.let { onSetup(message, it) }
            (message["realtimeInput"] as? JsonObject)?.let(::onRealtimeInput)
            (message["clientContent"] as? JsonObject)?.let(::onClientContent)
        }

        override suspend fun receive(): String? = outgoing.receiveCatching().getOrNull()

        override fun close() {
            closed = true
            scope.cancel()
            outgoing.close()
        }

        private fun emit(frame: JsonObject) {
            if (closed) return
            serverFrames.add(frame)
            outgoing.trySend(frame.toString())
        }

        private fun onSetup(message: JsonObject, setup: JsonObject) {
            firstSetup.compareAndSet(null, message)
            historyPending = (setup["historyConfig"] as? JsonObject)
                ?.get("initialHistoryInClientContent")?.jsonPrimitive?.booleanOrNull == true
            scope.launch {
                delay(setupCompleteAfterMs)
                emit(buildJsonObject { putJsonObject("setupComplete") {} })
            }
        }

        private fun onClientContent(content: JsonObject) {
            // With initialHistoryInClientContent the first clientContent is the history replay, not a user turn.
            if (historyPending) {
                historyPending = false
                return
            }
            if (content["turnComplete"]?.jsonPrimitive?.booleanOrNull != true) return
            val turns = (content["turns"] as? JsonArray).orEmpty().map { it.jsonObject }
            val typed = turns.lastOrNull { it["role"]?.jsonPrimitive?.content == "user" }
                ?.let { it["parts"] as? JsonArray }.orEmpty()
                .mapNotNull { (it as? JsonObject)?.get("text")?.jsonPrimitive?.content }
                .joinToString("")
            if (typed.isNotEmpty()) synchronized(lock) { startReply(typed, long = false) }
        }

        private fun onRealtimeInput(input: JsonObject) {
            (input["text"] as? JsonPrimitive)?.content?.takeIf { it.isNotEmpty() }?.let { typed ->
                synchronized(lock) { startReply(typed, long = false) }
            }
            val audio = input["audio"] as? JsonObject ?: return
            val data = audio["data"]?.jsonPrimitive?.content ?: return
            val rate = audio["mimeType"]?.jsonPrimitive?.content
                ?.substringAfter("rate=", "")?.toIntOrNull() ?: RealtimePCM.INPUT_RATE
            val bytes = Base64.getDecoder().decode(data)
            val samples = ShortArray(bytes.size / 2)
            ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().get(samples)
            synchronized(lock) { feed(samples, rate) }
        }

        private fun feed(samples: ShortArray, rate: Int) {
            val micros = samples.size * 1_000_000L / rate
            uplinkMicros.addAndGet(micros)
            sessionUplinkMicros += micros
            val frameSamples = (rate * frameMs / 1000).toInt()
            var buffer = pendingSamples + samples
            var at = 0
            while (buffer.size - at >= frameSamples) {
                frame(dbfs(buffer, at, frameSamples))
                at += frameSamples
            }
            buffer = buffer.copyOfRange(at, buffer.size)
            pendingSamples = buffer
        }

        private fun frame(db: Double) {
            if (db >= speechOnDbfs) {
                speechRunMs += frameMs
                if (speechRunMs >= speechOnMs) {
                    silenceRunMs = 0
                    if (!inFragment) {
                        inFragment = true
                        onFragmentStart()
                    }
                }
                return
            }
            speechRunMs = 0
            silenceRunMs += frameMs
            if (inFragment && silenceRunMs >= fragmentGapMs) {
                inFragment = false
                onFragmentEnd()
            }
            if (turn != null && !inFragment && silenceRunMs >= turnEndSilenceMs) onTurnEnd()
        }

        private fun onFragmentStart() {
            if (turn != null) return
            turn = Turn(script.poll())
            emit(voiceActivity("ACTIVITY_START"))
            if (replyActive) bargeIn()
        }

        private fun onFragmentEnd() {
            val current = turn ?: return
            val segments = current.clip?.segments.orEmpty()
            if (current.nextSegment < segments.size) emit(inputTranscription(segments[current.nextSegment++]))
        }

        private fun onTurnEnd() {
            val current = turn ?: return
            turn = null
            val segments = current.clip?.segments.orEmpty()
            while (current.nextSegment < segments.size) emit(inputTranscription(segments[current.nextSegment++]))
            emit(voiceActivity("ACTIVITY_END"))
            val clip = current.clip
            if (clip == null) {
                unscriptedTurns.incrementAndGet()
                return
            }
            startReply(clip.transcript, long = clip.id.endsWith("-long"))
        }

        /** Barge-in: interrupted=true, then the interrupted turn completes so the next turn starts clean. */
        private fun bargeIn() {
            generation++
            replyJob?.cancel()
            replyActive = false
            emit(serverContent { put("interrupted", true) })
            emit(serverContent { put("turnComplete", true) })
        }

        /** Called under [lock]. A reply still running is interrupted first. */
        private fun startReply(transcript: String, long: Boolean) {
            if (replyActive) bargeIn()
            val mine = ++generation
            replyActive = true
            val text = E2EFixture.replyText(lang, transcript)
            val chunks = splitChunks(text, chunkCount)
            val totalMs = if (long) audioMsAfterLongTurn else audioMs
            replyJob = scope.launch {
                val start = SystemClock.elapsedRealtime()
                val count = (totalMs / AUDIO_CHUNK_MS).toInt()
                for (index in 0 until count) {
                    val due = start + index * AUDIO_CHUNK_MS - SystemClock.elapsedRealtime()
                    if (due > 0) delay(due)
                    synchronized(lock) {
                        if (generation != mine) return@launch
                        emit(
                            serverContent {
                                putJsonObject("modelTurn") {
                                    putJsonArray("parts") {
                                        addJsonObject {
                                            putJsonObject("inlineData") {
                                                put("data", toneChunk(index))
                                                put("mimeType", "audio/pcm;rate=${RealtimePCM.OUTPUT_RATE}")
                                            }
                                        }
                                    }
                                    put("role", "model")
                                }
                                chunks.getOrNull(index)?.let { putJsonObject("outputTranscription") { put("text", it) } }
                            },
                        )
                    }
                }
                delay(AUDIO_CHUNK_MS)
                synchronized(lock) {
                    if (generation != mine) return@launch
                    emit(serverContent { put("generationComplete", true) })
                    emit(serverContent { put("turnComplete", true) })
                    replyActive = false
                }
            }
        }

        private fun voiceActivity(type: String) = buildJsonObject {
            putJsonObject("voiceActivity") {
                put("audioOffset", String.format(Locale.US, "%.3fs", sessionUplinkMicros / 1_000_000.0))
                put("type", type)
            }
        }
    }

    private companion object {
        const val AUDIO_CHUNK_MS = 100L
        const val TONE_HZ = 440.0

        /** Peak of a sine whose RMS is -30 dBFS. */
        val TONE_AMPLITUDE = 32767.0 * Math.pow(10.0, -30.0 / 20.0) * sqrt(2.0)

        fun serverContent(body: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit) = buildJsonObject {
            putJsonObject("serverContent", body)
        }

        fun inputTranscription(text: String) = serverContent { putJsonObject("inputTranscription") { put("text", text) } }

        /** 100 ms of the 440 Hz reply tone, chunk [index] of the reply (phase continuous), base64 PCM16 LE. */
        fun toneChunk(index: Int): String {
            val samples = (RealtimePCM.OUTPUT_RATE * AUDIO_CHUNK_MS / 1000).toInt()
            val buffer = ByteBuffer.allocate(samples * 2).order(ByteOrder.LITTLE_ENDIAN)
            val origin = index.toLong() * samples
            for (n in 0 until samples) {
                val t = (origin + n).toDouble() / RealtimePCM.OUTPUT_RATE
                buffer.putShort((TONE_AMPLITUDE * sin(2 * Math.PI * TONE_HZ * t)).toInt().toShort())
            }
            return Base64.getEncoder().encodeToString(buffer.array())
        }

        /** [count] consecutive non-empty pieces of [text] (fewer when the text is shorter), by code point. */
        fun splitChunks(text: String, count: Int): List<String> {
            val points = text.codePoints().toArray()
            val pieces = minOf(count, points.size).coerceAtLeast(1)
            return List(pieces) { index ->
                val from = points.size * index / pieces
                val to = points.size * (index + 1) / pieces
                String(points, from, to - from)
            }.filter { it.isNotEmpty() }
        }

        fun dbfs(samples: ShortArray, offset: Int, size: Int): Double {
            var sum = 0.0
            for (index in offset until offset + size) {
                val value = samples[index] / 32768.0
                sum += value * value
            }
            val rms = sqrt(sum / size)
            return if (rms <= 0.0) -120.0 else 20 * log10(rms)
        }
    }
}

/**
 * Debug [RealtimeAudioIO] for E2E: the uplink is the injected corpus (16 kHz s16, 20 ms frames on the real clock,
 * silence whenever nothing is queued, so a clip is always followed by silence); the downlink is [downlink] as usual
 * (the production player in scenarios). Reports when reply audio starts so a barge-in step can start talking a fixed
 * delay into the reply.
 */
internal class InjectedPcmRealtimeAudio(private val downlink: RealtimeAudioIO) : RealtimeAudioIO by downlink {
    private val queued = ConcurrentLinkedQueue<ShortArray>()
    private var current: ShortArray? = null
    private var position = 0
    private val stopped = AtomicBoolean(false)
    private val capturing = AtomicBoolean(false)

    @Volatile
    private var captureTap: ((ShortArray) -> Unit)? = null
    private val itemsSeen = ConcurrentHashMap.newKeySet<String>()
    private val lastEnqueueAt = AtomicLong(0)
    private val replyListeners = ConcurrentLinkedQueue<(Long) -> Unit>()
    private val scheduler = Executors.newSingleThreadScheduledExecutor { Thread(it, "e2e-injected-scheduler").apply { isDaemon = true } }

    /** elapsedRealtime of every reply-audio start seen on the downlink, in order. */
    val replyAudioStarts = ConcurrentLinkedQueue<Long>()

    /** True while injected speech is still queued or playing on the uplink. */
    val speaking: Boolean get() = synchronized(queued) { current != null || queued.isNotEmpty() }

    /** Queues [samples] (16 kHz s16) on the uplink after whatever is already queued. */
    fun say(samples: ShortArray) {
        synchronized(queued) { queued.add(samples) }
    }

    /** Queues [samples] [delayMs] after the next reply audio starts on the downlink. */
    fun sayAfterNextReplyStart(samples: ShortArray, delayMs: Long) {
        replyListeners.add { startedAt ->
            val wait = (startedAt + delayMs - SystemClock.elapsedRealtime()).coerceAtLeast(0)
            scheduler.schedule({ say(samples) }, wait, TimeUnit.MILLISECONDS)
        }
    }

    override fun start(onFrame: (ByteArray) -> Unit, onInterruption: () -> Unit) =
        start(onFrame, onInterruption, RealtimePCM.OUTPUT_RATE)

    override fun start(onFrame: (ByteArray) -> Unit, onInterruption: () -> Unit, uplinkRateHz: Int) =
        start(onFrame, onInterruption, uplinkRateHz) { onInterruption() }

    override fun start(
        onFrame: (ByteArray) -> Unit,
        onInterruption: () -> Unit,
        uplinkRateHz: Int,
        onActivationFailed: (Throwable) -> Unit,
    ) {
        downlink.startPlayback(onInterruption, onActivationFailed)
        startCapture(onFrame, uplinkRateHz)
    }

    override fun startPlayback(onInterruption: () -> Unit, onActivationFailed: (Throwable) -> Unit) =
        downlink.startPlayback(onInterruption, onActivationFailed)

    override fun startCapture(onFrame: (ByteArray) -> Unit, uplinkRateHz: Int) {
        if (stopped.get() || !capturing.compareAndSet(false, true)) return
        Thread({ captureLoop(onFrame, uplinkRateHz) }, "e2e-injected-mic").apply { isDaemon = true }.start()
    }

    override fun setOnCaptureFrame(onFrame: (ShortArray) -> Unit) {
        captureTap = onFrame
    }

    override fun enqueue(pcm16: ByteArray, itemId: String) {
        val now = SystemClock.elapsedRealtime()
        val previous = lastEnqueueAt.getAndSet(now)
        // A new item, or audio after a pause longer than a reply's chunk spacing, is a new reply's first audio.
        if (itemsSeen.add(itemId) || now - previous > REPLY_GAP_MS) {
            replyAudioStarts.add(now)
            while (true) replyListeners.poll()?.invoke(now) ?: break
        }
        downlink.enqueue(pcm16, itemId)
    }

    override fun stop() {
        stopped.set(true)
        scheduler.shutdownNow()
        downlink.stop()
    }

    private fun captureLoop(onFrame: (ByteArray) -> Unit, rate: Int) {
        val start = SystemClock.elapsedRealtime()
        var index = 0L
        while (!stopped.get()) {
            val wait = start + (index + 1) * FRAME_MS - SystemClock.elapsedRealtime()
            if (wait > 0) {
                try {
                    Thread.sleep(wait)
                } catch (_: InterruptedException) {
                    return
                }
            }
            if (stopped.get()) return
            val frame = nextFrame()
            captureTap?.invoke(frame)
            onFrame(toBytes(if (rate == RealtimePCM.INPUT_RATE) frame else resample(frame, rate)))
            index++
        }
    }

    private fun nextFrame(): ShortArray = synchronized(queued) {
        val out = ShortArray(FRAME_SAMPLES)
        var filled = 0
        while (filled < FRAME_SAMPLES) {
            val clip = current ?: queued.poll()?.also {
                current = it
                position = 0
            } ?: break
            val take = minOf(FRAME_SAMPLES - filled, clip.size - position)
            System.arraycopy(clip, position, out, filled, take)
            filled += take
            position += take
            if (position >= clip.size) current = null
        }
        out
    }

    companion object {
        private const val FRAME_MS = 20L
        private const val FRAME_SAMPLES = (RealtimePCM.INPUT_RATE * FRAME_MS / 1000).toInt()
        private const val REPLY_GAP_MS = 500L

        private fun toBytes(samples: ShortArray): ByteArray {
            val buffer = ByteBuffer.allocate(samples.size * 2).order(ByteOrder.LITTLE_ENDIAN)
            buffer.asShortBuffer().put(samples)
            return buffer.array()
        }

        /** Linear resample of a 16 kHz frame to [rate]. */
        private fun resample(samples: ShortArray, rate: Int): ShortArray {
            val count = (samples.size.toLong() * rate / RealtimePCM.INPUT_RATE).toInt()
            return ShortArray(count) { index ->
                val at = index.toDouble() * RealtimePCM.INPUT_RATE / rate
                val low = at.toInt().coerceAtMost(samples.size - 1)
                val high = (low + 1).coerceAtMost(samples.size - 1)
                val fraction = at - low
                (samples[low] * (1 - fraction) + samples[high] * fraction).toInt().toShort()
            }
        }

        /** The production player for scenarios: downlink audio plays as in the app. */
        fun production(): InjectedPcmRealtimeAudio {
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            return InjectedPcmRealtimeAudio(AndroidRealtimeAudio(context, KoinPlatform.getKoin().get<AndroidAudioSessionCoordinator>()))
        }
    }
}

/** Speaks corpus clips: the fake server learns the clip text, the injected source gets its PCM, in the same order. */
internal class E2EVoice(private val server: FakeGeminiServer, private val audio: InjectedPcmRealtimeAudio) {
    fun speak(clipId: String): E2EClip {
        val clip = E2EFixture.clip(clipId)
        server.expect(clip)
        audio.say(E2ECorpus.samples(clip.id))
        return clip
    }

    /** The barge-in step: [clipId] starts [delayMs] after the next reply audio starts on the downlink. */
    fun speakAfterReplyStart(clipId: String, delayMs: Long = 1_000): E2EClip {
        val clip = E2EFixture.clip(clipId)
        server.expect(clip)
        audio.sayAfterNextReplyStart(E2ECorpus.samples(clip.id), delayMs)
        return clip
    }
}

/** Screenshots via UiAutomation into getExternalFilesDir("e2e-shots") (pulled by the run script). */
internal object E2EShots {
    val dir: File
        get() = requireNotNull(InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir("e2e-shots")) {
            "external files dir unavailable"
        }.apply { mkdirs() }

    fun capture(): Bitmap? = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()

    /** Writes [bitmap] as [name].png; returns the file, or null when there was nothing to write. */
    fun save(name: String, bitmap: Bitmap?): File? {
        bitmap ?: return null
        val file = File(dir, "$name.png")
        FileOutputStream(file).use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        return file
    }
}

/** One soft check of a step. */
internal data class E2ECheck(val ok: Boolean, val detail: String)

/** What a step block can do: soft checks and the step screenshot (taken once, reused for layout checks). */
internal class E2EStep {
    val checks = mutableListOf<E2ECheck>()
    private var shot: Bitmap? = null
    private var shotTaken = false

    fun check(ok: Boolean, detail: String) {
        checks += E2ECheck(ok, detail)
    }

    fun <T> expectEquals(what: String, expected: T, actual: T) =
        check(expected == actual, "$what: expected $expected, actual $actual")

    fun verdict(name: String, verdict: E2ECheck) = check(verdict.ok, "$name: ${verdict.detail}")

    /** The step screenshot; the same bitmap is saved when the step ends. */
    fun screen(): Bitmap? {
        if (!shotTaken) {
            shot = E2EShots.capture()
            shotTaken = true
        }
        return shot
    }
}

/**
 * Soft-assertion scenario (contract item 5): every step saves <scenario>-<NN>-<step>.png whether it passed or not,
 * checks are collected into results.json [{scenario, step, ok, detail}], and [finish] fails once at the end.
 */
internal class E2EScenario(private val id: String) {
    private val results = mutableListOf<Pair<String, E2ECheck>>()
    private var index = 0

    fun step(name: String, block: E2EStep.() -> Unit) {
        index++
        val label = String.format(Locale.US, "%02d-%s", index, name)
        val step = E2EStep()
        try {
            step.block()
        } catch (error: Throwable) {
            step.check(false, "step threw ${error::class.java.simpleName}: ${error.message}")
        }
        val saved = E2EShots.save("$id-$label", step.screen())
        if (saved == null) step.check(false, "screenshot unavailable")
        if (step.checks.isEmpty()) step.check(true, "no checks")
        step.checks.forEach { results += label to it }
    }

    /** Appends this scenario's results to results.json, then fails if any check failed. */
    fun finish() {
        E2EResults.append(id, results)
        val failed = results.filterNot { it.second.ok }
        if (failed.isNotEmpty()) {
            throw AssertionError("[$id] ${failed.size} check(s) failed:\n" + failed.joinToString("\n") { "${it.first}: ${it.second.detail}" })
        }
    }
}

/** results.json next to the screenshots, appended scenario by scenario within a run. */
internal object E2EResults {
    private val file: File get() = File(E2EShots.dir, "results.json")

    @Synchronized
    fun append(scenario: String, results: List<Pair<String, E2ECheck>>) {
        val existing = if (file.isFile) Json.parseToJsonElement(file.readText()).jsonArray else JsonArray(emptyList())
        val merged = buildJsonArray {
            existing.forEach { add(it) }
            results.forEach { (step, check) ->
                addJsonObject {
                    put("scenario", scenario)
                    put("step", step)
                    put("ok", check.ok)
                    put("detail", check.detail)
                }
            }
        }
        file.writeText(merged.toString())
    }
}

/**
 * The fixture's layout criteria (realtime-e2e.v1.json layout). Rects and the bitmap are in screen pixels (the
 * UiAutomation screenshot's coordinates).
 */
internal object E2ELayout {
    private const val ALIGN_TOLERANCE_DP = 2f
    private const val BAND_COLUMN_WIDTH_PX = 40
    private const val BAND_COLUMN_X_FRACTION = 0.04
    private const val BAND_MAX_LUMA_DELTA = 4

    /** homeIdleKeyboardPillCentredUnderOrb: centre X within 2 dp, the keyboard pill below the orb. */
    fun keyboardPillCentredUnderOrb(keyboard: Rect, orb: Rect, density: Float): E2ECheck {
        val deltaX = abs(keyboard.exactCenterX() - orb.exactCenterX())
        val tolerance = ALIGN_TOLERANCE_DP * density
        val below = keyboard.top > orb.bottom
        return E2ECheck(
            deltaX <= tolerance && below,
            "centre X delta ${"%.1f".format(Locale.US, deltaX)} px (<= ${"%.1f".format(Locale.US, tolerance)}), keyboard=$keyboard orb=$orb below=$below",
        )
    }

    /**
     * stageListBandContinuity: median-luma rows of a 40 px column at x = 4% from [listTop] to [bottom], |delta| <= 4.
     * [bottom] stops the column at the first composer control it crosses: a control edge is not a list / stage seam.
     */
    fun stageListBandContinuity(shot: Bitmap, listTop: Int, bottom: Int = shot.height): E2ECheck {
        val x = (shot.width * BAND_COLUMN_X_FRACTION).toInt()
        val width = minOf(BAND_COLUMN_WIDTH_PX, shot.width - x)
        val top = listTop.coerceIn(0, shot.height)
        val end = bottom.coerceIn(top, shot.height)
        if (width <= 0 || end - top < 2) return E2ECheck(false, "column out of bounds (x=$x top=$top end=$end)")
        val row = IntArray(width)
        var previous = -1
        var worst = 0
        var worstY = -1
        for (y in top until end) {
            shot.getPixels(row, 0, width, x, y, width, 1)
            val lumas = row.map { luma(it) }.sorted()
            val median = lumas[lumas.size / 2]
            if (previous >= 0) {
                val delta = abs(median - previous)
                if (delta > worst) {
                    worst = delta
                    worstY = y
                }
            }
            previous = median
        }
        return E2ECheck(worst <= BAND_MAX_LUMA_DELTA, "max adjacent-row luma delta $worst at y=$worstY (<= $BAND_MAX_LUMA_DELTA), column x=$x..${x + width} y=$top..$end")
    }

    private fun luma(color: Int): Int =
        (0.299 * Color.red(color) + 0.587 * Color.green(color) + 0.114 * Color.blue(color)).toInt()
}

private fun JsonObject.obj(key: String): JsonObject = this[key]!!.jsonObject

private fun JsonObject.string(key: String): String = this[key]!!.jsonPrimitive.content

private fun JsonObject.long(key: String): Long = this[key]!!.jsonPrimitive.content.toLong()

private fun JsonObject.double(key: String): Double = this[key]!!.jsonPrimitive.content.toDouble()
