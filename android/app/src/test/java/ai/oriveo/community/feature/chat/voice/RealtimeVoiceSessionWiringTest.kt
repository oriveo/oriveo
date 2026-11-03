package ai.oriveo.community.feature.chat.voice

import ai.oriveo.community.feature.chat.realtimeVoiceTarget
import ai.oriveo.community.feature.chat.isRealtimeModelSelected
import ai.oriveo.community.R
import ai.oriveo.community.core.context.ChatContextRequest
import ai.oriveo.community.core.context.ContextConversation
import ai.oriveo.community.core.context.MemoryItem
import ai.oriveo.community.core.context.MemoryKind
import ai.oriveo.community.core.data.repository.PlannedRealtimeSession
import ai.oriveo.community.core.data.repository.RealtimeSessionProjector
import ai.oriveo.community.core.data.repository.RealtimeTransportInput
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.GenerationParameterSettingsStore
import ai.oriveo.community.core.model.Note
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.LastUsedModelRef
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.streaming.ChatStreamingManager
import ai.oriveo.community.core.voice.VoiceCatalog
import ai.oriveo.community.core.voice.VoiceDirection
import ai.oriveo.community.core.voice.VoiceEngineSelection
import ai.oriveo.community.core.voice.VoiceEngineSettings
import ai.oriveo.community.core.voice.VoiceOption
import ai.oriveo.community.core.voice.VoiceProviderCatalog
import ai.oriveo.community.core.voice.VoiceRealtimeEntry
import ai.oriveo.community.core.voice.VoiceTransport
import ai.oriveo.community.core.voice.conversation.ConversationStatusKey
import ai.oriveo.community.core.voice.conversation.EndReason
import ai.oriveo.community.core.voice.conversation.VoiceConversationChatPort
import ai.oriveo.community.core.voice.conversation.VoiceConversationEngine
import ai.oriveo.community.core.voice.conversation.VoiceConversationEvent
import ai.oriveo.community.core.voice.conversation.VoiceReplyEvent
import ai.oriveo.community.core.voice.realtime.RealtimeSessionEvent
import ai.oriveo.community.core.voice.realtime.RealtimeTransportKind
import ai.oriveo.community.core.voice.realtime.RealtimeTurnStatus
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveSessionExpiredException
import ai.oriveo.community.core.voice.realtime.wire.RealtimeEndpoint
import ai.oriveo.community.core.voice.realtime.wire.RealtimeHandshakeException
import ai.oriveo.community.core.voice.realtime.wire.RealtimeSessionTransport
import ai.oriveo.community.feature.chat.ChatSendCoordinator
import ai.oriveo.community.feature.chat.DraftChatViewModelFixture
import ai.oriveo.community.testing.TestSharedPreferences
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.mockk
import io.mockk.mockkObject
import io.mockk.unmockkObject
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Runnable
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.consumeAsFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.job
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.JsonNull
import ai.oriveo.community.core.voice.conversation.StartFailure
import ai.oriveo.community.core.voice.conversation.VoiceConversationForeground
import ai.oriveo.community.core.voice.conversation.VoiceConversationService
import ai.oriveo.community.core.voice.conversation.VoiceConversationServiceStarter
import ai.oriveo.community.core.voice.realtime.RealtimeConversationConstants
import ai.oriveo.community.core.voice.realtime.RealtimeModel
import kotlinx.coroutines.flow.MutableSharedFlow

/** Chat page / home ≋ opens a realtime session by the conversation engine (contract items 1, 2, 3, 5, 6, 7): real builder + real sink + fake connection / audio. */
@OptIn(ExperimentalCoroutinesApi::class)
class RealtimeVoiceSessionWiringTest {

    private class FakeConnection(
        override val kind: RealtimeTransportKind = RealtimeTransportKind.OpenAiRealtime,
    ) : RealtimeSessionTransport {
        val events = Channel<RealtimeSessionEvent>(Channel.UNLIMITED)
        var opened = 0
        var closes = 0
        val inputs = mutableListOf<RealtimeTransportInput>()
        var sent = 0

        override fun openRealtimeSession(transport: RealtimeTransportInput): Flow<RealtimeSessionEvent> {
            opened++
            inputs += transport
            return events.consumeAsFlow()
        }

        override fun sendAudio(pcm: ByteArray) {
            sent++
        }

        /** Truncation and typed sends are recorded in the order they happen (barge-in truncates first, then sends). */
        val log = mutableListOf<String>()
        val texts = mutableListOf<String>()

        override fun truncate(itemId: String?, contentIndex: Int, playedMs: Double) {
            log += "truncate:$itemId"
        }

        override fun sendUserText(text: String) {
            log += "text:$text"
            texts += text
        }

        override fun close() {
            closes++
            events.close()
        }
    }

    /** Ideal player (same as HomeRealtimeVoiceFlowTest) with a downlink callback recorded on top. */
    private class FakeAudio : IdealRealtimeAudio() {
        var onFrame: ((ByteArray) -> Unit)? = null

        var playbackStarts = 0
        var captureStarts = 0
        var playing = false

        override val isPlaying: Boolean get() = playing

        override fun start(onFrame: (ByteArray) -> Unit, onInterruption: () -> Unit) {
            this.onFrame = onFrame
        }

        override fun startPlayback(onInterruption: () -> Unit, onActivationFailed: (Throwable) -> Unit) {
            playbackStarts++
        }

        override fun startCapture(onFrame: (ByteArray) -> Unit, uplinkRateHz: Int) {
            captureStarts++
            this.onFrame = onFrame
        }

        override fun stopPlayback() {
            playing = false
        }
    }

    /**
     * Fake foreground service paired with ≋: [started] = whether the service ran into the foreground; [refused] = types that cannot run in the foreground; [kinds] = types awaited in order;
     * [ends] = the notification "end".
     */
    private class FakeForeground(var started: Boolean = true) : VoiceConversationForeground {
        var awaits = 0
        var stops = 0
        val kinds = mutableListOf<VoiceConversationService.Kind>()
        val refused = mutableSetOf<VoiceConversationService.Kind>()
        val ends = MutableSharedFlow<Unit>(extraBufferCapacity = 4)

        override suspend fun awaitStarted(): Boolean {
            awaits++
            return started
        }

        override suspend fun awaitStarted(kind: VoiceConversationService.Kind): Boolean {
            kinds += kind
            return awaitStarted() && kind !in refused
        }

        override val endRequests: Flow<Unit> = ends

        override fun stop() {
            stops++
        }
    }

    private object NoChat : VoiceConversationChatPort {
        override suspend fun send(text: String): Boolean = error("realtime must not send through the chat")
        override val replies: Flow<VoiceReplyEvent> = emptyFlow()
        override fun cancel() = Unit
    }

    private val entry = VoiceRealtimeEntry(
        model = "gpt-realtime",
        transport = VoiceTransport.OpenAIRealtime,
        path = "/v1/realtime",
        contextWindow = 128_000,
        voices = listOf(VoiceOption("marin", isDefault = true), VoiceOption("cedar")),
        inputTranscriptionModel = "gpt-4o-transcribe",
        isDefault = true,
    )
    private val provider = Provider(
        id = "conn-openai",
        kind = ProviderKind.OpenAI,
        apiKey = "sk-live",
        baseUrlText = "https://api.openai.com/v1",
        customName = "Work OpenAI",
    )
    private val cloud = VoiceEngineSelection.Cloud(
        providerKind = ProviderKind.OpenAI,
        connectionId = provider.id,
        model = entry.model,
        voice = "cedar",
    )

    /** [replanInline] = the turn-boundary replan runs on the test scheduler (IO in production), and the result comes back in the same turn. */
    private class Rig(
        val test: TestScope,
        catalogEntry: VoiceRealtimeEntry,
        val provider: Provider,
        replanInline: Boolean = false,
        /** Host recognition language (production reads the voice settings / UI language by default; injected under plain JVM). */
        language: () -> String? = { null },
    ) {
        val prefs = TestSharedPreferences()
        val settings = VoiceEngineSettings { prefs }
        val connection = FakeConnection(RealtimeTransportKind.fromRawValue(catalogEntry.transport.rawValue)!!)
        val foreground = FakeForeground()

        /** In connect order: one is opened first, and each reopen adds one more. */
        val connections = mutableListOf(connection)
        val made = mutableListOf<Pair<RealtimeTransportKind, RealtimeEndpoint>>()
        val added = mutableListOf<ChatMessage>()
        val addedTo = mutableListOf<String>()
        val sessions = VoiceConversationSessions()
        val created = mutableListOf<String>()
        val navigated = mutableListOf<String>()
        /** Whether each navigate runs on the Main dispatcher (production HandoffPort switches to Dispatchers.Main.immediate). */
        val navigatedOnMain = mutableListOf<Boolean>()
        private var onMain = false
        val updated = mutableListOf<ChatMessage>()
        val events = mutableListOf<VoiceConversationEvent>()
        val sinks = mutableListOf<RepositoryRealtimeTranscriptSink>()
        val audios = mutableListOf<FakeAudio>()
        val planned = mutableListOf<Conversation>()
        /** Realtime model selected on the chat page session / home pill (used by the [realtime], [home] and direct prepare cases). */
        var selected: VoiceEngineSelection.Cloud? = null

        /** Realtime model selected for the session [selection]; the old engine setting is written too: prepare does not read it (kept only for upgrade migration). */
        fun selectRealtime(selection: VoiceEngineSelection.Cloud) {
            settings.setSelection(VoiceDirection.Realtime, selection)
            selected = selection
        }

        var catalogCalls = 0
        /** The chat connection the session belongs to (other than the realtime connection). */
        var chatProviders: List<Provider> = emptyList()
        var instructions = ""
        var edit: (Conversation) -> Conversation = { it }
        var contextRequest: suspend (Conversation) -> ChatContextRequest = { c ->
            planned += c
            ChatContextRequest(ContextConversation(id = c.id, useMemory = false, instructions = c.instructions))
        }
        // Attached to backgroundScope: if an assertion fails it is cancelled with the test, so it reports red instead of hanging (contract card D item 4)
        val scope = CoroutineScope(UnconfinedTestDispatcher(test.testScheduler) + Job(test.backgroundScope.coroutineContext.job))
        val catalog = VoiceCatalog(
            providers = mapOf(provider.kind to VoiceProviderCatalog(realtime = listOf(catalogEntry))),
        )
        val builder = RealtimeVoiceSessionBuilder(
            settings = settings,
            catalog = {
                catalogCalls++
                catalog
            },
            providers = { listOf(provider) + chatProviders },
            conversation = { id ->
                Conversation(
                    id = id,
                    title = "t",
                    providerID = provider.id,
                    providerKind = provider.kind,
                    modelID = "gpt-5",
                    instructions = instructions,
                    // Fake repository: transcripts that were persisted are read back with the conversation.
                    messages = added.filterIndexed { i, _ -> addedTo[i] == id },
                ).let(edit)
            },
            sinkFor = { conversationId, createHomeConversation, attribution ->
                RepositoryRealtimeTranscriptSink(
                    conversationId = conversationId,
                    attribution = attribution,
                    add = { id, m ->
                        addedTo += id
                        added += m
                    },
                    update = { _, m -> updated += m },
                    scope = scope,
                    createConversation = createHomeConversation,
                ).also { sinks += it }
            },
            transport = { kind, endpoint ->
                made += kind to endpoint
                if (made.size == 1) connection else FakeConnection(kind).also { connections += it }
            },
            audio = { FakeAudio().also { audios += it } },
            scope = scope,
            clock = { test.testScheduler.currentTime },
            replanContext = if (replanInline) UnconfinedTestDispatcher(test.testScheduler) else kotlinx.coroutines.Dispatchers.IO,
            foreground = foreground,
            language = language,
        )

        suspend fun realtime(): RealtimeVoiceConversationEngine {
            settings.disclosure.markAccepted(provider.kind, VoiceDirection.Realtime)
            val choice = builder.prepare("c1", contextRequest, selected = selected)
            val engine = (choice as RealtimeVoiceSessionChoice.Realtime).engine
            scope.launch { engine.events.collect { events += it } }
            engine.start(NoChat)
            test.testScheduler.runCurrent()
            return engine
        }

        /** As rememberVoiceConversationHost's home wiring: the builder creates the conversation using the handoff port, and beginHome creates it using the pill model. */
        suspend fun home(
            owner: Any,
            newConversation: (suspend () -> Conversation?)? = null,
        ): RealtimeVoiceConversationEngine {
            settings.disclosure.markAccepted(provider.kind, VoiceDirection.Realtime)
            // Main = a marked test dispatcher: onMain is true while the code the sink write loop switches into runs.
            val main = StandardTestDispatcher(test.testScheduler)
            Dispatchers.setMain(
                object : CoroutineDispatcher() {
                    override fun dispatch(context: CoroutineContext, block: Runnable) = main.dispatch(
                        context,
                        Runnable {
                            onMain = true
                            try {
                                block.run()
                            } finally {
                                onMain = false
                            }
                        },
                    )
                },
            )
            var port: VoiceConversationSessions.HandoffPort? = null
            val choice = builder.prepare(null, contextRequest, newConversation, { port?.conversationId() }, selected)
            val engine = (choice as RealtimeVoiceSessionChoice.Realtime).engine
            scope.launch { engine.events.collect { events += it } }
            val handoff = sessions.beginHome(
                owner = owner,
                createConversation = { "new-${created.size + 1}".also { created += it } },
                navigate = {
                    navigated += it
                    navigatedOnMain += onMain
                },
            )
            port = handoff
            engine.start(handoff)
            test.testScheduler.runCurrent()
            return engine
        }

        fun turn(user: String, assistant: String) = send(
            RealtimeSessionEvent.UserSpeechStarted(null),
            RealtimeSessionEvent.UserSpeechStopped(null),
            RealtimeSessionEvent.UserTranscript(null, user, final = true),
            RealtimeSessionEvent.AssistantTranscript(null, assistant, final = true),
            RealtimeSessionEvent.AssistantTurnDone(null, RealtimeTurnStatus.Completed, assistant),
        )

        fun send(vararg e: RealtimeSessionEvent) {
            e.forEach { connections.last().events.trySend(it) }
            test.testScheduler.runCurrent()
        }
    }

