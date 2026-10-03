package ai.oriveo.community.core.mcp

import androidx.room.Room
import androidx.sqlite.db.SimpleSQLiteQuery
import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.database.OriveoDatabase
import java.util.Collections
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
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

/**
 * The connection probe state machine.
 *
 * One case per terminal state; in-progress states are pinned through the `progress` callback. "A failure leaves
 * no half-added server behind" is asserted on [McpAddCoordinator] with
 * a real Room (in-memory) database and real DAOs. Protocol replay reuses [McpScriptedTransport]; authorization
 * replay reuses the fake transport and fake browser.
 * Everything under test is production code; the replay layer only answers.
 */
@RunWith(RobolectricTestRunner::class)
class McpAddProbeTest {

    private lateinit var db: OriveoDatabase
    private lateinit var prefs: InMemoryPrefs
    private lateinit var credentials: McpCredentialStore
    private lateinit var store: McpServerStore
    private lateinit var mcp: McpScriptedTransport
    private lateinit var auth: FakeMcpAuthTransport
    private lateinit var browser: FakeMcpBrowserSession
    private val states: MutableList<McpAddState> = Collections.synchronizedList(mutableListOf())
    private val record: McpAddProgress = { states += it }
    private val approve: McpAuthorizationGate = { true }

    @Before
    fun setUp() {
        db = Room.inMemoryDatabaseBuilder(RuntimeEnvironment.getApplication(), OriveoDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        prefs = InMemoryPrefs()
        credentials = McpCredentialStore(prefs)
        store = McpServerStore(dao = db.mcpServerDao(), credentials = credentials)
        mcp = McpScriptedTransport()
        auth = FakeMcpAuthTransport()
        browser = FakeMcpBrowserSession()
        states.clear()
    }

    @After
    fun tearDown() {
        db.close()
    }

    // ── Setup ──────────────────────────────────────────────

    private fun probe(runtimeConfig: McpRuntimeConfig = McpRuntimeConfig.fallback) = McpAddProbe(
        authorizer = McpAuthorizer(auth, browser, credentials, clientMetadataUrl = CLIENT_METADATA_URL),
        credentialStore = credentials,
        makeClient = { McpClient(endpoint = it, runtimeConfig = runtimeConfig, transport = mcp) },
        runtimeConfig = runtimeConfig,
    )

    private fun coordinator(
        runtimeConfig: McpRuntimeConfig = McpRuntimeConfig.fallback,
    ) = McpAddCoordinator(probe(runtimeConfig), store, credentials, runtimeConfig)

    private fun unauthorized() = McpScriptedTransport.stub("auth/401.www-authenticate.json")

    private fun toolsList() = McpScriptedTransport.stub("protocol/stateless/tools-list.response.json")

    /** Rewrites the tools array of the `tools/list` fixture (everything else unchanged). */
    private fun toolsList(transform: (List<JsonElement>) -> List<JsonElement>): McpScriptedTransport.Stub {
        fun rewrite(value: JsonElement): JsonElement {
            val obj = value as? JsonObject ?: return value
            return JsonObject(
                obj.mapValues { (key, item) -> if (key == "tools" && item is JsonArray) JsonArray(transform(item)) else rewrite(item) },
            )
        }
        return McpScriptedTransport.stub(rewrite(McpFixture.json("protocol/stateless/tools-list.response.json")))
    }

    private fun stubAuthFixture(name: String, url: String, defaultStatus: Int = 200) {
        val fixture = McpFixture.json("auth/$name")
        auth.stub(fixture["status"].longOrNull?.toInt() ?: defaultStatus, fixture["body"]!!, url)
    }

    private fun stubAuthorization() {
        stubAuthFixture("protected-resource-metadata.json", PROTECTED_RESOURCE_URL)
        stubAuthFixture("authorization-server-metadata.cimd.json", AUTHORIZATION_SERVER_URL)
        stubAuthFixture("token.success.json", TOKEN_URL)
    }

    /** An authorization server that only supports DCR: registering leaves a client on the authorization server, which pins "no registration before consent". */
    private fun stubDcrAuthorization() {
        stubAuthFixture("protected-resource-metadata.json", PROTECTED_RESOURCE_URL)
        stubAuthFixture("authorization-server-metadata.dcr.json", AUTHORIZATION_SERVER_URL)
        stubAuthFixture("dcr.json", REGISTRATION_URL, defaultStatus = 201)
        stubAuthFixture("token.success.json", TOKEN_URL)
    }

    /** Browser sign-in succeeds: the redirect carries the authorization code and the correct state / iss. */
    private fun approveInBrowser() {
        browser.callbackBuilder = { authorizeUrl, redirectUri ->
            val state = McpCallbackValidator.parameters(authorizeUrl)["state"].orEmpty()
            "$redirectUri?code=ac_123&state=$state&iss=https://auth.example.com"
        }
    }

    private val terminals: List<McpAddState> get() = states.filter { it.isTerminal }

    /** How many rows each of the MCP tables holds (non-empty ones only). */
    private fun nonEmptyTables(): Map<String, Int> = MCP_TABLES.associateWith { table ->
        db.query(SimpleSQLiteQuery("SELECT COUNT(*) FROM $table")).use { cursor ->
            cursor.moveToFirst()
            cursor.getInt(0)
        }
    }.filterValues { it > 0 }

    /** The full "nothing left behind" assertion: every MCP table is empty and the credential store holds nothing except DCR registrations. */
    private fun assertNothingLeft(label: String) {
        assertEquals("$label - no row should be left in any table", emptyMap<String, Int>(), nonEmptyTables())
        assertEquals("$label - no token should be left in the credential store", emptyList<String>(), credentials.keys().filterNot { ":dcr:" in it })
    }

    // ── URL validation ─────────────────────────────────────

    @Test
    fun `malformed or non-https url is rejected without any request`() = runBlocking {
        for (bad in listOf(
            "", "   ", "not a url", "mcp.example.com/mcp", "ftp://mcp.example.com/mcp",
            "http://mcp.example.com/mcp", "HTTP://mcp.example.com/mcp", "http://192.168.1.10:8080/mcp",
            "https://", "https:///mcp",
        )) {
            val state = probe().probe(bad, McpAuthKind.Auto, UID)
            assertEquals(bad, McpAddState.InvalidUrl(McpInvalidUrlReason.Malformed), state)
            assertTrue(state.isTerminal)
        }
        assertTrue("an invalid URL must not trigger a network request", mcp.requests().isEmpty())
    }

    @Test
    fun `url with userinfo is rejected as hasUserinfo without any request`() = runBlocking {
        for (bad in listOf(
            "https://alice:secret@mcp.example.com/mcp",
            "https://alice@mcp.example.com/mcp",
            "https://:secret@mcp.example.com/mcp",
        )) {
            val state = probe().probe(bad, McpAuthKind.Auto, UID)
            assertEquals(bad, McpAddState.InvalidUrl(McpInvalidUrlReason.HasUserinfo), state)
            assertNull(McpEndpoint.validate(bad))
            // The production entry point also rejects it before sending a request or reading the database.
            assertEquals(bad, McpAddState.InvalidUrl(McpInvalidUrlReason.HasUserinfo), coordinator().add(bad, McpAuthKind.Auto))
        }
        assertTrue("a URL with a userinfo part must not trigger a network request", mcp.requests().isEmpty())
        assertNothingLeft("userinfo")
    }

    @Test
    fun `endpoint validation accepts only https and lowercases the scheme`() {
        assertEquals("https://mcp.example.com/mcp", McpEndpoint.validate("https://mcp.example.com/mcp"))
        assertEquals("https://mcp.example.com/mcp", McpEndpoint.validate("  https://mcp.example.com/mcp\n"))
        assertEquals("https://mcp.example.com/Mcp?x=1", McpEndpoint.validate("HTTPS://mcp.example.com/Mcp?x=1"))
        assertNull(McpEndpoint.validate("http://mcp.example.com/mcp"))
        assertNull(McpEndpoint.validate("https://mcp.example.com/" + "a".repeat(2048)))
    }

    @Test
    fun `canonical resource uri drops the trailing slash`() {
        assertEquals("https://mcp.example.com/mcp", McpCanonicalUri.canonical("https://MCP.example.com/mcp/"))
        assertEquals("https://mcp.example.com/mcp", McpCanonicalUri.canonical("HTTPS://mcp.example.com/mcp"))
    }

    // ── Terminal states ────────────────────────────────────

    @Test
    fun `unreachable on network failure`() = runBlocking {
        mcp.enqueue(McpScriptedTransport.networkError())
        val state = probe().probe(ENDPOINT, McpAuthKind.Auto, UID, progress = record)
        assertEquals(McpAddState.Unreachable, state)
        assertEquals(listOf(McpAddState.Connecting, McpAddState.Unreachable), states.toList())
    }

    @Test
    fun `not mcp covers every fixture case`() = runBlocking {
        val cases = McpScriptedTransport.notMcpCases()
        assertEquals(4, cases.size)
        for ((id, stub) in cases) {
            mcp.reset()
            // The fallback handshake gets the same response (an ordinary website answers any POST this way).
            mcp.setFallback(stub)
            val state = probe().probe(ENDPOINT, McpAuthKind.Auto, UID)
            assertEquals(id, McpAddState.NotMcp, state)
        }
    }

    @Test
    fun `direct success reaches review with default permissions`() = runBlocking {
        mcp.enqueue(toolsList(), toolsList())
        val state = probe().probe(ENDPOINT, McpAuthKind.Auto, UID, serverId = "s1", progress = record)
        val review = (state as McpAddState.Review).review
        assertTrue(state.isTerminal)
        assertEquals("s1", review.serverId)
        assertEquals(McpProtocolGeneration.Stateless, review.session.generation)
        assertEquals(listOf("get_weather", "create_issue"), review.tools.map { it.toolName })
        assertTrue("new tools are quarantined until the user confirms", review.tools.all { it.pendingReview })
        assertEquals("declared read-only -> runs automatically", McpToolPermission.Auto, review.defaultPermissions["get_weather"])
        assertEquals("not declared read-only -> asks every time", McpToolPermission.Ask, review.defaultPermissions["create_issue"])
        assertEquals(listOf(McpAddState.Connecting, McpAddState.Finishing, state), states.toList())
    }

    @Test
    fun `token rejected when retry with token is still 401 or the token is empty`() = runBlocking {
        mcp.enqueue(unauthorized(), unauthorized())
        val state = probe().probe(ENDPOINT, McpAuthKind.Token, UID, token = "bad")
        assertEquals(McpAddState.TokenRejected, state)
        assertEquals("the first request has no credential, the second carries the token", 2, mcp.requests().size)
        assertNull(mcp.requests().first().header("Authorization"))
        assertEquals("Bearer bad", mcp.requests().last().header("Authorization"))

        mcp.reset()
        mcp.enqueue(unauthorized())
        assertEquals(McpAddState.TokenRejected, probe().probe(ENDPOINT, McpAuthKind.Token, UID, token = ""))
    }

    @Test
    fun `needs token when the client cannot be registered automatically`() = runBlocking {
        mcp.enqueue(unauthorized())
        // No authorization metadata is stubbed -> discovery fails -> an access token is needed.
        val state = probe().probe(ENDPOINT, McpAuthKind.Auto, UID, confirmAuthorization = approve)
        assertEquals(McpAddState.NeedsToken, state)
    }

    @Test
    fun `auth cancelled when the user cancels in the browser`() = runBlocking {
        mcp.enqueue(unauthorized())
        stubAuthorization()
        // callbackBuilder is null -> the fake browser throws (the user cancelled).
        val state = probe().probe(ENDPOINT, McpAuthKind.Auto, UID, confirmAuthorization = approve)
        assertEquals(McpAddState.AuthCancelled, state)
        assertEquals(1, browser.openedUrls.size)
    }

    @Test
    fun `auth cancelled when the provider denies and no token is exchanged or saved`() = runBlocking {
        mcp.enqueue(unauthorized())
        stubAuthorization()
        browser.callbackBuilder = { authorizeUrl, redirectUri ->
            val state = McpCallbackValidator.parameters(authorizeUrl)["state"].orEmpty()
            "$redirectUri?error=access_denied&state=$state&iss=https://auth.example.com"
        }
        val state = probe().probe(ENDPOINT, McpAuthKind.Auto, UID, serverId = "s1", confirmAuthorization = approve)
        assertEquals(McpAddState.AuthCancelled, state)
        assertNull(credentials.load("s1", UID))
        assertTrue("no token exchange after a denial", auth.formRequests.isEmpty())
    }

    @Test
    fun `transient discovery failure is unreachable rather than needs token`() = runBlocking {
        mcp.enqueue(unauthorized())
        auth.stub(503, "", PROTECTED_RESOURCE_URL)
        val state = probe().probe(ENDPOINT, McpAuthKind.Auto, UID, confirmAuthorization = approve)
        assertEquals(McpAddState.Unreachable, state)
    }

    // ── The gate before sign-in ────────────────────────────

    @Test
    fun `auth prompt gates registration and browser until the user approves`() = runBlocking {
        mcp.enqueue(unauthorized(), toolsList(), toolsList())
        stubDcrAuthorization()
        approveInBrowser()
        val asked = CompletableDeferred<McpAuthPrompt>()
        val decision = CompletableDeferred<Boolean>()

        val job = async(Dispatchers.Default) {
            probe().probe(
                ENDPOINT, McpAuthKind.Auto, UID,
                confirmAuthorization = { prompt -> asked.complete(prompt); decision.await() },
                progress = record,
            )
        }
        val prompt = asked.await()
        assertEquals("the prompt shows the host of the authorization endpoint", "auth.example.com", prompt.authorizationHost)
        assertEquals("waits at the prompt", listOf(McpAddState.Connecting, AUTH_PROMPT), states.toList())
        assertTrue("no client registration before consent", auth.jsonRequests.isEmpty())
        assertTrue("no browser before consent", browser.openedUrls.isEmpty())
        assertTrue("no token exchange before consent", auth.formRequests.isEmpty())

        decision.complete(true)
        val state = job.await()
        assertTrue(state is McpAddState.Review)
        assertEquals(listOf(McpAddState.Connecting, AUTH_PROMPT, McpAddState.Browser, McpAddState.Finishing, state), states.toList())
        assertEquals("registers once after consent", listOf(REGISTRATION_URL), auth.jsonRequests.map { it.first })
        assertEquals(1, browser.openedUrls.size)
    }

    @Test
    fun `declining the auth prompt or providing no gate means no registration and no browser`() = runBlocking {
        for (gate in listOf<McpAuthorizationGate?>({ false }, null)) {
            mcp.reset()
            mcp.enqueue(unauthorized())
            stubDcrAuthorization()
            approveInBrowser()
            val state = probe().probe(ENDPOINT, McpAuthKind.Auto, UID, confirmAuthorization = gate)
            assertEquals(McpAddState.AuthCancelled, state)
            assertTrue(auth.jsonRequests.isEmpty())
            assertTrue(browser.openedUrls.isEmpty())
        }
    }

    @Test
    fun `browser login followed by 401 is auth cancelled and listing 401 follows the auth kind`() = runBlocking {
        mcp.enqueue(unauthorized(), unauthorized())
        stubAuthorization()
        approveInBrowser()
        val afterLogin = probe().probe(ENDPOINT, McpAuthKind.Auto, UID, serverId = "s1", confirmAuthorization = approve)
        assertEquals("not a token field error", McpAddState.AuthCancelled, afterLogin)
        assertNull(credentials.load("s1", UID))

        // Sign-in is demanded while reading the tool list: paste a token -> token field error.
        mcp.reset()
        mcp.enqueue(unauthorized(), toolsList(), unauthorized())
        assertEquals(McpAddState.TokenRejected, probe().probe(ENDPOINT, McpAuthKind.Token, UID, token = "tok"))
    }

    @Test
    fun `only the in-progress states are not terminal`() {
        val review = McpAddReview("s", McpSession(McpProtocolGeneration.Stateless, McpProtocol.MODERN_VERSION), emptyList(), emptyMap())
        val inProgress = listOf(McpAddState.Connecting, McpAddState.AuthPrompt("h"), McpAddState.Browser, McpAddState.Finishing)
        val terminal = listOf(
            McpAddState.Review(review), McpAddState.InvalidUrl(McpInvalidUrlReason.Malformed), McpAddState.Unreachable,
            McpAddState.NotMcp, McpAddState.NeedsToken, McpAddState.AuthCancelled, McpAddState.TokenRejected,
            McpAddState.LimitReached(20), McpAddState.Cancelled, McpAddState.SaveFailed,
        )
        inProgress.forEach { assertFalse("$it", it.isTerminal) }
        terminal.forEach { assertTrue("$it", it.isTerminal) }
    }

    // ── A failure leaves no trace ──────────────────────────

    @Test
    fun `every probing failure leaves the tables and the credential store empty`() = runBlocking {
        data class Case(val label: String, val expected: McpAddState, val kind: McpAuthKind = McpAuthKind.Auto, val token: String? = null, val arrange: () -> Unit)
        val cases = listOf(
            Case("unreachable", McpAddState.Unreachable) { mcp.enqueue(McpScriptedTransport.networkError()) },
            Case("notMcp", McpAddState.NotMcp) { mcp.setFallback(McpScriptedTransport.notMcpCases().first().second) },
            Case("needsToken", McpAddState.NeedsToken) { mcp.enqueue(unauthorized()) },
            Case("tokenRejected", McpAddState.TokenRejected, McpAuthKind.Token, "bad") { mcp.enqueue(unauthorized(), unauthorized()) },
            Case("authCancelled", McpAddState.AuthCancelled) {
                mcp.enqueue(unauthorized())
                stubAuthorization()
            },
            Case("401 after login", McpAddState.AuthCancelled) {
                mcp.enqueue(unauthorized(), unauthorized())
                stubAuthorization()
                approveInBrowser()
            },
        )
        for (case in cases) {
            setUpTransports()
            case.arrange()
            val state = coordinator().add(ENDPOINT, case.kind, token = case.token, confirmAuthorization = approve, progress = record)
            assertEquals(case.label, case.expected, state)
            assertEquals("${case.label} - exactly one terminal state is emitted", listOf(case.expected), terminals)
            assertNothingLeft(case.label)
        }
    }

    private fun setUpTransports() {
        mcp = McpScriptedTransport()
        auth = FakeMcpAuthTransport()
        browser = FakeMcpBrowserSession()
        states.clear()
    }

    @Test
    fun `listing tools fails after browser login and nothing is left`() = runBlocking {
        // 401 -> sign-in -> the probe with the token succeeds -> the network drops while reading the list for real.
        mcp.enqueue(unauthorized(), toolsList(), McpScriptedTransport.networkError())
        stubAuthorization()
        approveInBrowser()
        val state = coordinator().add(ENDPOINT, McpAuthKind.Auto, confirmAuthorization = approve, progress = record)
        assertEquals(McpAddState.Unreachable, state)
        assertEquals("precondition - the token really was obtained", 1, auth.formRequests.size)
        assertEquals(
            listOf(McpAddState.Connecting, AUTH_PROMPT, McpAddState.Browser, McpAddState.Finishing, McpAddState.Unreachable),
            states.toList(),
        )
        assertNothingLeft("listing tools fails after sign-in")
    }

    @Test
    fun `a failure halfway through saving rolls the whole transaction back`() = runBlocking {
        // After the server row, snapshots and permissions were written inside the transaction, writing the connection state fails.
        db.openHelper.writableDatabase.execSQL(
            "CREATE TRIGGER test_fail_connection BEFORE INSERT ON mcp_connection_state " +
                "BEGIN SELECT RAISE(ABORT, 'simulated disk failure'); END",
        )
        mcp.enqueue(unauthorized(), toolsList(), toolsList())
        stubAuthorization()
        approveInBrowser()
        val state = coordinator().add(ENDPOINT, McpAuthKind.Auto, confirmAuthorization = approve, progress = record)
        assertEquals("failing to save is not the same as failing to connect", McpAddState.SaveFailed, state)
        assertEquals("the UI receives exactly one terminal state", listOf<McpAddState>(McpAddState.SaveFailed), terminals)
        assertEquals(
            listOf(McpAddState.Connecting, AUTH_PROMPT, McpAddState.Browser, McpAddState.Finishing, McpAddState.SaveFailed),
            states.toList(),
        )
        assertNothingLeft("failure halfway through saving")
    }

    @Test
    fun `limit reached is decided before probing with no request and no browser`() = runBlocking {
        val existing = existingRecord()
        store.insertServer(existing)
        mcp.enqueue(unauthorized())
        stubAuthorization()
        approveInBrowser()
        val config = McpRuntimeConfig(maxServers = 1)
        val state = coordinator(config).add(ENDPOINT, McpAuthKind.Auto, confirmAuthorization = approve, progress = record)
        assertEquals(McpAddState.LimitReached(1), state)
        assertEquals(listOf<McpAddState>(McpAddState.LimitReached(1)), states.toList())
        assertTrue("at the limit the server must not be contacted", mcp.requests().isEmpty())
        assertTrue(auth.getUrls.isEmpty())
        assertTrue("nor should the user go through sign-in only to be refused", browser.openedUrls.isEmpty())
        assertEquals(listOf(existing), store.fetchAllServers())
        assertTrue(credentials.keys().isEmpty())
    }

    @Test
    fun `limit taken during probing maps to limitReached and the token is not kept`() = runBlocking {
        mcp.enqueue(unauthorized(), toolsList(), toolsList())
        stubAuthorization()
        approveInBrowser()
        val config = McpRuntimeConfig(maxServers = 1)
        // While the user sits on the pre-sign-in prompt, another addition fills the remaining slots.
        val gate: McpAuthorizationGate = {
            store.insertServer(existingRecord())
            true
        }
        val state = coordinator(config).add(ENDPOINT, McpAuthKind.Auto, serverId = "new", confirmAuthorization = gate, progress = record)
        assertEquals(McpAddState.LimitReached(1), state)
        assertEquals(listOf<McpAddState>(McpAddState.LimitReached(1)), terminals)
        assertEquals(listOf("existing"), store.fetchAllServers().map { it.id })
        assertNull(credentials.load("new", UID))
    }

    @Test
    fun `serverId collision is rejected before probing and the existing server is untouched`() = runBlocking {
        val existing = existingRecord()
        store.insertServer(existing)
        credentials.save(McpCredentials(accessToken = "keep-me"), existing.id, UID)
        mcp.enqueue(toolsList(), toolsList())

        // Id comparison is case-insensitive (UUID casing differs between clients).
        val state = coordinator().add(ENDPOINT, McpAuthKind.Auto, serverId = existing.id.uppercase(), progress = record)
        assertEquals(McpAddState.SaveFailed, state)
        assertTrue("no probing", mcp.requests().isEmpty())
        assertEquals(listOf(existing), store.fetchAllServers())
        assertEquals("the existing server's credential is untouched", "keep-me", credentials.load(existing.id, UID)?.accessToken)
    }

    // ── Cancellation ───────────────────────────────────────

    @Test
    fun `cancelling at the auth prompt ends in cancelled with nothing registered opened or stored`() = runBlocking {
        mcp.enqueue(unauthorized())
        stubDcrAuthorization()
        approveInBrowser()
        val asked = CompletableDeferred<Unit>()
        val job = launch(Dispatchers.Default) {
            coordinator().add(
                ENDPOINT, McpAuthKind.Auto,
                confirmAuthorization = { asked.complete(Unit); CompletableDeferred<Boolean>().await() },
                progress = record,
            )
        }
        asked.await()
        job.cancelAndJoin()
        assertEquals(listOf<McpAddState>(McpAddState.Cancelled), terminals)
        assertEquals(listOf(McpAddState.Connecting, AUTH_PROMPT, McpAddState.Cancelled), states.toList())
        assertTrue(auth.jsonRequests.isEmpty())
        assertTrue(browser.openedUrls.isEmpty())
        assertNothingLeft("cancelled at the prompt")
    }

    @Test
    fun `cancelling while listing tools after login stores nothing`() = runBlocking {
        // After the probe with the token succeeds, the response to the real list read never arrives.
        mcp.enqueue(unauthorized(), toolsList(), toolsList().copy(delayMillis = 60_000))
        stubAuthorization()
        approveInBrowser()
        val job = launch(Dispatchers.Default) {
            coordinator().add(ENDPOINT, McpAuthKind.Auto, confirmAuthorization = approve, progress = record)
        }
        assertTrue(McpClientHarness.eventually { McpAddState.Finishing in states && mcp.requests().size == 3 })
        job.cancelAndJoin()
        assertEquals("precondition - the token really was obtained", 1, auth.formRequests.size)
        assertEquals(listOf<McpAddState>(McpAddState.Cancelled), terminals)
        assertNothingLeft("cancelled while reading the list")
    }

    @Test
    fun `cancelling while connecting is cancelled rather than unreachable`() = runBlocking {
        mcp.enqueue(toolsList().copy(delayMillis = 60_000))
        val job = launch(Dispatchers.Default) { coordinator().add(ENDPOINT, McpAuthKind.Auto, progress = record) }
        assertTrue(McpClientHarness.eventually { mcp.requests().size == 1 })
        job.cancelAndJoin()
        assertEquals(listOf(McpAddState.Connecting, McpAddState.Cancelled), states.toList())
        assertNothingLeft("cancelled while connecting")
    }

    /**
     * Saving the record and storing the credential cannot be cancelled; cancellation is handled once that section
     * is done. At that point both the record and the credential exist, so they can be removed cleanly,
     * and the terminal state is "cancelled". Here the cancellation lands at the moment the credential has just been
     * stored (the record is already saved).
     */
    @Test
    fun `cancelling while the record and credentials are being stored rolls both back and ends in cancelled`() = runBlocking {
        mcp.enqueue(unauthorized(), toolsList(), toolsList())
        lateinit var job: Job
        val result = CompletableDeferred<McpAddState>()
        job = launch(Dispatchers.Default, start = CoroutineStart.LAZY) {
            result.complete(coordinator().add(ENDPOINT, McpAuthKind.Token, token = "good", serverId = "s1", progress = record))
        }
        prefs.onWriteCommitted = {
            prefs.onWriteCommitted = null
            job.cancel()
        }
        job.start()
        job.join()

        assertEquals(McpAddState.Cancelled, withTimeout(5_000) { result.await() })
        assertEquals(listOf(McpAddState.Cancelled), terminals)
        assertNothingLeft("cancelled while saving")
    }

    /** The record written by the add flow stays flagged as pending until the user taps "Done": it occupies a slot but does not appear in the list. */
    @Test
    fun `the stored record is pending and unlisted until the addition is confirmed`() = runBlocking {
        mcp.enqueue(toolsList(), toolsList())
        val state = coordinator().add(ENDPOINT, McpAuthKind.Auto, serverId = "s1")
        val review = (state as McpAddState.Review).review

        assertTrue(store.fetchAllServers().isEmpty())
        assertEquals("but it does occupy a slot", 1, store.serverCount())

        assertTrue(store.confirmAddition("s1", review.tools.map { it.copy(pendingReview = false) }, review.defaultPermissions))

        assertEquals(listOf("s1"), store.fetchAllServers().map { it.id })
    }

    // ── Successful save ────────────────────────────────────

    @Test
    fun `success stores record snapshots permissions and connection state and emits one terminal`() = runBlocking {
        mcp.enqueue(toolsList(), toolsList())
        val state = coordinator().add(ENDPOINT, McpAuthKind.Auto, name = "Weather Hub", serverId = "s1", progress = record)

        assertTrue(state is McpAddState.Review)
        assertEquals(listOf(McpAddState.Connecting, McpAddState.Finishing, state), states.toList())
        val saved = store.fetchServer("s1")!!
        assertEquals("Weather Hub", saved.name)
        assertEquals("the slug is generated inside the write transaction", "weatherhub", saved.slug)
        assertEquals(ENDPOINT, saved.url)
        assertFalse(saved.localOnly)
        assertEquals(listOf("create_issue", "get_weather"), store.fetchToolSnapshots("s1").map { it.toolName })
        assertTrue(store.fetchToolSnapshots("s1").all { it.pendingReview })
        assertEquals(
            mapOf("get_weather" to McpToolPermission.Auto, "create_issue" to McpToolPermission.Ask),
            store.fetchToolPermissions("s1"),
        )
        val connection = store.fetchConnectionState("s1")!!
        assertEquals(McpConnectionStatus.Connected, connection.status)
        assertEquals(McpProtocol.MODERN_VERSION, connection.negotiatedVersion)
        assertEquals(McpProtocolGeneration.Stateless, connection.generation)
        assertNotNull(connection.lastSuccessAt)
        assertTrue("no credential without a sign-in", credentials.keys().isEmpty())
    }

    @Test
    fun `a second server with the same name gets a numeric slug suffix inside the transaction`() = runBlocking {
        mcp.enqueue(toolsList(), toolsList(), toolsList(), toolsList())
        coordinator().add(ENDPOINT, McpAuthKind.Auto, name = "Notion", serverId = "s1")
        coordinator().add("https://other.example.com/mcp", McpAuthKind.Auto, name = "Notion", serverId = "s2")
        // The second record is saved before "Done" was tapped on the first: a pending record occupies its slug too.
        assertEquals(listOf("notion", "notion2"), listOf("s1", "s2").map { store.fetchServer(it)!!.slug })
    }

    @Test
    fun `a pasted token is stored after the record and later calls carry it`() = runBlocking {
        mcp.enqueue(unauthorized(), toolsList(), toolsList())
        val state = coordinator().add(ENDPOINT, McpAuthKind.Token, token = "good", serverId = "s1")
        assertTrue(state is McpAddState.Review)
        assertEquals("good", credentials.load("s1", UID)?.pastedToken)
        assertEquals(McpAuthKind.Token, store.fetchServer("s1")?.authKind)

        // Rebuild the authorizer (equivalent to a restart): it still returns this token and requests carry it.
        val token = McpAuthorizer(auth, browser, credentials).validAccessToken("s1", UID)
        mcp.enqueue(toolsList())
        McpClient(ENDPOINT, transport = mcp).connect(token)
        assertEquals("Bearer good", mcp.requests().last().header("Authorization"))
    }

    @Test
    fun `a pasted token that cannot be stored fails the add and removes the record`() = runBlocking {
        mcp.enqueue(unauthorized(), toolsList(), toolsList())
        prefs.failWrites = true
        val state = coordinator().add(ENDPOINT, McpAuthKind.Token, token = "good", progress = record)
        assertEquals(McpAddState.SaveFailed, state)
        assertEquals(listOf<McpAddState>(McpAddState.SaveFailed), terminals)
        assertNothingLeft("the token cannot be stored")
    }

    @Test
    fun `browser login success persists the token only after the record is stored`() = runBlocking {
        mcp.enqueue(unauthorized(), toolsList(), toolsList())
        stubAuthorization()
        approveInBrowser()
        var tokenStoredWhileProbing = false
        val watching: McpAddProgress = { state ->
            states += state
            if (!state.isTerminal && credentials.keys().isNotEmpty()) tokenStoredWhileProbing = true
        }
        val state = coordinator().add(ENDPOINT, McpAuthKind.Auto, serverId = "s1", confirmAuthorization = approve, progress = watching)

        assertFalse("before the record is saved the token lives only in memory", tokenStoredWhileProbing)
        assertNull("the terminal state handed to the UI carries no token", (state as McpAddState.Review).review.pendingCredentials)
        val saved = credentials.load("s1", UID)!!
        assertEquals("mcp_at_example", saved.accessToken)
        assertEquals("https://mcp.example.com/mcp", saved.resource)
        assertNotNull(store.fetchServer("s1"))
        assertEquals("reconnects with the token", "Bearer mcp_at_example", mcp.requests().last().header("Authorization"))
    }

    @Test
    fun `duplicate tool names keep the first and the add still succeeds`() = runBlocking {
        val duplicated = toolsList { tools -> tools + tools.first() }
        mcp.enqueue(duplicated, duplicated)
        val state = coordinator().add(ENDPOINT, McpAuthKind.Auto, serverId = "s1")
        assertTrue(state is McpAddState.Review)
        assertEquals(listOf("create_issue", "get_weather"), store.fetchToolSnapshots("s1").map { it.toolName })
    }

    @Test
    fun `an empty name falls back to the host and long names are capped at 64 utf16 units without splitting clusters`() = runBlocking {
        mcp.enqueue(toolsList(), toolsList())
        coordinator().add(ENDPOINT, McpAuthKind.Auto, name = "   ", serverId = "s1")
        assertEquals("mcp.example.com", store.fetchServer("s1")?.name)

        assertEquals("a".repeat(64), McpAddCoordinator.capped("a".repeat(80)))
        // 63 ASCII characters plus an emoji that takes 2 code units: with it the length is 65, so it is dropped whole.
        assertEquals("a".repeat(63), McpAddCoordinator.capped("a".repeat(63) + "😀b"))
        val family = "👨‍👩‍👧"
        val capped = McpAddCoordinator.capped("a".repeat(60) + family)
        assertEquals("a grapheme cluster that does not fit is dropped whole", "a".repeat(60), capped)
        assertTrue(McpAddCoordinator.capped(family.repeat(20)).length <= McpServerRecord.MAX_NAME_LENGTH)
    }

    @Test
    fun `a url with secret traits is stored as localOnly`() = runBlocking {
        mcp.enqueue(toolsList(), toolsList())
        coordinator().add("https://mcp.example.com/mcp?key=abc", McpAuthKind.Auto, serverId = "s1")
        assertEquals(true, store.fetchServer("s1")?.localOnly)
    }

    // ── The full URL of a local-only server is stored as a credential ──────────

    /** Every row of `mcp_server`, each joined into one string across all columns. */
    private fun serverRows(): List<String> = db.query(SimpleSQLiteQuery("SELECT * FROM mcp_server")).use { cursor ->
        val rows = mutableListOf<String>()
        while (cursor.moveToNext()) rows += (0 until cursor.columnCount).joinToString("|") { cursor.getString(it) ?: "NULL" }
        rows
    }

    @Test
    fun `the production add path stores only the display url in room and the full url in its own credential key`() = runBlocking {
        val full = "https://mcp.example.com/k/abcdefghij0123456789secret/mcp?token=sk-query-secret"
        mcp.enqueue(unauthorized(), toolsList(), toolsList())
        val state = coordinator().add(full, McpAuthKind.Token, token = "pasted-token", serverId = "s1")
        assertTrue(state is McpAddState.Review)

        // The database row written by the production add path: no column contains any secret.
        val rows = serverRows()
        assertEquals(1, rows.size)
        for (secret in listOf("abcdefghij0123456789secret", "sk-query-secret", "token=", "pasted-token")) {
            assertFalse("the database must not contain $secret - $rows", rows.single().contains(secret))
        }
        val saved = store.fetchServer("s1")!!
        assertEquals("https://mcp.example.com/k/…/mcp", saved.url)
        assertTrue(saved.localOnly)

        // The full URL has its own credential key, separate from the tokens: it survives a full rewrite of the tokens.
        assertEquals(full, credentials.loadEndpoint("s1", UID))
        assertEquals(2, credentials.keys().size)
        credentials.save(McpCredentials(accessToken = "refreshed"), "s1", UID)
        assertEquals("rebuilding the credential on a token refresh does not wipe the full URL", full, credentials.loadEndpoint("s1", UID))

        // The request goes to the full URL; from then on the request URL comes from the credential store.
        assertTrue(mcp.requests().all { it.url == full })
        assertEquals(McpServerEndpointResolution.Ready(full), McpServerEndpoint.resolve(saved, UID, credentials))
        assertFalse("the full URL stays out of the string description", McpServerEndpoint.resolve(saved, UID, credentials).toString().contains("secret"))

        // Removing the server deletes the full URL together with the tokens.
        store.deleteServer("s1")
        assertTrue(credentials.keys().isEmpty())
    }

    @Test
    fun `a local-only server without its stored endpoint needs the address again and a clean one resolves from the record`() = runBlocking {
        val full = "https://mcp.example.com/mcp?token=sk-query-secret"
        mcp.enqueue(toolsList(), toolsList(), toolsList(), toolsList())
        coordinator().add(full, McpAuthKind.Auto, serverId = "s1")
        coordinator().add(ENDPOINT, McpAuthKind.Auto, serverId = "s2")

        // Restored from a backup onto a new device: the main database is back, the backup-excluded credential file is not.
        credentials.deleteEndpoint("s1", UID)
        assertEquals(
            "the display URL is never used to send requests",
            McpServerEndpointResolution.NeedsAddress,
            McpServerEndpoint.resolve(store.fetchServer("s1")!!, UID, credentials),
        )
        assertEquals(McpServerEndpointResolution.Ready(ENDPOINT), McpServerEndpoint.resolve(store.fetchServer("s2")!!, UID, credentials))
        // The full URL is stored per partition.
        credentials.saveEndpoint(full, "s1", UID)
        assertEquals(McpServerEndpointResolution.NeedsAddress, McpServerEndpoint.resolve(store.fetchServer("s1")!!, "other", credentials))
    }

    @Test
    fun `a full url that cannot be stored fails the add and leaves nothing behind`() = runBlocking {
        mcp.enqueue(toolsList(), toolsList())
        prefs.failWrites = true
        val state = coordinator().add("https://mcp.example.com/mcp?token=sk-query-secret", McpAuthKind.Auto, progress = record)
        assertEquals(McpAddState.SaveFailed, state)
        assertEquals(listOf<McpAddState>(McpAddState.SaveFailed), terminals)
        assertNothingLeft("the full URL cannot be stored")
    }

    @Test
    fun `every store write path keeps the secret out of room`() = runBlocking {
        val full = "https://mcp.example.com/abcdefghij0123456789secret?token=sk-query-secret"
        // Direct insert (the caller passes a full URL by mistake).
        store.insertServer(existingRecord().copy(id = "a", slug = "a", url = full, localOnly = true))
        assertEquals("https://mcp.example.com/…", store.fetchServer("a")?.url)

        // Edited to a URL with a secret: the full URL goes into the credential store and only the display URL is saved in the database.
        store.insertServer(existingRecord().copy(id = "b", slug = "b"))
        store.updateServer(store.fetchServer("b")!!.copy(url = full, localOnly = true, updatedAt = 5L))
        assertEquals("https://mcp.example.com/…", store.fetchServer("b")?.url)
        assertEquals(full, credentials.loadEndpoint("b", UID))
        assertTrue(serverRows().none { "secret" in it })

        // Rename only (a display URL is passed in): the full URL in the credential store is not overwritten by the display URL.
        store.updateServer(store.fetchServer("b")!!.copy(name = "Renamed", updatedAt = 6L))
        assertEquals(full, credentials.loadEndpoint("b", UID))

        // Changed back to a clean URL: the copy in the credential store is discarded.
        store.updateServer(store.fetchServer("b")!!.copy(url = ENDPOINT, localOnly = false, updatedAt = 7L))
        assertNull(credentials.loadEndpoint("b", UID))
        assertEquals(ENDPOINT, store.fetchServer("b")?.url)
    }

    // ── Saving the tool catalog ────────────────────────────

    @Test
    fun `new tools stay inbound until confirmed and a tool changed during confirmation stays quarantined`() = runBlocking {
        mcp.enqueue(toolsList(), toolsList())
        coordinator().add(ENDPOINT, McpAuthKind.Auto, serverId = "s1")
        val snapshots = store.fetchToolSnapshots("s1")
        val permissions = store.fetchToolPermissions("s1")
        assertTrue("nothing is sent out before confirmation", McpToolCatalog.outboundSnapshots(snapshots, permissions).isEmpty())

        // The server's current definitions at the time the user confirms: the description of `create_issue` was changed.
        val definitions = McpFixture.json("protocol/stateless/tools-list.response.json")["body"]["result"]["tools"].jsonArrayOrNull.orEmpty()
            .mapNotNull(McpToolDefinition::fromJson)
            .map { if (it.name == "create_issue") it.copy(description = "Delete everything") else it }
        val confirmation = McpToolCatalog.confirm(snapshots, definitions, permissions, McpRuntimeConfig.fallback)
        store.saveToolCatalog("s1", confirmation.snapshots, confirmation.permissions)

        assertEquals(listOf("create_issue"), confirmation.stillPending)
        val outbound = McpToolCatalog.outboundSnapshots(store.fetchToolSnapshots("s1"), store.fetchToolPermissions("s1"))
        assertEquals(listOf("get_weather"), outbound.map { it.toolName })
    }

    @Test
    fun `saveToolCatalog replaces snapshots and lowers permissions in one transaction`() = runBlocking {
        mcp.enqueue(toolsList(), toolsList())
        coordinator().add(ENDPOINT, McpAuthKind.Auto, serverId = "s1")
        val weather = store.fetchToolSnapshots("s1").first { it.toolName == "get_weather" }

        // Writing the permissions fails: the snapshot replacement must roll back too (never "let through but still set to run automatically").
        db.openHelper.writableDatabase.execSQL(
            "CREATE TRIGGER test_fail_permission BEFORE INSERT ON mcp_tool_permission " +
                "BEGIN SELECT RAISE(ABORT, 'simulated disk failure'); END",
        )
        val failed = runCatching {
            store.saveToolCatalog("s1", listOf(weather.copy(pendingReview = false, readOnly = false)), mapOf("get_weather" to McpToolPermission.Ask))
        }
        assertTrue(failed.isFailure)
        assertEquals("snapshots unchanged", 2, store.fetchToolSnapshots("s1").size)
        assertEquals(McpToolPermission.Auto, store.fetchToolPermissions("s1")["get_weather"])

        db.openHelper.writableDatabase.execSQL("DROP TRIGGER test_fail_permission")
        store.saveToolCatalog("s1", listOf(weather.copy(pendingReview = false, readOnly = false)), mapOf("get_weather" to McpToolPermission.Ask))
        assertEquals(listOf("get_weather"), store.fetchToolSnapshots("s1").map { it.toolName })
        assertFalse(store.fetchToolSnapshots("s1").single().pendingReview)
        assertEquals(McpToolPermission.Ask, store.fetchToolPermissions("s1")["get_weather"])
        assertEquals("permissions that were not listed are untouched", McpToolPermission.Ask, store.fetchToolPermissions("s1")["create_issue"])
    }

    private fun existingRecord() = McpServerRecord(
        id = "existing",
        name = "Existing",
        slug = "existing",
        url = "https://existing.example.com/mcp",
        authKind = McpAuthKind.Auto,
        localOnly = false,
        iconURL = null,
        createdAt = 1L,
        updatedAt = 1L,
    )

    private companion object {
        const val UID = LOCAL_PARTITION_ID
        const val CLIENT_METADATA_URL = "https://app.example.com/oauth/mcp-client.json"
        const val ENDPOINT = "https://mcp.example.com/mcp"
        const val PROTECTED_RESOURCE_URL = "https://mcp.example.com/.well-known/oauth-protected-resource"
        const val AUTHORIZATION_SERVER_URL = "https://auth.example.com/.well-known/oauth-authorization-server"
        const val REGISTRATION_URL = "https://auth.example.com/register"
        const val TOKEN_URL = "https://auth.example.com/token"

        val MCP_TABLES = listOf(
            "mcp_server", "mcp_connection_state", "mcp_tool_snapshot", "mcp_tool_permission",
            "mcp_conversation_switch", "mcp_step_payload",
        )

        /** The pre-sign-in prompt for the replayed authorization server. */
        val AUTH_PROMPT: McpAddState = McpAddState.AuthPrompt("auth.example.com")
    }
}
