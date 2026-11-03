package ai.oriveo.community.e2e

import android.content.Context
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.ComposeTimeoutException
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.hasAnyDescendant
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.ComposeTestRule
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performSemanticsAction
import androidx.test.core.app.ActivityScenario
import androidx.test.espresso.Espresso
import androidx.test.platform.app.InstrumentationRegistry
import ai.oriveo.community.MainActivity
import ai.oriveo.community.R
import ai.oriveo.community.core.data.dao.ConversationDao
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.voice.ReadAloudController
import ai.oriveo.community.core.voice.ReadAloudEndReason
import ai.oriveo.community.core.voice.STTResult
import ai.oriveo.community.core.voice.STTSegment
import ai.oriveo.community.core.voice.SpeakablePlaceholder
import ai.oriveo.community.core.voice.VoiceTelemetry
import ai.oriveo.community.core.voice.conversation.ConversationAudio
import ai.oriveo.community.core.voice.conversation.ConversationAudioListener
import ai.oriveo.community.core.voice.conversation.ConversationRoute
import ai.oriveo.community.core.voice.conversation.ConversationStt
import ai.oriveo.community.core.voice.conversation.ConversationSttSource
import ai.oriveo.community.core.voice.conversation.ConversationTts
import ai.oriveo.community.core.voice.conversation.ConversationVoices
import ai.oriveo.community.core.voice.conversation.EarconKind
import ai.oriveo.community.core.voice.conversation.SelfRecordTurn
import ai.oriveo.community.core.voice.conversation.ServiceConversationForeground
import ai.oriveo.community.core.voice.conversation.SpeakerBargeInMemory
import ai.oriveo.community.core.voice.conversation.TtsOutcome
import ai.oriveo.community.core.voice.conversation.VoiceConversationController
import ai.oriveo.community.core.voice.conversation.VoiceConversationEnvironment
import ai.oriveo.community.core.voice.conversation.VoicePrompt
import ai.oriveo.community.core.voice.realtime.RealtimeModel
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveSocket
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveSocketFactory
import ai.oriveo.community.feature.chat.ChatScreenDebugProbe
import ai.oriveo.community.feature.chat.ChatViewModel
import ai.oriveo.community.feature.chat.voice.VoiceSwitchNoticeLatch
import ai.oriveo.community.smoke.SmokeSeed
import java.net.InetAddress
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.json.JSONArray
import org.json.JSONObject
import org.koin.mp.KoinPlatform

/**
 * Fake text provider of the fixture (fakeTextProvider): an OpenAI-compatible loopback upstream for the seeded smoke
 * text model. Records the model id of every chat request (textRequests / textRequestModels) and answers
 * "<fixture reply with {transcript} = the last user message>" as one SSE stream.
 */
internal class E2ETextProvider(private val lang: String = E2EArgs.locale) {
    private val server = MockWebServer()

    /** Model id of every chat-completions request body, in arrival order. */
    val models = ConcurrentLinkedQueue<String>()

    val baseUrl: String get() = "http://$LOOPBACK_HOST:${server.port}/v1"

    val requests: Int get() = models.size