    @Test
    fun endpoint_carries_host_recognition_language() = runTest {
        // The injected host recognition language goes through to the endpoint unchanged (mapping is at the wire layer).
        val zh = Rig(this, entry, provider, language = { "zh-Hans-CN" })
        zh.selectRealtime(cloud)
        zh.realtime()
        assertEquals("zh-Hans-CN", zh.made.single().second.language)
        zh.scope.cancel()

        // No host language → null, leaving automatic detection to the server.
        val none = Rig(this, entry, provider, language = { null })
        none.selectRealtime(cloud)
        none.realtime()
        assertEquals(null, none.made.single().second.language)
        none.scope.cancel()
    }

    @Test
    fun realtime_selection_starts_realtime() = runTest {
        val r = Rig(this, entry, provider)
        r.selectRealtime(cloud)
        val engine = r.realtime()

        assertEquals(1, r.made.size)
        val (kind, endpoint) = r.made.single()
        assertEquals(RealtimeTransportKind.OpenAiRealtime, kind)
        assertEquals("api.openai.com", endpoint.host)
        assertEquals("sk-live", endpoint.apiKey)
        assertEquals("gpt-realtime", endpoint.model)
        assertEquals("/v1/realtime", endpoint.path)
        // Voice takes the catalog default (the cedar from the old engine setting is not read).
        assertEquals("marin", endpoint.voice)
        assertEquals("gpt-4o-transcribe", endpoint.inputTranscriptionModel)
        assertEquals(1, r.connection.opened)
        assertTrue(engine.active.value)
        assertTrue(r.builder.realtimeActive)
        r.scope.cancel()
    }

    /** As rememberVoiceConversationHost's wiring: hands the engine's failure to the voice station handle and records the exit. */
    private class FailureRig(engine: RealtimeVoiceConversationEngine, retry: () -> Unit = {}, continueWithHistory: () -> Unit = {}) {
        val opened = mutableListOf<String>()
        var retried = 0
        var switched = 0
        var continued = 0
        var orbTaps = 0
        val handle = VoiceConversationHandle(
            page = VoiceConversationPage.Chat,
            statusState = mutableStateOf(ConversationStatusKey.ERROR),
            level = null,
            onEnd = {},
            onTapOrb = { orbTaps++ },
            onToggleMute = {},
            captionState = mutableStateOf(""),
            nudgesState = mutableStateOf(0),
            failureState = mutableStateOf(engine.failure.value),
            failureActions = RealtimeFailureActions(
                retry = {
                    retried++
                    retry()
                },
                openConnection = { opened += it },
                switchModel = { switched++ },
                continueWithHistory = {
                    continued++
                    continueWithHistory()
                },
            ),
        )
    }

    /** Session that ended in failure: the engine carries the failure, emits Ended(ERROR), and no event shows a toast (the failure is presented within the voice station). */
    private fun Rig.assertEndedOnFailureWithoutToast(engine: RealtimeVoiceConversationEngine) {
        assertFalse(engine.active.value)
        assertEquals(EndReason.ERROR, events.filterIsInstance<VoiceConversationEvent.Ended>().single().reason)
        assertTrue(events.all { voiceConversationEventToast(it) == null })
    }

    @Test
    fun failure_auth_shows_card_with_open_connection() = runTest {
        val r = Rig(this, entry, provider)
        r.selectRealtime(cloud)
        val engine = r.realtime()
        r.connection.events.close(RealtimeHandshakeException(401, "ProtocolException"))
        testScheduler.runCurrent()

        r.assertEndedOnFailureWithoutToast(engine)
        assertEquals(RealtimeFailure("auth", provider.id, "Work OpenAI", "gpt-realtime"), engine.failure.value)
        val card = realtimeFailureCard(engine.failure.value)!!
        assertEquals(R.string.voice_realtime_failure_auth, card.title)
        assertEquals(listOf<Any>("Work OpenAI"), card.titleArgs)
        assertEquals(
            listOf(RealtimeFailureButton(RealtimeFailureAction.OpenConnection, R.string.voice_realtime_action_open_connection)),
            card.buttons,
        )
        assertNull(realtimeFailureStatusWord(engine.failure.value))
        // Screen reader reads the failure text itself, not the generic "error" status word.
        assertEquals(
            R.string.voice_realtime_failure_auth to listOf<Any>("Work OpenAI"),
            voiceStatusAnnouncement(ConversationStatusKey.ERROR, engine.failure.value),
        )

        val f = FailureRig(engine)
        f.handle.perform(RealtimeFailureAction.OpenConnection)
        assertEquals(listOf(provider.id), f.opened)
        // A tap on the orb does not reopen: only max_duration is "tap to continue".
        f.handle.tapOrb()
        assertEquals(0, f.continued)
        assertEquals(1, f.orbTaps)

        engine.dismissFailure()
        assertNull(engine.failure.value)
        r.scope.cancel()
    }

    @Test
    fun failure_quota_shows_retry_and_switch() = runTest {
        val r = Rig(this, entry, provider)
        r.selectRealtime(cloud)
        val engine = r.realtime()
        r.connection.events.close(RealtimeHandshakeException(429, "ProtocolException"))
        testScheduler.runCurrent()

        r.assertEndedOnFailureWithoutToast(engine)
        assertEquals("quota", engine.failure.value?.category)
        val card = realtimeFailureCard(engine.failure.value)!!
        assertEquals(R.string.voice_realtime_failure_quota, card.title)
        assertEquals(listOf<Any>("Work OpenAI"), card.titleArgs)
        assertEquals(
            listOf(
                RealtimeFailureButton(RealtimeFailureAction.Retry, R.string.voice_realtime_action_retry),
                RealtimeFailureButton(RealtimeFailureAction.SwitchModel, R.string.voice_realtime_action_switch_model),
            ),
            card.buttons,
        )

        val f = FailureRig(engine)
        f.handle.perform(RealtimeFailureAction.Retry)
        f.handle.perform(RealtimeFailureAction.SwitchModel)
        assertEquals(1, f.retried)
        assertEquals(1, f.switched)
        assertTrue(f.opened.isEmpty())
        r.scope.cancel()
    }

    @Test
    fun failure_max_duration_tap_reopens_with_history() = runTest {
        val r = Rig(this, entry, provider)
        r.selectRealtime(cloud)
        val engine = r.realtime()
        r.send(RealtimeSessionEvent.Ready)
        r.turn("first question", "first answer")
        r.send(RealtimeSessionEvent.SessionEnded("max_duration"))

        r.assertEndedOnFailureWithoutToast(engine)
        assertEquals("max_duration", engine.failure.value?.category)
        // No card shown: the hint text becomes "Single realtime call limit reached, tap to continue".
        assertNull(realtimeFailureCard(engine.failure.value))
        assertEquals(R.string.voice_realtime_failure_max_duration, realtimeFailureStatusWord(engine.failure.value))
        assertEquals(
            R.string.voice_realtime_failure_max_duration to emptyList<Any>(),
            voiceStatusAnnouncement(ConversationStatusKey.ERROR, engine.failure.value),
        )
        // Without failure the status word is still read as before.
        assertEquals(
            R.string.voice_conversation_status_error to emptyList<Any>(),
            voiceStatusAnnouncement(ConversationStatusKey.ERROR, null),
        )

        // A tap = start a new call with history (the host goes through the same entry flow: prepare the same conversation again).
        var next: RealtimeVoiceConversationEngine? = null
        val f = FailureRig(engine, continueWithHistory = {
            r.scope.launch {
                val choice = r.builder.prepare("c1", r.contextRequest, selected = r.selected)
                next = (choice as RealtimeVoiceSessionChoice.Realtime).engine.also { it.start(NoChat) }
            }
        })
        f.handle.tapOrb()
        testScheduler.runCurrent()

        assertEquals(1, f.continued)
        assertEquals(0, f.orbTaps)
        assertEquals(2, r.made.size)
        val second = r.connections[1]
        assertTrue(r.connection.inputs.single().history.isEmpty())
        assertEquals(
            listOf(ChatRole.User to "first question", ChatRole.Assistant to "first answer"),
            second.inputs.single().history.map { it.role to it.text },
        )
        assertTrue(next!!.active.value)
        assertNull(next!!.failure.value)
        r.scope.cancel()
    }

    /** Design §6.6: for model_gone's "switch model", selectModel first switches the session back to the last-used text model, then opens the picker; if the last-used one is invalid, only the picker opens. */
    @Test
    fun model_gone_switch_reverts_to_last_text_model() = runTest {
        Dispatchers.setMain(UnconfinedTestDispatcher(testScheduler))
        val r = Rig(this, entry, provider)
        r.selectRealtime(cloud)
        val engine = r.realtime()
        r.connection.events.close(RealtimeHandshakeException(404, "ProtocolException"))
        testScheduler.runCurrent()
        r.assertEndedOnFailureWithoutToast(engine)
        assertEquals("model_gone", engine.failure.value?.category)
        assertEquals(listOf<Any>("gpt-realtime"), realtimeFailureCard(engine.failure.value)!!.titleArgs)

        suspend fun switchWith(lastUsed: LastUsedModelRef?): Pair<String?, Int> {
            val viewModel = DraftChatViewModelFixture(
                provider = DraftChatViewModelFixture.sendable(provider, modelId = "gpt-5"),
                applicationScope = r.scope,
            ).create()
            testScheduler.runCurrent()
            // The session currently has a realtime model selected.
            viewModel.selectModel(provider.id, "gpt-realtime")
            testScheduler.runCurrent()
            assertEquals("gpt-realtime", viewModel.activeModelId)
            var pickerOpened = 0
            val target = viewModel.realtimeVoiceTarget(
                "c1",
                openModelPicker = { pickerOpened++ },
                lastUsedModel = { lastUsed },
            )
            // As rememberVoiceConversationHost: the failure card's switch-model is handed to the target.
            val handle = VoiceConversationHandle(
                page = VoiceConversationPage.Chat,
                statusState = mutableStateOf(ConversationStatusKey.ERROR),
                level = null,
                onEnd = {},
                onTapOrb = {},
                onToggleMute = {},
                captionState = mutableStateOf(""),
                nudgesState = mutableStateOf(0),
                failureState = mutableStateOf(engine.failure.value),
                failureActions = RealtimeFailureActions(switchModel = target.onSwitchModel),
            )
            handle.perform(RealtimeFailureAction.SwitchModel)
            testScheduler.runCurrent()
            return viewModel.activeModelId to pickerOpened
        }

        assertEquals("gpt-5" to 1, switchWith(LastUsedModelRef(provider.id, "gpt-5")))
        // Last-used is empty / the connection is gone: do not change the selection, just open the picker.
        assertEquals("gpt-realtime" to 1, switchWith(null))
        assertEquals("gpt-realtime" to 1, switchWith(LastUsedModelRef("gone-connection", "gpt-5")))
        // Switching the model for other classes does not switch back.
        assertFalse(realtimeFailureRestoresTextModel(RealtimeFailure("quota", provider.id, "Work OpenAI", "gpt-realtime")))
        r.scope.cancel()
    }

    /** Consent to realtime disclosure on the voice station is recorded in disclosure storage (provider disclosure is recorded by the storage hook at the same time, see ProviderDisclosureCoRecorderTest). */
    @Test
    fun accepting_realtime_disclosure_also_accepts_provider_disclosure() = runTest {
        val r = Rig(this, entry, provider)

        r.builder.acceptDisclosure(provider.kind)

        assertTrue(r.settings.disclosure.isAccepted(provider.kind, VoiceDirection.Realtime))
        r.scope.cancel()
    }

    /** The realtime model is selected mid-way through a text session; the session store does not push back, but it is judged realtime immediately by the current selection, and the orb opens realtime accordingly. */
    @Test
    fun mid_text_conversation_select_realtime_starts_realtime_before_store_echo() = runTest {
        Dispatchers.setMain(UnconfinedTestDispatcher(testScheduler))
        val r = Rig(this, entry, provider)
        r.settings.disclosure.markAccepted(ProviderKind.OpenAI, VoiceDirection.Realtime)
        val viewModel = DraftChatViewModelFixture(
            provider = DraftChatViewModelFixture.sendable(provider, modelId = "gpt-5"),
            applicationScope = r.scope,
            voiceCatalog = { r.catalog },
        ).create()
        testScheduler.runCurrent()
        viewModel.selectModel(provider.id, "gpt-5")
        testScheduler.runCurrent()
        // Realtime model selected: the fake repository does not push back the session; the judgment can only read the current selection.
        viewModel.selectModel(provider.id, "gpt-realtime")
        assertTrue(viewModel.isRealtimeModelSelected())
        val choice = prepareRealtimeVoiceSession(r.builder, viewModel.realtimeVoiceTarget("c1"), r.contextRequest) { null }
        assertTrue(choice is RealtimeVoiceSessionChoice.Realtime)
        assertEquals(1, r.made.size)
        r.scope.cancel()
    }

