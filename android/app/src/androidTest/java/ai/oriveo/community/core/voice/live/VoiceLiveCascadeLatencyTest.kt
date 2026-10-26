package ai.oriveo.community.core.voice.live

import android.content.Context
import android.os.Build
import android.speech.tts.TextToSpeech
import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.provider.GeminiService
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.voice.AndroidSystemSTTBackend
import ai.oriveo.community.core.voice.AndroidSystemSTTSessionBackend
import ai.oriveo.community.core.voice.ChunkPlayer
import ai.oriveo.community.core.voice.CloudSTTEngine
import ai.oriveo.community.core.voice.CloudSpeechEngine
import ai.oriveo.community.core.voice.DefaultReadAloudEngineFactory
import ai.oriveo.community.core.voice.MediaChunkPlayer
import ai.oriveo.community.core.voice.ReadAloudEngineSource
import ai.oriveo.community.core.voice.STTSegment
import ai.oriveo.community.core.voice.SpeechAudioCache
import ai.oriveo.community.core.voice.SpeechEngine
import ai.oriveo.community.core.voice.SystemSTTEngine
import ai.oriveo.community.core.voice.SystemSTTRecognizer
import ai.oriveo.community.core.voice.SystemSTTRoute
import ai.oriveo.community.core.voice.SystemSTTRouter
import ai.oriveo.community.core.voice.SystemSpeechEngine
import ai.oriveo.community.core.voice.VoiceDirection
import ai.oriveo.community.core.voice.VoiceSttEntry
import ai.oriveo.community.core.voice.VoiceTtsEntry
import ai.oriveo.community.core.voice.conversation.CloudConversationTts
import ai.oriveo.community.core.voice.conversation.ConversationAudio
import ai.oriveo.community.core.voice.conversation.ConversationAudioListener
import ai.oriveo.community.core.voice.conversation.ConversationRoute
import ai.oriveo.community.core.voice.conversation.ConversationStatusKey
import ai.oriveo.community.core.voice.conversation.ConversationStt
import ai.oriveo.community.core.voice.conversation.ConversationSttSource
import ai.oriveo.community.core.voice.conversation.ConversationTtsSource
import ai.oriveo.community.core.voice.conversation.ConversationTts
import ai.oriveo.community.core.voice.conversation.EarconKind
import ai.oriveo.community.core.voice.conversation.ReadAloudConversationTtsSource
import ai.oriveo.community.core.voice.conversation.SpeakerBargeInMemory
import ai.oriveo.community.core.voice.conversation.SystemConversationTts
import ai.oriveo.community.core.voice.conversation.TtsOutcome
import ai.oriveo.community.core.voice.conversation.VoiceConversationChatPort
import ai.oriveo.community.core.voice.conversation.VoiceConversationController
import ai.oriveo.community.core.voice.conversation.VoiceConversationEnvironment
import ai.oriveo.community.core.voice.conversation.VoiceConversationForeground
import ai.oriveo.community.core.voice.conversation.VoiceReplyEvent
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import java.io.File
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Interceptor
import okhttp3.Response
import okhttp3.ResponseBody.Companion.asResponseBody
import okio.Buffer
import okio.ForwardingSource
import okio.buffer
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.koin.mp.KoinPlatform

/**
 * Voice live, group `latency`: the production [VoiceConversationController] with real cloud dictation (OpenAI
 * gpt-transcribe via [CloudSTTEngine]), a real chat leg ([GeminiService] gemini-2.5-flash-lite) and real cloud read
 * aloud ([ReadAloudConversationTtsSource] + [CloudConversationTts], OpenAI default voice). An injected
 * [ConversationAudio] paces 20 ms frames (speech level for each recorded turn clip, silence otherwise) into the
 * production VAD; its turn export encodes turn-k-16k.wav through the production AAC writer.
 * Cascade latency (contract item 7) = production VAD speechEnd (endTurn) → first sentence starts playing, + 600 ms.
 * Turns 1..5 run twice (two conversations) = 10 samples; p50 / p95 nearest rank against 3.0 / 6.0 s, over the line is
 * reported, not failed.
 *
 * [systemGroup]: same rig with system dictation ([SystemSTTEngine] Pipe session: the turn file is decoded and fed
 * through EXTRA_AUDIO_SOURCE) and system read aloud ([DefaultReadAloudEngineFactory.system] → [SystemConversationTts]);
 * first sound = the system voice's speak for the first reply sentence. Lines 2.0 / 4.0 s. When the emulator has no
 * pipe-capable recognizer or no TTS engine (or neither ever produced a turn), the reason is printed, the summary
 * reads unavailable, and the test does not fail.
 */
@RunWith(AndroidJUnit4::class)
class VoiceLiveCascadeLatencyTest {
    private val httpClient: HttpClient get() = KoinPlatform.getKoin().get()
    private val context get() = VoiceLive.context

