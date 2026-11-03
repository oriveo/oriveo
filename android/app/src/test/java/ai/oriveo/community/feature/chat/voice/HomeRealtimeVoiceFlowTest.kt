package ai.oriveo.community.feature.chat.voice

import android.os.Looper
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.navigation.NavHostController
import androidx.navigation.compose.ComposeNavigator
import androidx.navigation.compose.composable
import androidx.navigation.NavDestination.Companion.hasRoute
import androidx.navigation.createGraph
import androidx.navigation.toRoute
import androidx.room.Room
import ai.oriveo.community.core.context.ChatContextRequest
import ai.oriveo.community.core.context.ContextConversation
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.LastUsedModelRef
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.navigation.AppRoute
import ai.oriveo.community.core.navigation.returnHomeAfterDeleting
import ai.oriveo.community.core.voice.VoiceCatalog
import ai.oriveo.community.core.voice.VoiceDirection
import ai.oriveo.community.core.voice.VoiceEngineSelection
import ai.oriveo.community.core.voice.VoiceEngineSettings
import ai.oriveo.community.core.voice.VoiceOption
import ai.oriveo.community.core.voice.VoiceProviderCatalog
import ai.oriveo.community.core.voice.VoiceRealtimeEntry
import ai.oriveo.community.core.voice.VoiceTransport
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.voice.conversation.ConversationRoute
import ai.oriveo.community.core.voice.conversation.ConversationStatusKey
import ai.oriveo.community.core.voice.conversation.VoiceConversationChatPort
import ai.oriveo.community.core.voice.conversation.VoiceConversationController
import ai.oriveo.community.core.voice.conversation.VoiceConversationEvent
import ai.oriveo.community.core.voice.conversation.VoiceReplyEvent
import ai.oriveo.community.core.voice.conversation.EarconKind
import ai.oriveo.community.core.voice.conversation.EndReason
import ai.oriveo.community.core.voice.realtime.RealtimeAudioIO
import ai.oriveo.community.core.voice.realtime.RealtimeModel
import ai.oriveo.community.core.voice.realtime.RealtimePCM
import ai.oriveo.community.core.voice.realtime.RealtimeSessionEvent
import ai.oriveo.community.core.voice.realtime.RealtimeTransportKind
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveClosedException
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveEventMapper
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveSessionExpiredException
import ai.oriveo.community.core.voice.realtime.wire.RealtimeSessionTransport
import ai.oriveo.community.core.data.repository.RealtimeTransportInput
import ai.oriveo.community.testing.TestSharedPreferences
import java.io.File
import java.util.Base64
import java.util.Collections
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.consumeAsFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.job
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.shadows.ShadowLog

/**
 * Full home ≋ realtime conversation path: Gemini wire messages → production mapper → real builder / controller reducer → real sink
 * (write loop on the real Dispatchers.IO) → in-memory Room; navigation goes through a real NavController. The conversation creation and navigation triggered by the first persist must run on the main thread,
 * and the first user transcript is the conversation's first user message.
 */
@RunWith(RobolectricTestRunner::class)
@OptIn(ExperimentalCoroutinesApi::class)
class HomeRealtimeVoiceFlowTest {

    private class FakeConnection : RealtimeSessionTransport {
        override val kind: RealtimeTransportKind = RealtimeTransportKind.GeminiLive
        val events = Channel<RealtimeSessionEvent>(Channel.UNLIMITED)

        override fun openRealtimeSession(transport: RealtimeTransportInput): Flow<RealtimeSessionEvent> =
            events.consumeAsFlow()

        override fun sendAudio(pcm: ByteArray) = Unit
        override fun truncate(itemId: String?, contentIndex: Int, playedMs: Double) = Unit
        override fun close() {
            events.close()
        }
    }


    private class TestLifecycle : LifecycleOwner {
        val registry = LifecycleRegistry(this)
        override val lifecycle: Lifecycle get() = registry
    }

    private val entry = VoiceRealtimeEntry(
        model = "gemini-live-2.5-flash",
        transport = VoiceTransport.GeminiLive,
        path = "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent",
        contextWindow = 128_000,
        voices = listOf(VoiceOption("Puck", isDefault = true)),
        isDefault = true,
    )
    private val provider = Provider(
        id = "conn-gemini",
        kind = ProviderKind.Gemini,
        apiKey = "AIza-test",
        baseUrlText = "https://generativelanguage.googleapis.com/v1beta",
    )

