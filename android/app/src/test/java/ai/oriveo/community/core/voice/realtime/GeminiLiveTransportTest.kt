package ai.oriveo.community.core.voice.realtime

import ai.oriveo.community.core.context.RealtimeHistoryItem
import ai.oriveo.community.core.data.repository.RealtimeTransportInput
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveClosedException
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveConfig
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveSessionExpiredException
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveSocket
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveSocketFactory
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveTransport
import ai.oriveo.community.core.voice.realtime.wire.OkHttpGeminiLiveSocketFactory
import java.io.File
import java.io.IOException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** GeminiLiveTransport over a fake socket and virtual time: opening order, GoAway resumption and how the stream ends. */
@OptIn(ExperimentalCoroutinesApi::class)
class GeminiLiveTransportTest {

    private class FakeSocket(private val failSend: Boolean = false) : GeminiLiveSocket {
        val sent = mutableListOf<JsonObject>()
        private val incoming = Channel<String>(Channel.UNLIMITED)
        var closed = false
        /** Simulates the server having dropped before the Closed signal arrives: later sends fail. */
        var failSendNow = false
        /** How many frames can still be sent successfully; after that send fails. */
        var sendBudget = Int.MAX_VALUE
        /** Simulates a stuck upstream TCP: bytes passed to send afterwards all stay in the outbound queue and never drain. */
        var stalled = false
        private var queued = 0L
        override val queueSize: Long get() = queued
        var cancelled = false

        /** Upstream recovers: the outbound queue drains and no longer backs up. */
        fun drain() {
            stalled = false
            queued = 0L
        }

        override suspend fun send(text: String) {
            if (failSend || failSendNow || sendBudget <= 0) throw IOException("send failed")
            sendBudget--
            if (stalled) queued += text.toByteArray().size
            sent += Json.parseToJsonElement(text).jsonObject
        }

        /** The call order of close / cancel. */
        val shutdownCalls = mutableListOf<String>()

        override fun cancel() {
            shutdownCalls += "cancel"
            cancelled = true
            closed = true
            incoming.close()
        }

        override suspend fun receive(): String? = incoming.receiveCatching().getOrNull()

        override var closeCode: Int? = null

        override fun close() {
            shutdownCalls += "close"
            closed = true
            incoming.close()
        }

        fun server(json: String) {
            incoming.trySend(json)
        }

        /** The server closes the connection: receive returns null. */
        fun serverClose() {
            incoming.close()
        }

        /** The server closes the connection with [code] (for example 1008, session not found / expired). */
        fun serverClose(code: Int, reason: String? = null) {
            closeCode = code
            closeReason = reason
            incoming.close()
        }

        override var closeReason: String? = null
    }

    private class FakeFactory(private val failSend: Boolean = false, private val failConnect: Boolean = false) :
        GeminiLiveSocketFactory {
        val urls = mutableListOf<String>()
        val sockets = mutableListOf<FakeSocket>()

        override suspend fun connect(url: String): GeminiLiveSocket {
            urls += url
            if (failConnect) throw IOException("cannot reach $url")
            return FakeSocket(failSend).also { sockets += it }
        }
    }

    private val fixture: JsonObject by lazy {
        Json.parseToJsonElement(workspaceFile("shared/voice-contracts/realtime-events.v1.json").readText()).jsonObject
    }

    private fun fixtureCase(key: String, id: String): JsonObject =
        fixture[key]!!.jsonArray.map { it.jsonObject }.single { it["id"]!!.jsonPrimitive.content == id }

    /** Builds the transport config and input from an openCases input (instructions / history / model / voice / path). */
    private fun openCaseSetup(openCase: JsonObject): Pair<GeminiLiveConfig, RealtimeTransportInput> {
        val openInput = openCase["input"]!!.jsonObject
        val plan = openInput["plan"]!!.jsonObject
        val history = plan["history"]!!.jsonArray.map {
            val item = it.jsonObject
            val role = if (item["role"]!!.jsonPrimitive.content == "assistant") ChatRole.Assistant else ChatRole.User
            RealtimeHistoryItem(role, item["text"]!!.jsonPrimitive.content)
        }
        val entry = openInput["entry"]!!.jsonObject
        val fixtureConfig = config.copy(
            path = entry["path"]!!.jsonPrimitive.content,
            model = entry["model"]!!.jsonPrimitive.content,
            voice = openInput["voice"]!!.jsonPrimitive.content,
        )
        return fixtureConfig to RealtimeTransportInput(plan["instructions"]!!.jsonPrimitive.content, history)
    }

    private fun audio(base64: String): JsonObject =
        Json.parseToJsonElement("""{"realtimeInput":{"audio":{"data":"$base64","mimeType":"audio/pcm;rate=16000"}}}""").jsonObject

    /** Collects one stream: events, the terminating exception, and whether it has ended. */
    private class Collected(val events: MutableList<RealtimeSessionEvent>, val job: Job) {
        var error: Throwable? = null
        val finished get() = job.isCompleted
    }

    private val config = GeminiLiveConfig(
        host = "generativelanguage.googleapis.com",
        path = "/ws/live",
        model = "gemini-live",
        voice = "Kore",
        apiKey = "k+y/=",
    )

    private val input = RealtimeTransportInput(
        instructions = "Be brief.",
        history = listOf(RealtimeHistoryItem(ChatRole.User, "Hi"), RealtimeHistoryItem(ChatRole.Assistant, "Hello")),
    )

    private fun TestScope.collect(transport: GeminiLiveTransport, transportInput: RealtimeTransportInput = input): Collected {
        val events = mutableListOf<RealtimeSessionEvent>()
        lateinit var collected: Collected
        val job = launch {
            try {
                transport.openRealtimeSession(transportInput).collect { events += it }
            } catch (e: Throwable) {
                collected.error = e
            }
        }
        collected = Collected(events, job)
        runCurrent()
        return collected
    }

