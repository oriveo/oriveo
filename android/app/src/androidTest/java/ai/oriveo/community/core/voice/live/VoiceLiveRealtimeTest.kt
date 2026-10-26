package ai.oriveo.community.core.voice.live

import android.os.SystemClock
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import ai.oriveo.community.core.context.ContextConversation
import ai.oriveo.community.core.context.RealtimeSessionInput
import ai.oriveo.community.core.context.RealtimeSessionMessage
import ai.oriveo.community.core.context.assembleRealtimeSession
import ai.oriveo.community.core.data.repository.PlannedRealtimeSession
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.voice.VoiceDirection
import ai.oriveo.community.core.voice.VoiceRealtimeEntry
import ai.oriveo.community.core.voice.realtime.RealtimeAudioIO
import ai.oriveo.community.core.voice.realtime.RealtimeConversationSink
import ai.oriveo.community.core.voice.realtime.RealtimeEndReason
import ai.oriveo.community.core.voice.realtime.RealtimePCM
import ai.oriveo.community.core.voice.realtime.RealtimeTransportKind
import ai.oriveo.community.core.voice.realtime.RealtimeVoiceConversationController
import ai.oriveo.community.core.data.repository.RealtimeTransportInput
import ai.oriveo.community.core.voice.realtime.RealtimeSessionEvent
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveSocket
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveSocketFactory
import ai.oriveo.community.core.voice.realtime.wire.OkHttpGeminiLiveSocketFactory
import ai.oriveo.community.core.voice.realtime.wire.RealtimeEndpoint
import ai.oriveo.community.core.voice.realtime.wire.RealtimeSessionTransport
import ai.oriveo.community.core.voice.realtime.wire.RealtimeTransportFactory
import ai.oriveo.community.feature.chat.voice.RealtimeMessageAttribution
import ai.oriveo.community.feature.chat.voice.RepositoryRealtimeTranscriptSink
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Voice live, group `realtime`: the production [RealtimeVoiceConversationController] over a real
 * [RealtimeTransportFactory] connection, fed the recorded 24 kHz turn clips through an injected [RealtimeAudioIO]
 * (frames every 20 ms, silence after each turn until the assistant audio has played out). Turns are persisted by the
 * production [RepositoryRealtimeTranscriptSink]. One call per provider; per-turn latency = last turn frame pushed →
 * first assistant audio chunk. Each turn is settled on AssistantTurnDone + the assistant persist, and the next turn
 * is pushed only after that. Gemini runs over the production default socket; the wire timeline records server
 * ACTIVITY_START / ACTIVITY_END / first audio timings. The controller gets a reopener (contract B) that drains the
 * sink, projects a new plan with the persisted turns and opens a new production transport.
 */
@RunWith(AndroidJUnit4::class)
class VoiceLiveRealtimeTest {

    @Test
    fun realtimeOpenAI() = call(
        kind = ProviderKind.OpenAI,
        keyName = "openAI",
        host = OPENAI_HOST,
        turns = 3,
        limitUsd = 0.10,
        pick = { it.entry(ProviderKind.OpenAI, VoiceDirection.Realtime, OPENAI_MODEL) as? VoiceRealtimeEntry },
    )

    @Test
    fun realtimeGemini() = call(
        kind = ProviderKind.Gemini,
        keyName = "gemini",
        host = GEMINI_HOST,
        turns = 2,
        limitUsd = 0.05,
        pick = { catalog -> catalog.provider(ProviderKind.Gemini).realtime.firstOrNull { it.isDefault } },
    )

    /**
     * Contract B : after turn-1 the call is muted (nothing uplinked) until the server has closed the session
     * with 1008 (expiry, about 485 s in; other drops are resumed and waited past) plus [EXPIRE_SETTLE_MS], capped at
     * [MUTE_MAX_MS]. An unsettled turn-1 makes the case n/a and ends the call before the mute. While muted the controller
     * sleeps (no ended, no onError); unmuting makes it reopen through the injected reopener (same plan projection with
     * the transcripts persisted so far, a new production transport), then turn-2 and turn-3 must both get a user
     * transcript and assistant audio, and the second connection's setup / clientContent must carry turn-1's answer.
     * No close within the cap is recorded as not observed (n/a), not failed.
     */
    @Test
    fun geminiMuteExpiredReopens() = call(
        kind = ProviderKind.Gemini,
        keyName = "gemini",
        host = GEMINI_HOST,
        turns = 3,
        limitUsd = MUTE_LIMIT_USD,
        pick = { catalog -> catalog.provider(ProviderKind.Gemini).realtime.firstOrNull { it.isDefault } },
        mute = MutePlan(name = "expiredReopens"),
        callLimitMs = MUTE_CALL_LIMIT_MS,
    )

    /**
     * Mute phase after turn-1: ends [EXPIRE_SETTLE_MS] after the first 1008 close, or at [MUTE_MAX_MS].
     */
    private class MutePlan(val name: String)

    private data class Turn(val index: Int, val file: String, val durationSec: Double)

    private class TurnResult(
        val index: Int,
        val latencyMs: Long?,
        val userText: String?,
        val assistantText: String?,
        val assistantSec: Double,
        val finished: Boolean,
        val wire: String,
    )

