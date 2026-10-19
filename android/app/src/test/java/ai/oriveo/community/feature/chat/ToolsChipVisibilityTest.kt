package ai.oriveo.community.feature.chat

import androidx.room.Room
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.mcp.InMemoryPrefs
import ai.oriveo.community.core.mcp.McpAuthKind
import ai.oriveo.community.core.mcp.McpChatToolRunner
import ai.oriveo.community.core.mcp.McpClientHarness
import ai.oriveo.community.core.mcp.McpConnectionState
import ai.oriveo.community.core.mcp.McpConnectionStatus
import ai.oriveo.community.core.mcp.McpCredentialStore
import ai.oriveo.community.core.mcp.McpRuntimeConfig
import ai.oriveo.community.core.mcp.McpServerAddition
import ai.oriveo.community.core.mcp.McpServerStore
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * Visibility rule of the "Tools" chip in the capability bar: shown only when the master switch is on and at least one server has been added (even if all are off),
 * the same rule as the library chip; hidden when none has been added, and the discovery entry is in "Settings › MCP". Same-named cases exist on iOS / Web.
 * Uses real Room storage and the production entry `McpChatToolRunner`; the coordinator reads the panel state itself.
 */
@RunWith(RobolectricTestRunner::class)
class ToolsChipVisibilityTest {

    private lateinit var db: OriveoDatabase
    private lateinit var store: McpServerStore
    private lateinit var runner: McpChatToolRunner
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
    private var config = McpRuntimeConfig.fallback

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
        draftConversationId = "draft-session",
        currentConversationId = { null },
        activeProvider = { Provider(id = "openai", kind = ProviderKind.OpenAI, apiKey = "k") },
        activeModel = { null },
    )

    private suspend fun addServer() {
        store.addServer(
            McpServerAddition(
                id = SERVER, name = "Linear", url = "https://linear.example.com/mcp", authKind = McpAuthKind.Auto,
                localOnly = false, iconURL = null, createdAt = 1L,
                snapshots = emptyList(),
                permissions = emptyMap(),
                connectionState = McpConnectionState(SERVER, McpConnectionStatus.Connected),
            ),
            maxServers = 20,
        )
    }

    private suspend fun loaded(coordinator: ChatMcpCoordinator, hasServers: Boolean) {
        coordinator.refresh()
        assertTrue(
            "The panel state was not read within the time limit",
            McpClientHarness.eventually { coordinator.panelState.hasServers == hasServers },
        )
    }

    @Test
    fun `hidden without servers even when the feature is on`() = runBlocking {
        val coordinator = coordinator()
        loaded(coordinator, hasServers = false)
        assertTrue(coordinator.isEntryVisible)
        assertFalse(coordinator.isToolsChipVisible)
    }

    @Test
    fun `hidden before the panel state is loaded`() {
        assertFalse(coordinator().isToolsChipVisible)
    }

    @Test
    fun `shown with servers that are all switched off`() = runBlocking {
        addServer()
        val coordinator = coordinator()
        loaded(coordinator, hasServers = true)
        assertEquals(0, coordinator.panelState.enabledServerCount)
        assertTrue(coordinator.isToolsChipVisible)
    }

    @Test
    fun `hidden when the feature is switched off or not wired`() = runBlocking {
        addServer()
        config = config.copy(enabled = false)
        val off = coordinator()
        loaded(off, hasServers = true)
        assertFalse("hidden even with servers when mcpRuntimeConfig.enabled=false", off.isToolsChipVisible)
        assertFalse(coordinator(runner = null).isToolsChipVisible)
    }

    private companion object {
        const val SERVER = "aaaaaaaa-0000-4000-8000-0000000000c7"
    }
}