    private lateinit var db: OriveoDatabase
    private lateinit var repository: ConversationRepository
    private lateinit var nav: NavHostController
    private val extraDbs = mutableListOf<OriveoDatabase>()
    private val lifecycle = TestLifecycle()
    // The production sink write loop is attached to applicationScope (not the main thread): a real IO thread is used here.
    private val sinkScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @Before
    fun setUp() {
        // Main uses the test scheduler (under Robolectric that is the main thread = the test thread): continuations that hop from IO to Main run on the test thread via runTest.
        Dispatchers.setMain(StandardTestDispatcher())
        db = Room.inMemoryDatabaseBuilder(RuntimeEnvironment.getApplication(), OriveoDatabase::class.java)
            .allowMainThreadQueries()
            // Creating the conversation on the main thread completes in place: it does not wait for the Room thread in real time, so virtual time does not jump to the idle timeout while waiting.
            .setQueryExecutor { it.run() }
            .setTransactionExecutor { it.run() }
            .build()
        repository = repositoryOf(db)
        lifecycle.registry.currentState = Lifecycle.State.RESUMED
        nav = NavHostController(RuntimeEnvironment.getApplication()).apply {
            navigatorProvider.addNavigator(ComposeNavigator())
            setLifecycleOwner(lifecycle)
            graph = createGraph(startDestination = AppRoute.Home) {
                composable<AppRoute.Home> {}
                composable<AppRoute.Chat> {}
            }
        }
    }

    @After
    fun tearDown() {
        sinkScope.cancel()
        db.close()
        extraDbs.forEach { it.close() }
        Dispatchers.resetMain()
    }

    private fun repositoryOf(database: OriveoDatabase): ConversationRepository {
        return ConversationRepository(
            conversationDao = database.conversationDao(),
            messageDao = database.messageDao(),
        )
    }

    private fun conversationCount(database: OriveoDatabase): Int =
        database.openHelper.readableDatabase.query("SELECT COUNT(*) FROM conversations").use { it.moveToFirst(); it.getInt(0) }

    private fun onHome(): Boolean = nav.currentBackStackEntry!!.destination.hasRoute<AppRoute.Home>()

    private object NoChat : VoiceConversationChatPort {
        override suspend fun send(text: String): Boolean = false
        override val replies: Flow<VoiceReplyEvent> = emptyFlow()
        override fun cancel() = Unit
    }