    private data class Turn(val index: Int, val file: String, val durationSec: Double)

    private class Sample(val ok: Boolean, val ms: Long?, val hostMs: Long? = null)

    @Test
    fun cascadeLatency() {
        if (!VoiceLive.enabled(GROUP)) return
        val catalog = VoiceLive.catalog()
        val sttEntry = catalog.entry(ProviderKind.OpenAI, VoiceDirection.Stt, STT_MODEL) as? VoiceSttEntry
        assertNotNull("catalog has no stt entry $STT_MODEL", sttEntry)
        val ttsEntry: VoiceTtsEntry? = catalog.provider(ProviderKind.OpenAI).tts.firstOrNull { it.isDefault }
        assertNotNull("catalog has no default openAI tts entry", ttsEntry)
        val openAIKey = VoiceLive.key("openAI") ?: return fail("missing key openAI in voice-live/keys.json")
        val geminiKey = VoiceLive.key("gemini") ?: return fail("missing key gemini in voice-live/keys.json")
        val turns = turns()
        assertTrue("manifest turns", turns.size == TURNS)

        val budget = VoiceLive.Budget(LIMIT_USD)
        val provider = "openAI+gemini+openAI"
        val model = "$STT_MODEL+$CHAT_MODEL+${ttsEntry!!.model}"
        val samples = mutableListOf<Sample>()
        var overBudget = false
        var spentUsd = 0.0

        passes@ for (pass in 1..PASSES) {
            val run = PassRig(geminiKey, pass) { probe -> cloudLegs(sttEntry!!, ttsEntry, openAIKey, pass, probe) }
            try {
                run.start()
                for (turn in turns) {
                    // Reserve an upper bound before sending: STT seconds plus a reply of RESERVE_REPLY_CHARS.
                    val reserve = VoiceLive.sttUsd(STT_MODEL, turn.durationSec) + VoiceLive.ttsUsd("x".repeat(RESERVE_REPLY_CHARS))
                    if (!budget.reserve(reserve)) {
                        VoiceLive.evidence(ITEM, provider, model, false, null, "pass=$pass turn=${turn.index} budget exceeded", 0.0)
                        overBudget = true
                        break@passes
                    }
                    val sample = run.turn(turn)
                    val est = VoiceLive.sttUsd(STT_MODEL, turn.durationSec) + VoiceLive.ttsUsd("x".repeat(sample.spokenChars))
                    spentUsd += est
                    VoiceLive.evidence(ITEM, provider, model, sample.ok, sample.ms, sample.detail, est)
                    samples += Sample(sample.ok, sample.ms, sample.hostMs)
                }
            } finally {
                run.close()
            }
        }

        val hosts = samples.filter { it.ok }.mapNotNull { it.hostMs }.sorted()
        val hostP50 = nearestRank(hosts, 0.50)
        val hostP95 = nearestRank(hosts, 0.95)
        val latencies = samples.filter { it.ok }.mapNotNull { it.ms }.sorted()
        val p50 = nearestRank(latencies, 0.50)
        val p95 = nearestRank(latencies, 0.95)
        val okCount = samples.count { it.ok }
        VoiceLive.evidence(
            "cascade-summary",
            provider,
            model,
            okCount > 0,
            p50,
            "samples=${samples.size} ok=$okCount p50=${p50 ?: "-"} p95=${p95 ?: "-"} " +
                "lineP50=$LINE_P50_MS lineP95=$LINE_P95_MS " +
                "overP50=${p50?.let { it > LINE_P50_MS } ?: "-"} overP95=${p95?.let { it > LINE_P95_MS } ?: "-"} " +
                "hostP50Ms=${hostP50 ?: "-"} hostP95Ms=${hostP95 ?: "-"} hostLineMs=$HOST_LINE_MS " +
                "hostWithin=${hostP95?.let { it <= HOST_LINE_MS } ?: "-"}",
            spentUsd,
        )
        assertTrue("cascade: estimated spend would exceed $LIMIT_USD USD", !overBudget)
        assertTrue("cascade $model: no ok sample", okCount > 0)
    }

