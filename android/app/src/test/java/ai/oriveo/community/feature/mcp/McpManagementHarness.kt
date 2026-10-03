package ai.oriveo.community.feature.mcp

import androidx.room.Room
import androidx.sqlite.db.SimpleSQLiteQuery
import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.mcp.FakeMcpAuthTransport
import ai.oriveo.community.core.mcp.FakeMcpBrowserSession
import ai.oriveo.community.core.mcp.InMemoryPrefs
import ai.oriveo.community.core.mcp.McpAddCoordinator
import ai.oriveo.community.core.mcp.McpAddProbe
import ai.oriveo.community.core.mcp.McpAddState
import ai.oriveo.community.core.mcp.McpAuthKind
import ai.oriveo.community.core.mcp.McpAuthorizer
import ai.oriveo.community.core.mcp.McpBrowserSession
import ai.oriveo.community.core.mcp.McpCallbackValidator
import ai.oriveo.community.core.mcp.McpClient
import ai.oriveo.community.core.mcp.McpConversationGrants
import ai.oriveo.community.core.mcp.McpCredentialStore
import ai.oriveo.community.core.mcp.McpFixture
import ai.oriveo.community.core.mcp.McpRuntimeConfig
import ai.oriveo.community.core.mcp.McpScriptedTransport
import ai.oriveo.community.core.mcp.McpServerActions
import ai.oriveo.community.core.mcp.McpServerStore
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.robolectric.RuntimeEnvironment

/**
 * Setup for the add and management UI tests: real Room (in-memory) + real DAOs + the production store, authorizer, probe and coordinators; only the network is
 * replayed (`McpScriptedTransport` / `FakeMcpAuthTransport`, with fixtures from `shared/test-fixtures/mcp/`).
 */
class McpManagementHarness(browserSession: McpBrowserSession? = null) {
    val db: OriveoDatabase = Room.inMemoryDatabaseBuilder(RuntimeEnvironment.getApplication(), OriveoDatabase::class.java)
        .allowMainThreadQueries()
        .build()
    val prefs = InMemoryPrefs()
    val credentials = McpCredentialStore(prefs)

    /** "Always allow in this conversation": as in production, one instance is shared by the store and the chat send path. */
    val grants = McpConversationGrants()
    val store = McpServerStore(
        dao = db.mcpServerDao(),
        credentials = credentials,
        grants = grants,
    )
    val mcp = McpScriptedTransport()
    val auth = FakeMcpAuthTransport()
    val fakeBrowser = FakeMcpBrowserSession()

    /** Identifies itself with a client metadata document, so [stubAuthorization] needs no client registration. */
    val authorizer = McpAuthorizer(auth, browserSession ?: fakeBrowser, credentials, clientMetadataUrl = CLIENT_METADATA_URL)

    fun close() = db.close()

    /** Operations on a saved server (the production class). */
    fun actions(runtimeConfig: McpRuntimeConfig = McpRuntimeConfig.fallback) = McpServerActions(
        store = store,
        credentialStore = credentials,
        runtimeConfig = { runtimeConfig },
        authorizer = authorizer,
        makeClient = { endpoint, config -> McpClient(endpoint = endpoint, runtimeConfig = config, transport = mcp) },
    )

    /**
     * Adds a server through the production add path and releases its tools (the same as the user pressing Done on the default-permissions review).
     * [oauth]: the server requires sign-in and is added after signing in through the (fake) browser.
     */
    suspend fun addServer(
        name: String = "Linear",
        url: String = ENDPOINT,
        authKind: McpAuthKind = McpAuthKind.Auto,
        token: String? = null,
        oauth: Boolean = false,
        tools: McpScriptedTransport.Stub = toolsList(),
    ): String {
        mcp.reset()
        if (oauth) {
            stubAuthorization()
            approveInBrowser()
            mcp.enqueue(unauthorized(), tools, tools)
        } else if (authKind == McpAuthKind.Token) {
            mcp.enqueue(unauthorized(), tools, tools)
        } else {
            mcp.enqueue(tools, tools)
        }
        val state = coordinator().add(url, authKind, name = name, token = token, confirmAuthorization = { true })
        val review = (state as McpAddState.Review).review
        store.confirmAddition(review.serverId, review.tools.map { it.copy(pendingReview = false) }, review.defaultPermissions)
        mcp.reset()
        return review.serverId
    }

    fun makeClient(runtimeConfig: McpRuntimeConfig = McpRuntimeConfig.fallback): (String) -> McpClient =
        { McpClient(endpoint = it, runtimeConfig = runtimeConfig, transport = mcp) }