    fun start() {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                if (request.path?.contains("chat/completions") != true) return MockResponse().setResponseCode(404)
                val body = runCatching { JSONObject(request.body.readUtf8()) }.getOrNull()
                models += body?.optString("model").orEmpty()
                return MockResponse()
                    .setHeader("Content-Type", "text/event-stream")
                    .setHeader("Cache-Control", "no-cache")
                    .setBody(sse(reply(lastUserText(body))))
            }
        }
        server.start(InetAddress.getByName(LOOPBACK_HOST), 0)
    }

    fun shutdown() = server.shutdown()

    private fun reply(transcript: String): String =
        E2EFixture.root["fakeTextProvider"]!!.jsonObject["reply"]!!.jsonObject[lang]!!.jsonPrimitive.content
            .replace("{transcript}", transcript)

    private fun lastUserText(body: JSONObject?): String {
        val messages = body?.optJSONArray("messages") ?: return ""
        for (index in messages.length() - 1 downTo 0) {
            val message = messages.optJSONObject(index) ?: continue
            if (message.optString("role") != "user") continue
            val content = message.opt("content")
            // The app appends an <oriveo-...> dynamic block (e.g. voice tone guidance) after the user message. A real model does not repeat it; a fake model only echoes the user text, otherwise the reply is split into multiple sentences and the tts count is inflated.
            if (content is String) return content.substringBefore("\n\n<oriveo-")
            if (content is JSONArray) {
                return (0 until content.length()).mapNotNull { content.optJSONObject(it)?.optString("text") }
                    .firstOrNull { !it.startsWith("<oriveo-") }.orEmpty().substringBefore("\n\n<oriveo-")
            }
        }
        return ""
    }

    private fun sse(text: String): String = buildString {
        append("data: ").append(frame(JSONObject().put("content", text), null)).append("\n\n")
        append("data: ").append(frame(JSONObject(), "stop")).append("\n\n")
        append("data: [DONE]\n\n")
    }

    private fun frame(delta: JSONObject, finishReason: String?): String {
        val choice = JSONObject().put("index", 0).put("delta", delta).put("finish_reason", finishReason ?: JSONObject.NULL)
        return JSONObject()
            .put("id", "e2e")
            .put("object", "chat.completion.chunk")
            .put("created", 0)
            .put("model", SmokeSeed.MODEL_ID)
            .put("choices", JSONArray().put(choice))
            .toString()
    }

    private companion object {
        const val LOOPBACK_HOST = "127.0.0.1"
    }
}

/**
 * Debug injected recognizer of the ≋ conversation (fixture fakeTextProvider.dictation): each turn hears the next
 * text handed to [say] (a clip's segments joined); a turn with nothing said waits until the controller interrupts it.
 */
internal class E2EInjectedStt : ConversationSttSource {
    private val lock = Any()
    private val queued = ArrayDeque<String>()
    private val waiting = ArrayDeque<CompletableDeferred<STTResult>>()

    /** Turns the controller started (cascade STT started). */
    val turns = AtomicInteger(0)

    fun say(text: String) {
        synchronized(lock) {
            val turn = waiting.removeFirstOrNull()
            if (turn != null) turn.complete(STTResult.Success(text)) else queued.addLast(text)
        }
    }

    override suspend fun resolve(): ConversationStt = ConversationStt.SelfRecord {
        turns.incrementAndGet()
        val result = CompletableDeferred<STTResult>()
        synchronized(lock) {
            val text = queued.removeFirstOrNull()
            if (text != null) result.complete(STTResult.Success(text)) else waiting.addLast(result)
        }
        object : SelfRecordTurn {
            override var onRmsDb: ((Float) -> Unit)? = null

            override suspend fun await(): STTResult = result.await()

            override fun interrupt() {
                synchronized(lock) { waiting.remove(result) }
                result.complete(STTResult.Success(""))
            }
        }
    }
}

/** Counting debug speech engine: every utterance counts as started and finishes at once, nothing reaches the speaker. */
internal class E2ECountingTts : ConversationTts {
    val started = AtomicInteger(0)

    override val isCloud: Boolean = false

    override suspend fun speak(text: String, onLevel: (Float) -> Unit): TtsOutcome {
        started.incrementAndGet()
        return TtsOutcome.DONE
    }
}