    /**
     * Home wiring as in rememberVoiceConversationHost: through the production prepareRealtimeVoiceSession and VoiceConversationTarget,
     * with a real repository and real navigation. [homeCreate] null = HomeViewModel.createVoiceConversation (creates a real conversation with the pill model).
     */
    private inner class HomeFlow(
        val test: TestScope,
        val repo: ConversationRepository = repository,
        val homeCreate: (suspend () -> String?)? = null,
    ) {
        val settings = VoiceEngineSettings { TestSharedPreferences() }
        val connection = FakeConnection()
        val sessions = VoiceConversationSessions()
        val home = Any()
        val sinks = mutableListOf<RepositoryRealtimeTranscriptSink>()
        val created = mutableListOf<String>()

        /** Each navigate: (whether on the main thread, conversation id). */
        val navigated = mutableListOf<Pair<Boolean, String>>()
        val navigatedOnce = CompletableDeferred<Unit>()

        /** The state the home voice bar published at the moment of navigation. */
        var statusAtNavigate: ConversationStatusKey? = null
        lateinit var engine: RealtimeVoiceConversationEngine
        lateinit var handoff: VoiceConversationSessions.HandoffPort

        /** Every state and event the engine published. */
        val statuses = mutableListOf<ConversationStatusKey?>()
        val events = mutableListOf<VoiceConversationEvent>()
        private val mapper = GeminiLiveEventMapper()
        val scope = CoroutineScope(UnconfinedTestDispatcher(test.testScheduler) + Job(test.backgroundScope.coroutineContext.job))
        val builder = RealtimeVoiceSessionBuilder(
            settings = settings,
            catalog = { VoiceCatalog(providers = mapOf(provider.kind to VoiceProviderCatalog(realtime = listOf(entry)))) },
            providers = { listOf(provider) },
            conversation = { id -> repo.getWithMessages(id) },
            sinkFor = { conversationId, createHomeConversation, attribution ->
                RepositoryRealtimeTranscriptSink(repo, conversationId, attribution, sinkScope, createHomeConversation)
                    .also { sinks += it }
            },
            transport = { _, _ -> connection },
            audio = { IdealRealtimeAudio() },
            scope = scope,
            clock = { test.testScheduler.currentTime },
            replanContext = UnconfinedTestDispatcher(test.testScheduler),
        )

        /** Home pill has the realtime model selected: same as HomeViewModel.realtimeVoiceSelection, consent already given; does not write engine settings. */
        private fun select(): VoiceEngineSelection.Cloud {
            settings.disclosure.markAccepted(provider.kind, VoiceDirection.Realtime)
            return VoiceEngineSelection.Cloud(ProviderKind.Gemini, provider.id, entry.model)
        }

        private fun observe() {
            val collect = UnconfinedTestDispatcher(test.testScheduler)
            test.backgroundScope.launch(collect) { engine.statusKey.collect { statuses += it } }
            test.backgroundScope.launch(collect) { engine.events.collect { events += it } }
        }

        private val context: suspend (Conversation) -> ChatContextRequest = { c ->
            ChatContextRequest(ContextConversation(id = c.id, useMemory = false, instructions = c.instructions))
        }

        suspend fun start(): RealtimeVoiceConversationEngine {
            val selection = select()
            var port: VoiceConversationSessions.HandoffPort? = null
            val target = VoiceConversationTarget.Home(
                createConversation = homeCreate ?: {
                    repo.create(providerID = provider.id, providerKind = provider.kind, modelID = "gemini-2.5-flash")
                        .id.also { created += it }
                },
                // OriveoNavHost's onNavigateToChat.
                navigate = { id ->
                    navigated += (Looper.myLooper() == Looper.getMainLooper()) to id
                    statusAtNavigate = engine.statusKey.value
                    nav.navigate(AppRoute.Chat(conversationId = id))
                    navigatedOnce.complete(Unit)
                },
                // OriveoNavHost's onReturnHome: only returns home when the current page is the deleted conversation.
                returnHome = { id -> nav.returnHomeAfterDeleting(id) },
                realtimeSelection = selection,
            )
            val choice = prepareRealtimeVoiceSession(builder, target, context) { port?.conversationId() }
            engine = (choice as RealtimeVoiceSessionChoice.Realtime).engine
            observe()
            // Same as startConversation (home branch) in rememberVoiceConversationHost.
            val handoff = sessions.beginHome(home, target.createConversation, target.navigate)
            port = handoff
            this.handoff = handoff
            engine.start(handoff)
            test.testScheduler.runCurrent()
            return engine
        }

        /** Chat page draft entry: the conversation row is created by the page's own [create]. */
        suspend fun startChatDraft(create: suspend () -> String?): RealtimeVoiceConversationEngine {
            val selection = select()
            val draft = Conversation(id = "", title = "", providerID = provider.id, providerKind = provider.kind, modelID = entry.model)
            val target = VoiceConversationTarget.Chat(
                conversationId = null,
                context = context,
                createConversation = create,
                newConversation = { draft },
                realtimeSelection = selection,
            ) { NoChat }
            val choice = prepareRealtimeVoiceSession(builder, target, context) { null }
            engine = (choice as RealtimeVoiceSessionChoice.Realtime).engine
            observe()
            sessions.beginChat(home)
            engine.start(NoChat)
            test.testScheduler.runCurrent()
            return engine
        }

        /** A Gemini wire message becomes a unified event through the production mapper and is fed to the connection. */
        fun feed(messages: List<JsonObject>) {
            messages.flatMap { mapper.map(it) }.forEach { connection.events.trySend(it) }
            test.testScheduler.runCurrent()
        }

        /**
         * Recording playback: advances virtual time by ms (relative to the start moment), restores audioBytes to equal-length silent PCM, and feeds each message to the connection through the production mapper.
         */
        fun replay(recorded: List<JsonObject>) {
            val origin = test.testScheduler.currentTime
            for (entry in recorded) {
                val at = origin + entry["ms"]!!.jsonPrimitive.content.toLong()
                val wait = at - test.testScheduler.currentTime
                if (wait > 0) test.testScheduler.advanceTimeBy(wait)
                feed(listOf(restoreAudio(entry["msg"]!!) as JsonObject))
            }
        }

        /** The home conversation was created and navigation happened (creation completes in place on the main thread); if it did not happen, fail right away without waiting. */
        fun awaitNavigation() {
            test.testScheduler.runCurrent()
            assertTrue("home did not create a conversation and navigate", navigatedOnce.isCompleted)
        }

        /** After navigation, the sink write loop (IO) persists everything queued; returns the conversation written to. */
        suspend fun settle(): String? {
            awaitNavigation()
            return sinks.single().drain().also { test.testScheduler.runCurrent() }
        }

        /** After ending, wait for the write loop to finish up (including deleting an empty conversation); the write loop is on the IO thread, and main-thread tasks run normally in the meantime. */
        suspend fun finish() {
            withContext(Dispatchers.Default) { withTimeout(5_000) { sinks.single().drain() } }
            test.testScheduler.runCurrent()
        }

        suspend fun messages(id: String) = repo.getWithMessages(id)!!.messages.map { it.role to it.text }
    }

    private fun wire(json: String): JsonObject = Json.parseToJsonElement(json).jsonObject

    private val setup = wire("""{"setupComplete":{}}""")
    private val assistantAudio =
        wire("""{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"AAAA"}}]}}}""")

    /** In the same round, the assistant audio and transcript arrive first, and inputTranscription arrives late (before turnComplete). */
    private val assistantFirstTurn = listOf(
        setup,
        assistantAudio,
        wire("""{"serverContent":{"outputTranscription":{"text":"It's three"}}}"""),
        wire("""{"serverContent":{"outputTranscription":{"text":" o’clock."}}}"""),
        wire("""{"serverContent":{"inputTranscription":{"text":"What time"}}}"""),
        wire("""{"serverContent":{"inputTranscription":{"text":" is it?"}}}"""),
        wire("""{"serverContent":{"generationComplete":true}}"""),
        wire("""{"serverContent":{"turnComplete":true}}"""),
    )