    /** Session on connection A's text model; switching across providers to B's realtime model, with the store not pushing back → both realtime target and disclosure use B (in-memory selection). */
    @Test
    fun cross_provider_select_realtime_before_store_echo_uses_new_provider() = runTest {
        Dispatchers.setMain(UnconfinedTestDispatcher(testScheduler))
        val r = Rig(this, entry, provider)
        val textConnection = DraftChatViewModelFixture.sendable(
            Provider(id = "conn-a", kind = ProviderKind.Anthropic, apiKey = "sk-ant"),
            modelId = "claude-text",
        )
        val viewModel = DraftChatViewModelFixture(
            provider = textConnection,
            applicationScope = r.scope,
            voiceCatalog = { r.catalog },
            providersFlow = flowOf(listOf(textConnection, provider)),
        ).create()
        testScheduler.runCurrent()
        viewModel.selectModel(textConnection.id, "claude-text")
        testScheduler.runCurrent()
        assertEquals(textConnection.id, viewModel.conversationState.provider?.id)
        // Cross-provider realtime model selection: the fake repository does not push back the session, so the session projection is still A.
        viewModel.selectModel(provider.id, "gpt-realtime")
        val target = viewModel.realtimeVoiceTarget("c1")
        assertEquals(provider.id, target.realtimeSelection?.connectionId)
        assertEquals(provider.kind, target.realtimeSelection?.providerKind)
        // Realtime disclosure not consented: disclosure first, the kind is B's.
        val choice = prepareRealtimeVoiceSession(r.builder, target, r.contextRequest) { null }
        assertEquals(RealtimeVoiceSessionChoice.Disclosure(provider.kind), choice)
        r.scope.cancel()
    }

    /** Selecting a text model again switches the voice station target back to the cascade (without a realtime selection). */
    @Test
    fun realtime_back_to_text_target_is_cascade() = runTest {
        Dispatchers.setMain(UnconfinedTestDispatcher(testScheduler))
        val r = Rig(this, entry, provider)
        val viewModel = DraftChatViewModelFixture(
            provider = DraftChatViewModelFixture.sendable(provider, modelId = "gpt-5"),
            applicationScope = r.scope,
            voiceCatalog = { r.catalog },
        ).create()
        testScheduler.runCurrent()
        viewModel.selectModel(provider.id, "gpt-realtime")
        assertNotNull(viewModel.realtimeVoiceTarget("c1").realtimeSelection)
        viewModel.selectModel(provider.id, "gpt-5")
        assertNull(viewModel.realtimeVoiceTarget("c1").realtimeSelection)
        r.scope.cancel()
    }

    @Test
    fun handle_caption_follows_realtime_caption() = runTest {
        val r = Rig(this, entry, provider)
        r.selectRealtime(cloud)
        val engine = r.realtime()
        // As rememberVoiceConversationHost: the realtime engine's caption stream is connected to the handle.
        val flow = voiceConversationCaption(engine)
        val handle = VoiceConversationHandle(
            page = VoiceConversationPage.Chat,
            statusState = mutableStateOf(ConversationStatusKey.LISTENING),
            level = null,
            onEnd = {},
            onTapOrb = {},
            onToggleMute = {},
            captionState = object : State<String> {
                override val value: String get() = flow.value
            },
            nudgesState = mutableStateOf(0),
        )
        r.send(RealtimeSessionEvent.Ready, RealtimeSessionEvent.UserSpeechStarted("u1"))
        assertEquals("", handle.caption)
        r.send(RealtimeSessionEvent.UserTranscript("u1", "hello", false))
        assertEquals("hello", handle.caption)
        assertEquals(engine.caption.value, handle.caption)
        engine.end(EndReason.USER)
        testScheduler.runCurrent()
        assertEquals("", handle.caption)
        r.scope.cancel()
    }

    @Test
    fun realtime_failure_never_toasts() = runTest {
        val r = Rig(this, entry, provider)
        r.selectRealtime(cloud)
        val engine = r.realtime()
        // Failure before connecting: an unexpected drop after connecting first reopens with history (design 6.6); here we want the path that goes straight to a failure card.
        r.connection.events.close(IllegalStateException("boom"))
        testScheduler.runCurrent()
        engine.end(EndReason.USER)
        testScheduler.runCurrent()

        // Failure card state: unknown failure, title carries the model, exits are retry / switch model; one Ended(ERROR), zero toasts.
        r.assertEndedOnFailureWithoutToast(engine)
        val failure = engine.failure.value!!
        val card = realtimeFailureCard(failure)!!
        assertEquals(R.string.voice_realtime_failure_unknown, card.title)
        assertEquals(listOf<Any>("gpt-realtime"), card.titleArgs)
        assertEquals(listOf(RealtimeFailureAction.Retry, RealtimeFailureAction.SwitchModel), card.buttons.map { it.action })
        // A cascade error end and a realtime non-error end likewise do not toast.
        assertNull(voiceConversationEventToast(VoiceConversationEvent.Ended(EndReason.ERROR, "x")))
        assertNull(voiceConversationEventToast(VoiceConversationEvent.Ended(EndReason.USER, null)))
        r.scope.cancel()
    }

    @Test
    fun status_announcement_pauses_realtime_uplink() = runTest {
        val r = Rig(this, entry, provider)
        r.selectRealtime(cloud)
        val engine = r.realtime()
        r.send(RealtimeSessionEvent.Ready)
        val frame = ByteArray(480) { 0x40 }
        val audio = r.audios.single()
        audio.onFrame!!(frame)
        assertEquals(1, r.connection.sent)

        // As rememberVoiceConversationHost's wiring: the read-aloud speaker's onSpeaking is handed to the engine.
        val announcer = StatusAnnouncer(
            scope = r.scope,
            screenReaderOn = { true },
            speak = {},
            onSpeaking = engine::screenReaderSpeaking,
        )
        announcer.announce("Listening")
        audio.onFrame!!(frame)
        assertEquals(1, r.connection.sent)
        assertEquals(ConversationStatusKey.LISTENING, engine.statusKey.value)

        testScheduler.advanceTimeBy(StatusAnnouncer.estimateMillis("Listening") + 1)
        testScheduler.runCurrent()
        audio.onFrame!!(frame)
        assertEquals(2, r.connection.sent)
        r.scope.cancel()
    }

    @Test
    fun voice_entry_always_cascade() = runTest {
        // ≋ (no realtime model selected on the page) always cascades: the realtime selection in the old engine setting is neither read nor opened nor checked against the catalog; the old key is kept for upgrade migration.
        val r = Rig(this, entry, provider)
        r.selectRealtime(cloud)
        r.settings.disclosure.markAccepted(ProviderKind.OpenAI, VoiceDirection.Realtime)
        assertEquals(RealtimeVoiceSessionChoice.Cascade, r.builder.prepare("c1", r.contextRequest))
        val home = VoiceConversationTarget.Home(createConversation = { null }, navigate = {})
        assertEquals(RealtimeVoiceSessionChoice.Cascade, prepareRealtimeVoiceSession(r.builder, home, r.contextRequest) { null })
        val chat = VoiceConversationTarget.Chat(conversationId = "c1", context = r.contextRequest) { NoChat }
        assertEquals(RealtimeVoiceSessionChoice.Cascade, prepareRealtimeVoiceSession(r.builder, chat, r.contextRequest) { null })
        assertTrue(r.made.isEmpty())
        assertEquals(0, r.catalogCalls)
        assertFalse(r.builder.realtimeActive)
        assertEquals(cloud, r.settings.legacyRealtimeChoice())
        r.scope.cancel()
    }

    @Test
    fun selected_connection_gone_fails_model_gone_without_rewrite() = runTest {
        val r = Rig(this, entry, provider)
        val gone = cloud.copy(connectionId = "gone")
        r.selectRealtime(gone)
        r.settings.disclosure.markAccepted(ProviderKind.OpenAI, VoiceDirection.Realtime)
        val expected = RealtimeVoiceSessionChoice.Failed(
            RealtimeFailure(RealtimeModel.CATEGORY_MODEL_GONE, providerId = "gone", providerName = "", model = "gpt-realtime"),
        )
        assertEquals(expected, r.builder.prepare("c1", r.contextRequest, selected = gone))
        // No fallback, no settings rewrite, no hint consumed: entering again is still the same failure card.
        assertEquals(gone, r.settings.selection(VoiceDirection.Realtime))
        assertEquals(expected, r.builder.prepare("c1", r.contextRequest, selected = gone))
        assertTrue(r.made.isEmpty())
        r.scope.cancel()
    }

    @Test
    fun plan_rejected_fails_unknown_without_toast() = runTest {
        val r = Rig(this, entry.copy(contextWindow = 2_000), provider)
        r.selectRealtime(cloud)
        r.settings.disclosure.markAccepted(ProviderKind.OpenAI, VoiceDirection.Realtime)
        r.instructions = "word ".repeat(20_000)
        val choice = r.builder.prepare("c1", r.contextRequest, selected = r.selected)
        assertEquals(
            RealtimeVoiceSessionChoice.Failed(
                RealtimeFailure(RealtimeModel.CATEGORY_UNKNOWN, provider.id, "Work OpenAI", "gpt-realtime"),
            ),
            choice,
        )
        assertTrue(r.made.isEmpty())
        r.scope.cancel()
    }

    @Test
    fun assistant_attributed_to_realtime_model() = runTest {
        val r = Rig(this, entry, provider)
        r.selectRealtime(cloud)
        r.realtime()
        r.send(
            RealtimeSessionEvent.Ready,
            RealtimeSessionEvent.UserSpeechStarted(null),
            RealtimeSessionEvent.UserSpeechStopped(null),
            RealtimeSessionEvent.UserTranscript(null, "hello there", final = true),
            RealtimeSessionEvent.AssistantTranscript(null, "hi", final = true),
            RealtimeSessionEvent.AssistantTurnDone(null, RealtimeTurnStatus.Completed, "hi, how can I help"),
        )
        assertEquals(listOf(ChatRole.User, ChatRole.Assistant), r.added.map { it.role })
        val user = r.added[0]
        assertEquals("hello there", user.text)
        assertEquals(ChatMessageState.Delivered, user.state)
        val assistant = r.updated.single()
        assertEquals(r.added[1].id, assistant.id)
        assertEquals("hi, how can I help", assistant.text)
        assertEquals(ChatMessageState.Delivered, assistant.state)
        assertEquals(provider.id, assistant.providerID)
        assertEquals(ProviderKind.OpenAI, assistant.providerKind)
        assertEquals(provider.displayName, assistant.providerName)
        assertEquals("gpt-realtime", assistant.modelID)
        assertEquals("gpt-realtime", assistant.modelName)
        assertNull(assistant.attachments)
        assertTrue(assistant.createdAt!! > user.createdAt!!)
        r.scope.cancel()
    }

    /** Incoming call / Siri / permanent focus loss: the reducer's systemInterruption still closes as before. */
    @Test
    fun realtime_system_interruption_closes() = runTest {
        val r = Rig(this, entry, provider)
        r.selectRealtime(cloud)
        val engine = r.realtime()
        r.send(RealtimeSessionEvent.Ready)
        engine.systemInterruption()
        testScheduler.runCurrent()
        assertEquals(1, r.connection.closes)
        assertFalse(engine.active.value)
        assertFalse(r.builder.realtimeActive)
        assertEquals(VoiceConversationEvent.Ended(EndReason.SYSTEM, null), r.events.last())
        assertEquals(1, r.foreground.stops)
        r.scope.cancel()
    }

    /** Going to background / screen lock is not a reducer input: the session does not drop and turns keep going; 120 s with nobody speaking in the background still ends. */
    @Test
    fun realtime_background_keeps_session() = runTest {
        val r = Rig(this, entry, provider)
        r.selectRealtime(cloud)
        val engine = r.realtime()
        r.send(RealtimeSessionEvent.Ready)
        for (event in listOf("enterBackground", "screenLock")) {
            assertEquals(RealtimeModel.LifecycleResult(RealtimeModel.LIFECYCLE_CONTINUE, null), RealtimeModel.lifecycle(event))
        }
        testScheduler.advanceTimeBy(60_000)
        testScheduler.runCurrent()
        assertTrue(engine.active.value)
        assertEquals(0, r.connection.closes)
        r.turn("still there?", "yes")
        assertEquals(listOf("still there?", "yes"), r.added.map { it.text })
        assertTrue(engine.active.value)
        assertEquals(0, r.foreground.stops)
        testScheduler.advanceTimeBy(RealtimeConversationConstants.IDLE_END_MS + 1)
        testScheduler.runCurrent()
        assertFalse(engine.active.value)
        assertEquals(1, r.connection.closes)
        assertEquals(VoiceConversationEvent.Ended(EndReason.IDLE, null), r.events.last())
        assertEquals(1, r.foreground.stops)
        r.scope.cancel()
    }