/** Session without microphone, focus or routing: turns come from the self-recording STT. */
private class E2ENoMicrophoneAudio : ConversationAudio {
    override val echoCancellerAvailable: Boolean = true
    override val route: ConversationRoute = ConversationRoute.SPEAKER
    override fun open(listener: ConversationAudioListener, capture: Boolean) = Unit
    override fun close() = Unit
    override fun setMuted(muted: Boolean) = Unit
    override fun setCapturePaused(paused: Boolean) = Unit
    override fun beginTurn(prerollFrame: Long) = Unit
    override fun endTurn(endFrame: Long): ShortArray? = null
    override fun cancelTurn() = Unit
    override suspend fun writeTurn(samples: ShortArray): STTSegment? = null
    override suspend fun playEarcon(kind: EarconKind) = Unit
}

/** [FakeGeminiServer] as the socket factory, counting sockets the app closed (realtimeEnded). */
internal class E2ECountingSockets(private val server: FakeGeminiServer) : GeminiLiveSocketFactory {
    val closed = AtomicInteger(0)

    override suspend fun connect(url: String): GeminiLiveSocket {
        val socket = server.connect(url)
        return object : GeminiLiveSocket by socket {
            override fun close() {
                closed.incrementAndGet()
                socket.close()
            }

            override fun cancel() {
                closed.incrementAndGet()
                socket.cancel()
            }
        }
    }
}

/**
 * E2E app host for the midway-switch scenarios: seeds (SmokeSeed.reset + geminiConnection + conversation), replaces the
 * realtime builder (fake Gemini Live + injected PCM) and the cascade controller (injected STT + counting TTS), then
 * starts the real MainActivity. Not SmokeHost.start(): that asserts the smoke network guard the E2E script does not set.
 */
internal class E2EApp(private val compose: ComposeTestRule) {
    val text = E2ETextProvider()
    val gemini = FakeGeminiServer()
    val sockets = E2ECountingSockets(gemini)
    val stt = E2EInjectedStt()
    val tts = E2ECountingTts()
    lateinit var cascade: VoiceConversationController
        private set

    /** Realtime voice sessions started (builder audio() calls). */
    val realtimeSessions = AtomicInteger(0)

    @Volatile
    var realtimeAudio: InjectedPcmRealtimeAudio? = null
        private set

    private var scenario: ActivityScenario<MainActivity>? = null
    private val context: Context get() = InstrumentationRegistry.getInstrumentation().targetContext

    fun start() {
        closeParked()
        E2ECorpus.verify()
        text.start()
        runBlocking {
            SmokeSeed.reset(context, text.baseUrl)
            SmokeSeed.geminiConnection()
            SmokeSeed.conversation()
        }
        SmokeSeed.overrideRealtime(sockets) {
            realtimeSessions.incrementAndGet()
            InjectedPcmRealtimeAudio.production().also { realtimeAudio = it }
        }
        installCascade()
        scenario = ActivityScenario.launch(MainActivity::class.java)
    }

    /**
     * Per-case teardown, red / green / thrown alike: ends the voice stage and closes the picker / disclosure sheets,
     * then (finally) closes [others] and this host's activity and parks a fresh MainActivity on home, so no case
     * leaves the device on a disclosure, picker or voice stage. The parked home is closed by the next case's start.
     */
    fun finish(vararg others: ActivityScenario<MainActivity>?) {
        try {
            runCatching { clearSurfaces() }
        } finally {
            (others.toList() + scenario).filterNotNull().forEach { runCatching { it.close() } }
            scenario = null
            text.shutdown()
            parkAtHome()
        }
    }

    /** Sheets first (they can cover the end button), then the voice stage, then any sheet the end reopened. */
    private fun clearSurfaces() {
        closeSheets()
        val end = hasTestTag("voice_conversation_end_button")
        if (exists(end)) {
            runCatching { compose.onAllNodes(end, useUnmergedTree = true).onFirst().performClick() }
            waitUntil(CLEAR_MS) { !exists(end) }
        }
        closeSheets()
    }

