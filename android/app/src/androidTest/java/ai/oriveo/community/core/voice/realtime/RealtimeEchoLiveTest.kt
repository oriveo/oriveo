package ai.oriveo.community.core.voice.realtime

import ai.oriveo.community.core.voice.AndroidAudioSessionCoordinator
import org.koin.mp.KoinPlatform
import android.Manifest
import android.media.AudioManager
import android.os.SystemClock
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import ai.oriveo.community.core.context.ContextConversation
import ai.oriveo.community.core.context.RealtimeSessionInput
import ai.oriveo.community.core.context.assembleRealtimeSession
import ai.oriveo.community.core.data.repository.PlannedRealtimeSession
import ai.oriveo.community.core.data.repository.RealtimeTransportInput
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.voice.VoiceCatalog
import ai.oriveo.community.core.voice.VoiceDirection
import ai.oriveo.community.core.voice.VoiceRealtimeEntry
import ai.oriveo.community.core.voice.VoiceTelemetry
import ai.oriveo.community.core.voice.conversation.ConversationRoute
import ai.oriveo.community.core.voice.live.VoiceLive
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveSocket
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveSocketFactory
import ai.oriveo.community.core.voice.realtime.wire.OkHttpGeminiLiveSocketFactory
import ai.oriveo.community.core.voice.realtime.wire.OkHttpRealtimeSocketFactory
import ai.oriveo.community.core.voice.realtime.wire.RealtimeEndpoint
import ai.oriveo.community.core.voice.realtime.wire.RealtimeSessionTransport
import ai.oriveo.community.core.voice.realtime.wire.RealtimeSocket
import ai.oriveo.community.core.voice.realtime.wire.RealtimeSocketFactory
import ai.oriveo.community.core.voice.realtime.wire.RealtimeSocketListener
import ai.oriveo.community.core.voice.realtime.wire.RealtimeTransportFactory
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Small live echo sample for a real-key realtime speaker session (contract card item 7): on a Samsung device, the production [RealtimeVoiceConversationController] + real
 * [AndroidRealtimeAudio] (real microphone and speaker, STREAM_VOICE_CALL at 100%), with nobody speaking throughout. Each round is a new session: after Ready, send a text prompt asking for an
 * approximately 8 s reply (OpenAI: conversation.item.create(input_text) + response.create; Gemini: clientContent
 * turnComplete=true). The session closes 30 s after sending, a hard cap. Two configs alternate:
 * - gateOff: the audio wrapper reports the route as Headset only (the gate is not armed), plus transport make(route = HEADPHONES) (knob off);
 * - gateOn: the original AndroidRealtimeAudio route plus the transport's default route (knob on).
 * Counting: during the first reply's playback window (opens at the first enqueue, closes at the drained after the first AssistantTurnDone or when cleared by an interruption),
 * count UserSpeechStarted / Interrupted events; after the first AssistantTurnDone, each reappearance of AssistantAudio counts as one spontaneous reply. Each round writes one VoiceLive.evidence
 * (estUsd by turnUsd) plus one realtime-echo-live line. The in-process total estUsd plus this round's worst case > limit stops the run. This only measures and does not assert thresholds.
 * Degradation (contract card item 9, basis=transcript-proxy): the controller does not report false barge-in counts, and the rig has nobody speaking throughout, so after the first enqueue every final user transcript
 * counts as one false barge-in (falseBargeIns). With gateOn, falseBargeIns >= 2 (E-381 threshold) sets degraded=true. With gateOff the gate is not armed and the reducer
 * does not count, so degraded is null (summary line n/a).
 * Parameters: instrumentation `-e voiceLive realtime-echo` (switch), `-e rounds N` (default openAI 10, gemini 4).
 */
@RunWith(AndroidJUnit4::class)
class RealtimeEchoLiveTest {