    private fun FakeSocket.say(json: String, scope: TestScope) {
        server(json)
        scope.runCurrent()
    }

    private val setupComplete = """{"setupComplete":{}}"""
    private fun resumable(handle: String) = """{"sessionResumptionUpdate":{"newHandle":"$handle","resumable":true}}"""
    private fun goAway(timeLeft: String) = """{"goAway":{"timeLeft":"$timeLeft"}}"""
    private val userSpeaking = """{"serverContent":{"inputTranscription":{"text":"Hey"}}}"""
    private val turnComplete = """{"serverContent":{"turnComplete":true}}"""

    private fun JsonObject.setup(): JsonObject = this["setup"]!!.jsonObject

    @Test
    fun `history_sent_after_setup_complete`() = runTest {
        val mapCase = fixtureCase("mapCases", "gemini_normal_turn")
        val openCase = fixtureCase("openCases", "open_gemini_history_in_client_content")
        val (fixtureConfig, fixtureInput) = openCaseSetup(openCase)
        val factory = FakeFactory()
        val transport = GeminiLiveTransport(fixtureConfig, socketFactory = factory)
        // Audio before the first ready (including before collect starts) is buffered and flushed in order after the history has been sent
        transport.appendAudio("PRE1")
        val run = collect(transport, fixtureInput)
        transport.appendAudio("PRE2")
        runCurrent()
        val socket = factory.sockets.single()
        val expectedOpen = openCase["expected"]!!.jsonObject
        val beforeReady = expectedOpen["beforeReady"]!!.jsonArray.map { it.jsonObject }
        val afterReady = expectedOpen["afterReady"]!!.jsonArray.map { it.jsonObject }
        assertEquals(beforeReady, socket.sent)

        val messages = mapCase["input"]!!.jsonObject["messages"]!!.jsonArray
        socket.say(messages.first().toString(), this)
        val opened = beforeReady + afterReady + listOf(audio("PRE1"), audio("PRE2"))
        assertEquals(opened, socket.sent)
        for (message in messages.drop(1)) socket.say(message.toString(), this)
        transport.close()
        runCurrent()

        assertTrue(run.finished)
        assertNull(run.error)
        assertEquals(mapCase["expected"]!!, JsonArray(run.events.map { it.toJson() }))
        assertEquals(opened, socket.sent)
    }

    /** With the Ktor WebSockets layer the server only saw uplink 15 s late and did not answer; the production default must be the bare OkHttp socket. */
    @Test
    fun `default_socket_factory_is_bare_okhttp`() {
        assertSame(OkHttpGeminiLiveSocketFactory, GeminiLiveTransport(config).socketFactory)
    }

    @Test
    fun `connect_uses_authenticated_url`() = runTest {
        val factory = FakeFactory()
        val run = collect(GeminiLiveTransport(config, socketFactory = factory))
        assertEquals(listOf("wss://generativelanguage.googleapis.com/ws/live?key=k%2By%2F%3D"), factory.urls)
        run.job.cancel()
    }

    @Test
    fun `resumed_open_sends_handle_not_history`() = runTest {
        val factory = FakeFactory()
        val transport = GeminiLiveTransport(config, resumeHandle = "h0", socketFactory = factory)
        val run = collect(transport)
        val socket = factory.sockets.single()
        val setup = socket.sent.single().setup()
        assertEquals("h0", setup["sessionResumption"]!!.jsonObject["handle"]!!.jsonPrimitive.content)
        assertFalse(setup.containsKey("historyConfig"))
        socket.say(setupComplete, this)
        assertEquals(1, socket.sent.size)
        assertEquals(listOf<RealtimeSessionEvent>(RealtimeSessionEvent.Ready), run.events)
        assertEquals("h0", transport.lastResumeHandle)
        run.job.cancel()
    }

    @Test
    fun `go_away_idle_reconnects_with_last_handle`() = runTest {
        val openCase = fixtureCase("openCases", "open_gemini_resume_sends_handle_not_history")
        val handle = openCase["input"]!!.jsonObject["resumeHandle"]!!.jsonPrimitive.content
        val (fixtureConfig, fixtureInput) = openCaseSetup(openCase)
        val factory = FakeFactory()
        val transport = GeminiLiveTransport(fixtureConfig, socketFactory = factory)
        val run = collect(transport, fixtureInput)
        val first = factory.sockets.single()
        first.say(setupComplete, this)
        first.say(resumable("h-0"), this)
        first.say(resumable(handle), this)
        first.say(goAway("10s"), this)

        assertTrue(first.closed)
        assertEquals(2, factory.sockets.size)
        assertEquals(factory.urls[0], factory.urls[1])
        // The resume setup frame = the fixture's beforeReady (original instructions, with handle, no history), and no clientContent is sent afterwards
        val expectedSetup = openCase["expected"]!!.jsonObject["beforeReady"]!!.jsonArray.map { it.jsonObject }
        assertEquals(expectedSetup, factory.sockets[1].sent)
        factory.sockets[1].say(setupComplete, this)
        assertEquals(expectedSetup, factory.sockets[1].sent)
        assertEquals(handle, transport.lastResumeHandle)
        assertEquals(RealtimeSessionEvent.GoAway(10_000), run.events.last())
        assertFalse(run.finished)
        run.job.cancel()
    }

    @Test
    fun `go_away_mid_turn_waits_for_turn_complete`() = runTest {
        val factory = FakeFactory()
        val run = collect(GeminiLiveTransport(config, socketFactory = factory))
        val first = factory.sockets.single()
        first.say(setupComplete, this)
        first.say(resumable("h1"), this)
        first.say(userSpeaking, this)
        first.say(goAway("30s"), this)
        assertEquals(1, factory.sockets.size)
        assertFalse(first.closed)

        first.say(turnComplete, this)
        assertTrue(first.closed)
        assertEquals(2, factory.sockets.size)
        val setup = factory.sockets[1].sent.single().setup()
        assertEquals("h1", setup["sessionResumption"]!!.jsonObject["handle"]!!.jsonPrimitive.content)
        assertTrue(run.events.any { it is RealtimeSessionEvent.AssistantTurnDone })
        run.job.cancel()
    }