    /** Presses back while the model picker or the voice disclosure (its agree button) is on screen. */
    private fun closeSheets() {
        val agree = hasText(string(R.string.voice_disclosure_agree)) and hasClickAction()
        val open = { exists(hasTestTag("model_picker")) || nodes(agree, unmerged = false).isNotEmpty() }
        repeat(MAX_BACKS) {
            if (!open()) return
            Espresso.pressBackUnconditionally()
            waitUntil(CLEAR_MS) { !open() }
        }
    }

    /** A fresh MainActivity lands on home (the pill model_picker_button); kept open until the next case starts. */
    private fun parkAtHome() {
        parked = runCatching { ActivityScenario.launch(MainActivity::class.java) }.getOrNull()
        if (parked != null) waitUntil(STEP_MS) { exists(hasTestTag("model_picker_button")) }
    }

    /** Production cascade wiring (AppModule, as SmokeSeed.overrideCascade) except STT, TTS and audio. */
    private fun installCascade() {
        val koin = KoinPlatform.getKoin()
        val context = context
        cascade = VoiceConversationController(
            audio = E2ENoMicrophoneAudio(),
            sttSource = stt,
            ttsSource = { ConversationVoices(primary = tts, system = tts) },
            foreground = ServiceConversationForeground(context),
            environment = object : VoiceConversationEnvironment {
                override fun stopReadAloud() = koin.get<ReadAloudController>().stop(ReadAloudEndReason.USER_STOPPED)
            },
            memory = SpeakerBargeInMemory({
                context.getSharedPreferences(SpeakerBargeInMemory.PREFS_NAME, Context.MODE_PRIVATE)
            }),
            prompt = { which ->
                context.getString(
                    when (which) {
                        VoicePrompt.DidNotCatch -> R.string.voice_conversation_prompt_did_not_catch
                        VoicePrompt.ApprovalNeeded -> R.string.voice_conversation_prompt_approval_needed
                        VoicePrompt.SayAgain -> R.string.voice_conversation_prompt_say_again
                        VoicePrompt.CheckLanguage -> R.string.voice_conversation_prompt_check_language
                        VoicePrompt.EchoHint -> R.string.voice_conversation_prompt_echo_hint
                        is VoicePrompt.Placeholder -> when (which.kind) {
                            SpeakablePlaceholder.CODE -> R.string.voice_placeholder_code
                            SpeakablePlaceholder.TABLE -> R.string.voice_placeholder_table
                            SpeakablePlaceholder.MATH -> R.string.voice_placeholder_math
                        }
                    },
                )
            },
            telemetry = VoiceTelemetry(),
        )
        koin.declare(cascade, allowOverride = true)
    }

    // ---- UI ----

    fun waitUntil(timeoutMs: Long, condition: () -> Boolean): Boolean = try {
        compose.waitUntil(timeoutMs) { condition() }
        true
    } catch (_: ComposeTimeoutException) {
        false
    }

    fun nodes(matcher: SemanticsMatcher, unmerged: Boolean = true): List<SemanticsNode> =
        compose.onAllNodes(matcher, useUnmergedTree = unmerged).fetchSemanticsNodes(atLeastOneRootRequired = false)

    fun exists(matcher: SemanticsMatcher): Boolean = nodes(matcher).isNotEmpty()

    /** A string in the activity's (= the app's) language. */
    fun string(id: Int, vararg args: Any): String {
        var value = ""
        scenario?.onActivity { value = it.getString(id, *args) } ?: run { value = context.getString(id, *args) }
        return value
    }

    /** The copy of key [name] with [args]; null when the key is not in the app's resources. */
    fun copy(name: String, vararg args: Any): String? {
        val id = context.resources.getIdentifier(name, "string", context.packageName)
        return if (id == 0) null else string(id, *args)
    }

    /**
     * A node tagged [tag] by Modifier.testTag or by the Sentry tag (Modifier.sentryTag); some controls only carry the
     * latter. SentryModifier.SentryTag is private, so the semantics key is matched by its name.
     */
    fun tagged(tag: String): SemanticsMatcher = hasTestTag(tag) or SemanticsMatcher("sentryTag = $tag") {
        it.config.firstOrNull { entry -> entry.key.name == "SentryTag" }?.value == tag
    }