    @Test
    fun systemGroup() {
        if (!VoiceLive.enabled(GROUP)) return
        val geminiKey = VoiceLive.key("gemini") ?: return fail("missing key gemini in voice-live/keys.json")
        val turns = turns()
        assertTrue("manifest turns", turns.size == TURNS)
        val provider = "system+gemini+system"
        val model = "system+$CHAT_MODEL+system"

        // Legs that cannot start on this emulator: print why, report unavailable, do not fail.
        val route = systemPipeRoute()
        val ttsReady = systemTtsReady()
        val unavailable = listOfNotNull(
            route.second.takeIf { route.first == null },
            "systemTts=initFailed".takeIf { !ttsReady },
        )
        if (unavailable.isNotEmpty()) {
            systemSummary(provider, model, emptyList(), "unavailable ${unavailable.joinToString(" ")}")
            return
        }

        val samples = mutableListOf<Sample>()
        var chatFailed = false
        var silentTurns = 0
        passes@ for (pass in 1..PASSES) {
            val run = PassRig(geminiKey, pass) { probe -> systemLegs(route.first!!, pass, probe) }
            try {
                run.start()
                for (turn in turns) {
                    val sample = run.turn(turn)
                    // System legs and the chat text leg are not priced by the contract (item 6): 0.
                    VoiceLive.evidence(ITEM, provider, model, sample.ok, sample.ms, "${sample.detail} ${route.second}", 0.0)
                    samples += Sample(sample.ok, sample.ms)
                    if (sample.chatFailed) chatFailed = true
                    // The recognizer never produced text for the first turns: it did not come up; stop early.
                    silentTurns = if (sample.userText) 0 else silentTurns + 1
                    if (samples.none { it.ok } && silentTurns >= SILENT_TURNS_LIMIT) break@passes
                }
            } finally {
                run.close()
            }
        }
        val okCount = samples.count { it.ok }
        val note = if (okCount == 0 && !chatFailed) "unavailable systemStt=noText ${route.second}" else route.second
        systemSummary(provider, model, samples, note)
        assertTrue("cascade $model: no ok sample (chat leg failed)", okCount > 0 || !chatFailed)
    }

    private fun systemSummary(provider: String, model: String, samples: List<Sample>, note: String) {
        val latencies = samples.filter { it.ok }.mapNotNull { it.ms }.sorted()
        val p50 = nearestRank(latencies, 0.50)
        val p95 = nearestRank(latencies, 0.95)
        val okCount = samples.count { it.ok }
        VoiceLive.evidence(
            "cascade-summary",
            provider,
            model,
            okCount > 0,
            p50,
            "samples=${samples.size} ok=$okCount p50=${p50 ?: "-"} p95=${p95 ?: "-"} " +
                "lineP50=$SYSTEM_LINE_P50_MS lineP95=$SYSTEM_LINE_P95_MS " +
                "overP50=${p50?.let { it > SYSTEM_LINE_P50_MS } ?: "-"} overP95=${p95?.let { it > SYSTEM_LINE_P95_MS } ?: "-"} $note",
            0.0,
        )
    }

    /**
     * Gives the production en-US model download one chance (as SystemSTTPipeInstrumentedTest), then the production
     * route when it is a pipe; otherwise Pipe(DEFAULT) when a recognition service exists on sdk 33+ (same bypass);
     * null = no pipe-capable recognizer. Second = diagnosis.
     */
    private fun systemPipeRoute(): Pair<SystemSTTRoute.Pipe?, String> = runBlocking {
        val backend = AndroidSystemSTTBackend(context)
        backend.triggerModelDownload(SystemSTTRecognizer.ON_DEVICE, SYSTEM_LANGUAGE)
        val deadline = SystemClock.uptimeMillis() + MODEL_WAIT_MS
        var installed = false
        while (!installed && SystemClock.uptimeMillis() < deadline) {
            // The recognition service may die mid-download without calling back: bound every probe.
            val support = withTimeoutOrNull(CALLBACK_TIMEOUT_MS) { backend.checkSupport(SystemSTTRecognizer.ON_DEVICE, SYSTEM_LANGUAGE) }
            installed = support != null && SystemSTTRouter.matchLanguage(SYSTEM_LANGUAGE, support.installedOnDevice) != null
            if (!installed) delay(minOf(MODEL_POLL_MS, maxOf(deadline - SystemClock.uptimeMillis(), 0)))
        }
        val routed = withTimeoutOrNull(CALLBACK_TIMEOUT_MS) { SystemSTTRouter(backend).route(SYSTEM_LANGUAGE) }
        val defaultAvailable = backend.isRecognitionAvailable()
        val pipe = when {
            routed is SystemSTTRoute.Pipe -> routed
            defaultAvailable && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU ->
                SystemSTTRoute.Pipe(SystemSTTRecognizer.DEFAULT, SYSTEM_LANGUAGE)
            else -> null
        }
        pipe to "systemStt=${pipe?.recognizer ?: "none"} onDeviceModel=$installed routed=${routed ?: "timeout"} default=$defaultAvailable sdk=${Build.VERSION.SDK_INT}"
    }

    /** One TextToSpeech init: the system voice can start on this device. */
    private fun systemTtsReady(): Boolean {
        val done = CountDownLatch(1)
        val ok = AtomicBoolean(false)
        var tts: TextToSpeech? = null
        onMain {
            tts = TextToSpeech(context) { status ->
                ok.set(status == TextToSpeech.SUCCESS)
                done.countDown()
            }
        }
        val returned = done.await(TTS_INIT_TIMEOUT_SEC, TimeUnit.SECONDS)
        onMain { tts?.shutdown() }
        return returned && ok.get()
    }