    @Test
    fun echoOpenAI() = run(
        kind = ProviderKind.OpenAI,
        keyName = "openAI",
        host = OPENAI_HOST,
        defaultRounds = 10,
        limitUsd = 0.15,
        pick = { it.entry(ProviderKind.OpenAI, VoiceDirection.Realtime, OPENAI_MODEL) as? VoiceRealtimeEntry },
    )

    @Test
    fun echoGemini() = run(
        kind = ProviderKind.Gemini,
        keyName = "gemini",
        host = GEMINI_HOST,
        defaultRounds = 4,
        limitUsd = 0.11,
        pick = { catalog -> catalog.provider(ProviderKind.Gemini).realtime.firstOrNull { it.isDefault } },
    )

    private enum class Config(val label: String, val gateOn: Boolean) {
        GateOff("gateOff", false),
        GateOn("gateOn", true),
    }

    private class RoundResult(
        val config: Config,
        val ready: Boolean,
        val firstReplyMs: Long?,
        val speechStarts: Int,
        val interrupts: Int,
        val spontaneous: Int,
        val falseBargeIns: Int,
        val degraded: Boolean?,
        val assistantSec: Double,
        val usd: Double,
    )

    private fun run(
        kind: ProviderKind,
        keyName: String,
        host: String,
        defaultRounds: Int,
        limitUsd: Double,
        pick: (VoiceCatalog) -> VoiceRealtimeEntry?,
    ) {
        if (!VoiceLive.enabled(GROUP)) return
        val entry = pick(VoiceLive.catalog())
        assertNotNull("catalog has no realtime entry for ${kind.rawValue}", entry)
        entry!!
        val transportKind = RealtimeTransportKind.fromRawValue(entry.transport.rawValue)
        assertNotNull("no transport for ${entry.transport.rawValue}", transportKind)
        transportKind!!
        val apiKey = VoiceLive.key(keyName) ?: return fail("missing key $keyName in voice-live/keys.json")
        val rounds = InstrumentationRegistry.getArguments().getString(ROUNDS_ARG)?.trim()?.toIntOrNull() ?: defaultRounds
        val context = VoiceLive.context
        InstrumentationRegistry.getInstrumentation().uiAutomation
            .grantRuntimePermission(context.packageName, Manifest.permission.RECORD_AUDIO)

        val results = mutableListOf<RoundResult>()
        var spentUsd = 0.0
        // Each round is a new session: priorAssistantSec is always 0; worst case = the whole round uplinks and the whole round is a reply.
        val worstUsd = turnUsd(
            transportKind,
            userSec = (READY_TIMEOUT_MS + ROUND_LIMIT_MS) / 1000.0,
            elapsedSec = (READY_TIMEOUT_MS + ROUND_LIMIT_MS) / 1000.0,
            assistantSec = ROUND_LIMIT_MS / 1000.0,
        )
        for (round in 0 until rounds) {
            val config = if (round % 2 == 0) Config.GateOff else Config.GateOn
            if (spentUsd + worstUsd > limitUsd) {
                VoiceLive.evidence(
                    ITEM, kind.rawValue, entry.model, false, null,
                    "budget stop before round-$round spent=$spentUsd worst=$worstUsd limit=$limitUsd", 0.0,
                )
                break
            }
            val result = runRound(kind, transportKind, entry, host, apiKey, round, config)
            results += result
            spentUsd += result.usd
        }

        for (config in Config.values()) {
            val of = results.filter { it.config == config }
            Log.i(
                VoiceLive.TAG,
                "realtime-echo-live summary provider=${kind.rawValue} model=${entry.model} config=${config.label} " +
                    "rounds=${of.size} ready=${of.count { it.ready }} replied=${of.count { it.assistantSec > 0 }} " +
                    "roundsWithSpeechStart=${of.count { it.speechStarts > 0 }} " +
                    "roundsWithInterrupt=${of.count { it.interrupts > 0 }} " +
                    "roundsWithSpontaneous=${of.count { it.spontaneous > 0 }} " +
                    "speechStarts=${of.sumOf { it.speechStarts }} interrupts=${of.sumOf { it.interrupts }} " +
                    "spontaneous=${of.sumOf { it.spontaneous }} falseBargeIns=${of.sumOf { it.falseBargeIns }} " +
                    "degradedRounds=${if (config.gateOn) of.count { it.degraded == true } else "n/a"} " +
                    "basis=$DEGRADE_BASIS estUsd=$spentUsd",
            )
        }
        // Measurement only: no false-trigger threshold is asserted; a sample with no replies at all is invalid.
        assertTrue(
            "realtime-echo-live ${kind.rawValue} ${entry.model}: no round got assistant audio (rounds=${results.size})",
            results.any { it.assistantSec > 0 },
        )
    }