    @Test
    fun `go_away_forces_switch_when_time_left_runs_out`() = runTest {
        val factory = FakeFactory()
        val waits = mutableListOf<Long>()
        val transport = GeminiLiveTransport(config, socketFactory = factory, wait = { waits += it; delay(it) })
        val run = collect(transport)
        val first = factory.sockets.single()
        first.say(setupComplete, this)
        first.say(resumable("h1"), this)
        first.say(userSpeaking, this)
        first.say(goAway("5s"), this)
        assertEquals(listOf(4_000L), waits)

        advanceTimeBy(3_999)
        runCurrent()
        assertEquals(1, factory.sockets.size)
        advanceTimeBy(1)
        runCurrent()
        assertTrue(first.closed)
        assertEquals(2, factory.sockets.size)
        run.job.cancel()
    }

    @Test
    fun `gemini_switch_flushes_pending_user_text`() = runTest {
        val factory = FakeFactory()
        val transport = GeminiLiveTransport(config, socketFactory = factory, wait = { delay(it) })
        val run = collect(transport)
        val first = factory.sockets.single()
        first.say(setupComplete, this)
        first.say(resumable("h1"), this)
        // The reply starts first, then a late transcript for this turn (not final), then new speech carries into the next turn
        first.say("""{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"data":"AAAA"}}]}}}""", this)
        first.say("""{"serverContent":{"outputTranscription":{"text":"Sure"}}}""", this)
        first.say("""{"serverContent":{"inputTranscription":{"text":"Late"}}}""", this)
        first.say("""{"voiceActivity":{"type":"ACTIVITY_START"}}""", this)
        first.say("""{"serverContent":{"inputTranscription":{"text":"Next"}}}""", this)
        first.say(goAway("5s"), this)
        assertEquals(1, factory.sockets.size)
        val before = run.events.size
        advanceTimeBy(4_000)
        runCurrent()

        // Before force-switching the mapper: this turn's non-final text first, then the next turn's, once each; the assistant's unfinished text is not flushed
        assertTrue(first.closed)
        assertEquals(2, factory.sockets.size)
        assertEquals(
            listOf<RealtimeSessionEvent>(
                RealtimeSessionEvent.UserTranscript(null, "Late", final = true),
                RealtimeSessionEvent.UserTranscript(null, "Next", final = true),
            ),
            run.events.drop(before),
        )
        factory.sockets[1].say(setupComplete, this)
        factory.sockets[1].say(turnComplete, this)
        assertTrue(run.events.drop(before).none { it is RealtimeSessionEvent.UserTranscript && it.text != "Late" && it.text != "Next" })
        assertEquals(2, run.events.count { it is RealtimeSessionEvent.UserTranscript && it.final })
        run.job.cancel()
    }

    @Test
    fun `gemini_expiry_without_handle_flushes_pending_user_text`() = runTest {
        val factory = FakeFactory()
        val transport = GeminiLiveTransport(config, socketFactory = factory)
        val run = collect(transport)
        val first = factory.sockets.single()
        first.say(setupComplete, this)
        first.say(goAway("10s"), this)
        // While waiting for close with no handle: unfinished assistant text, then late user text (not final)
        first.say("""{"serverContent":{"outputTranscription":{"text":"Sure"}}}""", this)
        first.say(userSpeaking, this)
        first.serverClose()
        runCurrent()

        // Before ending, user text is emitted as final, then SessionEnded; the assistant's unfinished text is not flushed
        assertTrue(run.finished)
        assertNull(run.error)
        assertEquals(1, factory.sockets.size)
        assertEquals(
            listOf(
                RealtimeSessionEvent.UserTranscript(null, "Hey", final = true),
                RealtimeSessionEvent.SessionEnded("go_away"),
            ),
            run.events.takeLast(2),
        )
        assertEquals(1, run.events.count { it is RealtimeSessionEvent.UserTranscript && it.final })
        assertTrue(run.events.none { it is RealtimeSessionEvent.AssistantTranscript && it.final })
    }

    @Test
    fun `gemini_session_expired_flushes_pending_user_text`() = runTest {
        val factory = FakeFactory()
        val transport = GeminiLiveTransport(config, socketFactory = factory)
        val run = collect(transport)
        val first = factory.sockets.single()
        first.say(setupComplete, this)
        first.say(resumable("h1"), this)
        // The reply has started, then late user text (not final)
        first.say("""{"serverContent":{"outputTranscription":{"text":"Sure"}}}""", this)
        first.say(userSpeaking, this)
        // 1008 session expiry: before ending with an error, unfinished user text is emitted as final, and there is no resumption
        first.serverClose(1008)
        runCurrent()

        assertTrue(run.finished)
        assertSessionExpiredWithoutKey(run.error)
        assertEquals(1, factory.sockets.size)
        assertEquals(RealtimeSessionEvent.UserTranscript(null, "Hey", final = true), run.events.last())
        assertEquals(1, run.events.count { it is RealtimeSessionEvent.UserTranscript && it.final })
        assertTrue(run.events.none { it is RealtimeSessionEvent.AssistantTranscript && it.final })
    }