    /** What one turn observed besides the chat leg: first sound, spoken characters, the first off-path event. */
    private class Probe {
        val firstSoundAt = AtomicLong(-1)
        val spokenChars = AtomicInteger(0)
        val offPath = AtomicReference<String?>(null)

        /** Cloud STT / TTS requests of this turn, in send order (filled by [RequestTimer]). */
        val requests = ConcurrentLinkedQueue<TimedRequest>()

        fun reset() {
            firstSoundAt.set(-1)
            spokenChars.set(0)
            offPath.set(null)
            requests.clear()
        }
    }

    private enum class RequestKind { STT, TTS }

    /** One provider request: sent → response body fully read or the call failed; text = TTS `input` (null for STT). */
    private class TimedRequest(val kind: RequestKind, val startAt: Long, val text: String?) {
        val endAt = AtomicLong(-1)

        val done get() = endAt.get() >= 0

        val ms get() = endAt.get() - startAt

        fun end() {
            endAt.compareAndSet(-1, SystemClock.elapsedRealtime())
        }
    }

    /** OkHttp interceptor on the cloud legs' client: times STT / TTS requests by URL path until the body is read. */
    private class RequestTimer(private val probe: Probe) : Interceptor {
        override fun intercept(chain: Interceptor.Chain): Response {
            val request = chain.request()
            val path = request.url.encodedPath
            val kind = when {
                path.endsWith(STT_PATH) -> RequestKind.STT
                path.endsWith(TTS_PATH) -> RequestKind.TTS
                else -> return chain.proceed(request)
            }
            val text = if (kind == RequestKind.TTS) speechInput(request) else null
            val timed = TimedRequest(kind, SystemClock.elapsedRealtime(), text)
            probe.requests += timed
            val response = try {
                chain.proceed(request)
            } catch (error: Exception) {
                timed.end()
                throw error
            }
            val body = response.body
            val source = object : ForwardingSource(body.source()) {
                override fun read(sink: Buffer, byteCount: Long): Long =
                    super.read(sink, byteCount).also { if (it == -1L) timed.end() }

                override fun close() {
                    timed.end()
                    super.close()
                }
            }.buffer()
            return response.newBuilder().body(source.asResponseBody(body.contentType(), body.contentLength())).build()
        }

        /** The sentence a TTS request synthesizes: the JSON body's `input`. */
        private fun speechInput(request: okhttp3.Request): String? = runCatching {
            val buffer = Buffer()
            request.body?.writeTo(buffer)
            json.parseToJsonElement(buffer.readUtf8()).jsonObject["input"]?.jsonPrimitive?.content
        }.getOrNull()
    }

    private class Legs(val stt: ConversationSttSource, val tts: ConversationTtsSource, val cleanup: () -> Unit)

    /** Same engine settings as the production client (NetworkModule), plus [RequestTimer]. */
    private fun timedClient(probe: Probe): HttpClient = HttpClient(OkHttp) {
        engine {
            config {
                retryOnConnectionFailure(true)
                connectTimeout(20, TimeUnit.SECONDS)
                readTimeout(180, TimeUnit.SECONDS)
                writeTimeout(60, TimeUnit.SECONDS)
            }
            addInterceptor(RequestTimer(probe))
        }
    }

    /** OpenAI gpt-transcribe + OpenAI default voice; any system-voice use is off-path. */
    private fun cloudLegs(sttEntry: VoiceSttEntry, ttsEntry: VoiceTtsEntry, openAIKey: String, pass: Int, probe: Probe): Legs {
        // Fresh cache per pass so every reply is a real TTS request.
        val cacheDir = File(context.cacheDir, "voice-live-cascade-tts-$pass").apply { deleteRecursively() }
        val timed = timedClient(probe)
        val cloudEngine = DefaultReadAloudEngineFactory(
            httpClient = timed,
            cache = SpeechAudioCache(cacheDir),
            systemEngine = NoopSpeechEngine(),
            speechRate = { 1.0 },
        ).cloud(ttsEntry, ProviderKind.OpenAI, OPENAI_BASE, openAIKey, null, "OpenAI") as CloudSpeechEngine
        val sttEngine = CloudSTTEngine(timed, sttEntry, OPENAI_BASE, openAIKey, File(context.cacheDir, "voice-live-cascade-stt"))
        return Legs(
            stt = { ConversationStt.FromFile(sttEngine, STT_LANGUAGE, ProviderKind.OpenAI.rawValue) },
            tts = ReadAloudConversationTtsSource(
                readAloud = ReadAloudEngineSource.fixed(cloudEngine),
                system = NoopSystemTts(probe),
                cloud = { engine ->
                    CountingTts(
                        CloudConversationTts(engine, { Locale.US }, playerFactory = { FirstSoundPlayer(MediaChunkPlayer(VOICE_ATTRIBUTES), probe.firstSoundAt) }),
                        probe.spokenChars,
                    )
                },
            ),
            cleanup = {
                timed.close()
                cacheDir.deleteRecursively()
            },
        )
    }