    @Test
    fun realtime_starts_foreground_service() = runTest {
        val r = Rig(this, entry, provider)
        r.selectRealtime(cloud)
        val engine = r.realtime()
        assertEquals(1, r.foreground.awaits)
        assertEquals(1, r.connection.opened)
        assertTrue(engine.active.value)
        assertEquals(0, r.foreground.stops)
        r.scope.cancel()

        // The service did not run into the foreground: same as the cascade, a start failure does not enter the session and reports no telemetry; the connection and sink are closed and the service is stopped.
        val failed = Rig(this, entry, provider)
        failed.foreground.started = false
        failed.selectRealtime(cloud)
        val refused = failed.realtime()
        assertEquals(0, failed.connection.opened)
        assertEquals(1, failed.connection.closes)
        assertFalse(refused.active.value)
        assertFalse(failed.builder.realtimeActive)
        assertEquals(listOf<VoiceConversationEvent>(VoiceConversationEvent.StartFailed(StartFailure.FOREGROUND)), failed.events)
        assertEquals(1, failed.foreground.stops)
        assertTrue(failed.sinks.single().closed)
        failed.scope.cancel()
    }

    @Test
    fun notification_end_ends_as_user() = runTest {
        val r = Rig(this, entry, provider)
        r.selectRealtime(cloud)
        val engine = r.realtime()
        r.send(RealtimeSessionEvent.Ready)
        r.foreground.ends.tryEmit(Unit)
        testScheduler.runCurrent()
        assertFalse(engine.active.value)
        assertEquals(1, r.connection.closes)
        assertEquals(VoiceConversationEvent.Ended(EndReason.USER, null), r.events.last())
        assertEquals(1, r.foreground.stops)
        // No more "end" notifications after the session ends.
        val events = r.events.size
        r.foreground.ends.tryEmit(Unit)
        testScheduler.runCurrent()
        assertEquals(events, r.events.size)
        r.scope.cancel()
    }

    @Test
    fun realtime_end_stops_service() = runTest {
        val r = Rig(this, entry, provider)
        r.selectRealtime(cloud)
        val engine = r.realtime()
        r.send(RealtimeSessionEvent.Ready)
        assertEquals(0, r.foreground.stops)
        engine.end(EndReason.USER)
        testScheduler.runCurrent()
        assertFalse(engine.active.value)
        assertEquals(1, r.foreground.stops)
        r.scope.cancel()
    }

    /** realtime-model.v1 lifecycleCases: continue keeps the session alive; end ends it with system via the reducer systemInterruption. */
    @Test
    fun lifecycle_cases_match_fixture() = runTest {
        val fixture = Json.parseToJsonElement(workspaceFile("shared/voice-contracts/realtime-model.v1.json").readText()).jsonObject
        val cases = fixture["lifecycleCases"]!!.jsonArray.map { it.jsonObject }
        assertEquals(6, cases.size)
        for (case in cases) {
            val id = case["id"]!!.jsonPrimitive.content
            val expected = case["expected"]!!.jsonObject
            val reducerInput = expected["reducerInput"].takeUnless { it == null || it is JsonNull }?.jsonPrimitive?.content
            val result = RealtimeModel.lifecycle(case["input"]!!.jsonObject["event"]!!.jsonPrimitive.content)
            assertEquals(id, RealtimeModel.LifecycleResult(expected["action"]!!.jsonPrimitive.content, reducerInput), result)
            val r = Rig(this, entry, provider)
            r.selectRealtime(cloud)
            val engine = r.realtime()
            r.send(RealtimeSessionEvent.Ready)
            if (result.reducerInput == RealtimeModel.REDUCER_SYSTEM_INTERRUPTION) engine.systemInterruption()
            testScheduler.runCurrent()
            val ends = result.action == RealtimeModel.LIFECYCLE_END
            assertEquals(id, !ends, engine.active.value)
            assertEquals(id, if (ends) 1 else 0, r.connection.closes)
            assertEquals(id, if (ends) 1 else 0, r.foreground.stops)
            if (ends) assertEquals(id, VoiceConversationEvent.Ended(EndReason.SYSTEM, null), r.events.last())
            r.scope.cancel()
        }
    }

    private fun workspaceFile(relative: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("could not find $relative")
    }

    @Test
    fun home_realtime_creates_conversation_on_first_persist() = runTest {
        val r = Rig(this, entry, provider)
        r.selectRealtime(cloud)
        val home = Any()
        r.home(home)
        r.send(RealtimeSessionEvent.Ready)
        assertTrue(r.created.isEmpty())

        r.turn("hello there", "hi")
        assertEquals(listOf("new-1"), r.created)
        assertEquals(listOf("new-1"), r.navigated)
        assertEquals(listOf(true), r.navigatedOnMain)
        assertEquals("new-1", r.sessions.handoffConversationId)
        assertEquals(listOf("new-1", "new-1"), r.addedTo)
        assertEquals(listOf(ChatRole.User, ChatRole.Assistant), r.added.map { it.role })
        assertEquals("gpt-realtime", r.updated.single().modelID)
        // During the jump the home page is still the owner and the handover is incomplete: the home host leaving does not end the session.
        assertTrue(r.sessions.ownedBy(home))
        assertTrue(r.sessions.handingOff)
        r.scope.cancel()
    }

    @Test
    fun home_realtime_no_persist_leaves_no_conversation() = runTest {
        val r = Rig(this, entry, provider)
        r.selectRealtime(cloud)
        val engine = r.home(Any())
        r.send(RealtimeSessionEvent.Ready, RealtimeSessionEvent.UserSpeechStarted(null))
        engine.end(EndReason.USER)
        testScheduler.runCurrent()
        assertFalse(engine.active.value)
        assertTrue(r.created.isEmpty())
        assertTrue(r.navigated.isEmpty())
        assertTrue(r.added.isEmpty())
        assertNull(r.sessions.handoffConversationId)
        assertFalse(r.sessions.handingOff)
        r.scope.cancel()
    }

    @Test
    fun home_realtime_continues_after_handoff() = runTest {
        val r = Rig(this, entry, provider)
        r.selectRealtime(cloud)
        val engine = r.home(Any())
        r.send(RealtimeSessionEvent.Ready)
        r.turn("first", "one")

        val chatPage = Any()
        assertTrue(r.sessions.attach("new-1", chatPage) { NoChat })
        assertTrue(r.sessions.ownedBy(chatPage))
        assertFalse(r.sessions.handingOff)
        // The chat page takes over the same realtime engine instance; the connection does not drop.
        assertTrue(r.builder.running === engine)
        assertTrue(engine.active.value)
        assertEquals(0, r.connection.closes)

        r.turn("second", "two")
        assertEquals(listOf("new-1"), r.created)
        assertEquals(listOf("new-1"), r.navigated)
        assertEquals(List(4) { "new-1" }, r.addedTo)
        assertEquals(listOf("first", "one", "second", "two"), r.added.map { it.text })
        assertEquals(1, r.connection.opened)
        r.scope.cancel()
    }

    @Test
    fun plan_uses_chat_send_context() = runTest {
        val r = Rig(this, entry, provider)
        r.selectRealtime(cloud)
        val note = Note(
            id = "11111111-1111-1111-1111-111111111111",
            title = "Trip",
            body = "PINNED-NOTE-kyoto",
            createdAt = "2026-06-01T00:00:00Z",
            updatedAt = "2026-06-01T00:00:00Z",
        )
        val memory = MemoryItem(
            id = "memory-1",
            kind = MemoryKind.FACT,
            content = "MEMORY-likes-tea",
            mutationId = "mutation-1",
            deviceId = "device-1",
        )
        val coordinator = ChatSendCoordinator(
            chatStreamingManager = mockk<ChatStreamingManager>(relaxed = true),
            applicationScope = r.scope,
            pinnedNotesResolver = { listOf(note) },
            pendingPinnedNoteIds = { emptyList() },
            generationParameterSettingsStore = GenerationParameterSettingsStore(readPayload = { null }, writePayload = {}),
            reminderEnabled = { true },
        )
        r.edit = { it.copy(useMemory = true, pinnedNoteIds = listOf(note.id)) }
        // As chat page wiring: sendCoordinator::realtimeSessionContext + this page's memory list.
        r.contextRequest = { c -> coordinator.realtimeSessionContext(c, listOf(memory)) }
        r.realtime()

        val sent = r.connection.inputs.single().instructions
        assertTrue(sent.contains("PINNED-NOTE-kyoto"))
        assertTrue(sent.contains("MEMORY-likes-tea"))
        val conversation = r.edit(
            Conversation(
                id = "c1",
                title = "t",
                providerID = provider.id,
                providerKind = provider.kind,
                modelID = "gpt-5",
            ),
        )
        val expected = RealtimeSessionProjector.project(
            request = coordinator.realtimeSessionContext(conversation, listOf(memory)),
            rawMessages = conversation.messages,
            contextWindow = entry.contextWindow.toInt(),
            currentSessionId = null,
            sessionMessageIds = emptySet(),
        )
        assertEquals(PlannedRealtimeSession.from(expected)!!.transportInput().instructions, sent)
        r.scope.cancel()
    }

    @Test
    fun selected_model_missing_from_catalog_fails_model_gone() = runTest {
        val r = Rig(this, entry, provider)
        val missing = cloud.copy(model = "gpt-realtime-retired")
        r.selectRealtime(missing)
        r.settings.disclosure.markAccepted(ProviderKind.OpenAI, VoiceDirection.Realtime)
        val choice = r.builder.prepare("c1", r.contextRequest, selected = missing)
        assertEquals(
            RealtimeVoiceSessionChoice.Failed(
                RealtimeFailure(RealtimeModel.CATEGORY_MODEL_GONE, provider.id, "Work OpenAI", "gpt-realtime-retired"),
            ),
            choice,
        )
        assertEquals(missing, r.settings.selection(VoiceDirection.Realtime))
        assertTrue(r.made.isEmpty())
        r.scope.cancel()
    }

    /** Chat page draft (no conversation row yet): the first persist goes through the chat page's own create-conversation callback; no message is lost. */
    @Test
    fun chat_without_conversation_creates_on_first_persist() = runTest {
        // Replan runs on the test scheduler: the turn-boundary replan after the first persist is production behavior (realtime-session.v1), and the result is visible in the same turn.
        val r = Rig(this, entry, provider, replanInline = true)
        r.selectRealtime(cloud)
        r.settings.disclosure.markAccepted(ProviderKind.OpenAI, VoiceDirection.Realtime)
        val draft = Conversation(id = "", title = "", providerID = provider.id, providerKind = provider.kind, modelID = "gpt-5")
        val choice = r.builder.prepare(null, r.contextRequest, { draft }, {
            "chat-new".also { r.created += it }
        }, r.selected)
        val engine = (choice as RealtimeVoiceSessionChoice.Realtime).engine
        engine.start(NoChat)
        testScheduler.runCurrent()
        r.send(RealtimeSessionEvent.Ready)
        assertTrue(r.created.isEmpty())

        r.turn("hello there", "hi")
        assertEquals(listOf("chat-new"), r.created)
        assertEquals(listOf("chat-new", "chat-new"), r.addedTo)
        assertEquals(listOf("hello there", "hi"), r.added.map { it.text })
        // Opening once + the first turn-boundary replan once: both plans are for the same model.
        assertEquals(listOf("gpt-5", "gpt-5"), r.planned.map { it.modelID })
        r.scope.cancel()
    }

    /** Chat page list = persisted messages + temporary bubbles: a bubble appears only when it has text, reveals by what has been played, is replaced by the formal message after persisting, and the same sentence appears only once. */
    @Test
    fun chat_list_shows_live_bubbles_then_persisted_once() = runTest {
        val r = Rig(this, entry, provider)
        r.selectRealtime(cloud)
        val engine = r.realtime()
        val source = checkNotNull(ai.oriveo.community.feature.chat.realtimeLiveBubbleSource(engine.drafts, engine.attribution, engine.callMessageIds))
        fun shown() = r.added + ai.oriveo.community.feature.chat.RealtimeLiveHandover(source.callMessageIds.value)
            .bubbles(engine.drafts.value, r.added, source.attribution)
        fun list() = shown().map { Triple(it.role, it.text, it.id.startsWith("realtime_live")) }
        r.send(RealtimeSessionEvent.Ready, RealtimeSessionEvent.UserSpeechStarted(null))
        assertEquals(emptyList<Triple<ChatRole, String, Boolean>>(), list())

        r.send(RealtimeSessionEvent.UserTranscript(null, "hello", final = false))
        assertEquals(listOf(Triple(ChatRole.User, "hello", true)), list())

        r.send(RealtimeSessionEvent.UserSpeechStopped(null), RealtimeSessionEvent.UserTranscript(null, "hello there", final = true))
        assertEquals(listOf(Triple(ChatRole.User, "hello there", false)), list())

        // The ideal player plays as soon as it receives: the next played-progress report (≤ 100 ms) reveals the whole sentence.
        r.send(assistantAudio(), RealtimeSessionEvent.AssistantTranscript(null, "hi", final = false))
        testScheduler.advanceTimeBy(ai.oriveo.community.core.voice.realtime.RealtimeVoiceConversationController.PROGRESS_INTERVAL_MS)
        testScheduler.runCurrent()
        assertEquals(listOf(Triple(ChatRole.User, "hello there", false), Triple(ChatRole.Assistant, "hi", true)), list())
        // The header of the temporary AI bubble = the header of the formal message (the realtime-selected catalog model), so it does not jump on replacement.
        val live = shown().last()
        assertEquals(entry.model, live.modelName)

        r.send(RealtimeSessionEvent.AssistantTurnDone(null, RealtimeTurnStatus.Completed, "hi"))
        assertEquals(listOf(Triple(ChatRole.User, "hello there", false), Triple(ChatRole.Assistant, "hi", false)), list())
        val stored = r.added.last()
        assertEquals(
            listOf(stored.providerID, stored.providerKind, stored.providerName, stored.modelID, stored.modelName),
            listOf(live.providerID, live.providerKind, live.providerName, live.modelID, live.modelName),
        )
        r.scope.cancel()
    }