    @Test
    fun `gemini_drop_without_handle_flushes_pending_user_text`() = runTest {
        val factory = FakeFactory()
        val transport = GeminiLiveTransport(config, socketFactory = factory)
        val run = collect(transport)
        val first = factory.sockets.single()
        first.say(setupComplete, this)
        // The reply has started, then late user text (not final)
        first.say("""{"serverContent":{"outputTranscription":{"text":"Sure"}}}""", this)
        first.say(userSpeaking, this)
        // Unexpected disconnect with no handle: before ending with an error, unfinished user text is emitted as final
        first.serverClose()
        runCurrent()

        assertTrue(run.finished)
        assertClosedWithoutKey(run.error)
        assertEquals(1, factory.sockets.size)
        assertEquals(RealtimeSessionEvent.UserTranscript(null, "Hey", final = true), run.events.last())
        assertEquals(1, run.events.count { it is RealtimeSessionEvent.UserTranscript && it.final })
        assertTrue(run.events.none { it is RealtimeSessionEvent.AssistantTranscript && it.final })
    }

    @Test
    fun `gemini_switch_flushes_current_turn_user_text`() = runTest {
        val factory = FakeFactory()
        val transport = GeminiLiveTransport(config, socketFactory = factory, wait = { delay(it) })
        val run = collect(transport)
        val first = factory.sockets.single()
        first.say(setupComplete, this)
        first.say(resumable("h1"), this)
        first.say(userSpeaking, this)
        // Resuming after an unexpected disconnect: this turn's non-final user text is emitted as final before the old mapper is discarded
        first.serverClose()
        runCurrent()

        assertEquals(2, factory.sockets.size)
        assertEquals(RealtimeSessionEvent.UserTranscript(null, "Hey", final = true), run.events.last())
        // If the new connection fails to reconnect and drops again, nothing is delivered twice
        factory.sockets[1].serverClose()
        runCurrent()
        assertEquals(1, run.events.count { it is RealtimeSessionEvent.UserTranscript && it.final })
        run.job.cancel()
    }

    @Test
    fun `resumed_ready_not_reemitted`() = runTest {
        val factory = FakeFactory()
        val run = collect(GeminiLiveTransport(config, socketFactory = factory))
        val first = factory.sockets.single()
        first.say(setupComplete, this)
        first.say(resumable("h1"), this)
        first.say(goAway("10s"), this)
        val second = factory.sockets[1]
        second.say(setupComplete, this)

        assertEquals(1, run.events.count { it == RealtimeSessionEvent.Ready })
        assertEquals(1, second.sent.size)
        assertFalse(run.finished)
        run.job.cancel()
    }

    @Test
    fun `audio_buffered_during_switch_and_flushed_after_ready`() = runTest {
        val factory = FakeFactory()
        val transport = GeminiLiveTransport(config, socketFactory = factory)
        val run = collect(transport)
        val first = factory.sockets.single()
        first.say(setupComplete, this)
        transport.appendAudio("AAAA")
        runCurrent()
        assertEquals("AAAA", first.sent.last().audioData())

        first.say(resumable("h1"), this)
        first.say(goAway("10s"), this)
        val second = factory.sockets[1]
        val b = "B".repeat(100)
        val c = "C".repeat(219_900)
        transport.appendAudio(b)
        transport.appendAudio(c)
        transport.appendAudio("D")
        runCurrent()
        assertEquals(1, second.sent.size)

        second.say(setupComplete, this)
        assertEquals(listOf(c, "D"), second.sent.drop(1).map { it.audioData() })
        transport.appendAudio("EEEE")
        runCurrent()
        assertEquals("EEEE", second.sent.last().audioData())
        run.job.cancel()
    }

    @Test
    fun `go_away_without_handle_ends_session`() = runTest {
        val factory = FakeFactory()
        val transport = GeminiLiveTransport(config, socketFactory = factory)
        val run = collect(transport)
        val first = factory.sockets.single()
        first.say(setupComplete, this)
        first.say(goAway("10s"), this)
        assertEquals(1, factory.sockets.size)
        assertFalse(run.finished)
        // While waiting for the server to close, audio is still sent on the old connection
        transport.appendAudio("ZZZZ")
        runCurrent()
        assertEquals(audio("ZZZZ"), first.sent.last())

        first.serverClose()
        runCurrent()
        assertTrue(run.finished)
        assertNull(run.error)
        assertEquals(1, factory.sockets.size)
        assertEquals(
            listOf(RealtimeSessionEvent.Ready, RealtimeSessionEvent.GoAway(10_000), RealtimeSessionEvent.SessionEnded("go_away")),
            run.events,
        )
    }

    @Test
    fun `goaway_without_handle_then_1008_is_session_expired`() = runTest {
        val factory = FakeFactory()
        val run = collect(GeminiLiveTransport(config, socketFactory = factory))
        val first = factory.sockets.single()
        first.say(setupComplete, this)
        first.say(goAway("10s"), this)
        // A 1008 close after ready is always session expiry, taking precedence over "goAway without handle, wait for close, end normally"
        first.serverClose(1008)
        runCurrent()

        assertTrue(run.finished)
        assertSessionExpiredWithoutKey(run.error)
        assertEquals(listOf(RealtimeSessionEvent.Ready, RealtimeSessionEvent.GoAway(10_000)), run.events)
        assertEquals(1, factory.sockets.size)
    }

    @Test
    fun `session_expired_1008_reason_in_message_truncated_without_url_or_key`() = runTest {
        val factory = FakeFactory()
        val run = collect(GeminiLiveTransport(config, socketFactory = factory))
        val first = factory.sockets.single()
        first.say(setupComplete, this)
        // The close reason goes into the error description, truncated to 200 characters, without URL / key
        val reason = "BidiGenerateContent session is already connected to an existing client " +
            "wss://generativelanguage.googleapis.com/ws?key=${config.apiKey} " + "x".repeat(300)
        first.serverClose(1008, reason)
        runCurrent()

        assertTrue(run.finished)
        assertSessionExpiredWithoutKey(run.error)
        val message = run.error!!.message.orEmpty()
        assertTrue(message, message.contains("session is already connected to an existing client"))
        assertFalse(message, message.contains("wss://") || message.contains("googleapis"))
        assertFalse(message, message.contains("x".repeat(201)))
        val tail = message.substringAfter("(1008)")
        assertTrue(message, tail.length <= 200 + 2)
    }

