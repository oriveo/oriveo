package ai.oriveo.community.feature.chat

import androidx.room.Room
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.mcp.InMemoryPrefs
import ai.oriveo.community.core.mcp.McpAuthKind
import ai.oriveo.community.core.mcp.McpAuthPauseDecision
import ai.oriveo.community.core.mcp.McpAuthPauseRequest
import ai.oriveo.community.core.mcp.McpReauthorizer
import ai.oriveo.community.core.mcp.McpChatToolRunner
import ai.oriveo.community.core.mcp.McpClientHarness
import ai.oriveo.community.core.mcp.McpConnectionState
import ai.oriveo.community.core.mcp.McpConnectionStatus
import ai.oriveo.community.core.mcp.McpCredentialStore
import ai.oriveo.community.core.mcp.McpRuntimeConfig
import ai.oriveo.community.core.mcp.McpServerAddition
import ai.oriveo.community.core.mcp.McpServerStore
import ai.oriveo.community.core.mcp.McpStepPayload
import ai.oriveo.community.core.mcp.McpToolAvailability
import ai.oriveo.community.core.mcp.McpToolSnapshot
import ai.oriveo.community.core.mcp.McpToolStep
import ai.oriveo.community.core.mcp.mcpSha256Hex
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.async
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * Chat-side MCP orchestration: the chip count, the switches of a draft conversation, and step detail read from the stored payload.
 * Runs against the real Room store and the production entry point `McpChatToolRunner`; only the connection and the model are supplied by the test.
 */
@RunWith(RobolectricTestRunner::class)
class ChatMcpCoordinatorTest {

    private lateinit var db: OriveoDatabase
    private lateinit var store: McpServerStore
    private lateinit var runner: McpChatToolRunner
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
    private var config = McpRuntimeConfig.fallback
    private var conversationId: String? = null
    private var provider: Provider? = Provider(id = "openai", kind = ProviderKind.OpenAI, apiKey = "k")
    private var model: AIModel? = null