    /** After the persist effect has cleared the draft but the formal message has not yet entered the list: the temporary bubble keeps the last sentence and is only removed when a same-role message added in the conversation appears, so there is no blank gap. */
    @Test
    fun live_bubble_hands_over_without_gap() = runTest {
        val r = Rig(this, entry, provider)
        r.selectRealtime(cloud)
        val engine = r.realtime()
        val attribution = checkNotNull(engine.attribution)
        // Same-role messages already in the list before entering the session do not count as a replacement.
        val earlier = listOf(
            ChatMessage(id = "old-u", role = ChatRole.User, text = "hello there", providerKind = provider.kind,
                providerName = "", modelName = "", state = ChatMessageState.Delivered),
            ChatMessage(id = "old-a", role = ChatRole.Assistant, text = "hi", providerKind = provider.kind,
                providerName = "", modelName = "", state = ChatMessageState.Delivered),
        )
        fun live(listed: List<ChatMessage>) = ai.oriveo.community.feature.chat.RealtimeLiveHandover(engine.callMessageIds.value)
            .bubbles(engine.drafts.value, earlier + listed, attribution).map { it.role to it.text }
        r.send(
            RealtimeSessionEvent.Ready,
            RealtimeSessionEvent.UserSpeechStarted(null),
            RealtimeSessionEvent.UserTranscript(null, "hello", final = false),
        )
        assertEquals(listOf(ChatRole.User to "hello"), live(emptyList()))
        r.send(RealtimeSessionEvent.UserSpeechStopped(null), RealtimeSessionEvent.UserTranscript(null, "hello there", final = true))
        assertEquals(null, engine.drafts.value.user)
        // The formal message has not reached the list yet: the same sentence stays.
        assertEquals(listOf(ChatRole.User to "hello there"), live(emptyList()))
        val user = r.added.single()
        assertEquals(emptyList<Pair<ChatRole, String>>(), live(listOf(user)))

        r.send(assistantAudio(), RealtimeSessionEvent.AssistantTranscript(null, "hi", final = false))
        testScheduler.advanceTimeBy(ai.oriveo.community.core.voice.realtime.RealtimeVoiceConversationController.PROGRESS_INTERVAL_MS)
        testScheduler.runCurrent()
        assertEquals(listOf(ChatRole.Assistant to "hi"), live(listOf(user)))
        r.send(RealtimeSessionEvent.AssistantTurnDone(null, RealtimeTurnStatus.Completed, "hi"))
        assertEquals(null, engine.drafts.value.assistant)
        assertEquals(listOf(ChatRole.Assistant to "hi"), live(listOf(user)))
        assertEquals(emptyList<Pair<ChatRole, String>>(), live(r.added))
        r.scope.cancel()
    }

    /** This session's user sentence was already persisted before the list attached to the realtime session (home creates the conversation first, then jumps to the page): counted by the id written in this session, so the same sentence appears only once. */
    @Test
    fun live_bubble_no_duplicate_when_persisted_before_handover_set() = runTest {
        val r = Rig(this, entry, provider)
        r.selectRealtime(cloud)
        val engine = r.realtime()
        val attribution = checkNotNull(engine.attribution)
        r.send(
            RealtimeSessionEvent.Ready,
            RealtimeSessionEvent.UserSpeechStarted(null),
            RealtimeSessionEvent.UserSpeechStopped(null),
            RealtimeSessionEvent.UserTranscript(null, "hello there", final = true),
        )
        val user = r.added.single()
        assertEquals(setOf(user.id), engine.callMessageIds.value)
        // At this moment the list attaches the temporary bubble: this session's user sentence is already in the list.
        fun list(): List<Triple<ChatRole, String, Boolean>> {
            val listed = r.added
            val live = ai.oriveo.community.feature.chat.RealtimeLiveHandover(engine.callMessageIds.value)
                .bubbles(engine.drafts.value, listed, attribution)
            return (listed + live).map { Triple(it.role, it.text, it.id.startsWith("realtime_live")) }
        }
        assertEquals(listOf(Triple(ChatRole.User, "hello there", false)), list())
        r.scope.cancel()
    }

    /** Entering from home: after the conversation is created and the page jumps, the chat page attaches to the realtime session, and this session's user sentence and reply each appear only once. */
    @Test
    fun home_entry_user_line_shows_once_after_persist() = runTest {
        val r = Rig(this, entry, provider)
        r.selectRealtime(cloud)
        val engine = r.home(Any())
        val attribution = checkNotNull(engine.attribution)
        r.send(
            RealtimeSessionEvent.Ready,
            RealtimeSessionEvent.UserSpeechStarted(null),
            RealtimeSessionEvent.UserSpeechStopped(null),
            RealtimeSessionEvent.UserTranscript(null, "first", final = true),
        )
        assertEquals(listOf("new-1"), r.navigated)
        // Chat page new-1: list = persisted messages + this session's temporary bubble.
        fun list() = (r.added + ai.oriveo.community.feature.chat.RealtimeLiveHandover(engine.callMessageIds.value)
            .bubbles(engine.drafts.value, r.added, attribution))
            .map { Triple(it.role, it.text, it.id.startsWith("realtime_live")) }
        assertEquals(listOf(Triple(ChatRole.User, "first", false)), list())

        r.send(assistantAudio(), RealtimeSessionEvent.AssistantTranscript(null, "one", final = false))
        testScheduler.advanceTimeBy(ai.oriveo.community.core.voice.realtime.RealtimeVoiceConversationController.PROGRESS_INTERVAL_MS)
        testScheduler.runCurrent()
        assertEquals(listOf(Triple(ChatRole.User, "first", false), Triple(ChatRole.Assistant, "one", true)), list())
        r.send(RealtimeSessionEvent.AssistantTurnDone(null, RealtimeTurnStatus.Completed, "one"))
        assertEquals(listOf(Triple(ChatRole.User, "first", false), Triple(ChatRole.Assistant, "one", false)), list())
        r.scope.cancel()
    }

    /** Chat target for the realtime model selected on chat page conversation c1 (used by the typed-state cases). */
    private fun Rig.typingTarget() = VoiceConversationTarget.Chat(
        conversationId = "c1",
        context = contextRequest,
        createConversation = { "unused" },
        realtimeSelection = cloud.copy(voice = null),
    ) { NoChat }

    /** As the host's typed-state wiring: without a conversation, open a playback-only connection per the target, start the mediaPlayback foreground service, and send after the session starts. */
    private suspend fun Rig.typed(
        text: String,
        running: RealtimeVoiceConversationEngine?,
        onOutcome: (String) -> Unit = {},
        startService: () -> VoiceConversationServiceStarter.Result = { VoiceConversationServiceStarter.Result.Started },
    ): RealtimeVoiceSessionChoice? {
        val choice = sendRealtimeTyped(
            text = text,
            running = running,
            open = { prepareRealtimeVoiceSession(builder, typingTarget(), contextRequest, capture = false) { null } },
            startService = startService,
            onOutcome = onOutcome,
        ) { engine ->
            scope.launch { engine.events.collect { events += it } }
            engine.start(NoChat)
        }
        test.testScheduler.runCurrent()
        return choice
    }

    /** Existing realtime session: the typed state sends on the same connection without creating another; persisted on the final user transcript. */
    @Test
    fun typing_send_reuses_session() = runTest {
        val r = Rig(this, entry, provider)
        r.selectRealtime(cloud)
        val engine = r.realtime()
        r.send(RealtimeSessionEvent.Ready)
        val choice = r.typed("what time is it", engine)
        assertNull(choice)
        assertEquals(1, r.made.size)
        assertEquals(1, r.connection.opened)
        assertEquals(listOf("what time is it"), r.connection.texts)
        r.send(
            RealtimeSessionEvent.AssistantTranscript(null, "noon", final = true),
            RealtimeSessionEvent.AssistantTurnDone(null, RealtimeTurnStatus.Completed, "noon"),
        )
        assertEquals(listOf(ChatRole.User to "what time is it", ChatRole.Assistant to "noon"), r.added.map { it.role to it.text })
        r.scope.cancel()
    }

    /** No conversation: open a playback-only connection with the selected model (no capture, no foreground service), send once ready; the voice station reuses the same connection to start capture later. */
    @Test
    fun typing_send_opens_without_capture() = runTest {
        val r = Rig(this, entry, provider)
        r.settings.disclosure.markAccepted(ProviderKind.OpenAI, VoiceDirection.Realtime)
        val engine = (r.typed("hello", null) as RealtimeVoiceSessionChoice.Realtime).engine
        assertTrue(engine.active.value)
        assertFalse(engine.capturing.value)
        assertEquals("gpt-realtime", r.made.single().second.model)
        assertEquals(listOf(VoiceConversationService.Kind.MediaPlayback), r.foreground.kinds)
        // Do not send before ready, do not create the conversation or persist (queued, not dispatched to the reducer): a session whose connection is not built yet would lose the message.
        assertTrue(r.connection.texts.isEmpty())
        assertTrue(r.added.isEmpty())
        r.send(RealtimeSessionEvent.Ready)
        val audio = r.audios.single()
        assertEquals(1, audio.playbackStarts)
        assertEquals(0, audio.captureStarts)
        assertNull(audio.onFrame)
        assertEquals(listOf("hello"), r.connection.texts)
        r.send(
            RealtimeSessionEvent.AssistantTranscript(null, "hi there", final = true),
            RealtimeSessionEvent.AssistantTurnDone(null, RealtimeTurnStatus.Completed, "hi there"),
        )
        assertEquals(listOf("hello", "hi there"), r.added.map { it.text })

        engine.startCapture()
        testScheduler.runCurrent()
        assertTrue(engine.capturing.value)
        assertEquals(
            listOf(VoiceConversationService.Kind.MediaPlayback, VoiceConversationService.Kind.Microphone),
            r.foreground.kinds,
        )
        assertEquals(1, audio.captureStarts)
        checkNotNull(audio.onFrame)(ByteArray(960))
        assertTrue(r.connection.sent > 0)
        assertEquals(1, r.made.size)
        engine.end(EndReason.USER)
        testScheduler.runCurrent()
        assertEquals(1, r.foreground.stops)
        r.scope.cancel()
    }

    /** Typed-open session: one round finished speaking, stopped in the state waiting for the user. */
    private suspend fun Rig.typedIdle(): RealtimeVoiceConversationEngine {
        settings.disclosure.markAccepted(ProviderKind.OpenAI, VoiceDirection.Realtime)
        val engine = (typed("hello", null) as RealtimeVoiceSessionChoice.Realtime).engine
        send(RealtimeSessionEvent.Ready)
        send(
            RealtimeSessionEvent.AssistantTranscript(null, "hi there", final = true),
            RealtimeSessionEvent.AssistantTurnDone(null, RealtimeTurnStatus.Completed, "hi there"),
        )
        return engine
    }

    /** The playback-only session starts the same foreground service with mediaPlayback: going to background / screen lock keeps it per fixture lifecycle = continue; 120 s idle still ends it. */
    @Test
    fun playback_only_session_survives_background() = runTest {
        val r = Rig(this, entry, provider)
        val engine = r.typedIdle()
        assertFalse(engine.capturing.value)
        assertEquals(listOf(VoiceConversationService.Kind.MediaPlayback), r.foreground.kinds)
        for (event in listOf("enterBackground", "screenLock")) {
            assertEquals(RealtimeModel.LifecycleResult(RealtimeModel.LIFECYCLE_CONTINUE, null), RealtimeModel.lifecycle(event))
        }
        testScheduler.advanceTimeBy(60_000)
        testScheduler.runCurrent()
        assertTrue(engine.active.value)
        assertEquals(0, r.connection.closes)
        assertEquals(0, r.foreground.stops)
        testScheduler.advanceTimeBy(RealtimeConversationConstants.IDLE_END_MS + 1)
        testScheduler.runCurrent()
        assertFalse(engine.active.value)
        assertEquals(1, r.connection.closes)
        assertEquals(VoiceConversationEvent.Ended(EndReason.IDLE, null), r.events.last())
        assertEquals(1, r.foreground.stops)
        r.scope.cancel()
    }

    /** Voice station reuses capture: the same foreground service switches to microphone (no stop, no restart); the "end" notification still ends with user. */
    @Test
    fun capture_upgrade_switches_service_to_microphone() = runTest {
        val r = Rig(this, entry, provider)
        val engine = r.typedIdle()
        engine.startCapture()
        testScheduler.runCurrent()
        assertTrue(engine.capturing.value)
        assertEquals(
            listOf(VoiceConversationService.Kind.MediaPlayback, VoiceConversationService.Kind.Microphone),
            r.foreground.kinds,
        )
        assertEquals(0, r.foreground.stops)
        assertEquals(1, r.audios.single().captureStarts)
        assertEquals(1, r.made.size)
        r.foreground.ends.tryEmit(Unit)
        testScheduler.runCurrent()
        assertFalse(engine.active.value)
        assertEquals(VoiceConversationEvent.Ended(EndReason.USER, null), r.events.last())
        assertEquals(1, r.foreground.stops)
        r.scope.cancel()
    }