    @Test
    fun `session_expired_1008_reason_redacts_bare_and_percent_encoded_key`() = runTest {
        val factory = FakeFactory()
        val run = collect(GeminiLiveTransport(config, socketFactory = factory))
        val first = factory.sockets.single()
        first.say(setupComplete, this)
        // A key in the reason without a key= prefix, and its percent-encoded form, must also be stripped (matches iOS diagnosticReason)
        val lead = "BidiGenerateContent session is already connected to an existing client"
        val reason = "$lead wss://${config.host}${config.path}?key=${config.apiKey} " +
            "API key ${config.apiKey} expired; encoded k%2By%2F%3D " + "x".repeat(300)
        first.serverClose(1008, reason)
        runCurrent()

        assertTrue(run.finished)
        assertSessionExpiredWithoutKey(run.error)
        val message = run.error!!.message.orEmpty()
        assertTrue(message, message.contains(lead))
        assertTrue(message, message.contains("API key <redacted> expired; encoded <redacted>"))
        assertFalse(message, message.contains("wss://") || message.contains(config.host))
        assertFalse(message, message.contains("x".repeat(201)))
        assertTrue(message, message.substringAfter("(1008)").length <= 200 + 2)
    }

    @Test
    fun `goaway_without_handle_send_failure_ends_normally`() = runTest {
        val factory = FakeFactory()
        val transport = GeminiLiveTransport(config, socketFactory = factory)
        val run = collect(transport)
        val first = factory.sockets.single()
        first.say(setupComplete, this)
        first.say(goAway("10s"), this)
        // An uplink send failure while goAway has no handle ends normally as goAway and does not throw
        first.failSendNow = true
        transport.appendAudio("AAAA")
        runCurrent()

        assertTrue(run.finished)
        assertNull(run.error)
        assertEquals(
            listOf(RealtimeSessionEvent.Ready, RealtimeSessionEvent.GoAway(10_000), RealtimeSessionEvent.SessionEnded("go_away")),
            run.events,
        )
        assertEquals(1, factory.sockets.size)
    }

    @Test
    fun `ready_then_drop_repeatedly_stops_after_four`() = runTest {
        val factory = FakeFactory()
        val waits = mutableListOf<Long>()
        val run = collect(GeminiLiveTransport(config, socketFactory = factory, wait = { waits += it; delay(it) }))
        val first = factory.sockets.single()
        first.say(setupComplete, this)
        first.say(resumable("h1"), this)
        first.serverClose()
        runCurrent()
        // A resumed connection dropped by a non-1008 close right after ready: ready does not reset the count, backoff keeps growing, and after 4 attempts the stream ends with an error
        repeat(4) {
            if (run.finished) return@repeat
            val resumed = factory.sockets.last()
            resumed.say(setupComplete, this)
            resumed.serverClose()
            advanceTimeBy(5_000)
            runCurrent()
        }

        assertTrue(run.finished)
        assertClosedWithoutKey(run.error)
        assertEquals(5, factory.sockets.size)
        assertEquals(listOf(0L, 1_000L, 2_000L, 4_000L), waits)
    }

    @Test
    fun `counter_resets_after_server_content`() = runTest {
        val factory = FakeFactory()
        val waits = mutableListOf<Long>()
        val transport = GeminiLiveTransport(config, socketFactory = factory, wait = { waits += it; delay(it) })
        val run = collect(transport)
        val first = factory.sockets.single()
        first.say(setupComplete, this)
        first.say(resumable("h1"), this)
        first.serverClose()
        runCurrent()
        assertEquals(2, factory.sockets.size)
        // A resumed connection receives serverContent after ready: the count resets, and the next disconnect starts backoff from 0 again
        val second = factory.sockets[1]
        second.say(setupComplete, this)
        second.say(userSpeaking, this)
        second.serverClose()
        runCurrent()
        assertEquals(3, factory.sockets.size)
        // Only ready, no serverContent: no reset, and the next wait is 1 s
        val third = factory.sockets[2]
        third.say(setupComplete, this)
        third.serverClose()
        advanceTimeBy(1_000)
        runCurrent()

        assertEquals(4, factory.sockets.size)
        assertEquals(listOf(0L, 0L, 1_000L), waits)
        assertFalse(run.finished)
        transport.close()
        runCurrent()
        assertTrue(run.finished)
    }

    @Test
    fun `unexpected_close_fails_stream`() = runTest {
        val factory = FakeFactory()
        val run = collect(GeminiLiveTransport(config, socketFactory = factory))
        val first = factory.sockets.single()
        first.say(setupComplete, this)
        first.serverClose()
        runCurrent()

        assertTrue(run.finished)
        assertClosedWithoutKey(run.error)
        assertEquals(listOf<RealtimeSessionEvent>(RealtimeSessionEvent.Ready), run.events)

        // setup send failure: the stream ends with its own exception and the registered socket is closed
        val failingSend = FakeFactory(failSend = true)
        val sendRun = collect(GeminiLiveTransport(config, socketFactory = failingSend))
        assertTrue(sendRun.finished)
        assertClosedWithoutKey(sendRun.error)
        assertTrue(failingSend.sockets.single().closed)

        // Connection failure (the original error contains a URL with the key): mapped to its own exception without attaching the cause
        val failingConnect = FakeFactory(failConnect = true)
        val connectRun = collect(GeminiLiveTransport(config, socketFactory = failingConnect))
        assertTrue(connectRun.finished)
        assertClosedWithoutKey(connectRun.error)
        assertTrue(run.events.none { it is RealtimeSessionEvent.Error })
    }