    @Test
    fun first_turn_user_then_assistant() = runTest {
        val f = HomeFlow(this)
        f.start()
        f.feed(assistantFirstTurn)
        val id = f.settle()

        assertNotNull(id)
        assertEquals(listOf(id), f.created)
        assertEquals(
            listOf(ChatRole.User to "What time is it?", ChatRole.Assistant to "It's three o’clock."),
            f.messages(id!!),
        )
        f.scope.cancel()
    }

    @Test
    fun home_model_gone_switch_reverts_to_last_text_model() = runTest {
        // The realtime model selected on the home pill has been retired from the catalog: a tap on the orb does not fall back into a cascade and does not create a conversation; failure card model_gone;
        // "Switch model" first switches the pill back to the last-used text model (HomeScreen onSwitchModel -> HomeViewModel.setActiveModel).
        val f = HomeFlow(this)
        f.settings.disclosure.markAccepted(provider.kind, VoiceDirection.Realtime)
        val retired = VoiceEngineSelection.Cloud(ProviderKind.Gemini, provider.id, "gemini-live-retired")
        val target = VoiceConversationTarget.Home(
            createConversation = { error("model_gone: no conversation created") },
            navigate = { error("model_gone: no navigation") },
            realtimeSelection = retired,
        )
        val choice = prepareRealtimeVoiceSession(f.builder, target, { c ->
            ChatContextRequest(ContextConversation(id = c.id, useMemory = false))
        }) { null }

        val failure = (choice as RealtimeVoiceSessionChoice.Failed).failure
        assertEquals(RealtimeModel.CATEGORY_MODEL_GONE, failure.category)
        assertEquals("gemini-live-retired", failure.model)
        assertFalse(f.builder.realtimeActive)
        assertEquals(0, conversationCount(db))
        assertTrue("switching model restores the text model first", realtimeFailureRestoresTextModel(failure))
        val lastText = LastUsedModelRef(providerID = provider.id, modelID = "gemini-2.5-flash")
        assertEquals(lastText, lastTextModelToRestore(listOf(provider), lastText))
        // After returning to the text model the ≋ has no realtime selection: always cascade.
        val text = VoiceConversationTarget.Home(createConversation = { null }, navigate = {})
        assertEquals(RealtimeVoiceSessionChoice.Cascade, prepareRealtimeVoiceSession(f.builder, text, { c ->
            ChatContextRequest(ContextConversation(id = c.id, useMemory = false))
        }) { null })
        f.scope.cancel()
    }

    @Test
    fun navigate_on_main() = runTest {
        val f = HomeFlow(this)
        f.start()
        f.feed(assistantFirstTurn)
        val id = f.settle()!!

        assertEquals(listOf(true to id), f.navigated)
        val top = nav.currentBackStackEntry!!
        assertEquals(id, top.toRoute<AppRoute.Chat>().conversationId)
        assertEquals(id, f.sessions.handoffConversationId)
        assertTrue(f.sessions.handingOff)
        f.scope.cancel()
    }

    @Test
    fun end_then_open_conversation() = runTest {
        val f = HomeFlow(this)
        val engine = f.start()
        f.feed(assistantFirstTurn)
        val id = f.settle()!!

        engine.end(EndReason.USER)
        // The voice bar disappears immediately after ✕.
        assertFalse(engine.active.value)
        testScheduler.runCurrent()
        assertFalse(engine.active.value)

        // Reopen the conversation from the main thread: the top of the stack is this conversation's Chat, and the messages are all there.
        assertTrue(Looper.myLooper() == Looper.getMainLooper())
        nav.navigate(AppRoute.Chat(conversationId = id))
        assertEquals(id, nav.currentBackStackEntry!!.toRoute<AppRoute.Chat>().conversationId)
        assertEquals(
            listOf(ChatRole.User to "What time is it?", ChatRole.Assistant to "It's three o’clock."),
            f.messages(id),
        )
        f.scope.cancel()
    }

    @Test
    fun late_user_transcript_no_duplicate() = runTest {
        val f = HomeFlow(this)
        f.start()
        f.feed(assistantFirstTurn)
        // realtime-events.v1.json: an inputTranscription that arrives after turnComplete belongs to the next round.
        f.feed(fixtureMessages("gemini_late_input_transcription_goes_to_next_turn"))
        val id = f.settle()!!

        assertEquals(listOf(id), f.created)
        assertEquals(listOf(true to id), f.navigated)
        assertEquals(
            listOf(
                ChatRole.User to "What time is it?",
                ChatRole.Assistant to "It's three o’clock.",
                ChatRole.Assistant to "Hi there.",
                ChatRole.User to "Late words",
            ),
            f.messages(id),
        )
        f.scope.cancel()
    }