    /** The realtime entry foreground service fails to start (typed open, ≋ open, reuse capture): an unknown failure card on the station, no toast. */
    @Test
    fun foreground_start_failure_shows_unknown_card_no_toast() = runTest {
        // Typed open: the service is refused → Failed(unknown), the connection does not open, the sink is closed, no events.
        val typed = Rig(this, entry, provider)
        typed.settings.disclosure.markAccepted(ProviderKind.OpenAI, VoiceDirection.Realtime)
        val rejected = typed.typed("hello", null) {
            VoiceConversationServiceStarter.Result.Rejected(SecurityException("denied"))
        }
        assertEquals(RealtimeModel.CATEGORY_UNKNOWN, (rejected as RealtimeVoiceSessionChoice.Failed).failure.category)
        assertEquals("gpt-realtime", rejected.failure.model)
        assertEquals(0, typed.connection.opened)
        assertTrue(typed.connection.texts.isEmpty())
        assertTrue(typed.sinks.single().closed)
        assertTrue(typed.events.isEmpty())
        typed.scope.cancel()

        // ≋ open: the service does not run into the foreground → failure card unknown; StartFailed on a realtime session does not toast (the cascade still toasts as before).
        val voice = Rig(this, entry, provider)
        voice.foreground.started = false
        voice.selectRealtime(cloud)
        val refused = voice.realtime()
        assertFalse(refused.active.value)
        assertEquals(RealtimeModel.CATEGORY_UNKNOWN, refused.failure.value?.category)
        assertEquals(refused.unknownFailure(), refused.failure.value)
        val startFailed = VoiceConversationEvent.StartFailed(StartFailure.FOREGROUND)
        assertEquals(listOf<VoiceConversationEvent>(startFailed), voice.events)
        assertNull(voiceConversationEventToast(startFailed, realtime = true))
        assertEquals(R.string.voice_conversation_start_failed_toast to emptyList<Any>(), voiceConversationEventToast(startFailed))
        voice.scope.cancel()

        // Reuse capture: the service cannot switch to microphone → failure card unknown; the playback-only session is closed and the service stopped; no event toasts.
        val upgrade = Rig(this, entry, provider)
        val engine = upgrade.typedIdle()
        upgrade.foreground.refused += VoiceConversationService.Kind.Microphone
        engine.startCapture()
        testScheduler.runCurrent()
        assertFalse(engine.capturing.value)
        assertFalse(engine.active.value)
        assertEquals(RealtimeModel.CATEGORY_UNKNOWN, engine.failure.value?.category)
        assertEquals(0, upgrade.audios.single().captureStarts)
        assertEquals(1, upgrade.connection.closes)
        assertEquals(1, upgrade.foreground.stops)
        assertTrue(upgrade.events.none { voiceConversationEventToast(it, realtime = true) != null })
        // The host's start is refused (onStartFailed) goes through the same path: an already-ended session is not collected again.
        engine.captureStartFailed()
        testScheduler.runCurrent()
        assertEquals(1, upgrade.foreground.stops)
        upgrade.scope.cancel()
    }

    /** Back to the voice station (typed-open session, AI not speaking): reuse capture on the same connection, without interrupting or opening another connection. */
    @Test
    fun back_to_stage_resumes_capture_on_typed_session() = runTest {
        val r = Rig(this, entry, provider)
        val engine = r.typedIdle()
        resumeCaptureBackToStage(engine)
        testScheduler.runCurrent()
        assertTrue(engine.capturing.value)
        assertTrue(engine.active.value)
        assertEquals(1, r.audios.single().captureStarts)
        assertTrue(r.connection.log.none { it.startsWith("truncate:") })
        assertEquals(1, r.made.size)
        assertEquals(1, r.connection.opened)
        r.scope.cancel()
    }

    /** Back to the voice station as backToStage: without a session → only exits the typed state and shows the idle station, sends no request; a typed-open session running → sends a request to reuse capture. */
    @Test
    fun back_to_stage_without_session_only_leaves_typing() = runTest {
        var realtimeTyping = true
        var requests = 0
        backToVoiceStage(typedRealtimeSessionRunning(null), leaveTyping = { realtimeTyping = false }) { requests++ }
        assertFalse(realtimeTyping)
        assertEquals(0, requests)

        val r = Rig(this, entry, provider)
        val engine = r.typedIdle()
        realtimeTyping = true
        backToVoiceStage(typedRealtimeSessionRunning(engine), leaveTyping = { realtimeTyping = false }) { requests++ }
        assertFalse(realtimeTyping)
        assertEquals(1, requests)
        // Already capturing (the stage is running) does not send again.
        engine.startCapture()
        testScheduler.runCurrent()
        backToVoiceStage(typedRealtimeSessionRunning(engine), leaveTyping = {}) { requests++ }
        assertEquals(1, requests)
        r.scope.cancel()
    }

    /** Back to the voice station while the AI is speaking: first interrupt as the orb tap does (truncating the item being played), then reuse capture on the same connection. */
    @Test
    fun back_to_stage_while_speaking_interrupts_first() = runTest {
        val r = Rig(this, entry, provider)
        r.settings.disclosure.markAccepted(ProviderKind.OpenAI, VoiceDirection.Realtime)
        val engine = (r.typed("hello", null) as RealtimeVoiceSessionChoice.Realtime).engine
        r.send(RealtimeSessionEvent.Ready)
        val pcm = ai.oriveo.community.core.voice.realtime.RealtimePCM.toLittleEndian(ShortArray(2_400) { 1_000 })
        r.send(
            RealtimeSessionEvent.AssistantTranscript("a1", "a long answer", final = false),
            RealtimeSessionEvent.AssistantAudio("a1", 0, java.util.Base64.getEncoder().encodeToString(pcm), 24_000),
        )
        r.audios.single().playing = true
        assertEquals(ConversationStatusKey.SPEAKING, engine.statusKey.value)
        assertFalse(engine.capturing.value)
        resumeCaptureBackToStage(engine)
        testScheduler.runCurrent()
        assertEquals(listOf("text:hello", "truncate:a1"), r.connection.log)
        assertTrue(engine.capturing.value)
        assertEquals(1, r.audios.single().captureStarts)
        assertEquals(1, r.made.size)
        assertEquals(1, r.connection.opened)
        r.scope.cancel()
    }

    /** AI speaking and a send = barge-in: first truncate the item being played by the played ms, then send the text. */
    @Test
    fun typing_send_while_speaking_interrupts_first() = runTest {
        val r = Rig(this, entry, provider)
        r.selectRealtime(cloud)
        val engine = r.realtime()
        r.send(RealtimeSessionEvent.Ready)
        val pcm = ai.oriveo.community.core.voice.realtime.RealtimePCM.toLittleEndian(ShortArray(2_400) { 1_000 })
        r.send(
            RealtimeSessionEvent.AssistantTranscript("a1", "a long answer", final = false),
            RealtimeSessionEvent.AssistantAudio("a1", 0, java.util.Base64.getEncoder().encodeToString(pcm), 24_000),
        )
        r.audios.single().playing = true
        assertEquals(ConversationStatusKey.SPEAKING, engine.statusKey.value)
        r.typed("stop", engine)
        // Starting to speak triggers barge-in typed_N: the truncation comes before the text is sent.
        assertEquals(listOf("truncate:a1", "text:stop"), r.connection.log)
        assertEquals(ConversationStatusKey.THINKING, engine.statusKey.value)
        assertEquals(1, r.made.size)
        r.scope.cancel()
    }

    /** Send coordinator when the chat page has a realtime model selected (launchSend calls are counted; consumed clears the input box). */
    private fun Rig.typingCoordinator(
        consumed: MutableList<String>,
        onLaunch: () -> Unit = {},
    ): ai.oriveo.community.feature.chat.ChatSendCommandCoordinator {
        val providers = io.mockk.mockk<ai.oriveo.community.core.data.repository.ProviderRepository>()
        io.mockk.coEvery { providers.getById(provider.id) } returns provider
        val prefs = io.mockk.mockk<ai.oriveo.community.core.app.AppPreferencesRepository>(relaxed = true)
        io.mockk.coEvery { prefs.hasAcceptedProviderDisclosure(any()) } returns true
        return ai.oriveo.community.feature.chat.ChatSendCommandCoordinator(
            viewModelScope = scope,
            appPreferencesRepository = prefs,
            providerRepository = providers,
            conversationRepository = io.mockk.mockk(relaxed = true),
            currentConversation = { null },
            currentConversationId = { "c1" },
            onProviderSelectionError = {},
            onProviderResolutionError = {},
            onModelSelectionError = { error("realtime model must resolve") },
            onDisclosureRequired = { _, _ -> error("no text disclosure") },
            onConversationActivated = {},
            onComposerConsumed = { consumed += it },
            requestPin = {},
            onSendSettled = {},
            launchSend = { _, _, _, _, _, _, _, _, _, _, _ -> onLaunch() },
            voiceCatalog = { catalog },
        )
    }

    /** Typed send with a realtime model selected on the chat page: handed to the host to send to the realtime connection, never through the text chat API (neither launchSend nor the port send is touched). */
    @Test
    fun typing_send_never_hits_chat_api() = runTest {
        val r = Rig(this, entry, provider)
        r.settings.disclosure.markAccepted(ProviderKind.OpenAI, VoiceDirection.Realtime)
        var launches = 0
        val consumed = mutableListOf<String>()
        val coordinator = r.typingCoordinator(consumed) { launches++ }
        val typed = mutableListOf<String>()
        r.scope.launch { coordinator.realtimeTyped.collect { typed += it } }
        coordinator.sendMessage(text = "hello", attachments = null, providerId = provider.id, modelId = entry.model)
        testScheduler.runCurrent()
        assertEquals(listOf("hello"), typed)
        assertEquals(0, launches)
        // Handing it off does not mean persisted; the input box keeps the text for now.
        assertTrue(consumed.isEmpty())
        // After the host accepts it, it is sent to the realtime connection (NoChat calls report an error).
        r.typed(typed.single(), null, onOutcome = { coordinator.realtimeTypedSettled("hello", it, "hello") })
        r.send(RealtimeSessionEvent.Ready)
        assertEquals(listOf("hello"), r.connection.texts)
        assertEquals(0, launches)
        assertEquals(listOf("c1"), consumed)
        r.scope.cancel()
    }

    /** Typed-open session did not open (foreground service refused → failure card on the station): the input box keeps the original text; after this sentence finishes, the send key hands off the next one. */
    @Test
    fun typing_send_open_failed_keeps_text() = runTest {
        val r = Rig(this, entry, provider)
        r.settings.disclosure.markAccepted(ProviderKind.OpenAI, VoiceDirection.Realtime)
        val consumed = mutableListOf<String>()
        val coordinator = r.typingCoordinator(consumed)
        val typed = mutableListOf<String>()
        r.scope.launch { coordinator.realtimeTyped.collect { typed += it } }
        coordinator.sendMessage(text = "hello", attachments = null, providerId = provider.id, modelId = entry.model)
        testScheduler.runCurrent()
        // One sentence in flight: the send key does not hand off the next one.
        coordinator.sendMessage(text = "hello", attachments = null, providerId = provider.id, modelId = entry.model)
        testScheduler.runCurrent()
        assertEquals(listOf("hello"), typed)
        val outcomes = mutableListOf<String>()
        val choice = r.typed(
            typed.single(),
            null,
            onOutcome = {
                outcomes += it
                coordinator.realtimeTypedSettled("hello", it, "hello")
            },
        ) { VoiceConversationServiceStarter.Result.Rejected(SecurityException("denied")) }
        assertTrue(choice is RealtimeVoiceSessionChoice.Failed)
        assertEquals(listOf(RealtimeModel.TYPED_OPEN_FAILED), outcomes)
        assertTrue(RealtimeModel.typedSendOutcome(RealtimeModel.TYPED_CONTEXT_CHAT, outcomes.single()).inputKeepsText)
        assertTrue(consumed.isEmpty())
        assertTrue(r.added.isEmpty())
        // After it finishes, the same sentence can be sent again.
        coordinator.sendMessage(text = "hello", attachments = null, providerId = provider.id, modelId = entry.model)
        testScheduler.runCurrent()
        assertEquals(listOf("hello", "hello"), typed)
        r.scope.cancel()
    }

    /** Need to consent to realtime disclosure, user declines: hands back disclosureDeclined, the input box keeps the original text, no connection is created. */
    @Test
    fun typing_send_disclosure_declined_keeps_text() = runTest {
        val r = Rig(this, entry, provider)
        val consumed = mutableListOf<String>()
        val coordinator = r.typingCoordinator(consumed)
        val typed = mutableListOf<String>()
        r.scope.launch { coordinator.realtimeTyped.collect { typed += it } }
        coordinator.sendMessage(text = "hello", attachments = null, providerId = provider.id, modelId = entry.model)
        testScheduler.runCurrent()
        val outcomes = mutableListOf<Pair<String, String>>()
        val pending = PendingTypedSend { text, outcome ->
            outcomes += text to outcome
            coordinator.realtimeTypedSettled(text, outcome, "hello")
        }
        val choice = r.typed(typed.single(), null, onOutcome = { error("disclosure holds the sentence") })
        assertTrue(choice is RealtimeVoiceSessionChoice.Disclosure)
        pending.hold(typed.single())
        assertTrue(outcomes.isEmpty())
        pending.decline()
        assertEquals(listOf("hello" to RealtimeModel.TYPED_DISCLOSURE_DECLINED), outcomes)
        assertTrue(consumed.isEmpty())
        assertTrue(r.made.isEmpty())
        // Already finished: leaving the page does not report again.
        pending.leave()
        assertEquals(1, outcomes.size)
        r.scope.cancel()
    }

