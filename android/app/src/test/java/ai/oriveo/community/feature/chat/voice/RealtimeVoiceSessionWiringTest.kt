package ai.oriveo.community.feature.chat.voice

import ai.oriveo.community.feature.chat.realtimeVoiceTarget
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
import ai.oriveo.community.core.model.Skill
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.streaming.ChatStreamingManager
import ai.oriveo.community.core.voice.VoiceCatalog
import ai.oriveo.community.core.voice.VoiceDirection
import ai.oriveo.community.core.voice.VoiceEngineSelection
import ai.oriveo.community.core.voice.VoiceEngineSettings
import ai.oriveo.community.core.voice.VoiceFallbackReason
import ai.oriveo.community.core.voice.VoiceOption
import ai.oriveo.community.core.voice.VoiceProviderCatalog
import ai.oriveo.community.core.voice.VoiceRealtimeEntry
import ai.oriveo.community.core.voice.VoiceTransport
import ai.oriveo.community.core.voice.conversation.ConversationStatusKey
import ai.oriveo.community.core.voice.conversation.EarconKind
import ai.oriveo.community.core.voice.conversation.EndReason
import ai.oriveo.community.core.voice.conversation.VoiceConversationChatPort
import ai.oriveo.community.core.voice.conversation.VoiceConversationEngine
import ai.oriveo.community.core.voice.conversation.VoiceConversationEvent
import ai.oriveo.community.core.voice.conversation.VoiceReplyEvent
import ai.oriveo.community.core.voice.realtime.RealtimeAudioIO
import ai.oriveo.community.core.voice.realtime.RealtimeSessionEvent
import ai.oriveo.community.core.voice.realtime.RealtimeTransportKind
import ai.oriveo.community.core.voice.realtime.RealtimeTurnStatus
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveSessionExpiredException
import ai.oriveo.community.core.voice.realtime.wire.RealtimeEndpoint
import ai.oriveo.community.core.voice.realtime.wire.RealtimeSessionTransport
import ai.oriveo.community.core.model.SkillKnowledgeBase
import ai.oriveo.community.core.model.SkillKnowledgeBaseFile
import ai.oriveo.community.core.model.SkillKnowledgeFile
import ai.oriveo.community.core.model.SkillKnowledgeFileStatus
import ai.oriveo.community.core.model.SkillKnowledgeIngestionMode
import ai.oriveo.community.feature.chat.ChatSendCoordinator
import ai.oriveo.community.feature.chat.DraftChatViewModelFixture
import ai.oriveo.community.testing.TestSharedPreferences
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
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Realtime sessions opened by the chat page / home ≋ according to the conversation engine: real builder + real sink + fake connection / audio. */
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

        override fun truncate(itemId: String?, contentIndex: Int, playedMs: Double) = Unit

        override fun close() {
            closes++
            events.close()
        }
    }

    private class FakeAudio : RealtimeAudioIO {
        var onFrame: ((ByteArray) -> Unit)? = null

        override fun start(onFrame: (ByteArray) -> Unit, onInterruption: () -> Unit) {
            this.onFrame = onFrame
        }
        override fun enqueue(pcm16: ByteArray, itemId: String) = Unit
        override fun playedMs(itemId: String): Long = 0L
        override val isPlaying: Boolean get() = false
        override fun stopPlayback() = Unit
        override fun stop() = Unit
        override suspend fun playEarcon(kind: EarconKind) = Unit
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

    /** [replanInline] = the turn-boundary replan runs on the test scheduler (IO in production), so the result is back in the same turn. */
    private class Rig(
        val test: TestScope,
        catalogEntry: VoiceRealtimeEntry,
        val provider: Provider,
        replanInline: Boolean = false,
    ) {
        val prefs = TestSharedPreferences()
        val settings = VoiceEngineSettings { prefs }
        val connection = FakeConnection(RealtimeTransportKind.fromRawValue(catalogEntry.transport.rawValue)!!)

        /** In connection order: one for the first open, another for every reopen. */
        val connections = mutableListOf(connection)
        val made = mutableListOf<Pair<RealtimeTransportKind, RealtimeEndpoint>>()
        val added = mutableListOf<ChatMessage>()
        val addedTo = mutableListOf<String>()
        val sessions = VoiceConversationSessions()
        val created = mutableListOf<String>()
        val navigated = mutableListOf<String>()
        /** Whether each navigate ran on the Main dispatcher (the production HandoffPort switches to Dispatchers.Main.immediate). */
        val navigatedOnMain = mutableListOf<Boolean>()
        private var onMain = false
        val updated = mutableListOf<ChatMessage>()
        val events = mutableListOf<VoiceConversationEvent>()
        val sinks = mutableListOf<RepositoryRealtimeTranscriptSink>()
        val audios = mutableListOf<FakeAudio>()
        val planned = mutableListOf<Conversation>()
        /** The (connection, model) written as last used. */
        val remembered = mutableListOf<Pair<String, String>>()
        var catalogCalls = 0
        /** The chat connection the conversation lives on (besides the realtime connection). */
        var chatProviders: List<Provider> = emptyList()
        var instructions = ""
        var edit: (Conversation) -> Conversation = { it }
        var contextRequest: suspend (Conversation) -> ChatContextRequest = { c ->
            planned += c
            ChatContextRequest(ContextConversation(id = c.id, useMemory = false, instructions = c.instructions))
        }
        // Attached under backgroundScope: on a failed assertion it is cancelled with the test, so the test reports red instead of hanging.
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
                    // Fake repository: persisted transcripts are read back with the conversation.
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
            rememberLastUsed = { providerId, modelId -> remembered += providerId to modelId },
            replanContext = if (replanInline) UnconfinedTestDispatcher(test.testScheduler) else kotlinx.coroutines.Dispatchers.IO,
        )

        suspend fun realtime(): RealtimeVoiceConversationEngine {
            settings.disclosure.markAccepted(provider.kind, VoiceDirection.Realtime)
            val choice = builder.prepare("c1", contextRequest)
            val engine = (choice as RealtimeVoiceSessionChoice.Realtime).engine
            scope.launch { engine.events.collect { events += it } }
            engine.start(NoChat)
            test.testScheduler.runCurrent()
            return engine
        }

        /** Home wiring like rememberVoiceConversationHost: the builder gets the handoff port to create the conversation, and beginHome gets the pill model to create it. */
        suspend fun home(
            owner: Any,
            newConversation: (suspend () -> Conversation?)? = null,
        ): RealtimeVoiceConversationEngine {
            settings.disclosure.markAccepted(provider.kind, VoiceDirection.Realtime)
            // Main = a marked test scheduler: onMain is true while the code the sink write loop switched in is running.
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
            val choice = builder.prepare(null, contextRequest, newConversation) { port?.conversationId() }
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
    fun realtime_selection_starts_realtime() = runTest {
        val r = Rig(this, entry, provider)
        r.settings.setSelection(VoiceDirection.Realtime, cloud)
        val engine = r.realtime()

        assertEquals(1, r.made.size)
        val (kind, endpoint) = r.made.single()
        assertEquals(RealtimeTransportKind.OpenAiRealtime, kind)
        assertEquals("api.openai.com", endpoint.host)
        assertEquals("sk-live", endpoint.apiKey)
        assertEquals("gpt-realtime", endpoint.model)
        assertEquals("/v1/realtime", endpoint.path)
        assertEquals("cedar", endpoint.voice)
        assertEquals("gpt-4o-transcribe", endpoint.inputTranscriptionModel)
        assertEquals(1, r.connection.opened)
        assertTrue(engine.active.value)
        assertTrue(r.builder.realtimeActive)
        // Starting a realtime voice call counts as a send: the conversation's connection and chat model are written as last used (not the voice model).
        assertEquals(listOf(provider.id to "gpt-5"), r.remembered)
        r.scope.cancel()
    }

    @Test
    fun realtime_error_shows_toast_once() = runTest {
        val r = Rig(this, entry, provider)
        r.settings.setSelection(VoiceDirection.Realtime, cloud)
        val engine = r.realtime()
        r.send(RealtimeSessionEvent.Ready)
        r.connection.events.close(IllegalStateException("boom"))
        testScheduler.runCurrent()
        engine.end(EndReason.USER)
        testScheduler.runCurrent()

        val toasts = r.events.filterIsInstance<VoiceConversationEvent.Ended>().mapNotNull { realtimeEndedToast(engine, it) }
        assertEquals(listOf(R.string.voice_conversation_status_error), toasts)
        // The cascade shows no toast: its error is presented by the failed-message card; a realtime session that ends without an error shows none either.
        assertNull(realtimeEndedToast(mockk<VoiceConversationEngine>(), VoiceConversationEvent.Ended(EndReason.ERROR, "x")))
        assertNull(realtimeEndedToast(engine, VoiceConversationEvent.Ended(EndReason.USER, null)))
        r.scope.cancel()
    }

    @Test
    fun status_announcement_pauses_realtime_uplink() = runTest {
        val r = Rig(this, entry, provider)
        r.settings.setSelection(VoiceDirection.Realtime, cloud)
        val engine = r.realtime()
        r.send(RealtimeSessionEvent.Ready)
        val frame = ByteArray(480) { 0x40 }
        val audio = r.audios.single()
        audio.onFrame!!(frame)
        assertEquals(1, r.connection.sent)

        // Wiring like rememberVoiceConversationHost: the announcer's onSpeaking is forwarded to the engine.
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
    fun realtime_call_on_unsendable_chat_model_does_not_write_last_used() = runTest {
        // When the conversation's chat model can't be sent on (relay model removed / connection deleted), starting the call does not write last used; the call opens as usual.
        val relay = Provider(id = "conn-relay", kind = ProviderKind.Relay, apiKey = "sk-relay", models = listOf(AIModel(id = "kept", name = "Kept")))
        val removed = Conversation(id = "", title = "", providerID = "conn-relay", providerKind = ProviderKind.Relay, modelID = "gone")
        suspend fun remembered(chat: Conversation): List<Pair<String, String>> {
            val r = Rig(this, entry, provider)
            r.settings.setSelection(VoiceDirection.Realtime, cloud)
            r.chatProviders = listOf(relay)
            val engine = r.home(Any()) { chat }
            assertTrue("the call opens as usual", engine.active.value)
            return r.remembered.toList().also { r.scope.cancel() }
        }

        assertEquals(emptyList<Pair<String, String>>(), remembered(removed))
        assertEquals(emptyList<Pair<String, String>>(), remembered(removed.copy(providerID = "conn-deleted", providerKind = ProviderKind.Anthropic)))
        assertEquals(listOf("conn-relay" to "kept"), remembered(removed.copy(modelID = "kept")))
    }

    @Test
    fun system_selection_keeps_cascade() = runTest {
        val r = Rig(this, entry, provider)
        val choice = r.builder.prepare("c1", r.contextRequest)
        assertEquals(RealtimeVoiceSessionChoice.Cascade(), choice)
        assertTrue(r.made.isEmpty())
        assertTrue("last used is not written when no realtime call was opened", r.remembered.isEmpty())
        assertFalse(r.builder.realtimeActive)
        r.scope.cancel()
    }

    @Test
    fun fallback_consumes_use_notice_and_uses_cascade() = runTest {
        val r = Rig(this, entry, provider)
        r.settings.setSelection(VoiceDirection.Realtime, cloud.copy(connectionId = "gone"))
        r.settings.disclosure.markAccepted(ProviderKind.OpenAI, VoiceDirection.Realtime)
        val first = r.builder.prepare("c1", r.contextRequest)
        assertEquals(RealtimeVoiceSessionChoice.Cascade(fallback = VoiceFallbackReason.ConnectionMissing), first)
        assertEquals(VoiceEngineSelection.System, r.settings.selection(VoiceDirection.Realtime))
        // Consumed only once here: entering again carries no fallback reason.
        assertEquals(RealtimeVoiceSessionChoice.Cascade(), r.builder.prepare("c1", r.contextRequest))
        assertTrue(r.made.isEmpty())
        r.scope.cancel()
    }

    @Test
    fun plan_rejected_toasts_and_uses_cascade() = runTest {
        val r = Rig(this, entry.copy(contextWindow = 2_000), provider)
        r.settings.setSelection(VoiceDirection.Realtime, cloud)
        r.settings.disclosure.markAccepted(ProviderKind.OpenAI, VoiceDirection.Realtime)
        r.instructions = "word ".repeat(20_000)
        val choice = r.builder.prepare("c1", r.contextRequest)
        assertEquals(RealtimeVoiceSessionChoice.Cascade(planRejected = true), choice)
        assertEquals(R.string.voice_conversation_start_failed_toast, (choice as RealtimeVoiceSessionChoice.Cascade).toast)
        assertTrue(r.made.isEmpty())
        r.scope.cancel()
    }

    @Test
    fun assistant_attributed_to_realtime_model() = runTest {
        val r = Rig(this, entry, provider)
        r.settings.setSelection(VoiceDirection.Realtime, cloud)
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

    @Test
    fun background_closes_realtime() = runTest {
        val r = Rig(this, entry, provider)
        r.settings.setSelection(VoiceDirection.Realtime, cloud)
        val engine = r.realtime()
        r.send(RealtimeSessionEvent.Ready)
        engine.systemInterruption()
        testScheduler.runCurrent()
        assertEquals(1, r.connection.closes)
        assertFalse(engine.active.value)
        assertFalse(r.builder.realtimeActive)
        assertEquals(VoiceConversationEvent.Ended(EndReason.SYSTEM, null), r.events.last())
        r.scope.cancel()
    }

    @Test
    fun home_realtime_creates_conversation_on_first_persist() = runTest {
        val r = Rig(this, entry, provider)
        r.settings.setSelection(VoiceDirection.Realtime, cloud)
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
        // While navigating the home page is still the owner and the handoff is not complete: the home host leaving does not end the session.
        assertTrue(r.sessions.ownedBy(home))
        assertTrue(r.sessions.handingOff)
        r.scope.cancel()
    }

    @Test
    fun home_realtime_no_persist_leaves_no_conversation() = runTest {
        val r = Rig(this, entry, provider)
        r.settings.setSelection(VoiceDirection.Realtime, cloud)
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
        r.settings.setSelection(VoiceDirection.Realtime, cloud)
        val engine = r.home(Any())
        r.send(RealtimeSessionEvent.Ready)
        r.turn("first", "one")

        val chatPage = Any()
        assertTrue(r.sessions.attach("new-1", chatPage) { NoChat })
        assertTrue(r.sessions.ownedBy(chatPage))
        assertFalse(r.sessions.handingOff)
        // The chat page takes over the same realtime engine instance; the connection stays up.
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
        r.settings.setSelection(VoiceDirection.Realtime, cloud)
        val skill = Skill(id = "skill-1", name = "Tutor", systemPrompt = "SKILL-PROMPT-tutor")
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
            skillProvider = { id -> skill.takeIf { it.id == id } },
            pinnedNotesResolver = { listOf(note) },
            pendingPinnedNoteIds = { emptyList() },
            generationParameterSettingsStore = GenerationParameterSettingsStore(readPayload = { null }, writePayload = {}),
            reminderEnabled = { true },
        )
        r.edit = { it.copy(useMemory = true, skillId = skill.id, pinnedNoteIds = listOf(note.id)) }
        // Chat page wiring: sendCoordinator::realtimeSessionContext + this page's memory list.
        r.contextRequest = { c -> coordinator.realtimeSessionContext(c, listOf(memory)) }
        r.realtime()

        val sent = r.connection.inputs.single().instructions
        assertTrue(sent.contains("SKILL-PROMPT-tutor"))
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
    fun fallback_shows_engine_fallback_toast() = runTest {
        val r = Rig(this, entry, provider)
        r.settings.setSelection(VoiceDirection.Realtime, cloud.copy(connectionId = "gone"))
        r.settings.disclosure.markAccepted(ProviderKind.OpenAI, VoiceDirection.Realtime)
        val choice = r.builder.prepare("c1", r.contextRequest) as RealtimeVoiceSessionChoice.Cascade
        assertEquals(VoiceFallbackReason.ConnectionMissing, choice.fallback)
        assertEquals(R.string.voice_realtime_engine_fallback_toast, choice.toast)
        // The fallback is announced only once: entering again shows no toast.
        assertNull((r.builder.prepare("c1", r.contextRequest) as RealtimeVoiceSessionChoice.Cascade).toast)
        r.scope.cancel()
    }

    /** Chat page draft (no conversation row yet): the first persist goes through the chat page's own create-conversation callback, and no message is lost. */
    @Test
    fun chat_without_conversation_creates_on_first_persist() = runTest {
        // The replan runs on the test scheduler: the turn-boundary replan after the first persist is production behavior (realtime-session.v1), and its result is visible in the same turn
        val r = Rig(this, entry, provider, replanInline = true)
        r.settings.setSelection(VoiceDirection.Realtime, cloud)
        r.settings.disclosure.markAccepted(ProviderKind.OpenAI, VoiceDirection.Realtime)
        val draft = Conversation(id = "", title = "", providerID = provider.id, providerKind = provider.kind, modelID = "gpt-5")
        val choice = r.builder.prepare(null, r.contextRequest, { draft }) {
            "chat-new".also { r.created += it }
        }
        val engine = (choice as RealtimeVoiceSessionChoice.Realtime).engine
        engine.start(NoChat)
        testScheduler.runCurrent()
        r.send(RealtimeSessionEvent.Ready)
        assertTrue(r.created.isEmpty())

        r.turn("hello there", "hi")
        assertEquals(listOf("chat-new"), r.created)
        assertEquals(listOf("chat-new", "chat-new"), r.addedTo)
        assertEquals(listOf("hello there", "hi"), r.added.map { it.text })
        // One plan at open + one at the first-turn boundary replan, both for the same model
        assertEquals(listOf("gpt-5", "gpt-5"), r.planned.map { it.modelID })
        r.scope.cancel()
    }

    @Test
    fun sink_closed_after_end() = runTest {
        val r = Rig(this, entry, provider)
        r.settings.setSelection(VoiceDirection.Realtime, cloud)
        val engine = r.realtime()
        r.send(RealtimeSessionEvent.Ready)
        r.turn("first", "one")
        assertFalse(r.sinks.single().closed)
        engine.end(EndReason.USER)
        testScheduler.runCurrent()
        assertTrue(r.sinks.single().closed)
        // Writes already queued are still persisted; after close no new writes are accepted.
        assertEquals(listOf("first", "one"), r.added.map { it.text })
        r.scope.cancel()
    }

    @Test
    fun sink_closed_when_prepare_fails() = runTest {
        val r = Rig(this, entry, provider)
        r.settings.setSelection(VoiceDirection.Realtime, cloud)
        r.settings.disclosure.markAccepted(ProviderKind.OpenAI, VoiceDirection.Realtime)
        val engine = (r.builder.prepare("c1", r.contextRequest) as RealtimeVoiceSessionChoice.Realtime).engine
        // Entry failed after prepare (the foreground service / session start was never reached): the engine never started, and discarding it closes the sink.
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
        r.settings.setSelection(VoiceDirection.Realtime, stored)
        val choice = r.builder.prepare("c1", r.contextRequest)
        // Disclosure not accepted: no resolve, no settings rewrite, no toast; this time uses the cascade.
        assertEquals(RealtimeVoiceSessionChoice.Cascade(), choice)
        assertNull((choice as RealtimeVoiceSessionChoice.Cascade).toast)
        assertEquals(stored, r.settings.selection(VoiceDirection.Realtime))
        assertEquals(0, r.catalogCalls)
        assertTrue(r.made.isEmpty())
        r.scope.cancel()
    }

    @Test
    fun navigation_end_writes_draft() = runTest {
        val r = Rig(this, entry, provider)
        r.settings.setSelection(VoiceDirection.Realtime, cloud)
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
        r.settings.setSelection(VoiceDirection.Realtime, cloud)
        r.settings.disclosure.markAccepted(ProviderKind.OpenAI, VoiceDirection.Realtime)
        val draft = Conversation(id = "", title = "", providerID = provider.id, providerKind = provider.kind, modelID = "gpt-5")
        // The draft chat page did not wire a create-conversation callback: realtime messages have nowhere to be persisted, so this time uses the cascade instead of opening a realtime session that would lose messages.
        val target = VoiceConversationTarget.Chat(
            conversationId = null,
            context = r.contextRequest,
            newConversation = { draft },
        ) { NoChat }
        val choice = prepareRealtimeVoiceSession(r.builder, target, r.contextRequest) { null }
        assertEquals(RealtimeVoiceSessionChoice.Cascade(), choice)
        assertTrue(r.made.isEmpty())
        assertFalse(r.builder.realtimeActive)
        // With the callback wired, realtime works as usual.
        val withCreate = VoiceConversationTarget.Chat(
            conversationId = null,
            context = r.contextRequest,
            createConversation = { "chat-new" },
            newConversation = { draft },
        ) { NoChat }
        val realtime = prepareRealtimeVoiceSession(r.builder, withCreate, r.contextRequest) { null }
        assertTrue(realtime is RealtimeVoiceSessionChoice.Realtime)
        (realtime as RealtimeVoiceSessionChoice.Realtime).engine.discard()
        r.scope.cancel()
    }

    @Test
    fun home_plan_uses_first_send_conversation() = runTest {
        val r = Rig(this, entry, provider)
        r.settings.setSelection(VoiceDirection.Realtime, cloud)
        // The conversation object a home first send creates: the home pill model + pending instructions, not the realtime connection / model.
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
        // Starting a realtime call from home also writes last used: the pill's connection and model.
        assertEquals(listOf("conn-home" to "claude-home"), r.remembered)
        assertTrue(r.connection.inputs.single().instructions.contains("HOME-PENDING-INSTRUCTIONS"))
        // Attribution is still the realtime model.
        r.send(RealtimeSessionEvent.Ready)
        r.turn("hello", "hi")
        assertEquals("gpt-realtime", r.updated.single().modelID)
        r.scope.cancel()
    }

    /** A sent message written into [conversationId] from outside the session (by another client / the chat page). */
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
        r.settings.setSelection(VoiceDirection.Realtime, cloud)
        r.realtime()
        r.send(RealtimeSessionEvent.Ready)
        r.turn("first question", "first answer")
        r.turn("second question", "second answer")

        // One plan at open + one per turn boundary, all for c1 itself.
        assertEquals(listOf("c1", "c1", "c1"), r.planned.map { it.id })
        assertEquals(4, r.planned.last().messages.size)
        // The session's own transcripts do not enter the replan history: the fingerprint is unchanged and there is no reopen.
        assertEquals(1, r.made.size)
        assertEquals(0, r.connection.closes)
        assertTrue(r.connection.inputs.single().history.isEmpty())
        r.scope.cancel()
    }

    @Test
    fun external_message_changes_fingerprint_and_reopens() = runTest {
        val r = Rig(this, entry, provider, replanInline = true)
        r.settings.setSelection(VoiceDirection.Realtime, cloud)
        r.realtime()
        r.send(RealtimeSessionEvent.Ready)
        r.turn("first question", "first answer")
        assertEquals(1, r.made.size)

        // During the call a turn not written by this session appears in the conversation: the next turn boundary's lastHistoryId changes, so it reopens.
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
    fun skill_with_vector_store_two_turns_no_reopen_no_retrieval() = runTest {
        val r = Rig(this, entry, provider, replanInline = true)
        r.settings.setSelection(VoiceDirection.Realtime, cloud)
        val skill = Skill(
            id = "skill-kb",
            name = "Librarian",
            systemPrompt = "SKILL-PROMPT-librarian",
            knowledgeFiles = listOf(
                SkillKnowledgeFile(id = "kf-1", name = "guide.md", content = "SKILL-FILE-guide", charCount = 16),
            ),
            knowledgeBase = SkillKnowledgeBase(
                provider = "openai",
                retrievalModel = "gpt-4.1-mini",
                vectorStoreId = "vs_123",
                expiresAfterDays = 30,
                files = listOf(
                    SkillKnowledgeBaseFile(
                        id = "kb-1",
                        name = "manual.pdf",
                        mimeType = "application/pdf",
                        sizeBytes = 1024,
                        ingestionMode = SkillKnowledgeIngestionMode.NATIVE_FILE,
                        status = SkillKnowledgeFileStatus.READY,
                    ),
                ),
            ),
        )
        val coordinator = ChatSendCoordinator(
            chatStreamingManager = mockk<ChatStreamingManager>(relaxed = true),
            applicationScope = r.scope,
            skillProvider = { id -> skill.takeIf { it.id == id } },
            pinnedNotesResolver = { emptyList() },
            pendingPinnedNoteIds = { emptyList() },
            generationParameterSettingsStore = GenerationParameterSettingsStore(readPayload = { null }, writePayload = {}),
            reminderEnabled = { true },
        )
        r.edit = { it.copy(skillId = skill.id) }
        var planned = 0
        r.contextRequest = { c ->
            planned++
            coordinator.realtimeSessionContext(c, emptyList())
        }
        r.realtime()
        r.send(RealtimeSessionEvent.Ready)
        r.turn("what does the manual say", "it says hello")
        r.turn("and chapter two", "it says goodbye")

        // Planned at open and at both turn boundaries, with no knowledge retrieval run at all; knowledge holds only the knowledge files attached by the skill.
        assertEquals(3, planned)
        val sent = r.connection.inputs.single().instructions
        assertTrue(sent.contains("SKILL-PROMPT-librarian"))
        assertTrue(sent.contains("SKILL-FILE-guide"))
        assertEquals(1, r.made.size)
        assertEquals(0, r.connection.closes)
        r.scope.cancel()
    }

    @Test
    fun home_entry_first_turn_replan_keeps_fingerprint() = runTest {
        val r = Rig(this, entry, provider, replanInline = true)
        r.settings.setSelection(VoiceDirection.Realtime, cloud)
        val memory = MemoryItem(
            id = "memory-home",
            kind = MemoryKind.FACT,
            content = "MEMORY-home-likes-tea",
            mutationId = "mutation-home",
            deviceId = "device-1",
        )
        // Home wiring: the open uses the pending conversation (empty id, defaults), and the replan uses the real conversation created by the first persist.
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
        // The home entry has no pinned notes pending from compose: neither the open nor the replan carries notes.
        assertTrue(r.planned.all { it.pinnedNoteIds.isEmpty() })
        assertTrue(r.planned.all { newConversationContextRequest(it, listOf(memory)).conversation.pinnedNotes.isEmpty() })
        // After the first persist creates the conversation the fingerprint is unchanged: no reopen.
        assertEquals(1, r.made.size)
        assertEquals(0, r.connection.closes)
        assertEquals(listOf("new-1"), r.created)
        r.scope.cancel()
    }

    /**
     * Chat page draft entry (Chat target, conversationId = null) using the target produced by ChatViewModel.realtimeVoiceTarget (the same function the host uses):
     * the real ChatNoteCoordinator's compose-time pending pinned notes join the open through realtimeSessionContext; the first persist goes through the real
     * createFirstConversation → onConversationActivated → flushPendingPinnedNotes into pinnedNoteIds (pending kept, merged and deduplicated),
     * the replan is still the same note, and the fingerprint is unchanged so there is no reopen.
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
        // The real ChatViewModel's viewModelScope is on Main: it follows the test scheduler and is reset in @After (VM coroutines still need scheduling when runTest wraps up).
        Dispatchers.setMain(UnconfinedTestDispatcher(testScheduler))
        val r = Rig(this, entry, provider, replanInline = true)
        r.settings.setSelection(VoiceDirection.Realtime, cloud)
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
        // Fake repository: ids persisted by pinNoteToConversation are read back with the conversation.
        r.edit = { it.copy(pinnedNoteIds = fixture.pinned.toList()) }
        val vmTarget = viewModel.realtimeVoiceTarget(null)
        // Only records which conversation was planned around the VM target's context; context / create / pending conversation / port are the VM's original values.
        val context: suspend (Conversation) -> ChatContextRequest = { c ->
            r.planned += c
            vmTarget.context(c)
        }
        val target = VoiceConversationTarget.Chat(
            conversationId = vmTarget.conversationId,
            context = context,
            createConversation = vmTarget.createConversation,
            newConversation = vmTarget.newConversation,
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

    /** Muted, a 1008 expiry → does not end → unmuting reopens, and the new connection's plan history carries the transcripts already persisted by this call. */
    private suspend fun TestScope.expireMutedAndReopen(home: Boolean) {
        val r = Rig(this, geminiEntry, geminiProvider)
        r.settings.setSelection(
            VoiceDirection.Realtime,
            VoiceEngineSelection.Cloud(ProviderKind.Gemini, geminiProvider.id, geminiEntry.model, null),
        )
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
        // Does not rebuild the sink or resolve the selection again (no toast, no settings change)
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
}