    @Test
    fun assistant_first_moves_to_chat_before_speaking() = runTest {
        val f = HomeFlow(this)
        val engine = f.start()
        f.feed(listOf(setup))
        assertEquals(emptyList<Pair<Boolean, String>>(), f.navigated)

        // The first round event is assistant audio: create the conversation and navigate first, then reduce and publish speaking.
        f.feed(listOf(assistantAudio))
        f.awaitNavigation()
        val id = f.created.single()
        assertEquals(listOf(true to id), f.navigated)
        assertEquals(ConversationStatusKey.LISTENING, f.statusAtNavigate)
        assertEquals(id, nav.currentBackStackEntry!!.toRoute<AppRoute.Chat>().conversationId)
        assertEquals(ConversationStatusKey.SPEAKING, engine.statusKey.value)

        f.feed(assistantFirstTurn.drop(2))
        assertEquals(id, f.settle())
        assertEquals(listOf(id), f.created)
        assertEquals(listOf(true to id), f.navigated)
        assertEquals(
            listOf(ChatRole.User to "What time is it?", ChatRole.Assistant to "It's three o’clock."),
            f.messages(id),
        )
        f.scope.cancel()
    }

    @Test
    fun assistant_first_without_user_transcript() = runTest {
        val f = HomeFlow(this)
        f.start()
        f.feed(assistantFirstTurn.filterNot { "inputTranscription" in it.toString() })
        val id = f.settle()!!

        assertEquals(listOf(id), f.created)
        assertEquals(listOf(true to id), f.navigated)
        assertEquals(listOf(ChatRole.Assistant to "It's three o’clock."), f.messages(id))
        f.scope.cancel()
    }

    @Test
    fun empty_session_deletes_conversation() = runTest {
        val f = HomeFlow(this)
        val engine = f.start()
        f.feed(listOf(setup, assistantAudio))
        f.awaitNavigation()
        val id = f.created.single()
        assertNotNull(repository.getWithMessages(id))

        engine.end(EndReason.USER)
        assertFalse(engine.active.value)
        // Write loop finishing: the conversation that was persisted with zero rows is deleted.
        withContext(Dispatchers.Default) { withTimeout(5_000) { f.sinks.single().drain() } }
        testScheduler.runCurrent()
        assertNull(repository.getWithMessages(id))
        f.scope.cancel()
    }

    @Test
    fun empty_delete_returns_home() = runTest {
        val f = HomeFlow(this)
        val engine = f.start()
        f.feed(listOf(setup, assistantAudio))
        f.awaitNavigation()
        val id = f.created.single()
        assertFalse(onHome())

        engine.end(EndReason.USER)
        f.finish()
        // All three conditions hold: delete the empty conversation and return home.
        assertNull(repository.getWithMessages(id))
        assertEquals(0, conversationCount(db))
        assertTrue(onHome())
        f.scope.cancel()
    }

    @Test
    fun chat_draft_entry_never_deletes() = runTest {
        // The chat page draft has already created the conversation row; a realtime first round event does not create the conversation from home, and ending with zero rows does not delete it.
        val draftRow = repository.create(providerID = provider.id, providerKind = provider.kind, modelID = entry.model).id
        var pageCreates = 0
        val f = HomeFlow(this)
        val engine = f.startChatDraft {
            pageCreates++
            draftRow
        }
        f.feed(listOf(setup, assistantAudio))
        assertEquals(0, pageCreates)
        assertTrue(f.navigated.isEmpty())

        engine.end(EndReason.USER)
        f.finish()
        assertNotNull(repository.getWithMessages(draftRow))
        assertEquals(1, conversationCount(db))
        f.scope.cancel()
    }

    @Test
    fun end_during_creation_still_deletes_empty() = runTest {
        // Real Room async executor: the conversation insert runs on the Room thread, and the conversation has already ended before returning to the main thread.
        val asyncDb = Room.inMemoryDatabaseBuilder(RuntimeEnvironment.getApplication(), OriveoDatabase::class.java)
            .allowMainThreadQueries()
            .build()
            .also { extraDbs += it }
        val f = HomeFlow(this, repo = repositoryOf(asyncDb))
        val engine = f.start()
        f.feed(listOf(setup, assistantAudio))
        engine.end(EndReason.USER)
        assertFalse(engine.active.value)

        f.finish()
        // Conversation creation cannot be cancelled midway: the id that was created is still recorded, the empty conversation is deleted, and it returns home.
        assertEquals(0, conversationCount(asyncDb))
        assertTrue(onHome())
        f.scope.cancel()
    }

    @Test
    fun zero_turn_failure_keeps_card_on_home() = runTest {
        // Samsung A17: after the tap, Gemini Live closes before setup -> home releases ownership with zero rounds, and the failure card is hidden with it, looking like "tapped with no response".
        val f = HomeFlow(this)
        val engine = f.start()
        f.connection.events.close(GeminiLiveClosedException("Gemini Live connection closed unexpectedly"))
        testScheduler.runCurrent()

        assertFalse(engine.active.value)
        val failure = engine.failure.value
        assertEquals("unknown", failure?.category)
        // Same as the LaunchedEffect(active) in rememberVoiceConversationHost: zero rounds still release ownership and no conversation is kept.
        val released = releaseHomeZeroTurn(f.handoff, failure)
        assertFalse(f.sessions.ownedBy(f.home))
        assertEquals(0, conversationCount(db))
        // The failure card stays on the home stage; it is no longer shown once another page takes over.
        assertEquals(failure, stageFailure(failure, owned = false, releasedOnFailure = released, sessions = f.sessions))
        f.sessions.beginChat(Any())
        assertEquals(null, stageFailure(failure, owned = false, releasedOnFailure = released, sessions = f.sessions))
        f.scope.cancel()
    }