    /** The input box is cleared only after this sentence's user message is persisted; if the session ends before persist, endedBeforePersist is reported; if the input box has been changed when clearing, it is not cleared. */
    @Test
    fun typing_send_clears_after_persisted() = runTest {
        val r = Rig(this, entry, provider)
        r.settings.disclosure.markAccepted(ProviderKind.OpenAI, VoiceDirection.Realtime)
        val consumed = mutableListOf<String>()
        val coordinator = r.typingCoordinator(consumed)
        val outcomes = mutableListOf<String>()
        var composer = "hello"
        fun settle(text: String): (String) -> Unit = {
            outcomes += it
            coordinator.realtimeTypedSettled(text, it, composer)
        }
        val typed = mutableListOf<String>()
        r.scope.launch { coordinator.realtimeTyped.collect { typed += it } }
        coordinator.sendMessage(text = "hello", attachments = null, providerId = provider.id, modelId = entry.model)
        testScheduler.runCurrent()
        val engine = (r.typed(typed.last(), null, onOutcome = settle("hello")) as RealtimeVoiceSessionChoice.Realtime).engine
        // Not persisted before ready: no clear.
        assertTrue(outcomes.isEmpty())
        assertTrue(consumed.isEmpty())
        r.send(RealtimeSessionEvent.Ready)
        assertEquals(listOf(ChatRole.User to "hello"), r.added.map { it.role to it.text })
        assertEquals(listOf(RealtimeModel.TYPED_PERSISTED), outcomes)
        assertEquals(listOf("c1"), consumed)
        r.send(
            RealtimeSessionEvent.AssistantTranscript(null, "hi there", final = true),
            RealtimeSessionEvent.AssistantTurnDone(null, RealtimeTurnStatus.Completed, "hi there"),
        )

        // When the second sentence is persisted the user has already changed something else in the input box: no clear.
        composer = "again"
        coordinator.sendMessage(text = "again", attachments = null, providerId = provider.id, modelId = entry.model)
        testScheduler.runCurrent()
        composer = "again, edited"
        r.typed(typed.last(), engine, onOutcome = settle("again"))
        assertEquals(listOf(RealtimeModel.TYPED_PERSISTED, RealtimeModel.TYPED_PERSISTED), outcomes)
        assertEquals(listOf("c1"), consumed)

        // Session ends before persist: endedBeforePersist, the original text is kept.
        val r2 = Rig(this, entry, provider)
        r2.settings.disclosure.markAccepted(ProviderKind.OpenAI, VoiceDirection.Realtime)
        val outcomes2 = mutableListOf<String>()
        val engine2 = (r2.typed("bye", null, onOutcome = { outcomes2 += it }) as RealtimeVoiceSessionChoice.Realtime).engine
        engine2.end(EndReason.USER)
        testScheduler.runCurrent()
        assertEquals(listOf(RealtimeModel.TYPED_ENDED_BEFORE_PERSIST), outcomes2)
        assertTrue(r2.added.isEmpty())
        r.scope.cancel()
        r2.scope.cancel()
    }

    /** 100 ms of downlink audio (the ideal player finishes as soon as it receives it). */
    private fun assistantAudio(): RealtimeSessionEvent {
        val pcm = ai.oriveo.community.core.voice.realtime.RealtimePCM.toLittleEndian(ShortArray(2_400) { 1_000 })
        return RealtimeSessionEvent.AssistantAudio(null, 0, java.util.Base64.getEncoder().encodeToString(pcm), 24_000)
    }

    @Test
    fun sink_closed_after_end() = runTest {
        val r = Rig(this, entry, provider)
        r.selectRealtime(cloud)
        val engine = r.realtime()
        r.send(RealtimeSessionEvent.Ready)
        r.turn("first", "one")
        assertFalse(r.sinks.single().closed)
        engine.end(EndReason.USER)
        testScheduler.runCurrent()
        assertTrue(r.sinks.single().closed)
        // Writes already queued are persisted as usual; no new writes are accepted after close.
        assertEquals(listOf("first", "one"), r.added.map { it.text })
        r.scope.cancel()
    }

    @Test
    fun sink_closed_when_prepare_fails() = runTest {
        val r = Rig(this, entry, provider)
        r.selectRealtime(cloud)
        r.settings.disclosure.markAccepted(ProviderKind.OpenAI, VoiceDirection.Realtime)
        val engine = (r.builder.prepare("c1", r.contextRequest, selected = r.selected) as RealtimeVoiceSessionChoice.Realtime).engine
        // Failure after prepare (foreground service / session start not reached): the engine was never started, so the sink is closed on discard.
        engine.discard()
        testScheduler.runCurrent()
        assertTrue(r.sinks.single().closed)
        assertEquals(0, r.connection.opened)
        assertFalse(r.builder.realtimeActive)
        r.scope.cancel()
    }

    @Test
    fun undisclosed_gate_before_resolve_keeps_setting() = runTest {
        val r = Rig(this, entry, provider)
        val stored = cloud.copy(connectionId = "gone")
        r.selectRealtime(stored)
        val choice = r.builder.prepare("c1", r.contextRequest, selected = stored)
        // Voice disclosure not consented: disclose first, do not resolve, do not rewrite settings, do not fall back to the cascade.
        assertEquals(RealtimeVoiceSessionChoice.Disclosure(ProviderKind.OpenAI), choice)
        assertEquals(stored, r.settings.selection(VoiceDirection.Realtime))
        assertEquals(0, r.catalogCalls)
        assertTrue(r.made.isEmpty())
        r.scope.cancel()
    }

    /** Chat page session has a realtime model selected and the engine setting is system: the orb tap opens realtime per the session's connection and model (catalog default voice). */
    @Test
    fun chat_realtime_tap_starts_selected_model() = runTest {
        val r = Rig(this, entry, provider)
        r.settings.disclosure.markAccepted(ProviderKind.OpenAI, VoiceDirection.Realtime)
        val target = VoiceConversationTarget.Chat(
            conversationId = "c1",
            context = r.contextRequest,
            createConversation = { "unused" },
            realtimeSelection = cloud.copy(voice = null),
        ) { NoChat }
        val choice = prepareRealtimeVoiceSession(r.builder, target, r.contextRequest) { null }
        val engine = (choice as RealtimeVoiceSessionChoice.Realtime).engine
        engine.start(NoChat)
        testScheduler.runCurrent()
        val (kind, endpoint) = r.made.single()
        assertEquals(RealtimeTransportKind.OpenAiRealtime, kind)
        assertEquals("gpt-realtime", endpoint.model)
        assertEquals("sk-live", endpoint.apiKey)
        assertEquals("marin", endpoint.voice)
        assertTrue(engine.active.value)
        assertEquals(VoiceEngineSelection.System, r.settings.selection(VoiceDirection.Realtime))
        r.scope.cancel()
    }

    /** Realtime selected: connection missing / model missing from catalog / catalog unavailable / plan refused → all failure cards, never fall back to the cascade. */
    @Test
    fun selected_realtime_never_cascades() = runTest {
        suspend fun choice(rig: Rig, selection: VoiceEngineSelection.Cloud): RealtimeVoiceSessionChoice {
            rig.settings.disclosure.markAccepted(ProviderKind.OpenAI, VoiceDirection.Realtime)
            return rig.builder.prepare("c1", rig.contextRequest, selected = selection).also { rig.scope.cancel() }
        }
        val gone = choice(Rig(this, entry, provider), cloud.copy(connectionId = "gone"))
        val missing = choice(Rig(this, entry, provider), cloud.copy(model = "nope"))
        val rejected = Rig(this, entry.copy(contextWindow = 2_000), provider).apply { instructions = "word ".repeat(20_000) }
        val planRejected = choice(rejected, cloud)
        val noAuth = choice(Rig(this, entry, provider.copy(kind = ProviderKind.Relay)), cloud)
        listOf(gone, missing, planRejected, noAuth).forEach { assertFalse("$it", it is RealtimeVoiceSessionChoice.Cascade) }
        assertEquals(RealtimeModel.CATEGORY_MODEL_GONE, (gone as RealtimeVoiceSessionChoice.Failed).failure.category)
        assertEquals(RealtimeModel.CATEGORY_MODEL_GONE, (missing as RealtimeVoiceSessionChoice.Failed).failure.category)
        assertEquals(RealtimeModel.CATEGORY_UNKNOWN, (planRejected as RealtimeVoiceSessionChoice.Failed).failure.category)
        assertEquals(RealtimeModel.CATEGORY_MODEL_GONE, (noAuth as RealtimeVoiceSessionChoice.Failed).failure.category)
    }

    @Test
    fun unconsented_shows_disclosure_first() = runTest {
        val r = Rig(this, entry, provider)
        val target = VoiceConversationTarget.Chat(
            conversationId = "c1",
            context = r.contextRequest,
            createConversation = { "unused" },
            realtimeSelection = cloud,
        ) { NoChat }
        val first = prepareRealtimeVoiceSession(r.builder, target, r.contextRequest) { null }
        assertEquals(RealtimeVoiceSessionChoice.Disclosure(ProviderKind.OpenAI), first)
        assertEquals(0, r.catalogCalls)
        assertTrue(r.made.isEmpty())
        assertFalse(r.settings.disclosure.isAccepted(ProviderKind.OpenAI, VoiceDirection.Realtime))

        r.builder.acceptDisclosure(ProviderKind.OpenAI)
        assertTrue(r.settings.disclosure.isAccepted(ProviderKind.OpenAI, VoiceDirection.Realtime))
        val second = prepareRealtimeVoiceSession(r.builder, target, r.contextRequest) { null }
        assertTrue(second is RealtimeVoiceSessionChoice.Realtime)
        assertEquals(1, r.made.size)
        (second as RealtimeVoiceSessionChoice.Realtime).engine.discard()
        r.scope.cancel()
    }

    @Test
    fun navigation_end_writes_draft() = runTest {
        val r = Rig(this, entry, provider)
        r.selectRealtime(cloud)
        val engine = r.realtime()
        r.send(
            RealtimeSessionEvent.Ready,
            RealtimeSessionEvent.UserSpeechStarted(null),
            RealtimeSessionEvent.UserTranscript(null, "remind me to ", final = false),
        )
        engine.endLeavingPage()
        testScheduler.runCurrent()
        assertFalse(engine.active.value)
        assertTrue(r.events.contains(VoiceConversationEvent.DraftTranscript("remind me to")))
        assertEquals(VoiceConversationEvent.Ended(EndReason.USER, null), r.events.last())
        assertEquals(1, r.connection.closes)
        r.scope.cancel()
    }

    @Test
    fun chat_target_without_create_callback_uses_cascade() = runTest {
        val r = Rig(this, entry, provider)
        r.selectRealtime(cloud)
        r.settings.disclosure.markAccepted(ProviderKind.OpenAI, VoiceDirection.Realtime)
        val draft = Conversation(id = "", title = "", providerID = provider.id, providerKind = provider.kind, modelID = "gpt-5")
        // The draft chat page has no create-conversation callback attached: realtime messages have nowhere to persist, so this time it cascades instead of opening a realtime session that would lose messages.
        val target = VoiceConversationTarget.Chat(
            conversationId = null,
            context = r.contextRequest,
            newConversation = { draft },
        ) { NoChat }
        val choice = prepareRealtimeVoiceSession(r.builder, target, r.contextRequest) { null }
        assertEquals(RealtimeVoiceSessionChoice.Cascade, choice)
        assertTrue(r.made.isEmpty())
        assertFalse(r.builder.realtimeActive)
        // With the callback attached it is realtime as usual.
        val withCreate = VoiceConversationTarget.Chat(
            conversationId = null,
            context = r.contextRequest,
            createConversation = { "chat-new" },
            newConversation = { draft },
            realtimeSelection = r.selected,
        ) { NoChat }
        val realtime = prepareRealtimeVoiceSession(r.builder, withCreate, r.contextRequest) { null }
        assertTrue(realtime is RealtimeVoiceSessionChoice.Realtime)
        (realtime as RealtimeVoiceSessionChoice.Realtime).engine.discard()
        r.scope.cancel()
    }

    @Test
    fun home_plan_uses_first_send_conversation() = runTest {
        val r = Rig(this, entry, provider)
        r.selectRealtime(cloud)
        // The conversation object for the first send created from home: the home pill model + pending instructions, not the realtime connection / model.
        val firstSend = Conversation(
            id = "",
            title = "",
            providerID = "conn-home",
            providerKind = ProviderKind.Anthropic,
            modelID = "claude-home",
            instructions = "HOME-PENDING-INSTRUCTIONS",
        )
        r.chatProviders = listOf(Provider(id = "conn-home", kind = ProviderKind.Anthropic, apiKey = "sk-ant"))
        r.home(Any()) { firstSend }
        assertEquals(listOf(firstSend), r.planned)
        assertTrue(r.connection.inputs.single().instructions.contains("HOME-PENDING-INSTRUCTIONS"))
        // Ownership is still the realtime model.
        r.send(RealtimeSessionEvent.Ready)
        r.turn("hello", "hi")
        assertEquals("gpt-realtime", r.updated.single().modelID)
        r.scope.cancel()
    }