    fun coordinator(runtimeConfig: McpRuntimeConfig = McpRuntimeConfig.fallback) = McpAddCoordinator(
        probe = McpAddProbe(authorizer, credentials, makeClient(runtimeConfig), runtimeConfig),
        store = store,
        credentialStore = credentials,
        runtimeConfig = runtimeConfig,
    )

    // ── Replay ─────────────────────────────────────────────────

    fun unauthorized() = McpScriptedTransport.stub("auth/401.www-authenticate.json")

    fun toolsList() = McpScriptedTransport.stub("protocol/stateless/tools-list.response.json")

    /** Rewrites the tool array in the `tools/list` fixture (everything else untouched). */
    fun toolsList(transform: (List<JsonElement>) -> List<JsonElement>): McpScriptedTransport.Stub {
        fun rewrite(value: JsonElement): JsonElement {
            val obj = value as? JsonObject ?: return value
            return JsonObject(
                obj.mapValues { (key, item) -> if (key == "tools" && item is JsonArray) JsonArray(transform(item)) else rewrite(item) },
            )
        }
        return McpScriptedTransport.stub(rewrite(McpFixture.json("protocol/stateless/tools-list.response.json")))
    }

    private fun stubAuthFixture(name: String, url: String, defaultStatus: Int = 200) {
        val fixture = McpFixture.json("auth/$name") as JsonObject
        val status = fixture["status"]?.jsonPrimitive?.content?.toIntOrNull() ?: defaultStatus
        auth.stub(status, fixture.getValue("body"), url)
    }

    /** An authorization server that accepts a client metadata document as the client id. */
    fun stubAuthorization() {
        stubAuthFixture("protected-resource-metadata.json", PROTECTED_RESOURCE_URL)
        stubAuthFixture("authorization-server-metadata.cimd.json", AUTHORIZATION_SERVER_URL)
        stubAuthFixture("token.success.json", TOKEN_URL)
    }

    /** An authorization server that only offers dynamic client registration: registering leaves a client behind on the authorization server. */
    fun stubDcrAuthorization() {
        stubAuthFixture("protected-resource-metadata.json", PROTECTED_RESOURCE_URL)
        stubAuthFixture("authorization-server-metadata.dcr.json", AUTHORIZATION_SERVER_URL)
        stubAuthFixture("dcr.json", REGISTRATION_URL, defaultStatus = 201)
        stubAuthFixture("token.success.json", TOKEN_URL)
    }

    /** A successful sign-in in the fake browser: the redirect carries the authorization code and the correct state / iss. */
    fun approveInBrowser() {
        fakeBrowser.callbackBuilder = { authorizeUrl, redirectUri -> successCallback(authorizeUrl, redirectUri) }
    }

    // ── Assertions ─────────────────────────────────────────────

    /** Row counts of the MCP tables (non-empty ones only). */
    fun nonEmptyTables(): Map<String, Int> = MCP_TABLES.associateWith { table ->
        db.query(SimpleSQLiteQuery("SELECT COUNT(*) FROM $table")).use { cursor ->
            cursor.moveToFirst()
            cursor.getInt(0)
        }
    }.filterValues { it > 0 }

    /** Keys in the credential store other than the dynamic client registration (tokens, full addresses). */
    fun credentialKeys(): List<String> = credentials.keys().filterNot { ":dcr:" in it }

    companion object {
        /** The partition every test runs in. */
        const val UID = LOCAL_PARTITION_ID
        const val ENDPOINT = "https://mcp.example.com/mcp"
        const val PROTECTED_RESOURCE_URL = "https://mcp.example.com/.well-known/oauth-protected-resource"
        const val AUTHORIZATION_SERVER_URL = "https://auth.example.com/.well-known/oauth-authorization-server"
        const val REGISTRATION_URL = "https://auth.example.com/register"
        const val TOKEN_URL = "https://auth.example.com/token"
        const val ISSUER = "https://auth.example.com"
        const val CLIENT_METADATA_URL = "https://app.example.com/oauth/mcp-client.json"

        val MCP_TABLES = listOf(
            "mcp_server", "mcp_connection_state", "mcp_tool_snapshot", "mcp_tool_permission",
            "mcp_conversation_switch", "mcp_step_payload",
        )

        fun successCallback(authorizeUrl: String, redirectUri: String): String {
            val state = McpCallbackValidator.parameters(authorizeUrl)["state"].orEmpty()
            return "$redirectUri?code=ac_123&state=$state&iss=$ISSUER"
        }
    }
}