    @Test
    fun creation_failure_ends_with_error_not_speaking() = runTest {
        var attempts = 0
        val f = HomeFlow(this, homeCreate = {
            attempts++
            null
        })
        val engine = f.start()
        f.feed(listOf(setup, assistantAudio))
        f.feed(assistantFirstTurn.drop(2))

        // Try only once; on failure, end with the same error that the home cascade's first-send failure ends with; the home voice bar never reaches speaking.
        assertEquals(1, attempts)
        assertFalse(engine.active.value)
        assertFalse(ConversationStatusKey.SPEAKING in f.statuses)
        assertEquals(
            // The reducer maps codes outside the six categories to unknown.
            VoiceConversationEvent.Ended(EndReason.ERROR, "unknown"),
            f.events.filterIsInstance<VoiceConversationEvent.Ended>().single(),
        )
        assertTrue(f.navigated.isEmpty())
        assertEquals(0, conversationCount(db))
        f.scope.cancel()
    }

    private val recording: JsonObject by lazy {
        Json.parseToJsonElement(
            workspaceFile("shared/voice-contracts/recordings/gemini-live-home-two-turn.v1.json").readText(),
        ).jsonObject
    }

    private fun recordedMessages(variant: String? = null): List<JsonObject> {
        val source = if (variant == null) {
            recording
        } else {
            recording["variants"]!!.jsonArray.map { it.jsonObject }.single { it["id"]!!.jsonPrimitive.content == variant }
        }
        return source["messages"]!!.jsonArray.map { it.jsonObject }
    }

    private val expectedMessages: List<Pair<ChatRole, String>> by lazy { roleTexts(recording) }

    private fun variantExpectedMessages(variant: String): List<Pair<ChatRole, String>> =
        roleTexts(recording["variants"]!!.jsonArray.map { it.jsonObject }.single { it["id"]!!.jsonPrimitive.content == variant })

    private fun roleTexts(source: JsonObject): List<Pair<ChatRole, String>> =
        source["expectedMessages"]!!.jsonArray.map { it.jsonObject }.map {
            val role = when (val r = it["role"]!!.jsonPrimitive.content) {
                "user" -> ChatRole.User
                "assistant" -> ChatRole.Assistant
                else -> error("unknown role $r")
            }
            role to it["text"]!!.jsonPrimitive.content
        }

    /** Base64 of the n-byte silent PCM restored from a redacted {"audioBytes": n}. */
    private fun restoreAudio(element: JsonElement): JsonElement = when (element) {
        is JsonObject -> if (element.keys == setOf("audioBytes")) {
            JsonPrimitive(Base64.getEncoder().encodeToString(ByteArray(element["audioBytes"]!!.jsonPrimitive.content.toInt())))
        } else {
            JsonObject(element.mapValues { restoreAudio(it.value) })
        }
        is JsonArray -> JsonArray(element.map { restoreAudio(it) })
        else -> element
    }

    @Test
    fun replay_recorded_gemini_two_turn() = runTest {
        ShadowLog.clear()
        val f = HomeFlow(this)
        f.start()
        f.replay(recordedMessages())
        val id = f.settle()!!

        assertEquals(listOf(id), f.created)
        assertEquals(listOf(true to id), f.navigated)
        assertEquals(expectedMessages, f.messages(id))
        // Every realtime event is logged.
        val logged = ShadowLog.getLogsForTag("RealtimeVoice").map { it.msg }
        assertTrue(logged.any { "userTranscript" in it })
        assertTrue(logged.any { "assistantTurnDone" in it })
        f.scope.cancel()
    }

    @Test
    fun replay_recorded_gemini_barge_in() = runTest {
        // Real recording: mid-story the speaker interrupts a long story and switches to telling a joke; the persisted messages match expectedMessages (the interrupted half-sentence from the assistant + the new round).
        val bargeIn = Json.parseToJsonElement(
            workspaceFile("shared/voice-contracts/recordings/gemini-live-barge-in.v1.json").readText(),
        ).jsonObject
        val f = HomeFlow(this)
        f.start()
        f.replay(bargeIn["messages"]!!.jsonArray.map { it.jsonObject })
        val id = f.settle()!!

        assertEquals(listOf(id), f.created)
        assertEquals(roleTexts(bargeIn), f.messages(id))
        f.scope.cancel()
    }