    /** System dictation over the pipe + the read-aloud factory's system branch speaking through SystemConversationTts. */
    private fun systemLegs(route: SystemSTTRoute.Pipe, pass: Int, probe: Probe): Legs {
        val sttEngine = SystemSTTEngine(AndroidSystemSTTSessionBackend(context), routeFor = { route })
        val systemEngine = DefaultReadAloudEngineFactory(
            httpClient = httpClient,
            cache = SpeechAudioCache(File(context.cacheDir, "voice-live-cascade-system-cache")),
            systemEngine = SystemSpeechEngine(context, speechRate = { 1.0 }),
            speechRate = { 1.0 },
        ).system()
        val tempDir = File(context.cacheDir, "voice-live-cascade-system-tts-$pass").apply { deleteRecursively() }
        val voice = FirstSpeakTts(SystemConversationTts(context, speechRate = { 1.0 }, localeFor = { Locale.US }, tempDir = tempDir), probe)
        return Legs(
            stt = { ConversationStt.FromFile(sttEngine, route.languageTag) },
            tts = ReadAloudConversationTtsSource(
                readAloud = ReadAloudEngineSource.fixed(systemEngine),
                system = voice,
                cloud = { error("system group picked a cloud engine") },
            ),
            cleanup = { tempDir.deleteRecursively() },
        )
    }

    private class TurnSample(
        val ok: Boolean,
        val ms: Long?,
        val detail: String,
        val spokenChars: Int,
        val chatFailed: Boolean,
        val userText: Boolean,
        val hostMs: Long?,
    )

    /** One conversation: production controller + real legs; turns are driven one after another. */
    private inner class PassRig(
        geminiKey: String,
        private val pass: Int,
        legsFor: (Probe) -> Legs,
    ) {
        private val chatScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        private val audio = InjectedAudio()
        private val chat = GeminiChat(geminiKey, chatScope)
        private val probe = Probe()
        private val legs = legsFor(probe)

        val controller = VoiceConversationController(
            audio = audio,
            sttSource = legs.stt,
            ttsSource = legs.tts,
            foreground = object : VoiceConversationForeground {
                override suspend fun awaitStarted(): Boolean = true

                override val endRequests: Flow<Unit> = emptyFlow()

                override fun stop() = Unit
            },
            environment = object : VoiceConversationEnvironment {
                override fun stopReadAloud() = Unit
            },
            memory = SpeakerBargeInMemory({ context.getSharedPreferences(MEMORY_PREFS, Context.MODE_PRIVATE) }),
            prompt = { which -> "$PROMPT_PREFIX$which" },
        )

        fun start() {
            onMain { controller.start(chat) }
            check(awaitListening(START_TIMEOUT_MS)) { "conversation did not reach listening" }
        }

        fun turn(turn: Turn): TurnSample {
            val wav = File(VoiceLive.audioDir, turn.file)
            probe.reset()
            chat.resetTurn()
            // Let the listening state settle (guards, noise floor) before the next utterance.
            Thread.sleep(SETTLE_MS)
            audio.resetTurn(wav)
            audio.speak((turn.durationSec * 1000 / FRAME_MS).toInt())
            val terminal = chat.terminal.await(TURN_TIMEOUT_SEC, TimeUnit.SECONDS) || probe.offPath.get() != null
            val listening = terminal && awaitListening(TURN_TIMEOUT_SEC * 1000)
            val speechEnd = audio.speechEndAt.get().takeIf { it >= 0 }
            val sound = probe.firstSoundAt.get().takeIf { it >= 0 }
            val offPath = probe.offPath.get()
            val ms = if (speechEnd != null && sound != null) sound - speechEnd + VAD_END_SILENCE_MS else null
            val sent = chat.sentAt.get().takeIf { it >= 0 }
            val firstToken = chat.firstTokenAt.get().takeIf { it >= 0 }
            val reply = chat.lastReply
            val ok = ms != null && listening && offPath == null && chat.failure == null &&
                !chat.lastUser.isNullOrBlank() && !reply.isNullOrBlank()
            val split = split(ms, sent, sound)
            val detail = buildString {
                append("pass=$pass turn=${turn.index}")
                append(" sttDoneMs=${rel(sent, speechEnd)} firstTokenMs=${rel(firstToken, speechEnd)}")
                append(" firstSoundMs=${rel(sound, speechEnd)} chars=${probe.spokenChars.get()}")
                append(" sttReqMs=${split.stt ?: "-"} chatMs=${split.chat ?: "-"} ttsReqMs=${split.tts ?: "-"} hostMs=${split.host ?: "-"}")
                append(" user=${chat.lastUser.orEmpty().take(TEXT_LIMIT)} reply=${reply.orEmpty().take(TEXT_LIMIT)}")
                offPath?.let { append(" error=$it") }
                chat.failure?.let { append(" error=chat:$it") }
                if (!terminal) append(" error=timeout")
                if (terminal && !listening) append(" error=notListening")
            }
            return TurnSample(ok, ms, detail, probe.spokenChars.get(), chat.failure != null, !chat.lastUser.isNullOrBlank(), split.host)
        }

        /**
         * Request-level split of one sample. stt = STT requests sent → body read; chat = chat.send → the delta whose
         * accumulated text first contains the first TTS request's sentence (not found → null); tts = union of all TTS
         * request intervals clipped to [first TTS request sent, first sound] (chunks and retries count, overlaps once);
         * host = ms − VAD end silence − the three. Any part missing, or first sound before the first TTS request
         * started (tts and host), → null.
         */
        private fun split(ms: Long?, sent: Long?, sound: Long?): Split {
            val requests = probe.requests.toList()
            val stts = requests.filter { it.kind == RequestKind.STT }
            val stt = stts.takeIf { list -> list.isNotEmpty() && list.all { it.done } }?.sumOf { it.ms }
            val ttss = requests.filter { it.kind == RequestKind.TTS }
            val first = ttss.minByOrNull { it.startAt }
            val sentence = first?.text?.trim()?.takeIf { it.isNotEmpty() }
            val chatMs = if (sent != null && sentence != null) {
                chat.deltas.firstOrNull { it.second.trim().contains(sentence) }?.let { it.first - sent }
            } else {
                null
            }
            val tts = if (sound != null && first != null && sound >= first.startAt) union(ttss, first.startAt, sound) else null
            val host = if (ms != null && stt != null && chatMs != null && tts != null) ms - VAD_END_SILENCE_MS - stt - chatMs - tts else null
            return Split(stt, chatMs, tts, host)
        }

        /** Union length of the requests' [start, end] clipped to [from, to]; an unfinished request runs to [to]. */
        private fun union(requests: List<TimedRequest>, from: Long, to: Long): Long {
            val spans = requests.map { maxOf(it.startAt, from) to minOf(if (it.done) it.endAt.get() else to, to) }
                .filter { it.second > it.first }
                .sortedBy { it.first }
            var total = 0L
            var start = -1L
            var end = -1L
            for ((s, e) in spans) {
                if (start < 0 || s > end) {
                    if (start >= 0) total += end - start
                    start = s
                    end = e
                } else {
                    end = maxOf(end, e)
                }
            }
            if (start >= 0) total += end - start
            return total
        }

        fun close() {
            runCatching { onMain { controller.end() } }
            awaitInactive()
            audio.close()
            chatScope.cancel()
            legs.cleanup()
        }

        private fun awaitListening(timeoutMs: Long): Boolean = runBlocking {
            withTimeoutOrNull(timeoutMs) { controller.statusKey.first { it == ConversationStatusKey.LISTENING } } != null
        }

        private fun awaitInactive() = runBlocking {
            withTimeoutOrNull(END_TIMEOUT_MS) { controller.active.first { !it } }
        }
    }