    /**
     * Opens the first home conversation item by its click action rather than a tap at its center: the bottom
     * navigation can cover the row, and a coordinate tap would land on a tab instead.
     */
    fun clickFirstConversationItem() {
        compose.onAllNodes(hasTestTag("home_conversation_item"))[0].performSemanticsAction(SemanticsActions.OnClick)
    }

    /** Home → the seeded conversation's chat page. */
    fun openSeededChat(): Boolean {
        if (!waitUntil(STEP_MS) { exists(hasTestTag("home_conversation_item")) }) return false
        clickFirstConversationItem()
        return waitUntil(STEP_MS) { exists(hasTestTag("chat_screen")) }
    }

    /** The chat top bar model switcher row (merged: its texts are model name then provider name). */
    private fun topBarMatcher(): SemanticsMatcher = hasContentDescription(string(R.string.model_switcher)) and hasClickAction()

    /** The model name the chat top bar shows; null when the row is not found. */
    fun topBarModel(): String? = nodes(topBarMatcher(), unmerged = false).firstOrNull()
        ?.config?.getOrNull(SemanticsProperties.Text)?.firstOrNull()?.text

    /** Texts and content descriptions of every node on screen. */
    fun screenTexts(): List<String> = nodes(SemanticsMatcher("any") { true }).flatMap { node ->
        node.config.getOrNull(SemanticsProperties.Text).orEmpty().map { it.text } +
            node.config.getOrNull(SemanticsProperties.ContentDescription).orEmpty()
    }

    fun onScreen(value: String): Boolean = screenTexts().any { it == value }

    /**
     * (user, assistant) messages of the list the chat page shows, streaming temporary rows included; read from the
     * page's ChatViewModel rather than composed nodes, so rows scrolled out of the viewport still count. (0, 0) when
     * no chat page is registered.
     */
    fun bubbles(): Pair<Int, Int> {
        val messages = onMain { vm -> (vm.conversation.value.conversation ?: vm.bootstrapConversation)?.messages }.orEmpty()
        return messages.count { it.role == ChatRole.User } to messages.count { it.role == ChatRole.Assistant }
    }

    /** Id of the conversation the chat page shows; null when no chat page is registered or it has none yet. */
    fun currentConversationId(): String? = onMain { vm -> vm.conversation.value.conversation?.id }

    /** Reads the registered chat page view model once on the main thread. */
    private fun <T> onMain(read: (ChatViewModel) -> T?): T? {
        var value: T? = null
        InstrumentationRegistry.getInstrumentation().runOnMainSync { value = ChatScreenDebugProbe.viewModel?.let(read) }
        return value
    }

    /**
     * Opens the model picker from the chat top bar and taps a row: [row] matches it in the merged tree, [section] is
     * the provider header that expands a collapsed section. The switch notice latch ([VoiceSwitchNoticeLatch]) is
     * cleared before the pick; after it, when [expectModel] is set, waits for the latch to hold that model name (the
     * status line shows the notice only briefly, the latch keeps it). Returns (null, latched name) or
     * (failure text, null).
     */
    fun pickModel(row: SemanticsMatcher, section: String, expectModel: String?): Pair<String?, String?> {
        VoiceSwitchNoticeLatch.clear()
        val bar = nodes(topBarMatcher(), unmerged = false)
        if (bar.isEmpty()) return "testability gap: chat top bar model switcher row not found by content description" to null
        compose.onAllNodes(topBarMatcher())[0].performClick()
        if (!waitUntil(STEP_MS) { exists(hasTestTag("model_picker_list")) }) return "model picker list did not open" to null
        revealPickerRow(row, section, realtime = section == geminiSection)
        if (!waitUntil(STEP_MS) { nodes(row, unmerged = false).isNotEmpty() }) {
            return "picker row not found: ${row.description}; picker texts=${screenTexts().take(40)}" to null
        }
        compose.onAllNodes(row).onFirst().performClick()
        if (exists(hasTestTag("model_picker"))) Espresso.pressBack()
        if (expectModel != null) waitUntil(NOTICE_MS) { VoiceSwitchNoticeLatch.last == expectModel }
        waitUntil(STEP_MS) { !exists(hasTestTag("model_picker")) }
        return null to VoiceSwitchNoticeLatch.last
    }