    private fun call(
        kind: ProviderKind,
        keyName: String,
        host: String,
        turns: Int,
        limitUsd: Double,
        pick: (ai.oriveo.community.core.voice.VoiceCatalog) -> VoiceRealtimeEntry?,
        mute: MutePlan? = null,
        callLimitMs: Long = CALL_LIMIT_MS,
    ) {
        if (!VoiceLive.enabled(GROUP)) return
        val entry = pick(VoiceLive.catalog())
        assertNotNull("catalog has no realtime entry for ${kind.rawValue}", entry)
        entry!!
        val transportKind = RealtimeTransportKind.fromRawValue(entry.transport.rawValue)
        assertNotNull("no transport for ${entry.transport.rawValue}", transportKind)
        transportKind!!
        val apiKey = VoiceLive.key(keyName) ?: return fail("missing key $keyName in voice-live/keys.json")
        val clips = turns().take(turns)
        assertEquals("manifest turns", turns, clips.size)

        val signals = TurnSignals()
        val timeline = WireTimeline(signals)
        val connections = ConnectionLog()
        // A new production transport per connection (first open and each reopen), wrapped only to record the wire.
        fun newConnection(): RealtimeSessionTransport {
            val rawConnection = RealtimeTransportFactory.make(
                transportKind,
                RealtimeEndpoint(
                    host = host,
                    apiKey = apiKey,
                    model = entry.model,
                    path = entry.path,
                    voice = entry.defaultVoice.id,
                    inputTranscriptionModel = entry.inputTranscriptionModel,
                ),
                geminiSocketFactory = GeminiLiveSocketFactory { url ->
                    // Production default socket; wrapped only to record the wire timeline.
                    timeline.socket(connections.wrap(OkHttpGeminiLiveSocketFactory.connect(url)))
                },
            )
            // Records each event as it reaches the controller (after the transport's signal loop).
            return object : RealtimeSessionTransport by rawConnection {
                override fun openRealtimeSession(transport: RealtimeTransportInput): Flow<RealtimeSessionEvent> =
                    rawConnection.openRealtimeSession(transport).onEach {
                        timeline.controller(it)
                        if (it is RealtimeSessionEvent.AssistantTurnDone) signals.turnDone(SystemClock.elapsedRealtime())
                    }
            }
        }
        val connection = newConnection()
        val executor = Executors.newSingleThreadExecutor { Thread(it, "voice-live-realtime") }
        val scope = CoroutineScope(executor.asCoroutineDispatcher() + Job())
        val sinkJob = Job()
        val sinkScope = CoroutineScope(executor.asCoroutineDispatcher() + sinkJob)
        val audio = InjectedAudio()
        val messages = mutableListOf<ChatMessage>()
        val production = RepositoryRealtimeTranscriptSink(
            conversationId = "voice-live-${kind.rawValue}",
            attribution = RealtimeMessageAttribution(
                providerID = "voice-live-${kind.rawValue}",
                providerKind = kind,
                providerName = kind.rawValue,
                model = entry.model,
            ),
            add = { _, message -> synchronized(messages) { messages += message } },
            update = { _, _ -> },
            scope = sinkScope,
        )
        val sink = object : RealtimeConversationSink {
            override fun appendUser(text: String) {
                timeline.mark("persist user len=${text.length}")
                signals.user(text)
                production.appendUser(text)
            }

            override fun appendAssistant(text: String) {
                timeline.mark("persist assistant len=${text.length}")
                signals.assistant(text)
                production.appendAssistant(text)
            }
        }
        val ended = CountDownLatch(1)
        var endReason: RealtimeEndReason? = null
        var errorCode: String? = null
        lateinit var controller: RealtimeVoiceConversationController<RealtimeSessionTransport>
        runBlocking(scope.coroutineContext) {
            controller = RealtimeVoiceConversationController(
                connection = connection,
                audio = audio,
                plan = plan(entry),
                sink = sink,
                scope = scope,
                onError = { errorCode = it },
                onEnded = { reason, _ ->
                    endReason = reason
                    ended.countDown()
                },
                // Contract B item 4: same projection as the first open, history = first-open messages (none) plus
                // what this call's sink has persisted (after its queue has drained); a new production transport.
                reopen = {
                    production.drain()
                    val persisted = synchronized(messages) { messages.toList() }
                    timeline.mark("reopen history=${persisted.size}")
                    newConnection() to plan(entry, persisted)
                },
            )
            controller.start()
        }

        val results = mutableListOf<TurnResult>()
        var spentUsd = 0.0
        var cumulativeAssistantSec = 0.0
        var overBudget = false
        val callStart = SystemClock.elapsedRealtime()
        val callDeadline = callStart + callLimitMs
        var muteStart: Long? = null
        var muteEnd: Long? = null
        var expired: Boolean? = null
        var turn1Incomplete = false
        var muteEndReason: RealtimeEndReason? = null
        var muteErrorCode: String? = null
        // Billed seconds exclude the mute: nothing is uplinked and the expired connection is gone.
        fun billedSec(now: Long): Double = (now - callStart - ((muteEnd ?: now) - (muteStart ?: now))) / 1000.0
        try {
            val onFrame = audio.awaitStart(READY_TIMEOUT_MS)
            if (onFrame == null) {
                VoiceLive.evidence(ITEM, kind.rawValue, entry.model, false, null, "not ready error=$errorCode end=$endReason", 0.0)
                fail("realtime ${kind.rawValue} ${entry.model}: session not ready (error=$errorCode end=$endReason)")
            }
            // Frames go to the latest start() callback: a reopened connection's driver starts the audio again.
            onFrame!!
            val pump = FramePump { frame -> audio.currentOnFrame()?.invoke(frame) }
            for (clip in clips) {
                if (ended.count == 0L) break
                // Projected cost of this turn with a pessimistic answer length; not sent when over the limit.
                val elapsedSec = billedSec(SystemClock.elapsedRealtime())
                val projected = turnUsd(
                    transportKind,
                    userSec = pump.sentSec + clip.durationSec + TURN_TIMEOUT_MS / 1000.0,
                    priorAssistantSec = cumulativeAssistantSec,
                    elapsedSec = elapsedSec + TURN_TIMEOUT_MS / 1000.0,
                    assistantSec = PROJECTED_ASSISTANT_SEC,
                )
                if (spentUsd + projected > limitUsd) {
                    overBudget = true
                    VoiceLive.evidence(ITEM, kind.rawValue, entry.model, false, null, "budget exceeded turn-${clip.index}", spentUsd)
                    break
                }
                val result = runTurn(clip, pump, audio, signals, controller, ended, callDeadline, timeline)
                results += result
                val turnUsd = turnUsd(
                    transportKind,
                    userSec = pump.sentSec,
                    priorAssistantSec = cumulativeAssistantSec,
                    elapsedSec = billedSec(SystemClock.elapsedRealtime()),
                    assistantSec = result.assistantSec,
                )
                cumulativeAssistantSec += result.assistantSec
                spentUsd += turnUsd
                val ok = !result.userText.isNullOrBlank() && result.assistantSec > 0
                val detail = "turn-${result.index} user=${result.userText.orEmpty()} " +
                    "assistant=${result.assistantText.orEmpty()} assistantSec=${"%.2f".format(result.assistantSec)} " +
                    "finished=${result.finished} ${result.wire}" + (errorCode?.let { " error=$it" } ?: "")
                VoiceLive.evidence(ITEM, kind.rawValue, entry.model, ok, result.latencyMs, detail, turnUsd)
                if (spentUsd > limitUsd) {
                    overBudget = true
                    break
                }
                if (SystemClock.elapsedRealtime() >= callDeadline) break
                if (mute != null && muteStart == null && !result.finished) {
                    // No settled turn-1 (no AssistantTurnDone + assistant persist in time): nothing to carry into a
                    // reopen, so the case is n/a and the call ends now instead of muting (cost).
                    turn1Incomplete = true
                    val reason = "turn-${result.index} not settled within ${TURN_TIMEOUT_MS} ms " +
                        "(turnDone=${signals.turnDoneAt != null} assistant=${result.assistantText != null} end=$endReason)"
                    Log.i(VoiceLive.TAG, "realtime ${kind.rawValue} mute-${mute.name}: $reason")
                    VoiceLive.evidence(ITEM, kind.rawValue, entry.model, false, null, "unavailable mute-${mute.name} $reason", 0.0)
                    break
                }
                if (mute != null && muteStart == null && ended.count > 0L) {
                    // Turn-1's answer must reach the second connection's history (contract B item 4).
                    connections.historyProbe = result.assistantText?.trim()?.take(HISTORY_PROBE_CHARS)?.takeIf { it.isNotEmpty() }
                    val start = SystemClock.elapsedRealtime()
                    muteStart = start
                    val sawClose = runMute(mute, start, callStart, controller, scope, ended, connections, timeline)
                    expired = sawClose
                    muteEndReason = endReason
                    muteErrorCode = errorCode
                    if (sawClose) unmuteAndAwaitReady(mute, callStart, controller, scope, ended, connections, timeline)
                    val end = SystemClock.elapsedRealtime()
                    muteEnd = end
                    val closed = connections.closedBetween(start, end)
                    // Mute-phase sample: ms = mute duration; cost is booked on the next turn.
                    val detail = "mute-${mute.name} muteMs=${end - start} sessionMs=${end - callStart} " +
                        "connects=${connections.count} closedDuringMute=$closed " +
                        "expiredDuringMute=${connections.expiredBetween(start, end)} end=$muteEndReason " +
                        connections.describe(callStart) + (muteErrorCode?.let { " error=$it" } ?: "")
                    if (!sawClose) {
                        Log.i(VoiceLive.TAG, "realtime ${kind.rawValue} mute-${mute.name}: no expiry observed (no 1008 within ${MUTE_MAX_MS} ms, end=$muteEndReason)")
                        VoiceLive.evidence(ITEM, kind.rawValue, entry.model, false, null, "unavailable no-expiry-observed $detail", 0.0)
                        break
                    }
                    VoiceLive.evidence(
                        ITEM, kind.rawValue, entry.model, muteEndReason == null && muteErrorCode == null, end - start,
                        detail, 0.0,
                    )
                }
            }
        } finally {
            runBlocking(scope.coroutineContext) { controller.end() }
            ended.await(END_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            // Lets the last socket close land before the per-connection diagnostics are read.
            Thread.sleep(DIAG_SETTLE_MS)
            production.close()
            runBlocking { withTimeoutOrNull(END_TIMEOUT_MS) { sinkJob.children.forEach { it.join() } } }
            scope.cancel()
            sinkScope.cancel()
            audio.stop()
            executor.shutdown()
            connections.diag(timeline, callStart)
            timeline.print(kind.rawValue)
        }

        val latencies = results.mapNotNull { it.latencyMs }.sorted()
        // Summary only, not an evidence sample (contract item 5 is one line per turn).
        Log.i(
            VoiceLive.TAG,
            "realtime summary ${kind.rawValue} ${entry.model} turns=${results.size} " +
                "p50=${nearestRank(latencies, 0.50)} p95=${nearestRank(latencies, 0.95)} " +
                "callMs=${SystemClock.elapsedRealtime() - callStart} end=$endReason estUsd=$spentUsd " +
                connections.describe(callStart),
        )
        assertTrue("realtime ${kind.rawValue}: estimated spend ${"%.4f".format(spentUsd)} over $limitUsd USD", !overBudget)
        assertTrue(
            "realtime ${kind.rawValue} ${entry.model}: no turn with user transcript and assistant audio (error=$errorCode)",
            results.any { !it.userText.isNullOrBlank() && it.assistantSec > 0 },
        )
        if (mute != null && turn1Incomplete) return
        if (mute != null) {
            assertNotNullValue("mute phase never ran (turns=${results.size} end=$endReason)", muteStart)
            // Other drops during the mute must have been resumed: the call may not end without a 1008 expiry.
            assertEquals(
                "call ended during the mute without a 1008 expiry ${connections.describe(callStart)}",
                null,
                if (expired == true) null else muteEndReason,
            )
            if (expired == true) {
                assertEquals("endReason during the muted expiry", null, muteEndReason)
                assertEquals("errorCode during the muted expiry", null, muteErrorCode)
                assertTrue(
                    "connections after the reopen ${connections.describe(callStart)}",
                    connections.count >= 2,
                )
                assertEquals(
                    "reopened connection setup / clientContent carries turn-1's answer " +
                        "(probe ${connections.historyProbe?.length ?: 0} chars) ${connections.describe(callStart)}",
                    true,
                    connections.historyProbe != null && connections.historyOnReopen() == true,
                )
                for (index in listOf(2, 3)) {
                    val turn = results.firstOrNull { it.index == index }
                    assertTrue(
                        "realtime ${kind.rawValue} mute-${mute.name}: turn-$index after the reopen has no user " +
                            "transcript and assistant audio (error=$errorCode end=$endReason)",
                        turn != null && !turn.userText.isNullOrBlank() && turn.assistantSec > 0,
                    )
                }
            }
        }
        val assistants = synchronized(messages) { messages.filter { it.role == ChatRole.Assistant } }
        assertTrue("realtime ${kind.rawValue}: no assistant message persisted", assistants.isNotEmpty())
        for (message in assistants) {
            assertEquals("assistant message modelID", entry.model, message.modelID)
            assertEquals("assistant message providerKind", kind, message.providerKind)
        }
    }

    private fun <T : Any> assertNotNullValue(message: String, value: T?): T {
        assertNotNull(message, value)
        return value!!
    }

    /**
     * Mutes the call via the production controller and waits, sending nothing (the controller gates the uplink), until
     * [EXPIRE_SETTLE_MS] after a 1008 close (session expired, also a resumption rejected with 1008), or [MUTE_MAX_MS].
     * Other closes are logged and the wait goes on (production resumes them by handle). Stays muted; returns whether a
     * 1008 was seen.
     */
    private fun runMute(
        plan: MutePlan,
        muteStart: Long,
        callStart: Long,
        controller: RealtimeVoiceConversationController<RealtimeSessionTransport>,
        scope: CoroutineScope,
        ended: CountDownLatch,
        connections: ConnectionLog,
        timeline: WireTimeline,
    ): Boolean {
        timeline.mark("mute-${plan.name} start")
        runBlocking(scope.coroutineContext) { controller.toggleMute() }
        var expiredAt: Long? = null
        var otherCloses = 0
        while (ended.count > 0L) {
            val now = SystemClock.elapsedRealtime()
            if (expiredAt == null && connections.expiredBetween(muteStart, now) > 0) expiredAt = now
            val others = connections.closedBetween(muteStart, now) - connections.expiredBetween(muteStart, now)
            if (others > otherCloses) {
                otherCloses = others
                timeline.mark("mute-${plan.name} non-1008 close #$others, waiting on ${connections.describe(callStart)}")
            }
            if (expiredAt != null && now - expiredAt >= EXPIRE_SETTLE_MS) break
            if (now - muteStart >= MUTE_MAX_MS) break
            ended.await(MUTE_POLL_MS, TimeUnit.MILLISECONDS)
        }
        return expiredAt != null
    }

    /** Unmutes (the controller reopens) and gives the newest connection [READY_TIMEOUT_MS] to become ready. */
    private fun unmuteAndAwaitReady(
        plan: MutePlan,
        callStart: Long,
        controller: RealtimeVoiceConversationController<RealtimeSessionTransport>,
        scope: CoroutineScope,
        ended: CountDownLatch,
        connections: ConnectionLog,
        timeline: WireTimeline,
    ) {
        if (ended.count == 0L) return
        timeline.mark("mute-${plan.name} unmute ${connections.describe(callStart)}")
        runBlocking(scope.coroutineContext) { controller.toggleMute() }
        val readyBy = SystemClock.elapsedRealtime() + READY_TIMEOUT_MS
        while (ended.count > 0L && !connections.latestReady() && SystemClock.elapsedRealtime() < readyBy) {
            ended.await(MUTE_POLL_MS, TimeUnit.MILLISECONDS)
        }
        timeline.mark("mute-${plan.name} end ${connections.describe(callStart)}")
    }

    /**
     * Pushes one turn clip, then silence until AssistantTurnDone has reached the controller and the assistant reply has
     * been persisted; the turn is settled there (the next turn starts right after).
     */
    private fun runTurn(
        clip: Turn,
        pump: FramePump,
        audio: InjectedAudio,
        signals: TurnSignals,
        controller: RealtimeVoiceConversationController<RealtimeSessionTransport>,
        ended: CountDownLatch,
        callDeadline: Long,
        timeline: WireTimeline,
    ): TurnResult {
        signals.reset()
        audio.resetTurn()
        val samples = readWav24k(File(VoiceLive.audioDir, clip.file))
        val pushStartAt = SystemClock.elapsedRealtime()
        timeline.mark("turn-${clip.index} push start samples24k=${samples.size} peak=${samples.maxOfOrNull { kotlin.math.abs(it.toInt()) } ?: 0}")
        pump.push(samples)
        val lastFrameAt = SystemClock.elapsedRealtime()
        timeline.mark("turn-${clip.index} push end, silence starts")
        audio.markSpeechEnd(lastFrameAt)
        val deadline = minOf(lastFrameAt + TURN_TIMEOUT_MS, callDeadline)
        var finished = false
        while (SystemClock.elapsedRealtime() < deadline && ended.count > 0L) {
            if (signals.turnDoneAt != null && signals.assistantText != null) {
                finished = true
                break
            }
            pump.silence()
        }
        // A user transcript can arrive after the answer started; give it a moment before reading the turn.
        if (signals.userText == null && ended.count > 0L) {
            repeat(TRANSCRIPT_GRACE_FRAMES) { if (signals.userText == null) pump.silence() }
        }
        val firstAudioAt = audio.firstAudioAt
        // Server-side receive times (socket layer) relative to the clip: start vs push start, the rest vs push end.
        fun rel(at: Long?, base: Long) = at?.let { (it - base).toString() } ?: "-"
        val wire = "activityStartMs=${rel(signals.activityStartAt, pushStartAt)} " +
            "activityEndMs=${rel(signals.activityEndAt, lastFrameAt)} " +
            "firstAudioRecvMs=${rel(signals.firstAudioRecvAt, lastFrameAt)} " +
            "firstAudioEnqueueMs=${rel(firstAudioAt, lastFrameAt)} " +
            "turnDoneMs=${rel(signals.turnDoneAt, lastFrameAt)} pushMs=${lastFrameAt - pushStartAt}"
        timeline.mark("turn-${clip.index} settled $wire")
        return TurnResult(
            index = clip.index,
            latencyMs = firstAudioAt?.let { it - lastFrameAt },
            userText = signals.userText,
            assistantText = signals.assistantText,
            assistantSec = audio.turnAudioBytes / BYTES_PER_SEC,
            finished = finished,
            wire = wire,
        )
    }

    private fun plan(entry: VoiceRealtimeEntry, persisted: List<ChatMessage> = emptyList()): PlannedRealtimeSession =
        PlannedRealtimeSession.from(
        assembleRealtimeSession(
            RealtimeSessionInput(
                contextWindow = entry.contextWindow.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
                conversation = ContextConversation(id = "voice-live", useMemory = false),
                history = persisted.map { RealtimeSessionMessage(id = it.id, role = it.role, text = it.text) },
            ),
        ),
    ) ?: error("realtime plan rejected")

    private fun turns(): List<Turn> {
        val manifest = Json.parseToJsonElement(File(VoiceLive.audioDir, "manifest.json").readText()).jsonObject
        return manifest.getValue("turns").jsonArray.map {
            val obj = it.jsonObject
            Turn(
                index = obj.getValue("index").jsonPrimitive.content.toInt(),
                file = obj.getValue("file24k").jsonPrimitive.content,
                durationSec = obj.getValue("durationSec").jsonPrimitive.content.toDouble(),
            )
        }.sortedBy { it.index }
    }

    /** Contract item 6 per turn; [userSec] / [priorAssistantSec] are cumulative over the call. */
    private fun turnUsd(
        kind: RealtimeTransportKind,
        userSec: Double,
        priorAssistantSec: Double,
        elapsedSec: Double,
        assistantSec: Double,
    ): Double = when (kind) {
        RealtimeTransportKind.GeminiLive ->
            elapsedSec * 32 * 3.0 / 1_000_000 + assistantSec * 32 * 12.0 / 1_000_000
        else ->
            (userSec * 10 + priorAssistantSec * 20) * 10.0 / 1_000_000 + assistantSec * 20 * 20.0 / 1_000_000
    }

    private fun nearestRank(sorted: List<Long>, p: Double): String {
        if (sorted.isEmpty()) return "-"
        val rank = kotlin.math.ceil(p * sorted.size).toInt().coerceIn(1, sorted.size)
        return sorted[rank - 1].toString()
    }

    /**
     * Wire timeline (diagnostics): every message sent / received on the Gemini socket and every event reaching the
     * controller, with time since the first record. Consecutive records with the same label merge into one run
     * (count, bytes, peak |sample|, max gap) so per-frame audio stays readable.
     */
    private class WireTimeline(private val signals: TurnSignals) {
        private class Run(val label: String, val firstAt: Long) {
            var lastAt = firstAt
            var count = 0
            var bytes = 0L
            var peak = 0
            var maxGapMs = 0L
        }

        private val lock = Any()
        private val runs = mutableListOf<Run>()
        private var origin = -1L

        fun socket(inner: GeminiLiveSocket): GeminiLiveSocket = object : GeminiLiveSocket {
            // The transport reads the close code (1008 = session expired); a wrapper must not hide it.
            override val closeCode: Int? get() = inner.closeCode

            // The 1008 diagnostics carry the close reason; forward it too.
            override val closeReason: String? get() = inner.closeReason

            // The transport reads the outbound backlog to detect a stalled uplink.
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
            val bytes = (event as? RealtimeSessionEvent.AssistantAudio)?.base64?.let { decodedSize(it) } ?: 0L
            val detail = when (event) {
                is RealtimeSessionEvent.UserTranscript -> " final=${event.final}"
                is RealtimeSessionEvent.AssistantTranscript -> " final=${event.final}"
                else -> ""
            }
            add("ctl ${event::class.simpleName}$detail", bytes)
        }

        fun mark(label: String) = add("mark $label")

        private fun record(direction: String, text: String) {
            val obj = runCatching { Json.parseToJsonElement(text) as? JsonObject }.getOrNull()
            if (obj == null) {
                add("$direction <non-json ${text.length}>")
                return
            }
            val audio = (((obj["realtimeInput"] as? JsonObject)?.get("audio") as? JsonObject)?.get("data"))
                ?.jsonPrimitive?.content
            if (audio != null) {
                val pcm = java.util.Base64.getDecoder().decode(audio)
                add("$direction realtimeInput.audio", pcm.size.toLong(), peak16(pcm))
                return
            }
            val content = obj["serverContent"] as? JsonObject
            if (content != null) {
                val keys = content.keys.sorted().joinToString("+")
                val parts = ((content["modelTurn"] as? JsonObject)?.get("parts") as? JsonArray).orEmpty()
                val bytes = parts.sumOf { part ->
                    (((part as? JsonObject)?.get("inlineData") as? JsonObject)?.get("data"))?.jsonPrimitive?.content
                        ?.let { decodedSize(it) } ?: 0L
                }
                val input = (content["inputTranscription"] as? JsonObject)?.get("text")?.jsonPrimitive?.content
                val inputNote = input?.let { " inLen=${it.length}" }.orEmpty()
                if (direction == "recv" && bytes > 0) signals.audioRecv(SystemClock.elapsedRealtime())
                add("$direction serverContent{$keys}$inputNote", bytes)
                return
            }
            val activity = (obj["voiceActivity"] as? JsonObject)?.get("type")?.jsonPrimitive?.content
            if (activity != null) {
                if (direction == "recv") signals.activity(activity, SystemClock.elapsedRealtime())
                add("$direction voiceActivity.$activity")
                return
            }
            add("$direction ${obj.keys.sorted().joinToString("+")}")
        }

        private fun add(label: String, bytes: Long = 0, peak: Int = 0) {
            val now = SystemClock.elapsedRealtime()
            synchronized(lock) {
                if (origin < 0) origin = now
                val last = runs.lastOrNull()
                val run = if (last != null && last.label == label && !label.startsWith("mark")) {
                    last.maxGapMs = maxOf(last.maxGapMs, now - last.lastAt)
                    last.lastAt = now
                    last
                } else {
                    Run(label, now).also { runs += it }
                }
                run.count++
                run.bytes += bytes
                run.peak = maxOf(run.peak, peak)
            }
        }

        fun print(provider: String) {
            val copy = synchronized(lock) { runs.toList() }
            for (run in copy) {
                Log.i(
                    VoiceLive.TAG,
"VOICE-LIVE realtime timeline $provider +${run.firstAt - origin}..${run.lastAt - origin}ms ${run.label} " +
                        "n=${run.count} bytes=${run.bytes} peak=${run.peak} maxGapMs=${run.maxGapMs}",
                )
            }
        }

        private fun decodedSize(base64: String): Long = java.util.Base64.getDecoder().decode(base64).size.toLong()

        private fun peak16(pcm: ByteArray): Int {
            var peak = 0
            var i = 0
            while (i + 1 < pcm.size) {
                val sample = ((pcm[i + 1].toInt() shl 8) or (pcm[i].toInt() and 0xFF)).toShort().toInt()
                peak = maxOf(peak, kotlin.math.abs(sample))
                i += 2
            }
            return peak
        }
    }

    /**
     * Per-connection record (connect / setupComplete / goAway / closed times and close reason). "closed" is the socket
     * receive end, or a host close when that comes first; a goAway switch closes the old connection as host.
     */
    private class ConnectionLog {
        class Conn(val index: Int, val openAt: Long) {
            @Volatile var readyAt: Long? = null
            @Volatile var goAwayAt: Long? = null
            @Volatile var closedAt: Long? = null
            @Volatile var reason: String? = null
            @Volatile var closeCode: Int? = null

            /** Whether a setup / clientContent text sent on this connection contained [historyProbe]; never the text. */
            @Volatile var historyHit: Boolean? = null

            // Diagnostics: counts and times only, never content / URL / key.
            val sent = java.util.concurrent.ConcurrentHashMap<String, Int>()
            @Volatile var firstAudioSentAt: Long? = null
            @Volatile var lastAudioSentAt: Long? = null
            @Volatile var firstClientContentAt: Long? = null
            val received = java.util.concurrent.ConcurrentHashMap<String, Int>()
            @Volatile var lastRecvAt: Long? = null
        }

        /** Substring looked for in setup / clientContent of connections after the first (set after turn-1). */
        @Volatile var historyProbe: String? = null

        private val lock = Any()
        private val conns = mutableListOf<Conn>()

        val count: Int get() = synchronized(lock) { conns.size }

        private fun snapshot(): List<Conn> = synchronized(lock) { conns.toList() }

        fun wrap(inner: GeminiLiveSocket): GeminiLiveSocket {
            val conn = synchronized(lock) { Conn(conns.size + 1, SystemClock.elapsedRealtime()).also { conns += it } }
            fun closed(reason: String) {
                if (conn.closedAt != null) return
                conn.reason = reason
                conn.closedAt = SystemClock.elapsedRealtime()
            }
            return object : GeminiLiveSocket {
                override val closeCode: Int? get() = inner.closeCode

                override val closeReason: String? get() = inner.closeReason

                override val queueSize: Long get() = inner.queueSize

                override suspend fun send(text: String) {
                    noteHistory(conn, text)
                    noteSent(conn, text)
                    try {
                        inner.send(text)
                    } catch (e: Throwable) {
                        closed("send failed ${e::class.simpleName}")
                        throw e
                    }
                }

                override suspend fun receive(): String? {
                    val text = inner.receive()
                    if (text == null) {
                        conn.closeCode = inner.closeCode
                        closed("receive end code=${inner.closeCode ?: "-"}")
                    } else {
                        val obj = runCatching { Json.parseToJsonElement(text) as? JsonObject }.getOrNull()
                        val keys = obj?.keys.orEmpty()
                        val now = SystemClock.elapsedRealtime()
                        conn.lastRecvAt = now
                        for (key in keys) {
                            if (key == "serverContent") {
                                val sub = (obj?.get(key) as? JsonObject)?.keys.orEmpty()
                                for (k in sub) conn.received.merge("serverContent.$k", 1, Int::plus)
                            } else {
                                conn.received.merge(key, 1, Int::plus)
                            }
                        }
                        if ("setupComplete" in keys && conn.readyAt == null) conn.readyAt = now
                        if ("goAway" in keys && conn.goAwayAt == null) conn.goAwayAt = now
                    }
                    return text
                }

                override fun close() {
                    closed("host close")
                    inner.close()
                }

                override fun cancel() {
                    closed("stalled cancel")
                    inner.cancel()
                }
            }
        }

        private fun noteSent(conn: Conn, text: String) {
            val now = SystemClock.elapsedRealtime()
            if (text.contains("\"realtimeInput\"")) {
                val audio = text.contains("\"audio\"")
                conn.sent.merge(if (audio) "realtimeInput.audio" else "realtimeInput.other", 1, Int::plus)
                if (audio) {
                    if (conn.firstAudioSentAt == null) conn.firstAudioSentAt = now
                    conn.lastAudioSentAt = now
                }
                return
            }
            val keys = runCatching { (Json.parseToJsonElement(text) as? JsonObject)?.keys }.getOrNull().orEmpty()
            for (key in keys) conn.sent.merge(key, 1, Int::plus)
            if ("clientContent" in keys && conn.firstClientContentAt == null) conn.firstClientContentAt = now
        }

        /** One `VOICE-LIVE-DIAG` timeline mark per connection: what was sent / received, counts and times since [base]. */
        fun diag(timeline: WireTimeline, base: Long) {
            for (c in snapshot()) {
                fun rel(at: Long?) = at?.let { "+${it - base}" } ?: "-"
                fun counts(map: Map<String, Int>) = map.toSortedMap().entries.joinToString(",") { "${it.key}=${it.value}" }
                timeline.mark(
                    "VOICE-LIVE-DIAG conn#${c.index} open=${rel(c.openAt)} ready=${rel(c.readyAt)} " +
                        "goAway=${rel(c.goAwayAt)} closed=${rel(c.closedAt)} reason=${c.reason ?: "-"} " +
                        "sent{${counts(c.sent)}} firstClientContent=${rel(c.firstClientContentAt)} " +
                        "audioSent=${rel(c.firstAudioSentAt)}..${rel(c.lastAudioSentAt)} " +
                        "recv{${counts(c.received)}} lastRecv=${rel(c.lastRecvAt)} history=${c.historyHit ?: "-"}",
                )
            }
        }

        private fun noteHistory(conn: Conn, text: String) {
            val probe = historyProbe ?: return
            if (conn.index < 2 || text.contains("\"realtimeInput\"")) return
            val keys = runCatching { (Json.parseToJsonElement(text) as? JsonObject)?.keys }.getOrNull().orEmpty()
            if ("setup" !in keys && "clientContent" !in keys) return
            // The wire text is JSON: look for the probe as a JSON string body too (quotes / newlines escaped).
            val escaped = Json.encodeToString(String.serializer(), probe).removeSurrounding("\"")
            val hit = text.contains(probe) || text.contains(escaped)
            conn.historyHit = conn.historyHit == true || hit
        }

        /**
         * The connection opened after the first 1008 close (the controller's reopen; handle resumes before it carry
         * no history): whether its setup / clientContent carried [historyProbe]; null = none sent / no such connection.
         */
        fun historyOnReopen(): Boolean? {
            val all = snapshot()
            val expiredAt = all.firstOrNull { it.closeCode == SESSION_EXPIRED_CODE }?.closedAt ?: return null
            return all.firstOrNull { it.openAt >= expiredAt }?.historyHit
        }

        /** Closes not made by the host (network / server) within [from, to]. */
        /** Server closes with 1008 (session expired / resumption rejected) within [from, to]. */
        fun expiredBetween(from: Long, to: Long): Int =
            snapshot().count { c -> c.closeCode == SESSION_EXPIRED_CODE && c.closedAt?.let { it in from..to } == true }

        fun closedBetween(from: Long, to: Long): Int =
            snapshot().count { c -> c.reason != "host close" && c.closedAt?.let { it in from..to } == true }

        fun latestReady(): Boolean = snapshot().lastOrNull()?.let { it.readyAt != null && it.closedAt == null } == true

        fun describe(base: Long): String = snapshot().joinToString(" ", prefix = "conns=[", postfix = "]") { c ->
            fun rel(at: Long?) = at?.let { "+${it - base}" } ?: "-"
            "#${c.index}{open=${rel(c.openAt)} ready=${rel(c.readyAt)} goAway=${rel(c.goAwayAt)} " +
                "closed=${rel(c.closedAt)} reason=${c.reason ?: "-"} history=${c.historyHit ?: "-"}}"
        }
    }

    /** User / assistant persists of the current turn, as the controller emits them. */
    private class TurnSignals {
        @Volatile var userText: String? = null
            private set

        @Volatile var assistantText: String? = null
            private set

        // Socket-layer receive times and the controller's AssistantTurnDone; first one after reset() wins.
        @Volatile var activityStartAt: Long? = null
            private set

        @Volatile var activityEndAt: Long? = null
            private set

        @Volatile var firstAudioRecvAt: Long? = null
            private set

        @Volatile var turnDoneAt: Long? = null
            private set

        fun reset() {
            userText = null
            assistantText = null
            activityStartAt = null
            activityEndAt = null
            firstAudioRecvAt = null
            turnDoneAt = null
        }

        fun activity(type: String, at: Long) {
            when (type) {
                "ACTIVITY_START" -> if (activityStartAt == null) activityStartAt = at
                "ACTIVITY_END" -> if (activityEndAt == null) activityEndAt = at
            }
        }

        fun audioRecv(at: Long) {
            if (firstAudioRecvAt == null) firstAudioRecvAt = at
        }

        fun turnDone(at: Long) {
            if (turnDoneAt == null) turnDoneAt = at
        }

        fun user(text: String) {
            if (text.isNotBlank()) userText = text
        }

        fun assistant(text: String) {
            assistantText = text
        }
    }

    /** Uplinks 24 kHz PCM16 in 20 ms frames at real-time pace. */
    private class FramePump(private val onFrame: (ByteArray) -> Unit) {
        private var next = SystemClock.elapsedRealtime()
        private var sentBytes = 0L

        val sentSec: Double get() = sentBytes / BYTES_PER_SEC

        fun push(samples: ShortArray) {
            var offset = 0
            while (offset < samples.size) {
                val count = minOf(FRAME_SAMPLES, samples.size - offset)
                val frame = ShortArray(FRAME_SAMPLES)
                samples.copyInto(frame, 0, offset, offset + count)
                send(RealtimePCM.toLittleEndian(frame))
                offset += count
            }
        }

        fun silence() = send(ByteArray(FRAME_SAMPLES * 2))

        private fun send(frame: ByteArray) {
            val wait = next - SystemClock.elapsedRealtime()
            if (wait > 0) Thread.sleep(wait) else next = SystemClock.elapsedRealtime()
            onFrame(frame)
            sentBytes += frame.size
            next += FRAME_MS
        }
    }

    /**
     * Injected audio: no microphone or speaker. Playback is simulated in real time (queued audio "plays" at
     * 24 kHz from when it is enqueued), so the controller's drain and played-duration logic sees real timing.
     */
    private class InjectedAudio : RealtimeAudioIO {
        private val lock = Any()
        private val started = CountDownLatch(1)

        @Volatile private var onFrame: ((ByteArray) -> Unit)? = null
        private var playEnd = 0L
        private val items = HashMap<String, LongArray>() // itemId -> [startMs, endMs)
        private var speechEndAt: Long? = null

        @Volatile var firstAudioAt: Long? = null
            private set

        @Volatile var turnAudioBytes = 0L
            private set

        fun currentOnFrame(): ((ByteArray) -> Unit)? = onFrame

        fun awaitStart(timeoutMs: Long): ((ByteArray) -> Unit)? =
            if (started.await(timeoutMs, TimeUnit.MILLISECONDS)) onFrame else null

        fun resetTurn() = synchronized(lock) {
            speechEndAt = null
            firstAudioAt = null
            turnAudioBytes = 0L
        }

        fun markSpeechEnd(at: Long) = synchronized(lock) { speechEndAt = at }

        override fun start(onFrame: (ByteArray) -> Unit, onInterruption: () -> Unit) {
            this.onFrame = onFrame
            started.countDown()
        }

        override fun enqueue(pcm16: ByteArray, itemId: String) {
            val now = SystemClock.elapsedRealtime()
            synchronized(lock) {
                if (speechEndAt != null && firstAudioAt == null) firstAudioAt = now
                turnAudioBytes += pcm16.size
                val start = maxOf(now, playEnd)
                playEnd = start + (pcm16.size / 2) * 1000L / RealtimePCM.OUTPUT_RATE
                val range = items.getOrPut(itemId) { longArrayOf(start, start) }
                range[1] = playEnd
            }
        }

        override fun playedMs(itemId: String): Long = synchronized(lock) {
            val range = items[itemId] ?: return 0L
            (SystemClock.elapsedRealtime() - range[0]).coerceIn(0L, range[1] - range[0])
        }

        override val isPlaying: Boolean
            get() = synchronized(lock) { SystemClock.elapsedRealtime() < playEnd }

        override fun stopPlayback() {
            val now = SystemClock.elapsedRealtime()
            synchronized(lock) {
                for (range in items.values) range[1] = minOf(range[1], maxOf(range[0], now))
                playEnd = now
            }
        }

        override fun stop() {
            stopPlayback()
        }
    }

    /** 24 kHz mono 16-bit WAV → samples (walks RIFF chunks). */
    private fun readWav24k(file: File): ShortArray {
        val wav = file.readBytes()
        val bytes = ByteBuffer.wrap(wav).order(ByteOrder.LITTLE_ENDIAN)
        require(String(wav, 0, 4, Charsets.US_ASCII) == "RIFF" && String(wav, 8, 4, Charsets.US_ASCII) == "WAVE") {
            "not a WAVE file: ${file.name}"
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
                require(channels == 1 && rate == RealtimePCM.OUTPUT_RATE && bits == 16) {
                    "expected 24 kHz mono 16-bit, got $channels/$rate/$bits"
                }
            } else if (id == "data") {
                val count = minOf(length, wav.size - body) / 2
                return ShortArray(count) { bytes.getShort(body + it * 2) }
            }
            at = body + length + (length and 1)
        }
        error("no data chunk in ${file.name}")
    }