    private class Split(val stt: Long?, val chat: Long?, val tts: Long?, val host: Long?)

    /** Frames every 20 ms from a pacing thread; speech level for the requested frame count, silence otherwise. */
    private class InjectedAudio : ConversationAudio {
        override val echoCancellerAvailable: Boolean = false
        override val route: ConversationRoute = ConversationRoute.SPEAKER
        val speechEndAt = AtomicLong(-1)

        @Volatile private var listener: ConversationAudioListener? = null

        @Volatile private var muted = false

        @Volatile private var paused = false

        @Volatile private var turnOpen = false

        @Volatile private var wav: File? = null
        private val speechFrames = AtomicInteger(0)
        private val running = AtomicBoolean(false)
        private var pacer: Thread? = null
        private val slotDir = File(VoiceLive.context.cacheDir, "voice-live-cascade-slot")

        override fun open(listener: ConversationAudioListener, capture: Boolean) {
            this.listener = listener
            running.set(true)
            pacer = Thread({ pace() }, "voice-live-cascade-frames").apply { start() }
        }

        private fun pace() {
            var index = 0L
            var next = SystemClock.elapsedRealtime()
            while (running.get()) {
                val speaking = speechFrames.getAndUpdate { if (it > 0) it - 1 else 0 } > 0
                if (!muted && !paused) listener?.onFrame(index++, if (speaking) SPEECH_DB else SILENCE_DB)
                next += FRAME_MS
                val wait = next - SystemClock.elapsedRealtime()
                if (wait > 0) Thread.sleep(wait)
            }
        }

        fun resetTurn(file: File) {
            wav = file
            speechEndAt.set(-1)
        }

        fun speak(frames: Int) = speechFrames.set(frames)

        override fun close() {
            running.set(false)
            pacer?.join(PACER_JOIN_MS)
            pacer = null
            listener = null
        }