    /**
     * Brings [row] into the open picker list. The Gemini section is collapsed by default, so for a [realtime] row the
     * realtime filter chip (text starts with voice_realtime_model_tag in the app language) is tapped first; a row
     * still missing then has its [section] header tapped to expand it; finally the list scrolls to the row.
     */
    fun revealPickerRow(row: SemanticsMatcher, section: String, realtime: Boolean) {
        val list = hasTestTag("model_picker_list")
        val tag = if (realtime) copy(RealtimeModel.COPY_MODEL_TAG) else null
        if (tag != null && nodes(row, unmerged = false).isEmpty()) {
            val chip = textStartsWith(tag) and hasClickAction() and !realtimeRow()
            if (nodes(chip, unmerged = false).isEmpty()) runCatching { compose.onNode(list).performScrollToNode(chip) }
            if (nodes(chip, unmerged = false).isNotEmpty()) {
                compose.onAllNodes(chip).onFirst().performClick()
                waitUntil(CLEAR_MS) { nodes(row, unmerged = false).isNotEmpty() }
            }
        }
        if (nodes(row, unmerged = false).isEmpty()) {
            val header = hasText(section) and hasClickAction()
            runCatching { compose.onNode(list).performScrollToNode(header) }
            if (nodes(header, unmerged = false).isNotEmpty()) compose.onAllNodes(header).onFirst().performClick()
        }
        runCatching { compose.onNode(list).performScrollToNode(row) }
    }

    private fun textStartsWith(prefix: String): SemanticsMatcher = SemanticsMatcher("text starts with \"$prefix\"") { node ->
        node.config.getOrNull(SemanticsProperties.Text).orEmpty().any { it.text.startsWith(prefix) }
    }

    fun realtimeRow(): SemanticsMatcher = hasTestTag("model_picker_realtime_row")

    fun textRow(): SemanticsMatcher =
        hasTestTag("model_picker_row") and (hasText(SmokeSeed.MODEL_NAME, substring = true) or hasAnyDescendant(hasText(SmokeSeed.MODEL_NAME)))

    val geminiSection: String get() = ProviderKind.Gemini.displayName

    // ---- db ----

    /** Ids of the guest's conversations in the local db. */
    fun conversationIds(): List<String> = runBlocking {
        KoinPlatform.getKoin().get<ConversationDao>().getAll(SmokeSeed.ACCOUNT_ID).map { it.id }
    }

    /** (user, assistant) rows of the seeded conversation in the local db. */
    fun db(): Pair<Int, Int> = runBlocking {
        val messages = KoinPlatform.getKoin().get<ConversationRepository>()
            .getWithMessages(SmokeSeed.SEEDED_CONVERSATION_ID)?.messages.orEmpty()
        messages.count { it.role == ChatRole.User } to messages.count { it.role == ChatRole.Assistant }
    }

    companion object {
        const val STEP_MS = 20_000L
        const val NOTICE_MS = 4_000L
        private const val CLEAR_MS = 2_000L
        private const val MAX_BACKS = 4

        /** The home MainActivity the previous case's finish left open. */
        @Volatile
        private var parked: ActivityScenario<MainActivity>? = null

        /** Closes the parked home before a case seeds and launches its own activity. */
        fun closeParked() {
            parked?.let { runCatching { it.close() } }
            parked = null
        }
    }
}