    /** A message already sent into [conversationId] outside the session (sent from the other end / the chat page). */
    private fun Rig.external(conversationId: String, id: String, role: ChatRole, text: String) {
        addedTo += conversationId
        added += ChatMessage(
            id = id,
            role = role,
            text = text,
            providerKind = provider.kind,
            providerName = "other",
            modelName = "gpt-5",
            state = ChatMessageState.Delivered,
        )
    }

    @Test
    fun own_transcripts_do_not_change_fingerprint() = runTest {
        val r = Rig(this, entry, provider, replanInline = true)
        r.selectRealtime(cloud)
        r.realtime()
        r.send(RealtimeSessionEvent.Ready)
        r.turn("first question", "first answer")
        r.turn("second question", "second answer")

        // Opening + a plan at each turn boundary, all planned for c1 itself.
        assertEquals(listOf("c1", "c1", "c1"), r.planned.map { it.id })
        assertEquals(4, r.planned.last().messages.size)
        // This session's own transcripts do not enter the replan history: the fingerprint does not change, no reopen.
        assertEquals(1, r.made.size)
        assertEquals(0, r.connection.closes)
        assertTrue(r.connection.inputs.single().history.isEmpty())
        r.scope.cancel()
    }

    @Test
    fun external_message_changes_fingerprint_and_reopens() = runTest {
        val r = Rig(this, entry, provider, replanInline = true)
        r.selectRealtime(cloud)
        r.realtime()
        r.send(RealtimeSessionEvent.Ready)
        r.turn("first question", "first answer")
        assertEquals(1, r.made.size)

        // A turn within the session that was not written by this session appears during the call → at the next turn boundary the lastHistoryId changes → reopen.
        r.external("c1", "ext-user", ChatRole.User, "typed question")
        r.external("c1", "ext-assistant", ChatRole.Assistant, "typed answer")
        r.turn("second question", "second answer")
        testScheduler.runCurrent()

        assertEquals(2, r.made.size)
        assertEquals(r.made[0], r.made[1])
        val reopened = r.connections[1].inputs.single()
        assertEquals(
            listOf("first question", "first answer", "typed question", "typed answer", "second question", "second answer"),
            reopened.history.map { it.text },
        )
        assertEquals(1, r.sinks.size)
        r.scope.cancel()
    }

    @Test
    fun home_entry_first_turn_replan_keeps_fingerprint() = runTest {
        val r = Rig(this, entry, provider, replanInline = true)
        r.selectRealtime(cloud)
        val memory = MemoryItem(
            id = "memory-home",
            kind = MemoryKind.FACT,
            content = "MEMORY-home-likes-tea",
            mutationId = "mutation-home",
            deviceId = "device-1",
        )
        // As home wiring: the opening uses the pending conversation (empty id, default values), and the replan uses the real conversation created by the first persist.
        r.contextRequest = { c ->
            r.planned += c
            newConversationContextRequest(c, listOf(memory))
        }
        val firstSend = Conversation(
            id = "",
            title = "",
            providerID = provider.id,
            providerKind = provider.kind,
            modelID = "gpt-5",
        )
        r.home(Any()) { firstSend }
        r.send(RealtimeSessionEvent.Ready)
        r.turn("hello there", "hi")
        r.turn("how are you", "fine")

        assertEquals(listOf("", "new-1", "new-1"), r.planned.map { it.id })
        assertTrue(r.connection.inputs.single().instructions.contains("MEMORY-home-likes-tea"))
        // The home entry has no compose-time pinned note waiting: neither the opening nor the replan carries notes.
        assertTrue(r.planned.all { it.pinnedNoteIds.isEmpty() })
        assertTrue(r.planned.all { newConversationContextRequest(it, listOf(memory)).conversation.pinnedNotes.isEmpty() })
        // After the first persist creates the conversation the fingerprint is unchanged: no reopen.
        assertEquals(1, r.made.size)
        assertEquals(0, r.connection.closes)
        assertEquals(listOf("new-1"), r.created)
        r.scope.cancel()
    }

    /**
     * Chat page draft entry (Chat target, conversationId = null) uses the target produced by ChatViewModel.realtimeVoiceTarget (the same function the host uses):
     * the real ChatNoteCoordinator's compose-time pending pinned note is merged into the opening via realtimeSessionContext; the first persist goes through the real
     * createFirstConversation → onConversationActivated → flushPendingPinnedNotes into pinnedNoteIds (pending is kept, merged and de-duplicated),
     * the replan is still the same note, the fingerprint is unchanged, no reopen.
     */
    @Test
    fun chat_draft_entry_real_note_coordinator_keeps_fingerprint() = runTest {
        val note = Note(
            id = "22222222-2222-2222-2222-222222222222",
            title = "Draft",
            body = "PINNED-NOTE-pending",
            createdAt = "2026-06-01T00:00:00Z",
            updatedAt = "2026-06-01T00:00:00Z",
        )
        // The real ChatViewModel's viewModelScope runs on Main: it follows the test dispatcher and is reset in @After (the VM coroutine still needs scheduling when runTest finishes).
        Dispatchers.setMain(UnconfinedTestDispatcher(testScheduler))
        val r = Rig(this, entry, provider, replanInline = true)
        r.selectRealtime(cloud)
        r.settings.disclosure.markAccepted(provider.kind, VoiceDirection.Realtime)
        val fixture = DraftChatViewModelFixture(
            provider = DraftChatViewModelFixture.sendable(provider, modelId = "gpt-5"),
            applicationScope = r.scope,
            notes = listOf(note),
            createdId = "chat-new",
        )
        val viewModel = fixture.create()
        testScheduler.runCurrent()
        viewModel.noteCoordinator.attachNoteToContext(note)
        assertEquals(listOf(note.id), viewModel.noteCoordinator.pendingPinnedNoteIds)
        // Fake repository: the id persisted by pinNoteToConversation is read back with the conversation.
        r.edit = { it.copy(pinnedNoteIds = fixture.pinned.toList()) }
        val vmTarget = viewModel.realtimeVoiceTarget(null)
        // Only records which conversation was planned outside the VM target's context; context / create-conversation / pending conversation / port are all the original values produced by the VM.
        val context: suspend (Conversation) -> ChatContextRequest = { c ->
            r.planned += c
            vmTarget.context(c)
        }
        val target = VoiceConversationTarget.Chat(
            conversationId = vmTarget.conversationId,
            context = context,
            createConversation = vmTarget.createConversation,
            newConversation = vmTarget.newConversation,
            // Realtime model selected on the session (no selection means cascade).
            realtimeSelection = r.selected,
            port = vmTarget.port,
        )
        val engine = (prepareRealtimeVoiceSession(r.builder, target, context) { null } as RealtimeVoiceSessionChoice.Realtime).engine
        r.scope.launch { engine.events.collect { r.events += it } }
        engine.start(NoChat)
        testScheduler.runCurrent()
        r.send(RealtimeSessionEvent.Ready)
        r.turn("hello there", "hi")
        r.turn("how are you", "fine")

        assertEquals(listOf("chat-new"), fixture.created)
        assertEquals(listOf(note.id), fixture.pinned)
        assertEquals(listOf(note.id), viewModel.noteCoordinator.pendingPinnedNoteIds)
        assertEquals(listOf("", "chat-new", "chat-new"), r.planned.map { it.id })
        assertEquals(listOf(emptyList(), listOf(note.id), listOf(note.id)), r.planned.map { it.pinnedNoteIds })
        val planNotes = r.planned.map { c -> vmTarget.context(c).conversation.pinnedNotes.map { it.text } }
        assertEquals(List(3) { listOf("PINNED-NOTE-pending") }, planNotes)
        assertTrue(r.connection.inputs.single().instructions.contains("PINNED-NOTE-pending"))
        assertEquals(1, r.made.size)
        assertEquals(0, r.connection.closes)
        r.scope.cancel()
    }

    @After
    fun resetMainDispatcher() {
        Dispatchers.resetMain()
    }

    private val geminiEntry = VoiceRealtimeEntry(
        model = "gemini-live-2.5-flash",
        transport = VoiceTransport.GeminiLive,
        path = "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent",
        contextWindow = 128_000,
        voices = listOf(VoiceOption("Puck", isDefault = true)),
        isDefault = true,
    )
    private val geminiProvider = Provider(
        id = "conn-gemini",
        kind = ProviderKind.Gemini,
        apiKey = "AIza-test",
        baseUrlText = "https://generativelanguage.googleapis.com/v1beta",
    )

    @Test
    fun muted_session_expired_reopens_with_history() = runTest {
        expireMutedAndReopen(home = false)
        expireMutedAndReopen(home = true)
    }

    /** Contract card B items 4 and 6: while muted, 1008 expires → does not end → unmute and reopen; the new connection's plan history carries the transcripts persisted in this call. */
    private suspend fun TestScope.expireMutedAndReopen(home: Boolean) {
        val r = Rig(this, geminiEntry, geminiProvider)
        r.selectRealtime(VoiceEngineSelection.Cloud(ProviderKind.Gemini, geminiProvider.id, geminiEntry.model, null))
        val engine = if (home) r.home(Any()) else r.realtime()
        val target = if (home) "new-1" else "c1"
        r.send(RealtimeSessionEvent.Ready)
        r.turn("first question", "first answer")

        engine.toggleMute()
        testScheduler.runCurrent()
        r.connection.events.close(GeminiLiveSessionExpiredException("Gemini Live session expired (1008)"))
        testScheduler.runCurrent()
        assertTrue(r.events.none { it is VoiceConversationEvent.Ended })
        assertTrue(engine.active.value)
        assertFalse(r.sinks.single().closed)
        assertEquals(1, r.made.size)

        engine.toggleMute()
        testScheduler.runCurrent()
        assertEquals(2, r.connections.size)
        val second = r.connections[1]
        assertEquals(1, second.opened)
        assertEquals(RealtimeTransportKind.GeminiLive, r.made[1].first)
        assertEquals(r.made[0].second, r.made[1].second)
        assertTrue(r.connection.inputs.single().history.isEmpty())
        assertEquals(
            listOf(ChatRole.User to "first question", ChatRole.Assistant to "first answer"),
            second.inputs.single().history.map { it.role to it.text },
        )
        // Does not rebuild the sink or resolve the selection again (no hint, no settings change).
        assertEquals(1, r.sinks.size)
        assertEquals(1, r.catalogCalls)

        r.send(RealtimeSessionEvent.Ready)
        assertEquals(ConversationStatusKey.LISTENING, engine.statusKey.value)
        r.turn("second question", "second answer")
        assertEquals(
            listOf("first question", "first answer", "second question", "second answer"),
            r.added.map { it.text },
        )
        assertEquals(List(4) { target }, r.addedTo)
        if (home) assertEquals(listOf("new-1"), r.created)
        assertTrue(r.events.none { it is VoiceConversationEvent.Ended })
        assertFalse(r.sinks.single().closed)
        r.scope.cancel()
    }

    /** A running cascade (fake): records end, and active becomes false after end. */
    private class RunningCascade : VoiceConversationEngine {
        override val statusKey = kotlinx.coroutines.flow.MutableStateFlow<ConversationStatusKey?>(null)
        override val level = kotlinx.coroutines.flow.MutableStateFlow(0f)
        override val active = kotlinx.coroutines.flow.MutableStateFlow(true)
        override val events = MutableSharedFlow<VoiceConversationEvent>()
        val ends = mutableListOf<EndReason>()
        override fun start(chat: VoiceConversationChatPort) = Unit
        override fun tapOrb() = Unit
        override fun toggleMute() = Unit
        override fun screenReaderSpeaking(speaking: Boolean) = Unit
        override fun end(reason: EndReason) {
            ends += reason
            active.value = false
        }
    }

    /** While the cascade runs the page switches to a realtime model → the cascade ends once as user, then the same entry path prepares a realtime session. */
    @Test
    fun cascade_running_select_realtime_ends_cascade_and_starts_realtime() = runTest {
        val r = Rig(this, entry, provider)
        r.settings.disclosure.markAccepted(provider.kind, VoiceDirection.Realtime)
        val cascade = RunningCascade()
        val before = r.selected.voiceEngineKey()
        r.selectRealtime(cloud)
        // As host wiring: the target after switching carries the new realtime model.
        val target = VoiceConversationTarget.Chat(
            conversationId = "c1",
            context = r.contextRequest,
            realtimeSelection = r.selected,
            port = { NoChat },
        )
        var reentered = 0
        val switched = switchVoiceEngine(cascade, before, target.realtimeSelection.voiceEngineKey()) { reentered++ }

        assertTrue(switched)
        assertEquals(listOf(EndReason.USER), cascade.ends)
        assertFalse(cascade.active.value)
        assertEquals(1, reentered)
        val choice = prepareRealtimeVoiceSession(r.builder, target, r.contextRequest) { null }
        val engine = (choice as RealtimeVoiceSessionChoice.Realtime).engine
        engine.start(NoChat)
        testScheduler.runCurrent()
        assertTrue(engine.active.value)
        assertEquals(RealtimeTransportKind.OpenAiRealtime, r.made.single().first)
        assertEquals("gpt-realtime", r.made.single().second.model)
        r.scope.cancel()
    }
}