        override fun setMuted(muted: Boolean) {
            this.muted = muted
        }

        override fun setCapturePaused(paused: Boolean) {
            this.paused = paused
        }

        override fun beginTurn(prerollFrame: Long) {
            turnOpen = true
        }

        /** Production VAD speechEnd: the user is done speaking. */
        override fun endTurn(endFrame: Long): ShortArray? {
            if (!turnOpen) return null
            turnOpen = false
            speechEndAt.compareAndSet(-1, SystemClock.elapsedRealtime())
            return wav?.let { VoiceLive.readWav(it) }
        }

        override fun cancelTurn() {
            turnOpen = false
        }

        /** The recorded clip through the production AAC writer (the samples are that clip). */
        override suspend fun writeTurn(samples: ShortArray): STTSegment? = withContext(Dispatchers.IO) {
            val file = wav ?: return@withContext null
            runCatching { VoiceLive.recordSegment(file, slotDir) }.getOrNull()
        }

        override suspend fun playEarcon(kind: EarconKind) = Unit
    }

    /** Chat leg: production GeminiService stream with the conversation history; events of the current reply only. */
    private inner class GeminiChat(private val apiKey: String, private val scope: CoroutineScope) : VoiceConversationChatPort {
        private val service = GeminiService(httpClient, json, TransportRegistry(json))
        private val flow = MutableSharedFlow<VoiceReplyEvent>(extraBufferCapacity = 256)
        private val history = mutableListOf<ChatMessage>()
        private var job: Job? = null

        override val replies: Flow<VoiceReplyEvent> = flow

        @Volatile var terminal = CountDownLatch(1)
            private set
        val sentAt = AtomicLong(-1)
        val firstTokenAt = AtomicLong(-1)

        /** Every non-empty delta of the current reply: arrival time and the accumulated text at that moment. */
        val deltas = ConcurrentLinkedQueue<Pair<Long, String>>()

        @Volatile var lastUser: String? = null
            private set

        @Volatile var lastReply: String? = null
            private set

        @Volatile var failure: String? = null
            private set

        fun resetTurn() {
            terminal = CountDownLatch(1)
            sentAt.set(-1)
            firstTokenAt.set(-1)
            deltas.clear()
            lastUser = null
            lastReply = null
            failure = null
        }

        override suspend fun send(text: String): Boolean {
            sentAt.compareAndSet(-1, SystemClock.elapsedRealtime())
            lastUser = text
            val latch = terminal
            synchronized(history) { history += message(ChatRole.User, text) }
            val messages = synchronized(history) { history.toList() }
            job = scope.launch {
                var full = ""
                try {
                    service.sendMessageStream(
                        apiKey, CHAT_MODEL, messages, null, false, ReasoningMode.Automatic, false, ChatRequestOptions(),
                    ).collect { event ->
                        if (event is StreamEvent.Delta && event.text.isNotEmpty()) {
                            val now = SystemClock.elapsedRealtime()
                            firstTokenAt.compareAndSet(-1, now)
                            full += event.text
                            deltas += now to full
                            flow.emit(VoiceReplyEvent.Text(full))
                        }
                    }
                    lastReply = full
                    synchronized(history) { history += message(ChatRole.Assistant, full) }
                    flow.emit(VoiceReplyEvent.Completed())
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Exception) {
                    // Class name only: messages may carry request URLs.
                    failure = error::class.simpleName ?: "error"
                    flow.emit(VoiceReplyEvent.Failed(failure!!))
                } finally {
                    latch.countDown()
                }
            }
            return true
        }

        override fun cancel() {
            job?.cancel()
            job = null
        }

        private fun message(role: ChatRole, text: String) = ChatMessage(
            id = UUID.randomUUID().toString(),
            role = role,
            text = text,
            providerKind = ProviderKind.Gemini,
            providerName = "Gemini",
            modelID = CHAT_MODEL,
            modelName = CHAT_MODEL,
            state = ChatMessageState.Delivered,
        )
    }

    /** Marks the first chunk handed to the player (the first sentence starts playing). */
    private class FirstSoundPlayer(private val delegate: ChunkPlayer, private val firstSoundAt: AtomicLong) : ChunkPlayer {
        override suspend fun play(file: File): Boolean {
            firstSoundAt.compareAndSet(-1, SystemClock.elapsedRealtime())
            return delegate.play(file)
        }

        override fun stop() = delegate.stop()
    }

    /** Counts spoken characters for the TTS price (contract item 6). */
    private class CountingTts(private val delegate: ConversationTts, private val chars: AtomicInteger) : ConversationTts {
        override val isCloud: Boolean get() = delegate.isCloud

        override suspend fun speak(text: String, onLevel: (Float) -> Unit): TtsOutcome {
            chars.addAndGet(text.length)
            return delegate.speak(text, onLevel)
        }
    }