    private companion object {
        const val GROUP = "realtime"
        const val ITEM = "realtime"
        const val OPENAI_MODEL = "gpt-realtime-2.1-mini"
        const val OPENAI_HOST = "api.openai.com"
        const val GEMINI_HOST = "generativelanguage.googleapis.com"
        const val CALL_LIMIT_MS = 90_000L
        const val TURN_TIMEOUT_MS = 25_000L
        const val READY_TIMEOUT_MS = 20_000L
        const val END_TIMEOUT_MS = 10_000L
        const val PROJECTED_ASSISTANT_SEC = 15.0
        const val FRAME_MS = 20L
        const val FRAME_SAMPLES = RealtimePCM.OUTPUT_RATE / 50
        const val TRANSCRIPT_GRACE_FRAMES = 100
        const val BYTES_PER_SEC = RealtimePCM.OUTPUT_RATE * 2.0
        const val MUTE_MAX_MS = 870_000L
        const val MUTE_POLL_MS = 1_000L
        const val MUTE_LIMIT_USD = 0.05
        const val EXPIRE_SETTLE_MS = 2_000L
        const val DIAG_SETTLE_MS = 1_000L
        const val SESSION_EXPIRED_CODE = 1008
        const val HISTORY_PROBE_CHARS = 20
        const val MUTE_CALL_LIMIT_MS = MUTE_MAX_MS + 180_000L
    }
}