    @Test
    fun replay_human_pauses_fragments() = runTest {
        // The first round's inputTranscription splits into three segments; the first segment comes before modelTurn and is itself the event that triggers creating the conversation: still 4 expectedMessages.
        val f = HomeFlow(this)
        f.start()
        f.replay(recordedMessages("human_pauses_first_turn_three_fragments"))
        val id = f.settle()!!

        assertEquals(listOf(id), f.created)
        assertEquals(listOf(true to id), f.navigated)
        assertEquals(expectedMessages, f.messages(id))
        f.scope.cancel()
    }

    @Test
    fun replay_speaker_echo_during_first_reply() = runTest {
        // Loudspeaker echo: an inputTranscription that arrives only after the first round's reply has started belongs to the next round; the persisted order has the user before the assistant in each round.
        val f = HomeFlow(this)
        f.start()
        f.replay(recordedMessages("speaker_echo_during_first_reply"))
        val id = f.settle()!!

        assertEquals(listOf(id), f.created)
        assertEquals(listOf(true to id), f.navigated)
        assertEquals(variantExpectedMessages("speaker_echo_during_first_reply"), f.messages(id))
        f.scope.cancel()
    }

    @Test
    fun full_path_end_then_open_conversation() = runTest {
        val f = HomeFlow(this)
        val engine = f.start()
        f.replay(recordedMessages())
        val id = f.settle()!!

        engine.end(EndReason.USER)
        assertFalse(engine.active.value)
        f.finish()
        // A conversation with persisted content is not deleted and does not return home; reopening it shows all four messages.
        assertFalse(onHome())
        nav.navigate(AppRoute.Chat(conversationId = id))
        assertEquals(id, nav.currentBackStackEntry!!.toRoute<AppRoute.Chat>().conversationId)
        assertEquals(expectedMessages, f.messages(id))
        f.scope.cancel()
    }

    @Test
    fun empty_delete_returns_home_only_when_on_that_chat() = runTest {
        val other = repository.create(providerID = provider.id, providerKind = provider.kind, modelID = entry.model).id
        val f = HomeFlow(this)
        val engine = f.start()
        f.feed(listOf(setup, assistantAudio))
        f.awaitNavigation()
        val id = f.created.single()
        // Before deleting the empty one, the user has already moved to another conversation: delete the empty conversation, but stay on the current page.
        nav.navigate(AppRoute.Chat(conversationId = other))

        engine.end(EndReason.USER)
        f.finish()
        assertNull(repository.getWithMessages(id))
        assertFalse(onHome())
        assertEquals(other, nav.currentBackStackEntry!!.toRoute<AppRoute.Chat>().conversationId)
        f.scope.cancel()
    }

    @Test
    fun empty_delete_races_new_message_keeps_it() = runTest {
        // Real Room executor; the sink write loop runs on a real IO thread, and leaving the page takes the real navigation.
        val asyncDb = Room.inMemoryDatabaseBuilder(RuntimeEnvironment.getApplication(), OriveoDatabase::class.java)
            .build()
            .also { extraDbs += it }
        val repo = repositoryOf(asyncDb)
        repeat(40) { round ->
            val id = repo.create(providerID = provider.id, providerKind = provider.kind, modelID = entry.model).id
            nav.navigate(AppRoute.Chat(conversationId = id))
            val order = Collections.synchronizedList(mutableListOf<String>())
            val sink = RepositoryRealtimeTranscriptSink(
                conversationId = null,
                attribution = RealtimeMessageAttribution(provider.id, provider.kind, "Gemini", entry.model),
                add = repo::addMessage,
                update = repo::updateMessage,
                scope = sinkScope,
                // Same as the home wiring of VoiceConversationHost: switch to the main thread to leave the page (only when the current page is that conversation).
                createConversation = RealtimeConversationCreator(
                    home = true,
                    create = { id },
                    onEmptyDeleted = { cid ->
                        withContext(Dispatchers.Main.immediate) {
                            order += "returnHome"
                            nav.returnHomeAfterDeleting(cid)
                        }
                    },
                ),
                delete = { cid ->
                    order += "deleteIfEmpty"
                    repo.deleteIfEmpty(cid)
                },
            )
            assertTrue(sink.ensureConversation())
            val sent = round % 2 == 0
            // Messages the chat page has already emitted before leaving (running concurrently with conversation teardown on another IO thread).
            if (sent) {
                async(Dispatchers.IO) { repo.addMessage(id, userMessage("m-$round", "hello $round")) }.await()
            }
            sink.close()
            withContext(Dispatchers.Default) { withTimeout(5_000) { sink.drain() } }
            testScheduler.runCurrent()

            // Leave the page first, then delete from the database; even when the delete is skipped, navigate only once.
            assertEquals(listOf("returnHome", "deleteIfEmpty"), order.toList())
            assertTrue(onHome())
            val stored = repo.getWithMessages(id)
            if (sent) {
                // Messages already emitted: the conversation and messages are both there, nothing is deleted.
                assertEquals(listOf(ChatRole.User to "hello $round"), stored!!.messages.map { it.role to it.text })
                assertEquals(1, messageCount(asyncDb, id))
            } else {
                assertNull(stored)
                assertEquals(0, messageCount(asyncDb, id))
            }
        }
    }