    /** Stands in for the system voice so a cloud failure or a prompt shows up instead of being masked. */
    private class NoopSystemTts(private val probe: Probe) : ConversationTts {
        override val isCloud: Boolean = false

        override suspend fun speak(text: String, onLevel: (Float) -> Unit): TtsOutcome {
            probe.offPath.compareAndSet(null, "systemVoice")
            return TtsOutcome.DONE
        }
    }

    /**
     * System group voice: a reply sentence's speak marks the first sound and goes to the system voice; a prompt
     * (controller cue, e.g. nothing recognized) is off-path and not spoken; a failed sentence is off-path.
     */
    private class FirstSpeakTts(private val delegate: ConversationTts, private val probe: Probe) : ConversationTts {
        override val isCloud: Boolean get() = delegate.isCloud

        override suspend fun speak(text: String, onLevel: (Float) -> Unit): TtsOutcome {
            if (text.startsWith(PROMPT_PREFIX)) {
                probe.offPath.compareAndSet(null, "prompt:${text.removePrefix(PROMPT_PREFIX)}")
                return TtsOutcome.DONE
            }
            probe.firstSoundAt.compareAndSet(-1, SystemClock.elapsedRealtime())
            probe.spokenChars.addAndGet(text.length)
            return delegate.speak(text, onLevel).also {
                if (it == TtsOutcome.FAILED) probe.offPath.compareAndSet(null, "systemTts:failed")
            }
        }
    }

    private class NoopSpeechEngine : SpeechEngine {
        override val engineName: String = "system"

        override fun speak(utterances: List<String>, locale: Locale, listener: SpeechEngine.Listener) = listener.onDoneAll()

        override fun stop() = Unit
    }

    private fun turns(): List<Turn> {
        val manifest = Json.parseToJsonElement(File(VoiceLive.audioDir, "manifest.json").readText()).jsonObject
        return manifest.getValue("turns").jsonArray.map {
            val obj = it.jsonObject
            Turn(
                index = obj.getValue("index").jsonPrimitive.content.toInt(),
                file = obj.getValue("file16k").jsonPrimitive.content,
                durationSec = obj.getValue("durationSec").jsonPrimitive.content.toDouble(),
            )
        }.sortedBy { it.index }
    }

    private fun onMain(block: () -> Unit) = InstrumentationRegistry.getInstrumentation().runOnMainSync(block)

    private fun rel(at: Long?, from: Long?): String = if (at != null && from != null) (at - from).toString() else "-"

    private fun nearestRank(sorted: List<Long>, p: Double): Long? {
        if (sorted.isEmpty()) return null
        val rank = kotlin.math.ceil(p * sorted.size).toInt().coerceIn(1, sorted.size)
        return sorted[rank - 1]
    }

    private companion object {
        const val GROUP = "latency"
        const val ITEM = "cascade"
        const val LIMIT_USD = 0.05
        const val TURNS = 5
        const val PASSES = 2
        const val STT_MODEL = "gpt-transcribe"
        const val STT_LANGUAGE = "en"
        const val CHAT_MODEL = "gemini-2.5-flash-lite"
        const val OPENAI_BASE = "https://api.openai.com/v1"
        const val RESERVE_REPLY_CHARS = 200
        const val FRAME_MS = 20L
        const val SPEECH_DB = -20.0
        const val SILENCE_DB = -60.0

        /** VAD end silence (VoiceConversationConstants.VAD_END_SILENCE_MS): speechEnd fires this long after the voice stops. */
        const val VAD_END_SILENCE_MS = 600L
        const val LINE_P50_MS = 3_000L
        const val LINE_P95_MS = 6_000L

        /** Host's own overhead line (ms − 600 − provider request time). */
        const val HOST_LINE_MS = 300L
        const val STT_PATH = "/audio/transcriptions"
        const val TTS_PATH = "/audio/speech"
        const val START_TIMEOUT_MS = 20_000L
        const val TURN_TIMEOUT_SEC = 90L
        const val END_TIMEOUT_MS = 5_000L
        const val PACER_JOIN_MS = 1_000L
        const val TEXT_LIMIT = 80
        const val SETTLE_MS = 1_000L
        const val MEMORY_PREFS = "voice_live_cascade"
        const val PROMPT_PREFIX = "prompt:"
        const val SYSTEM_LANGUAGE = "en-US"
        const val SYSTEM_LINE_P50_MS = 2_000L
        const val SYSTEM_LINE_P95_MS = 4_000L
        const val CALLBACK_TIMEOUT_MS = 20_000L
        const val TTS_INIT_TIMEOUT_SEC = 10L
        const val MODEL_WAIT_MS = 180_000L
        const val MODEL_POLL_MS = 5_000L
        const val SILENT_TURNS_LIMIT = 2
        val json = Json { ignoreUnknownKeys = true }
        val VOICE_ATTRIBUTES get() = ai.oriveo.community.core.voice.conversation.VOICE_COMMUNICATION_ATTRIBUTES
    }
}