    private fun runRound(
        kind: ProviderKind,
        transportKind: RealtimeTransportKind,
        entry: VoiceRealtimeEntry,
        host: String,
        apiKey: String,
        round: Int,
        config: Config,
    ): RoundResult {
        val signals = RoundSignals()
        val timeline = WireTimeline()
        val ready = CountDownLatch(1)
        val openAiSocket = AtomicReference<RealtimeSocket?>(null)
        val geminiSocket = AtomicReference<GeminiLiveSocket?>(null)
        var uplinkBytes = 0L
        val endpoint = RealtimeEndpoint(
            host = host,
            apiKey = apiKey,
            model = entry.model,
            path = entry.path,
            voice = entry.defaultVoice.id,
            inputTranscriptionModel = entry.inputTranscriptionModel,
        )
        val okHttp = OkHttpRealtimeSocketFactory()
        val rawConnection = RealtimeTransportFactory.make(
            transportKind,
            endpoint,
            socketFactory = RealtimeSocketFactory { url, headers, listener ->
                // Production default socket; only wrapped to record the receive timeline and keep the socket for sending text.
                okHttp.connect(url, headers, timeline.listener(listener)).also { openAiSocket.set(it) }
            },
            geminiSocketFactory = GeminiLiveSocketFactory { url ->
                timeline.socket(OkHttpGeminiLiveSocketFactory.connect(url)).also { geminiSocket.set(it) }
            },
            route = if (config.gateOn) {
                { ConversationRoute.SPEAKER }
            } else {
                { ConversationRoute.HEADPHONES }
            },
        )
        val uplinkRate = rawConnection.uplinkSampleRateHz
        val connection: RealtimeSessionTransport = object : RealtimeSessionTransport by rawConnection {
            override fun openRealtimeSession(transport: RealtimeTransportInput): Flow<RealtimeSessionEvent> =
                rawConnection.openRealtimeSession(transport).onEach {
                    timeline.controller(it)
                    signals.event(it, SystemClock.elapsedRealtime())
                    if (it is RealtimeSessionEvent.Ready) ready.countDown()
                }

            override fun sendAudio(pcm: ByteArray) {
                synchronized(signals) { uplinkBytes += pcm.size }
                rawConnection.sendAudio(pcm)
            }
        }
        val audio = ObservedAudio(AndroidRealtimeAudio(VoiceLive.context, KoinPlatform.getKoin().get<AndroidAudioSessionCoordinator>()), config.gateOn, signals)
        val executor = Executors.newSingleThreadExecutor { Thread(it, "realtime-echo-live") }
        val scope = CoroutineScope(executor.asCoroutineDispatcher() + Job())
        val ended = CountDownLatch(1)
        var endReason: RealtimeEndReason? = null
        var errorCode: String? = null
        var controller: RealtimeVoiceConversationController<RealtimeSessionTransport>? = null
        val openAt = SystemClock.elapsedRealtime()
        var sentAt: Long? = null
        var closeAt = openAt
        try {
            runBlocking(scope.coroutineContext) {
                val started = RealtimeVoiceConversationController<RealtimeSessionTransport>(
                    connection = connection,
                    audio = audio,
                    plan = plan(entry),
                    sink = object : RealtimeConversationSink {
                        override fun appendUser(text: String) = timeline.mark("persist user len=${text.length}")
                        override fun appendAssistant(text: String) = timeline.mark("persist assistant len=${text.length}")
                    },
                    scope = scope,
                    onError = { errorCode = it },
                    onEnded = { reason, _ ->
                        endReason = reason
                        ended.countDown()
                    },
                )
                controller = started
                started.start()
            }
            if (ready.await(READY_TIMEOUT_MS, TimeUnit.MILLISECONDS) && ended.count > 0L) {
                timeline.mark("round-$round ${config.label} prompt")
                sentAt = SystemClock.elapsedRealtime()
                sendPrompt(transportKind, openAiSocket.get(), geminiSocket.get())
                ended.await(ROUND_LIMIT_MS, TimeUnit.MILLISECONDS)
            }
        } finally {
            closeAt = SystemClock.elapsedRealtime()
            controller?.let { runBlocking(scope.coroutineContext) { it.end() } }
            ended.await(END_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            scope.cancel()
            audio.stop()
            audio.restoreVolume()
            executor.shutdown()
            timeline.print(kind.rawValue, round)
        }

        val assistantSec = audio.enqueuedBytes / BYTES_PER_SEC
        val userSec = synchronized(signals) { uplinkBytes } / (uplinkRate * 2.0)
        val usd = turnUsd(transportKind, userSec, (closeAt - openAt) / 1000.0, assistantSec)
        val firstReplyMs = sentAt?.let { sent -> audio.firstEnqueueAt?.let { it - sent } }
        val wasReady = sentAt != null
        val falseBargeIns = signals.finalTranscripts
        val degraded = if (config.gateOn) falseBargeIns >= FALSE_BARGE_IN_LIMIT else null
        val degradeDetail = "falseBargeIns=$falseBargeIns degraded=${degraded ?: "n/a"} basis=$DEGRADE_BASIS"
        val detail = "round-$round config=${config.label} ready=$wasReady route=${audio.reportedRoute} " +
            "volume=${audio.volumeIndex}/${audio.volumeMax} speechStarts=${signals.speechStarts} " +
            "interrupts=${signals.interrupts} spontaneous=${signals.spontaneous} $degradeDetail " +
            "assistantSec=${"%.2f".format(assistantSec)} userSec=${"%.2f".format(userSec)} " +
            "end=$endReason" + (errorCode?.let { " error=$it" } ?: "")
        VoiceLive.evidence(ITEM, kind.rawValue, entry.model, wasReady && assistantSec > 0, firstReplyMs, detail, usd)
        Log.i(
            VoiceLive.TAG,
            "realtime-echo-live provider=${kind.rawValue} model=${entry.model} round=$round config=${config.label} " +
                "ready=$wasReady route=${audio.reportedRoute} volume=${audio.volumeIndex}/${audio.volumeMax} " +
                "firstReplyMs=${firstReplyMs ?: "-"} speechStartsDuringReply=${signals.speechStarts} " +
                "interruptsDuringReply=${signals.interrupts} spontaneousReplies=${signals.spontaneous} " +
                "$degradeDetail assistantSec=${"%.2f".format(assistantSec)} userSec=${"%.2f".format(userSec)} " +
                "estUsd=${"%.5f".format(usd)} end=$endReason",
        )
        return RoundResult(
            config = config,
            ready = wasReady,
            firstReplyMs = firstReplyMs,
            speechStarts = signals.speechStarts,
            interrupts = signals.interrupts,
            spontaneous = signals.spontaneous,
            falseBargeIns = falseBargeIns,
            degraded = degraded,
            assistantSec = assistantSec,
            usd = usd,
        )
    }

    /** Sends the text prompt after Ready, straight over the production connection's socket (the production control plane has no entry point for sending text). */
    private fun sendPrompt(kind: RealtimeTransportKind, openAi: RealtimeSocket?, gemini: GeminiLiveSocket?) {
        when (kind) {
            RealtimeTransportKind.GeminiLive -> {
                val message = buildJsonObject {
                    putJsonObject("clientContent") {
                        putJsonArray("turns") {
                            addJsonObject {
                                put("role", "user")
                                putJsonArray("parts") { addJsonObject { put("text", PROMPT) } }
                            }
                        }
                        put("turnComplete", true)
                    }
                }
                val socket = gemini ?: error("gemini socket not open")
                runBlocking { socket.send(message.toString()) }
            }
            else -> {
                val socket = openAi ?: error("realtime socket not open")
                val item = buildJsonObject {
                    put("type", "conversation.item.create")
                    putJsonObject("item") {
                        put("type", "message")
                        put("role", "user")
                        putJsonArray("content") {
                            addJsonObject {
                                put("type", "input_text")
                                put("text", PROMPT)
                            }
                        }
                    }
                }
                check(socket.send(item.toString())) { "conversation.item.create not sent" }
                check(socket.send(buildJsonObject { put("type", "response.create") }.toString())) {
                    "response.create not sent"
                }
            }
        }
    }

    private fun plan(entry: VoiceRealtimeEntry): PlannedRealtimeSession = PlannedRealtimeSession.from(
        assembleRealtimeSession(
            RealtimeSessionInput(
                contextWindow = entry.contextWindow.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
                conversation = ContextConversation(id = "realtime-echo-live", useMemory = false),
                history = emptyList(),
            ),
        ),
    ) ?: error("realtime plan rejected")

    /** Same as turnUsd in VoiceLiveRealtimeTest (contract item 6 pricing); for a new session priorAssistantSec = 0. */
    private fun turnUsd(kind: RealtimeTransportKind, userSec: Double, elapsedSec: Double, assistantSec: Double): Double =
        when (kind) {
            RealtimeTransportKind.GeminiLive ->
                elapsedSec * 32 * 3.0 / 1_000_000 + assistantSec * 32 * 12.0 / 1_000_000
            else ->
                userSec * 10 * 10.0 / 1_000_000 + assistantSec * 20 * 20.0 / 1_000_000
        }

    /**
     * Per-round counting. First reply playback window: opens at the first enqueue, closes at the drained after the first AssistantTurnDone (or on a cleared interruption);
     * UserSpeechStarted / Interrupted are counted inside the window; after the first AssistantTurnDone, each reappearance of AssistantAudio counts as one spontaneous reply.
     */
    private class RoundSignals {
        private val lock = Any()
        private var windowOpen = false
        private var windowClosed = false
        private var firstTurnDone = false
        private var awaitingReply = false

        @Volatile var speechStarts = 0
            private set

        @Volatile var interrupts = 0
            private set

        @Volatile var spontaneous = 0
            private set

        /** Final user transcript count after the first enqueue (nobody speaks, so all are proxy counts of false barge-ins). */
        @Volatile var finalTranscripts = 0
            private set

        fun event(event: RealtimeSessionEvent, at: Long) = synchronized(lock) {
            when (event) {
                is RealtimeSessionEvent.UserSpeechStarted -> if (windowOpen && !windowClosed) speechStarts++
                is RealtimeSessionEvent.Interrupted -> if (windowOpen && !windowClosed) interrupts++
                is RealtimeSessionEvent.UserTranscript -> if (event.final && windowOpen) finalTranscripts++
                is RealtimeSessionEvent.AssistantTurnDone -> {
                    firstTurnDone = true
                    awaitingReply = true
                }
                is RealtimeSessionEvent.AssistantAudio -> if (firstTurnDone && awaitingReply) {
                    spontaneous++
                    awaitingReply = false
                }
                else -> Unit
            }
        }

        fun enqueued() = synchronized(lock) { if (!windowClosed) windowOpen = true }

        fun drained() = synchronized(lock) { if (windowOpen && firstTurnDone) windowClosed = true }

        fun playbackStopped() = synchronized(lock) { if (windowOpen) windowClosed = true }
    }

    /**
     * Wraps the real [AndroidRealtimeAudio]: with gateOff it reports the route as Headset only (the gate is not armed); with gateOn it passes through unchanged.
     * Also records enqueued bytes, the first enqueue time, and drained / cleared; after capture starts, raises STREAM_VOICE_CALL to 100% (restored at the end).
     */
    private class ObservedAudio(
        private val inner: AndroidRealtimeAudio,
        private val gateOn: Boolean,
        private val signals: RoundSignals,
    ) : RealtimeAudioIO by inner {
        private val audioManager = VoiceLive.context.getSystemService(AudioManager::class.java)
        private var previousVolume: Int? = null

        @Volatile var enqueuedBytes = 0L
            private set

        @Volatile var firstEnqueueAt: Long? = null
            private set

        @Volatile var volumeIndex: Int? = null
            private set

        @Volatile var volumeMax: Int? = null
            private set

        @Volatile var reportedRoute: String = "-"
            private set

        override val route: VoiceTelemetry.ConversationRoute
            get() = (if (gateOn) inner.route else VoiceTelemetry.ConversationRoute.Headset)
                .also { reportedRoute = it.name.lowercase() }

        override fun start(onFrame: (ByteArray) -> Unit, onInterruption: () -> Unit) {
            inner.start(onFrame, onInterruption)
            maxVolume()
        }

        override fun start(onFrame: (ByteArray) -> Unit, onInterruption: () -> Unit, uplinkRateHz: Int) {
            inner.start(onFrame, onInterruption, uplinkRateHz)
            maxVolume()
        }

        // Call volume is tracked per output device: adjust it after entering communication mode and selecting the route (inner.start).
        private fun maxVolume() {
            val max = audioManager.getStreamMaxVolume(AudioManager.STREAM_VOICE_CALL)
            if (previousVolume == null) previousVolume = audioManager.getStreamVolume(AudioManager.STREAM_VOICE_CALL)
            runCatching { audioManager.setStreamVolume(AudioManager.STREAM_VOICE_CALL, max, 0) }
            volumeMax = max
            volumeIndex = audioManager.getStreamVolume(AudioManager.STREAM_VOICE_CALL)
        }

        fun restoreVolume() {
            previousVolume?.let { runCatching { audioManager.setStreamVolume(AudioManager.STREAM_VOICE_CALL, it, 0) } }
            previousVolume = null
        }

        override fun enqueue(pcm16: ByteArray, itemId: String) {
            val first = firstEnqueueAt == null
            if (first) firstEnqueueAt = SystemClock.elapsedRealtime()
            enqueuedBytes += pcm16.size
            signals.enqueued()
            inner.enqueue(pcm16, itemId)
            // The driver uses the four-argument start (async activation), delegated straight to inner and bypassing the two overrides above; activation is long done by the first downlink enqueue, so volume is adjusted here
            if (first && volumeIndex == null) maxVolume()
        }

        override fun setOnDrained(onDrained: () -> Unit) {
            inner.setOnDrained {
                signals.drained()
                onDrained()
            }
        }

        override fun stopPlayback() {
            signals.playbackStopped()
            inner.stopPlayback()
        }
    }

    /**
     * Wire timeline (diagnostics, simplified from VoiceLiveRealtimeTest.WireTimeline): OpenAI records the type of each received message, Gemini records the message keys sent and received,
     * plus events arriving at the controller; adjacent entries with the same label are merged into one run (count, bytes). Content, URLs and keys are never recorded.
     */
    private class WireTimeline {
        private class Run(val label: String, val firstAt: Long) {
            var lastAt = firstAt
            var count = 0
            var bytes = 0L
        }

        private val lock = Any()
        private val runs = mutableListOf<Run>()
        private var origin = -1L

        fun listener(inner: RealtimeSocketListener): RealtimeSocketListener = object : RealtimeSocketListener {
            override fun onOpen(socket: RealtimeSocket) {
                add("open")
                inner.onOpen(socket)
            }

            override fun onMessage(text: String) {
                val type = runCatching {
                    (Json.parseToJsonElement(text) as? JsonObject)?.get("type")?.jsonPrimitive?.content
                }.getOrNull()
                add("recv ${type ?: "<non-json ${text.length}>"}")
                inner.onMessage(text)
            }

            override fun onClosed(code: Int, reason: String) {
                add("closed code=$code")
                inner.onClosed(code, reason)
            }

            override fun onFailure(error: Throwable) {
                add("failure ${error::class.simpleName}")
                inner.onFailure(error)
            }
        }

        fun socket(inner: GeminiLiveSocket): GeminiLiveSocket = object : GeminiLiveSocket {
            // The transport reads close code / reason and uses backlog to judge staleness and a stuck uplink; the wrapper must not hide them.
            override val closeCode: Int? get() = inner.closeCode

            override val closeReason: String? get() = inner.closeReason

            override val queueSize: Long get() = inner.queueSize

            override suspend fun send(text: String) {
                record("send", text)
                inner.send(text)
            }

            override suspend fun receive(): String? {
                val text = inner.receive()
                if (text == null) add("recv <closed>") else record("recv", text)
                return text
            }

            override fun close() {
                add("socket close")
                inner.close()
            }

            override fun cancel() {
                add("socket cancel")
                inner.cancel()
            }
        }

        fun controller(event: RealtimeSessionEvent) {
            val bytes = (event as? RealtimeSessionEvent.AssistantAudio)?.base64?.let { it.length * 3L / 4 } ?: 0L
            add("ctl ${event::class.simpleName}", bytes)
        }

        fun mark(label: String) = add("mark $label")

        private fun record(direction: String, text: String) {
            val obj = runCatching { Json.parseToJsonElement(text) as? JsonObject }.getOrNull()
            if (obj == null) {
                add("$direction <non-json ${text.length}>")
                return
            }
            val content = obj["serverContent"] as? JsonObject
            val keys = if (content != null) "serverContent{${content.keys.sorted().joinToString("+")}}" else obj.keys.sorted().joinToString("+")
            add("$direction $keys", text.length.toLong())
        }

        private fun add(label: String, bytes: Long = 0) {
            val now = SystemClock.elapsedRealtime()
            synchronized(lock) {
                if (origin < 0) origin = now
                val last = runs.lastOrNull()
                val run = if (last != null && last.label == label && !label.startsWith("mark")) {
                    last.lastAt = now
                    last
                } else {
                    Run(label, now).also { runs += it }
                }
                run.count++
                run.bytes += bytes
            }
        }

        fun print(provider: String, round: Int) {
            val copy = synchronized(lock) { runs.toList() }
            for (run in copy) {
                Log.i(
                    VoiceLive.TAG,
                    "VOICE-LIVE realtime-echo timeline $provider round-$round +${run.firstAt - origin}..${run.lastAt - origin}ms " +
                        "${run.label} n=${run.count} bytes=${run.bytes}",
                )
            }
        }
    }

    private companion object {
        const val GROUP = "realtime-echo"
        const val ITEM = "realtime-echo-live"
        const val ROUNDS_ARG = "rounds"
        const val DEGRADE_BASIS = "transcript-proxy"
        const val FALSE_BARGE_IN_LIMIT = 2
        const val OPENAI_MODEL = "gpt-realtime-2.1-mini"
        const val OPENAI_HOST = "api.openai.com"
        const val GEMINI_HOST = "generativelanguage.googleapis.com"
        const val READY_TIMEOUT_MS = 20_000L
        const val ROUND_LIMIT_MS = 30_000L
        const val END_TIMEOUT_MS = 10_000L
        const val BYTES_PER_SEC = RealtimePCM.OUTPUT_RATE * 2.0
        const val PROMPT = "Please talk for about eight seconds, in a few natural sentences, about the weather in autumn."
    }
}