    @Test
    fun `unexpected_close_with_handle_reconnects_with_last_handle`() = runTest {
        val factory = FakeFactory()
        val waits = mutableListOf<Long>()
        val transport = GeminiLiveTransport(config, socketFactory = factory, wait = { waits += it; delay(it) })
        val run = collect(transport)
        val first = factory.sockets.single()
        first.say(setupComplete, this)
        first.say(resumable("h-0"), this)
        first.say(resumable("h-1"), this)
        first.serverClose()
        runCurrent()

        // Unexpected disconnect: the second socket sets up with the latest handle, sends no history, and the event stream does not end
        assertEquals(2, factory.sockets.size)
        val second = factory.sockets[1]
        assertEquals("h-1", second.sent.single().setup()["sessionResumption"]!!.jsonObject["handle"]!!.jsonPrimitive.content)
        assertFalse(run.finished)
        // Uplink audio during the disconnect is buffered in order and replayed after Ready
        transport.appendAudio("AAAA")
        transport.appendAudio("BBBB")
        runCurrent()
        assertEquals(1, second.sent.size)
        second.say(setupComplete, this)
        assertEquals(listOf("AAAA", "BBBB"), second.sent.drop(1).map { it.audioData() })
        assertTrue(second.sent.none { it.containsKey("clientContent") })
        assertEquals(listOf<RealtimeSessionEvent>(RealtimeSessionEvent.Ready), run.events.filter { it == RealtimeSessionEvent.Ready })

        // The first serverContent after Ready resets the count: two more drops (each reconnecting to Ready and receiving content) still resume
        second.say(userSpeaking, this)
        second.serverClose()
        runCurrent()
        factory.sockets[2].say(setupComplete, this)
        factory.sockets[2].say(userSpeaking, this)
        factory.sockets[2].serverClose()
        runCurrent()
        factory.sockets[3].say(setupComplete, this)
        assertEquals(4, factory.sockets.size)
        // Each is the first reconnect after a reset: backoff resets too, and every wait is 0
        assertEquals(listOf(0L, 0L, 0L), waits)
        assertFalse(run.finished)
        run.job.cancel()
    }

    @Test
    fun `send_failure_after_ready_reconnects_and_resends_audio`() = runTest {
        val factory = FakeFactory()
        val transport = GeminiLiveTransport(config, socketFactory = factory)
        val run = collect(transport)
        val first = factory.sockets.single()
        first.say(setupComplete, this)
        first.say(resumable("h1"), this)
        // The server has dropped but the Closed signal is queued after the audio: this frame's send fails
        first.failSendNow = true
        transport.appendAudio("AAAA")
        runCurrent()

        assertFalse(run.finished)
        assertEquals(2, factory.sockets.size)
        val second = factory.sockets[1]
        assertEquals("h1", second.sent.single().setup()["sessionResumption"]!!.jsonObject["handle"]!!.jsonPrimitive.content)
        transport.appendAudio("BBBB")
        first.serverClose()
        runCurrent()
        assertFalse(run.finished)
        second.say(setupComplete, this)
        assertEquals(listOf("AAAA", "BBBB"), second.sent.drop(1).map { it.audioData() })
        run.job.cancel()
    }

    @Test
    fun `flush_failure_at_ready_keeps_unsent_audio_and_reconnects`() = runTest {
        val factory = FakeFactory()
        val transport = GeminiLiveTransport(config, resumeHandle = "h0", socketFactory = factory)
        val run = collect(transport)
        val first = factory.sockets.single()
        transport.appendAudio("AAAA")
        transport.appendAudio("BBBB")
        transport.appendAudio("CCCC")
        runCurrent()
        // Replay at Ready: AAAA is sent, BBBB fails
        first.sendBudget = 1
        first.say(setupComplete, this)

        assertFalse(run.finished)
        assertEquals(listOf("AAAA"), first.sent.drop(1).map { it.audioData() })
        assertEquals(2, factory.sockets.size)
        val second = factory.sockets[1]
        assertEquals("h0", second.sent.single().setup()["sessionResumption"]!!.jsonObject["handle"]!!.jsonPrimitive.content)
        second.say(setupComplete, this)
        assertEquals(listOf("BBBB", "CCCC"), second.sent.drop(1).map { it.audioData() })
        run.job.cancel()
    }

    /** The base64 length of a 20 ms 16 kHz PCM16 frame (640 bytes), with a sequence number to check ordering. */
    private fun frame(index: Int): String = index.toString().padStart(6, '0') + "A".repeat(850)

    @Test
    fun `stalled_send_drops_and_resumes`() = runTest {
        val factory = FakeFactory()
        val transport = GeminiLiveTransport(config, socketFactory = factory)
        val run = collect(transport)
        val first = factory.sockets.single()
        first.say(setupComplete, this)
        first.say(resumable("h1"), this)
        // Upstream stuck: the outbound queue only grows; 9.6 s of frames are pushed continuously
        first.stalled = true
        val frames = (0 until 480).map { frame(it) }
        for (f in frames) transport.appendAudio(f)
        runCurrent()

        // Backlog exceeds 8 s of audio: the old connection is dropped (without waiting for it to drain) and the new connection sets up with the handle
        // Best-effort 1000 close first, then immediate teardown
        assertEquals(listOf("close", "cancel"), first.shutdownCalls)
        val handedToFirst = first.sent.count { it.containsKey("realtimeInput") }
        assertTrue("stall detected after ~8 s of backlog, got $handedToFirst frames", handedToFirst in 398..401)
        assertEquals(2, factory.sockets.size)
        val second = factory.sockets[1]
        assertEquals("h1", second.sent.single().setup()["sessionResumption"]!!.jsonObject["handle"]!!.jsonPrimitive.content)
        assertFalse(run.finished)

        // After Ready, the latest ~5 s is replayed (in order, including the last frame) and anything earlier is dropped
        second.say(setupComplete, this)
        val resent = second.sent.drop(1).map { it.audioData() }
        assertEquals(frames.takeLast(resent.size), resent)
        assertTrue("resent ~5 s, got ${resent.size} frames", resent.size in 250..260)

        // Normal uplink continues afterwards
        transport.appendAudio(frame(480))
        runCurrent()
        assertEquals(frame(480), second.sent.last().audioData())
        assertEquals(2, factory.sockets.size)
        assertFalse(run.finished)
        run.job.cancel()
    }