    @Before
    fun setUp() {
        db = Room.inMemoryDatabaseBuilder(RuntimeEnvironment.getApplication(), OriveoDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        val credentials = McpCredentialStore(InMemoryPrefs())
        store = McpServerStore(db.mcpServerDao(), credentials)
        runner = McpChatToolRunner(
            httpClient = HttpClient(MockEngine { respond("") }),
            json = Json { ignoreUnknownKeys = true },
            store = store,
            credentialStore = credentials,
            runtimeConfig = { config },
        )
        runBlocking {
            store.addServer(
                McpServerAddition(
                    id = SERVER, name = "Linear", url = "https://linear.example.com/mcp", authKind = McpAuthKind.Auto,
                    localOnly = false, iconURL = null, createdAt = 1L,
                    snapshots = listOf(
                        McpToolSnapshot(
                            serverId = SERVER, toolName = "search", title = "Search", description = "Search issues",
                            inputSchema = buildJsonObject { put("type", "object") }, annotations = buildJsonObject { put("readOnlyHint", true) },
                            contentHash = mcpSha256Hex("search"), readOnly = true, updatedAt = 1L,
                        ),
                    ),
                    permissions = emptyMap(),
                    connectionState = McpConnectionState(SERVER, McpConnectionStatus.Connected),
                ),
                maxServers = 20,
            )
        }
    }

    @After
    fun tearDown() {
        scope.cancel()
        db.close()
    }

    private fun coordinator(runner: McpChatToolRunner? = this.runner) = ChatMcpCoordinator(
        scope = scope,
        runner = runner,
        confirmationCoordinator = null,
        draftConversationId = DRAFT,
        currentConversationId = { conversationId },
        activeProvider = { provider },
        activeModel = { model },
    )

    private suspend fun settle(condition: () -> Boolean) =
        assertTrue("the state did not settle in time", McpClientHarness.eventually(condition = condition))

    @Test
    fun `the entry is hidden when the feature is switched off or not wired`() {
        assertTrue(coordinator().isEntryVisible)
        assertFalse(coordinator(runner = null).isEntryVisible)
        config = config.copy(enabled = false)
        assertFalse("the entry is hidden when mcpRuntimeConfig.enabled=false", coordinator().isEntryVisible)
    }

    @Test
    fun `a new chat starts with everything off and its switches follow the conversation once it exists`() = runBlocking {
        val coordinator = coordinator()
        coordinator.refresh()
        settle { coordinator.panelState.hasServers }
        assertEquals("a new conversation starts with everything off", 0, coordinator.panelState.enabledServerCount)

        coordinator.setServerEnabled(SERVER, enabled = true)
        // The database is the source of truth: the UI updates first, so a switch shown as on does not prove the write landed.
        runner.awaitSwitchWrites()
        assertEquals("before the first message it is recorded under the draft id", listOf(SERVER), store.fetchEnabledServerIds(DRAFT))
        settle { coordinator.panelState.outboundToolCount == 1 }
        assertEquals(1, coordinator.panelState.enabledServerCount)

        // First message sent: the conversation becomes real and the switches follow it; the send path reads exactly these.
        coordinator.adoptDraft(CONVERSATION)
        conversationId = CONVERSATION
        assertEquals(listOf(SERVER), store.fetchEnabledServerIds(CONVERSATION))
        assertEquals(emptyList<String>(), store.fetchEnabledServerIds(DRAFT))
        coordinator.refresh()
        settle { coordinator.panelState.enabledServerCount == 1 }

        coordinator.setServerEnabled(SERVER, enabled = false)
        runner.awaitSwitchWrites()
        assertEquals(emptyList<String>(), store.fetchEnabledServerIds(CONVERSATION))
        settle { coordinator.panelState.enabledServerCount == 0 }
    }

    /**
     * Switch writes do not follow the cancellation of UI coroutines: leaving the chat page right after a flip (the page scope is cancelled), or a following action cancelling the panel reload,
     * must still leave the write in the database. Otherwise the UI shows the switch on while the next message goes out without tools.
     */
    @Test
    fun `a switch write survives the page scope being cancelled and a refresh racing it`() = runBlocking {
        val gone = CoroutineScope(SupervisorJob() + Dispatchers.Default).also { it.cancel() }
        val leaving = ChatMcpCoordinator(
            scope = gone, runner = runner, confirmationCoordinator = null, draftConversationId = DRAFT,
            currentConversationId = { conversationId }, activeProvider = { provider }, activeModel = { model },
        )
        leaving.setServerEnabled(SERVER, enabled = true)
        runner.awaitSwitchWrites()
        assertEquals("the page is gone, the write still lands", listOf(SERVER), store.fetchEnabledServerIds(DRAFT))

        // The panel reload is cancelled by another action right after a flip: the result of the last flip still lands, in flip order.
        val busy = ChatMcpCoordinator(
            scope = CoroutineScope(SupervisorJob() + Dispatchers.Default), runner = runner, confirmationCoordinator = null,
            draftConversationId = DRAFT, currentConversationId = { conversationId }, activeProvider = { provider }, activeModel = { model },
        )
        busy.setServerEnabled(SERVER, enabled = false)
        busy.setServerEnabled(SERVER, enabled = true)
        busy.setServerEnabled(SERVER, enabled = false)
        busy.refresh()
        runner.awaitSwitchWrites()
        assertEquals(emptyList<String>(), store.fetchEnabledServerIds(DRAFT))
    }

    /** Sending waits for in-flight writes: when the user flips a switch and sends right away, that write must have landed by the time the send path reads the conversation switches. */
    @Test
    fun `sending waits for a switch write that is still in flight`() = runBlocking {
        val executor = java.util.concurrent.Executors.newSingleThreadExecutor()
        val release = java.util.concurrent.CountDownLatch(1)
        try {
            val slowWrites = McpChatToolRunner(
                httpClient = HttpClient(MockEngine { respond("") }),
                json = Json { ignoreUnknownKeys = true },
                store = store,
                credentialStore = McpCredentialStore(InMemoryPrefs()),
                runtimeConfig = { config },
                writeScope = CoroutineScope(SupervisorJob() + executor.asCoroutineDispatcher()),
            )
            // The writer thread is busy: this flip is queued behind it and has not landed yet.
            executor.execute { release.await() }
            val coordinator = coordinator(runner = slowWrites)
            conversationId = CONVERSATION
            coordinator.setServerEnabled(SERVER, enabled = true)
            assertEquals("precondition: the write is still in flight", emptyList<String>(), store.fetchEnabledServerIds(CONVERSATION))

            var enabledWhenPlanned: List<String>? = null
            val send = async(Dispatchers.Default) {
                slowWrites.plan(CONVERSATION, provider!!, AIModel(id = "gpt", name = "GPT", toolCall = true), memoryVerdict = null)
                enabledWhenPlanned = store.fetchEnabledServerIds(CONVERSATION)
            }
            kotlinx.coroutines.delay(150)
            assertFalse("sending does not proceed until the write has landed", send.isCompleted)

            release.countDown()
            send.await()
            assertEquals("the send reads the switches as the user left them", listOf(SERVER), enabledWhenPlanned)
        } finally {
            release.countDown()
            executor.shutdownNow()
        }
    }

    @Test
    fun `starting another new chat drops the switches of the unsent draft`() = runBlocking {
        val coordinator = coordinator()
        coordinator.setServerEnabled(SERVER, enabled = true)
        runner.awaitSwitchWrites()
        assertEquals(listOf(SERVER), store.fetchEnabledServerIds(DRAFT))
        settle { coordinator.panelState.enabledServerCount == 1 }

        coordinator.resetDraft()

        assertTrue("the switches are cleared in the database", McpClientHarness.eventually { runBlocking { store.fetchEnabledServerIds(DRAFT).isEmpty() } })
        settle { coordinator.panelState.enabledServerCount == 0 }
    }

    @Test
    fun `on a connection that cannot carry tools the chip shows no count and the panel says why`() = runBlocking {
        store.setServerEnabled(true, DRAFT, SERVER)
        // The llama.cpp native endpoint has no tool adapter.
        provider = Provider(
            id = "relay-1", kind = ProviderKind.Relay, apiKey = "k", baseUrlText = "https://relay.test",
            relayRequested = RelayRequestedConfig(transport = RelayTransport.LlamaCppNative),
        )
        model = AIModel(id = "local-model", name = "Local", toolCall = true)
        val coordinator = coordinator()

        coordinator.openToolPanel()

        settle { coordinator.panelState.availability == McpToolAvailability.ModelUnsupported }
        assertTrue(coordinator.showToolPanel)
        assertEquals(0, coordinator.panelState.enabledServerCount)
        assertTrue("the servers are still there, just not operable", coordinator.panelState.hasServers)
        coordinator.dismissToolPanel()
        assertFalse(coordinator.showToolPanel)
    }

    @Test
    fun `step detail reads the stored payload and says so when there is none`() = runBlocking {
        store.saveStepPayload("m1", "1:c1", arguments = "{\"q\":\"bug\"}", resultPrefix = "3 issues")
        val coordinator = coordinator()
        val step = McpToolStep(
            id = "1:c1", serverId = SERVER, serverName = "Linear", toolName = "search", title = "Search",
            argsSummary = "bug", status = "done", step = 1,
        )

        coordinator.openStepDetail("m1", step)
        settle { coordinator.stepDetail?.loading == false }
        assertEquals(McpStepPayload("{\"q\":\"bug\"}", "3 issues"), coordinator.stepDetail?.payload)

        // A message whose payload is not in the store.
        coordinator.openStepDetail("m-without-payload", step)
        settle { coordinator.stepDetail?.messageId == "m-without-payload" && coordinator.stepDetail?.loading == false }
        assertNull(coordinator.stepDetail?.payload)

        coordinator.dismissStepDetail()
        assertNull(coordinator.stepDetail)
    }

    // ── Sign-in expiring mid-run and the step limit ────────────

    private suspend fun pausedLoop(stepId: String = "3:c3", conversation: String = CONVERSATION): Deferred<McpAuthPauseDecision> {
        val waiting = scope.async {
            runner.authPauses.awaitDecision(McpAuthPauseRequest(conversation, SERVER, "Linear", stepId))
        }
        settle { runner.authPauses.pending.value.any { it.request.stepId == stepId } }
        return waiting
    }

    @Test
    fun `a paused step is shown for its own conversation and signing in again resumes it`() = runBlocking {
        conversationId = CONVERSATION
        var reauthorized: String? = null
        runner.reauthorizer = McpReauthorizer { serverId -> reauthorized = serverId; true }
        val coordinator = coordinator().also { it.observeLoopState() }
        val waiting = pausedLoop()
        val elsewhere = pausedLoop(stepId = "1:x", conversation = "another-conversation")

        settle { coordinator.pausedStepIds() == setOf("3:c3") }

        coordinator.reauthorize(SERVER)

        assertEquals(McpAuthPauseDecision.Resume, waiting.await())
        assertEquals(SERVER, reauthorized)
        settle { coordinator.pausedStepIds().isEmpty() }
        assertTrue("steps paused in other conversations are unaffected", elsewhere.isActive)
        elsewhere.cancel()
    }

    @Test
    fun `a re-sign-in that does not succeed keeps the step paused and skip moves on`() = runBlocking {
        conversationId = CONVERSATION
        runner.reauthorizer = McpReauthorizer { false }
        val coordinator = coordinator().also { it.observeLoopState() }
        val waiting = pausedLoop()
        settle { coordinator.pausedStepIds() == setOf("3:c3") }

        coordinator.reauthorize(SERVER)
        assertTrue("it stays paused until sign-in succeeds", waiting.isActive)
        assertEquals(setOf("3:c3"), coordinator.pausedStepIds())

        coordinator.skipStep("3:c3")
        assertEquals(McpAuthPauseDecision.Skip, waiting.await())
    }

    @Test
    fun `stopping the answer withdraws its paused step`() = runBlocking {
        conversationId = CONVERSATION
        val coordinator = coordinator().also { it.observeLoopState() }
        val waiting = pausedLoop()

        coordinator.cancelPending(CONVERSATION)

        assertTrue(runCatching { waiting.await() }.exceptionOrNull() is kotlinx.coroutines.CancellationException)
        settle { coordinator.pausedStepIds().isEmpty() }
    }

    @Test
    fun `the step limit flag follows the message it was raised for`() = runBlocking {
        val coordinator = coordinator().also { it.observeLoopState() }
        runner.markStepLimitReached("Message-1")

        settle { coordinator.isStepLimitReached("message-1") }
        assertFalse(coordinator.isStepLimitReached("message-2"))

        runner.clearStepLimitReached("message-1")
        settle { !coordinator.isStepLimitReached("message-1") }
    }

    private companion object {
        const val SERVER = "aaaaaaaa-0000-4000-8000-000000000001"
        const val DRAFT = "draft-session"
        const val CONVERSATION = "conversation-1"
    }
}
