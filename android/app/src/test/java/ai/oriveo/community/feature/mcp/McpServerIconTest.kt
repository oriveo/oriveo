package ai.oriveo.community.feature.mcp

import android.graphics.Bitmap
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Column
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import ai.oriveo.community.core.mcp.McpAddState
import ai.oriveo.community.core.mcp.McpAuthKind
import ai.oriveo.community.core.mcp.McpFixture
import ai.oriveo.community.core.mcp.McpRefreshResult
import ai.oriveo.community.core.mcp.McpRuntimeConfig
import ai.oriveo.community.core.mcp.McpScriptedTransport
import ai.oriveo.community.core.mcp.McpServerIconPolicy
import ai.oriveo.community.core.mcp.McpServerOverview
import ai.oriveo.community.core.mcp.McpToolAvailability
import ai.oriveo.community.core.mcp.McpToolPanelModel
import ai.oriveo.community.feature.chat.mcp.MCP_SERVER_ICON_FALLBACK_TAG
import ai.oriveo.community.feature.chat.mcp.MCP_SERVER_ICON_IMAGE_TAG
import ai.oriveo.community.feature.chat.mcp.McpServerIcon
import ai.oriveo.community.feature.chat.mcp.McpServerIconMemoryCache
import ai.oriveo.community.feature.chat.mcp.McpServerIconStore
import ai.oriveo.community.feature.chat.mcp.setMcpServerIconStoreForTest
import ai.oriveo.community.feature.mcp.McpManagementHarness.Companion.ENDPOINT
import ai.oriveo.community.feature.mcp.McpManagementHarness.Companion.UID
import ai.oriveo.community.ui.theme.OriveoTheme
import java.io.File
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Server icons: selection rules, the production path from what the server reports about itself to the record, fetching and caching, and the UI fallback.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w390dp-h844dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class McpServerIconTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    @get:Rule
    val temporaryFolder = TemporaryFolder()

    private lateinit var harness: McpManagementHarness

    @Before
    fun setUp() {
        harness = McpManagementHarness()
        McpServerIconMemoryCache.clear()
    }

    @After
    fun tearDown() {
        McpServerIconMemoryCache.clear()
        setMcpServerIconStoreForTest(null)
        harness.close()
    }

    // ── Selection rules ────────────────────────────────────────

    @Test
    fun `only https icons on the server's own host or a parent or child domain are loadable`() {
        val server = "https://mcp.linear.app/mcp"
        for (ok in listOf("https://mcp.linear.app/icon.png", "https://linear.app/static/icon.png", "https://cdn.mcp.linear.app/i.webp")) {
            assertEquals(ok, ok, McpServerIconPolicy.loadable(ok, server))
        }
        for (bad in listOf(
            null,
            "",
            "http://mcp.linear.app/icon.png",
            "data:image/png;base64,AAAA",
            "https://tracker.example.com/pixel.png",
            // Sibling domains do not count: without a public suffix list, allowing them would allow all of `*.app`.
            "https://static.linear.app/icon.png",
            "https://app/icon.png",
            "https://user:pass@mcp.linear.app/icon.png",
            "https://mcp.linear.app/" + "a".repeat(2100),
        )) {
            assertNull(bad, McpServerIconPolicy.loadable(bad, server))
        }
    }

    @Test
    fun `picking from serverInfo icons takes the first usable bitmap and skips svg and foreign hosts`() {
        fun icon(src: String, mimeType: String? = null) = buildJsonObject {
            put("src", src)
            if (mimeType != null) put("mimeType", mimeType)
        }
        val icons = buildJsonArray {
            add(icon("https://mcp.example.com/logo.svg", "image/svg+xml"))
            add(icon("https://mcp.example.com/logo-vector.svg"))
            add(icon("https://tracker.evil.example/pixel.png", "image/png"))
            add(icon("https://mcp.example.com/logo-48.png", "image/png"))
            add(icon("https://mcp.example.com/logo-96.png", "image/png"))
        }
        assertEquals("https://mcp.example.com/logo-48.png", McpServerIconPolicy.pick(icons, ENDPOINT))
        assertNull(McpServerIconPolicy.pick(JsonArray(emptyList()), ENDPOINT))
        assertNull(McpServerIconPolicy.pick(null, ENDPOINT))
        assertNull(McpServerIconPolicy.pick(JsonPrimitive("https://mcp.example.com/logo.png"), ENDPOINT))
    }

    // ── Production path: server-reported → record → UI data ────

    /** Legacy handshake: the modern probe gets a 400 with an empty body → `initialize`, whose `serverInfo` carries icons. */
    private fun legacyHandshakeWithIcons(icons: JsonElement): List<McpScriptedTransport.Stub> {
        fun withIcons(value: JsonElement): JsonElement {
            val obj = value as? JsonObject ?: return value
            return JsonObject(
                obj.mapValues { (key, item) ->
                    if (key == "serverInfo" && item is JsonObject) JsonObject(item + ("icons" to icons)) else withIcons(item)
                },
            )
        }
        return listOf(
            McpScriptedTransport.emptyJson(400),
            McpScriptedTransport.stub(withIcons(McpFixture.json("protocol/session/initialize.response.json"))),
        )
    }

    private val serverIcons = buildJsonArray {
        add(buildJsonObject { put("src", "https://mcp.example.com/icon.png"); put("mimeType", "image/png") })
    }

    @Test
    fun `an icon the server reports at add time is stored on the record and reaches the panel and the list`() = runBlocking {
        harness.mcp.enqueue(legacyHandshakeWithIcons(serverIcons))
        harness.mcp.setFallback(McpScriptedTransport.stub("protocol/session/tools-list.response.json"))

        val state = harness.coordinator().add(ENDPOINT, McpAuthKind.Auto)

        val review = (state as McpAddState.Review).review
        assertEquals("https://mcp.example.com/icon.png", review.session.serverIconUrl)
        assertEquals("https://mcp.example.com/icon.png", harness.store.fetchServer(review.serverId)?.iconURL)
        // The user pressed Done on the default-permissions review: only then does it enter the list and the tool panel.
        harness.store.markAdditionConfirmed(review.serverId)
        assertEquals("https://mcp.example.com/icon.png", McpServerOverview.load(harness.store, harness.credentials, UID).single().iconUrl)
        val panel = McpToolPanelModel.load("chat-1", harness.store, harness.credentials, UID, McpRuntimeConfig.fallback, McpToolAvailability.Available)
        assertEquals("https://mcp.example.com/icon.png", panel.rows.single().iconURL)
    }

    @Test
    fun `an icon on a foreign host is not stored and a stored one that breaks the rule is not offered to the ui`() = runBlocking {
        val foreign = buildJsonArray {
            add(buildJsonObject { put("src", "https://tracker.evil.example/pixel.png"); put("mimeType", "image/png") })
        }
        harness.mcp.enqueue(legacyHandshakeWithIcons(foreign))
        harness.mcp.setFallback(McpScriptedTransport.stub("protocol/session/tools-list.response.json"))
        val review = (harness.coordinator().add(ENDPOINT, McpAuthKind.Auto) as McpAddState.Review).review
        assertNull(harness.store.fetchServer(review.serverId)?.iconURL)
        harness.store.markAdditionConfirmed(review.serverId)

        // A record that already holds an icon address breaking the rules: it is withheld from the UI on read as well.
        harness.store.updateServer(harness.store.fetchServer(review.serverId)!!.copy(iconURL = "https://tracker.evil.example/pixel.png"))
        assertNull(McpServerOverview.load(harness.store, harness.credentials, UID).single().iconUrl)
        val panel = McpToolPanelModel.load("chat-1", harness.store, harness.credentials, UID, McpRuntimeConfig.fallback, McpToolAvailability.Available)
        assertNull(panel.rows.single().iconURL)
    }

    @Test
    fun `reloading tools adopts an icon the server started reporting`() = runBlocking {
        val server = harness.addServer()
        assertNull(harness.store.fetchServer(server)?.iconURL)
        harness.mcp.enqueue(legacyHandshakeWithIcons(serverIcons))
        harness.mcp.setFallback(McpScriptedTransport.stub("protocol/session/tools-list.response.json"))

        assertTrue(harness.actions().refreshTools(server) is McpRefreshResult.Connected)

        assertEquals("https://mcp.example.com/icon.png", harness.store.fetchServer(server)?.iconURL)
    }

    // ── Fetching and caching ───────────────────────────────────

    @Test
    fun `icon bytes are fetched once then served from disk and refetched only after they expire`() {
        var clock = 1_000_000L
        val fetched = mutableListOf<String>()
        var payload = byteArrayOf(1, 2, 3)
        val directory = File(temporaryFolder.root, "icons")
        fun store() = McpServerIconStore(directory, fetch = { url -> fetched += url; payload }, now = { clock })
        val url = "https://mcp.example.com/icon.png"

        assertArrayEquals(byteArrayOf(1, 2, 3), store().bytes(url))
        // A new instance (= process restart): it is on disk, so no request is sent.
        assertArrayEquals(byteArrayOf(1, 2, 3), store().bytes(url))
        assertEquals(listOf(url), fetched)

        clock += McpServerIconStore.MAX_AGE_MILLIS + 1
        payload = byteArrayOf(9)
        assertArrayEquals("fetched again after expiry", byteArrayOf(9), store().bytes(url))
        assertEquals(2, fetched.size)
    }

    @Test
    fun `non-https oversized and failed icons yield nothing and a failure is not retried on every draw`() {
        var attempts = 0
        val directory = File(temporaryFolder.root, "icons")
        val tooBig = McpServerIconStore(directory, fetch = { attempts += 1; ByteArray(McpServerIconStore.MAX_ICON_BYTES + 1) })
        assertNull("anything over the size limit is not used", tooBig.bytes("https://mcp.example.com/huge.png"))
        assertNull(tooBig.bytes("https://mcp.example.com/huge.png"))
        assertEquals("an address that failed is not fetched again in this process", 1, attempts)

        val failing = McpServerIconStore(directory, fetch = { error("network down") })
        assertNull(failing.bytes("https://mcp.example.com/icon.png"))

        var plainHttp = 0
        val http = McpServerIconStore(directory, fetch = { plainHttp += 1; byteArrayOf(1) })
        assertNull("https only", http.bytes("http://mcp.example.com/icon.png"))
        assertEquals(0, plainHttp)
        assertTrue("nothing was written to disk", directory.listFiles().isNullOrEmpty())
    }

    @Test
    fun `an expired icon that cannot be refetched keeps showing the cached one`() {
        var clock = 0L
        val directory = File(temporaryFolder.root, "icons")
        val url = "https://mcp.example.com/icon.png"
        McpServerIconStore(directory, fetch = { byteArrayOf(7) }, now = { clock }).bytes(url)
        clock += McpServerIconStore.MAX_AGE_MILLIS + 1
        assertArrayEquals(byteArrayOf(7), McpServerIconStore(directory, fetch = { null }, now = { clock }).bytes(url))
    }

    // ── UI: show the icon when there is one, otherwise fall back to the initial tile ────

    private fun render(iconUrl: String?) {
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent { OriveoTheme { Column { McpServerIcon(name = "Unknown MCP service", iconUrl = iconUrl) } } }
        composeRule.waitForIdle()
    }

    @Test
    fun `a server with a loaded icon shows the icon without the letter tile`() {
        val url = "https://mcp.example.com/icon.png"
        McpServerIconMemoryCache.put(url, Bitmap.createBitmap(48, 48, Bitmap.Config.ARGB_8888))
        render(url)
        composeRule.onAllNodesWithTag(MCP_SERVER_ICON_IMAGE_TAG, useUnmergedTree = true).assertCountEquals(1)
        composeRule.onAllNodesWithTag(MCP_SERVER_ICON_FALLBACK_TAG, useUnmergedTree = true).assertCountEquals(0)
    }

    @Test
    fun `an icon that cannot be fetched falls back to the letter tile`() {
        setMcpServerIconStoreForTest(McpServerIconStore(File(temporaryFolder.root, "icons"), fetch = { null }))
        render("https://mcp.example.com/icon.png")
        composeRule.waitUntil(10_000) {
            composeRule.onAllNodesWithTag(MCP_SERVER_ICON_FALLBACK_TAG, useUnmergedTree = true).fetchSemanticsNodes().size == 1
        }
        composeRule.onAllNodesWithTag(MCP_SERVER_ICON_IMAGE_TAG, useUnmergedTree = true).assertCountEquals(0)
    }

    @Test
    fun `a server without an icon shows the letter tile`() {
        render(null)
        composeRule.onAllNodesWithTag(MCP_SERVER_ICON_IMAGE_TAG, useUnmergedTree = true).assertCountEquals(0)
        composeRule.onAllNodesWithTag(MCP_SERVER_ICON_FALLBACK_TAG, useUnmergedTree = true).assertCountEquals(1)
    }
}