    @Test
    fun `backlog_below_threshold_keeps_connection`() = runTest {
        val factory = FakeFactory()
        val transport = GeminiLiveTransport(config, socketFactory = factory)
        val run = collect(transport)
        val first = factory.sockets.single()
        first.say(setupComplete, this)
        first.say(resumable("h1"), this)
        first.stalled = true
        val frames = (0 until 350).map { frame(it) }
        for (f in frames) transport.appendAudio(f)
        runCurrent()

        // 7 s backlog: no disconnect, everything goes to the original connection
        assertFalse(first.cancelled)
        assertFalse(first.closed)
        assertEquals(1, factory.sockets.size)
        assertEquals(frames, first.sent.filter { it.containsKey("realtimeInput") }.map { it.audioData() })
        assertFalse(run.finished)
        run.job.cancel()
    }

    @Test
    fun `resume_flush_does_not_trip_stall`() = runTest {
        val factory = FakeFactory()
        val transport = GeminiLiveTransport(config, socketFactory = factory)
        val run = collect(transport)
        val first = factory.sockets.single()
        first.say(setupComplete, this)
        first.say(resumable("h1"), this)
        first.serverClose()
        runCurrent()
        val second = factory.sockets[1]
        // Buffered to the limit during the disconnect (about 5.16 s)
        for (i in 0 until 300) transport.appendAudio(frame(i))
        runCurrent()
        // After Ready the full buffer is replayed at once: the outbound queue rises briefly while new frames keep arriving
        second.stalled = true
        second.say(setupComplete, this)
        val flushed = second.sent.count { it.containsKey("realtimeInput") }
        assertTrue("flushed a full buffer, got $flushed frames", flushed in 250..260)
        for (i in 300 until 320) transport.appendAudio(frame(i))
        runCurrent()
        assertFalse(second.cancelled)
        // After the queue drains, uplink continues as usual with no disconnect
        second.drain()
        for (i in 320 until 340) transport.appendAudio(frame(i))
        runCurrent()
        assertFalse(second.cancelled)
        assertFalse(second.closed)
        assertEquals(2, factory.sockets.size)
        assertEquals(frame(339), second.sent.last().audioData())
        assertFalse(run.finished)
        run.job.cancel()
    }

    @Test
    fun `send_failure_after_ready_without_handle_still_fails`() = runTest {
        val factory = FakeFactory()
        val transport = GeminiLiveTransport(config, socketFactory = factory)
        val run = collect(transport)
        factory.sockets.single().say(setupComplete, this)
        factory.sockets.single().failSendNow = true
        transport.appendAudio("AAAA")
        runCurrent()
        assertTrue(run.finished)
        assertClosedWithoutKey(run.error)
        assertEquals(1, factory.sockets.size)
    }

    @Test
    fun `unexpected_close_without_handle_still_fails`() = runTest {
        val factory = FakeFactory()
        val run = collect(GeminiLiveTransport(config, socketFactory = factory))
        factory.sockets.single().say(setupComplete, this)
        factory.sockets.single().serverClose()
        runCurrent()
        assertTrue(run.finished)
        assertClosedWithoutKey(run.error)
        assertEquals(1, factory.sockets.size)
    }

    @Test
    fun `four_failed_reconnects_back_off_then_end_with_original_error`() = runTest {
        val factory = FakeFactory()
        val waits = mutableListOf<Long>()
        val run = collect(GeminiLiveTransport(config, socketFactory = factory, wait = { waits += it; delay(it) }))
        val first = factory.sockets.single()
        first.say(setupComplete, this)
        first.say(resumable("h1"), this)
        first.serverClose()
        runCurrent()
        // The first reconnect does not wait
        assertEquals(2, factory.sockets.size)
        // Before reconnects 2 to 4 it waits 1 / 2 / 4 s respectively: no connection is made before the wait is over
        for ((index, backoff) in listOf(1_000L, 2_000L, 4_000L).withIndex()) {
            factory.sockets.last().serverClose()
            advanceTimeBy(backoff - 1)
            runCurrent()
            assertEquals(index + 2, factory.sockets.size)
            advanceTimeBy(1)
            runCurrent()
            assertEquals(index + 3, factory.sockets.size)
            assertFalse(run.finished)
        }
        factory.sockets.last().serverClose()
        runCurrent()

        assertTrue(run.finished)
        assertEquals(5, factory.sockets.size)
        assertEquals(listOf(0L, 1_000L, 2_000L, 4_000L), waits)
        assertClosedWithoutKey(run.error)
        assertTrue(run.error!!.message.orEmpty(), run.error!!.message.orEmpty().contains("closed unexpectedly"))
    }

    @Test
    fun `resumed_connection_rejected_with_1008_ends_at_once_without_backoff`() = runTest {
        val factory = FakeFactory()
        val waits = mutableListOf<Long>()
        val run = collect(GeminiLiveTransport(config, socketFactory = factory, wait = { waits += it; delay(it) }))
        val first = factory.sockets.single()
        first.say(setupComplete, this)
        first.say(resumable("h1"), this)
        first.serverClose()
        runCurrent()
        assertEquals(2, factory.sockets.size)
        // A resumed connection closed by the server with 1008 (session not found / expired) before ready: the handle is invalid, so backoff retries are pointless
        factory.sockets.last().serverClose(1008)
        runCurrent()

        assertTrue(run.finished)
        assertSessionExpiredWithoutKey(run.error)
        assertEquals(listOf(0L), waits)
        advanceUntilIdle()
        assertEquals(2, factory.sockets.size)
    }