    @Test
    fun session_expired_keeps_pending_user_text() = runTest {
        val f = HomeFlow(this)
        val engine = f.start()
        f.feed(listOf(setup, assistantAudio))
        f.awaitNavigation()
        val id = f.created.single()
        // The reply has started, and then the user's text arrives late (not final).
        f.feed(
            listOf(
                wire("""{"serverContent":{"outputTranscription":{"text":"Sure"}}}"""),
                wire("""{"serverContent":{"inputTranscription":{"text":"Hey"}}}"""),
            ),
        )
        // The 1008 branch of GeminiLiveTransport: first flush the user's text as final, then end with session expiry.
        f.connection.events.trySend(RealtimeSessionEvent.UserTranscript(null, "Hey", final = true))
        f.connection.events.close(GeminiLiveSessionExpiredException("Gemini Live session expired (1008)"))
        testScheduler.runCurrent()
        engine.end(EndReason.USER)
        assertFalse(engine.active.value)
        f.finish()

        // Read the database: that user message is there, exactly one; the conversation is not deleted as an empty conversation.
        val stored = repository.getWithMessages(id)
        assertNotNull(stored)
        assertEquals(
            "${stored!!.messages.map { it.role to it.text }}",
            listOf(ChatRole.User to "Hey"),
            stored.messages.filter { it.role == ChatRole.User }.map { it.role to it.text },
        )
        assertTrue("${f.events}", f.events.none { it is VoiceConversationEvent.DraftTranscript })
        f.scope.cancel()
    }

    @Test
    fun end_draft_delivered_once() = runTest {
        val f = HomeFlow(this)
        val engine = f.start()
        f.connection.events.trySend(RealtimeSessionEvent.Ready)
        f.connection.events.trySend(RealtimeSessionEvent.UserSpeechStarted(null))
        f.connection.events.trySend(RealtimeSessionEvent.UserTranscript(null, "remind me to ", final = false))
        testScheduler.runCurrent()

        // The same end is triggered repeatedly (the user taps end, leaves the page, goes to background): the draft is delivered only once.
        engine.end(EndReason.USER)
        engine.end(EndReason.USER)
        engine.end(EndReason.SYSTEM)
        engine.systemInterruption()
        testScheduler.runCurrent()
        assertFalse(engine.active.value)
        assertEquals(
            listOf(VoiceConversationEvent.DraftTranscript("remind me to")),
            f.events.filterIsInstance<VoiceConversationEvent.DraftTranscript>(),
        )
        assertEquals(1, f.events.count { it is VoiceConversationEvent.Ended })
        f.scope.cancel()
    }

    private fun userMessage(id: String, text: String) = ChatMessage(
        id = id,
        role = ChatRole.User,
        text = text,
        providerKind = provider.kind,
        providerName = "Gemini",
        modelName = entry.model,
        state = ChatMessageState.Delivered,
    )

    private fun messageCount(database: OriveoDatabase, conversationId: String): Int =
        database.openHelper.readableDatabase.query("SELECT COUNT(*) FROM messages WHERE conversationId = ?", arrayOf(conversationId))
            .use { it.moveToFirst(); it.getInt(0) }

    private fun fixtureMessages(caseId: String): List<JsonObject> {
        val fixture = Json.parseToJsonElement(workspaceFile("shared/voice-contracts/realtime-events.v1.json").readText()).jsonObject
        val case = fixture["mapCases"]!!.jsonArray.map { it.jsonObject }
            .single { it["id"]!!.jsonPrimitive.content == caseId }
        return case["input"]!!.jsonObject["messages"]!!.jsonArray.map { it.jsonObject }
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
}

/**
 * Ideal player (following the recording-playback section of scripts/voice-contracts-check.mjs): fed by the audioBytes count; each segment is played out at 24 kHz 16-bit as soon as it is queued
 * (playedMs = samples received for the item × 1000 / 24000, rounded down), so the queue never backs up -- isPlaying is always false, and during speaking the controller issues playbackDrained right after turnDone.
 * stopPlayback freezes what has been played.
 */
internal open class IdealRealtimeAudio(
    override val route: ConversationRoute = ConversationRoute.SPEAKER,
) : RealtimeAudioIO {
    /** Samples played (= received) per item. */
    private val played = mutableMapOf<String, Long>()

    override fun start(onFrame: (ByteArray) -> Unit, onInterruption: () -> Unit) = Unit

    override fun enqueue(pcm16: ByteArray, itemId: String) {
        played[itemId] = (played[itemId] ?: 0L) + pcm16.size / 2
    }

    override fun playedMs(itemId: String): Long = (played[itemId] ?: 0L) * 1000 / RealtimePCM.OUTPUT_RATE

    override val isPlaying: Boolean get() = false

    override fun stopPlayback() = Unit

    override fun stop() = Unit

    override suspend fun playEarcon(kind: EarconKind) = Unit
}