    @Test
    fun `ready_connection_closed_with_1008_ends_as_session_expired_without_resume`() = runTest {
        val factory = FakeFactory()
        val waits = mutableListOf<Long>()
        val run = collect(GeminiLiveTransport(config, socketFactory = factory, wait = { waits += it; delay(it) }))
        val first = factory.sockets.single()
        first.say(setupComplete, this)
        first.say(resumable("h1"), this)
        // A 1008 close after the first connection's ready means session expiry, with no resumption even with a handle
        first.serverClose(1008)
        runCurrent()

        assertTrue(run.finished)
        assertSessionExpiredWithoutKey(run.error)
        advanceUntilIdle()
        assertEquals(1, factory.sockets.size)
        assertEquals(emptyList<Long>(), waits)
    }

    @Test
    fun `ready_resumed_connection_closed_with_1008_ends_as_session_expired`() = runTest {
        val factory = FakeFactory()
        val run = collect(GeminiLiveTransport(config, socketFactory = factory))
        val first = factory.sockets.single()
        first.say(setupComplete, this)
        first.say(resumable("h1"), this)
        first.serverClose()
        runCurrent()
        val resumed = factory.sockets.last()
        resumed.say(setupComplete, this)
        assertFalse(run.finished)
        resumed.serverClose(1008)
        runCurrent()

        assertTrue(run.finished)
        assertSessionExpiredWithoutKey(run.error)
        advanceUntilIdle()
        assertEquals(2, factory.sockets.size)
    }

    @Test
    fun `ready_connection_closed_with_other_code_still_resumes`() = runTest {
        val factory = FakeFactory()
        val transport = GeminiLiveTransport(config, socketFactory = factory)
        val run = collect(transport)
        val first = factory.sockets.single()
        first.say(setupComplete, this)
        first.say(resumable("h1"), this)
        first.serverClose(1011)
        runCurrent()

        assertFalse(run.finished)
        assertEquals(2, factory.sockets.size)
        assertEquals("h1", factory.sockets.last().sent.first().setup()["sessionResumption"]!!.jsonObject["handle"]!!.jsonPrimitive.content)
        transport.close()
        runCurrent()
        assertTrue(run.finished)
    }

    @Test
    fun `host_close_during_backoff_ends_at_once_without_reconnect`() = runTest {
        val factory = FakeFactory()
        val waits = mutableListOf<Long>()
        val transport = GeminiLiveTransport(config, socketFactory = factory, wait = { waits += it; delay(it) })
        val run = collect(transport)
        factory.sockets.single().say(setupComplete, this)
        factory.sockets.single().say(resumable("h1"), this)
        factory.sockets.last().serverClose()
        runCurrent()
        for (backoff in listOf(1_000L, 2_000L)) {
            factory.sockets.last().serverClose()
            advanceTimeBy(backoff)
            runCurrent()
        }
        // Host close during the 4 s wait before the fourth reconnect: ends immediately, without waiting it out or connecting again
        factory.sockets.last().serverClose()
        runCurrent()
        assertEquals(4_000L, waits.last())
        val sockets = factory.sockets.size
        val start = testScheduler.currentTime
        transport.close()
        runCurrent()

        assertTrue(run.finished)
        assertNull(run.error)
        assertTrue(testScheduler.currentTime - start < 4_000L)
        assertEquals(sockets, factory.sockets.size)
        advanceUntilIdle()
        assertEquals(sockets, factory.sockets.size)
    }

    @Test
    fun `host_close_does_not_reconnect`() = runTest {
        val factory = FakeFactory()
        val transport = GeminiLiveTransport(config, socketFactory = factory)
        val run = collect(transport)
        val first = factory.sockets.single()
        first.say(setupComplete, this)
        first.say(resumable("h1"), this)
        transport.close()
        runCurrent()
        assertTrue(run.finished)
        assertNull(run.error)
        assertTrue(first.closed)
        assertEquals(1, factory.sockets.size)
    }

    private fun assertSessionExpiredWithoutKey(error: Throwable?) {
        assertTrue(error.toString(), error is GeminiLiveSessionExpiredException)
        assertNull(error!!.cause)
        val message = error.message.orEmpty()
        assertFalse(message, message.contains("key=") || message.contains("k%2By") || message.contains(config.apiKey))
    }

    private fun assertClosedWithoutKey(error: Throwable?) {
        assertTrue(error.toString(), error is GeminiLiveClosedException)
        assertNull(error!!.cause)
        val message = error.message.orEmpty()
        assertFalse(message, message.contains("key=") || message.contains("k%2By") || message.contains(config.apiKey))
    }

    @Test
    fun `close_finishes_stream_without_event`() = runTest {
        val factory = FakeFactory()
        val transport = GeminiLiveTransport(config, socketFactory = factory)
        val run = collect(transport)
        val first = factory.sockets.single()
        first.say(setupComplete, this)
        transport.close()
        runCurrent()
        assertTrue(run.finished)
        assertNull(run.error)
        assertTrue(first.closed)
        assertEquals(listOf<RealtimeSessionEvent>(RealtimeSessionEvent.Ready), run.events)

        // Cancelling collection also closes the socket
        val other = FakeFactory()
        val cancelled = collect(GeminiLiveTransport(config, socketFactory = other))
        cancelled.job.cancel()
        runCurrent()
        assertTrue(other.sockets.single().closed)

        // close() is sticky: called before collect, the stream ends normally right away and no connection is made
        val never = FakeFactory()
        val closedEarly = GeminiLiveTransport(config, socketFactory = never)
        closedEarly.close()
        val early = collect(closedEarly)
        assertTrue(early.finished)
        assertNull(early.error)
        assertTrue(early.events.isEmpty())
        assertTrue(never.urls.isEmpty())
    }

    private fun JsonObject.audioData(): String =
        this["realtimeInput"]!!.jsonObject["audio"]!!.jsonObject["data"]!!.jsonPrimitive.content

    private fun workspaceFile(relative: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("Cannot find $relative")
    }
}
