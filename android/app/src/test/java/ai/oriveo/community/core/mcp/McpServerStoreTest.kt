package ai.oriveo.community.core.mcp

import android.content.Context
import androidx.room.Room
import androidx.sqlite.db.SimpleSQLiteQuery
import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.database.OriveoDatabase
import java.io.File
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
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
 * CRUD, limits and the credential boundary of MCP server records.
 *
 * Runs a real Room (in-memory database) and the real DAO; only the credential medium is swapped for in-memory prefs:
 * the medium changes, the semantics do not, and key construction and cleanup stay in production code.
 */
@RunWith(RobolectricTestRunner::class)
class McpServerStoreTest {

    private lateinit var db: OriveoDatabase
    private lateinit var credentials: McpCredentialStore
    private lateinit var grants: McpConversationGrants
    private lateinit var store: McpServerStore
    private var clock = 10_000L

    @Before
    fun setUp() {
        val context = RuntimeEnvironment.getApplication()
        db = Room.inMemoryDatabaseBuilder(context, OriveoDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        credentials = McpCredentialStore(
            context.getSharedPreferences("mcp-credential-test", Context.MODE_PRIVATE),
        )
        grants = McpConversationGrants()
        store = McpServerStore(
            dao = db.mcpServerDao(),
            credentials = credentials,
            now = { clock },
            grants = grants,
        )
    }

    @After
    fun tearDown() {
        db.close()
    }

    @Test
    fun `insert fetch and update round trip`() = runBlocking {
        val record = record(id = "s1", name = "Notion", slug = "notion")

        store.insertServer(record)

        assertEquals(listOf("Notion"), store.fetchAllServers().map { it.name })
        assertEquals("https://mcp.example.com/notion", store.fetchServer("s1")?.url)
        assertEquals(McpAuthKind.Auto, store.fetchServer("s1")?.authKind)
        assertNull("iconURL is nullable", store.fetchServer("s1")?.iconURL)
        assertEquals(1, store.serverCount())

        store.updateServer(
            record.copy(
                name = "Notion Workspace",
                url = "https://mcp.example.com/v2",
                authKind = McpAuthKind.Token,
                localOnly = true,
                iconURL = "https://mcp.example.com/icon.png",
                updatedAt = 9_000L,
            ),
        )

        val updated = store.fetchServer("s1")
        assertEquals("Notion Workspace", updated?.name)
        assertEquals("https://mcp.example.com/v2", updated?.url)
        assertEquals(McpAuthKind.Token, updated?.authKind)
        assertEquals(true, updated?.localOnly)
        assertEquals("https://mcp.example.com/icon.png", updated?.iconURL)
        assertEquals(9_000L, updated?.updatedAt)
        assertEquals("createdAt does not change on update", 1_000L, updated?.createdAt)
    }

    /** The slug is the tool-name prefix and never changes after creation: even if an update passes a different slug, the stored one must not move. */
    @Test
    fun `update never rewrites the slug even when a different one is passed in`() = runBlocking {
        store.insertServer(record(id = "s1", name = "Notion", slug = "notion"))

        store.updateServer(record(id = "s1", name = "Renamed", slug = "renamed"))

        assertEquals("renamed is the value passed in; the stored slug must still be notion", "notion", store.fetchServer("s1")?.slug)
        assertEquals("Renamed", store.fetchServer("s1")?.name)
        assertEquals("notion", rawString("SELECT slug FROM mcp_server WHERE id = 's1'"))
    }

    @Test
    fun `limit is enforced and falls back to twenty`() = runBlocking {
        assertEquals("built-in fallback", 20, McpRuntimeConfig.fallback.maxServers)

        repeat(20) { index ->
            store.insertServer(record(id = "s$index", name = "Server $index", slug = "srv$index"))
        }
        assertEquals(20, store.serverCount())

        val error = runCatching {
            store.insertServer(record(id = "s20", name = "One too many", slug = "srv20"))
        }.exceptionOrNull()
        assertTrue("the 21st must be blocked by the limit", error is McpStoreError.LimitReached)
        assertEquals(20, (error as McpStoreError.LimitReached).max)
        assertEquals("nothing is stored when over the limit", 20, store.serverCount())

        // The limit is a parameter: an explicitly passed smaller value applies just the same.
        val tight = runCatching { store.insertServer(record(id = "tight", slug = "tight"), maxServers = 1) }
            .exceptionOrNull()
        assertTrue(tight is McpStoreError.LimitReached)
        assertEquals(1, (tight as McpStoreError.LimitReached).max)
    }

    /** The limit check and the insert share one write transaction: concurrent adds cannot cross the limit together. */
    @Test
    fun `concurrent inserts cannot overshoot the limit`() = runBlocking {
        val outcomes = (0 until 12).map { index ->
            async(kotlinx.coroutines.Dispatchers.IO) {
                runCatching {
                    store.insertServer(record(id = "s$index", name = "Server $index", slug = "srv$index"), maxServers = 5)
                }
            }
        }.awaitAll()

        assertEquals(5, outcomes.count { it.isSuccess })
        assertTrue(outcomes.filter { it.isFailure }.all { it.exceptionOrNull() is McpStoreError.LimitReached })
        assertEquals(5, store.serverCount())
    }

    @Test
    fun `slug collision is rejected and unique slug picks a free suffix`() = runBlocking {
        store.insertServer(record(id = "s1", name = "Notion", slug = "notion"))

        val error = runCatching {
            store.insertServer(record(id = "s2", name = "Notion Backup", slug = "notion"))
        }.exceptionOrNull()
        assertTrue(
            "a slug collision must be a distinguishable SlugConflict, not the raw constraint exception of the unique index: $error",
            error is McpStoreError.SlugConflict,
        )
        assertEquals("notion", (error as McpStoreError.SlugConflict).slug)
        assertEquals("nothing is stored on a collision", 1, store.serverCount())

        // uniqueSlug has no side effects: the next candidate only advances after a real insert.
        assertEquals("notion2", store.uniqueSlug("Notion"))
        assertEquals("asking again without inserting gives the same answer", "notion2", store.uniqueSlug("Notion"))
        store.insertServer(record(id = "s2", name = "Notion", slug = store.uniqueSlug("Notion")))
        assertEquals("notion3", store.uniqueSlug("Notion"))
        store.insertServer(record(id = "s3", name = "Notion", slug = store.uniqueSlug("Notion")))
        assertEquals("notion4", store.uniqueSlug("Notion"))
        assertEquals(listOf("notion", "notion2", "notion3"), store.fetchAllServers().map { it.slug })
    }

    /** The shared fixture is replayed case by case. A slug contains only `[a-z0-9]` and never `-`. */
    @Test
    fun `slug make replays the shared fixture vectors`() {
        val cases = fixture().getJSONObject("slugMake").getJSONArray("cases")
        assertTrue("the fixture must not be empty", cases.length() > 0)
        for (index in 0 until cases.length()) {
            val case = cases.getJSONObject(index)
            val slug = McpSlug.make(case.getString("name"))
            assertEquals(case.getString("caseId"), case.getString("expect"), slug)
            assertTrue(
                "${case.getString("caseId")}: slug must match [a-z0-9]{1,16}, got $slug",
                SLUG_SHAPE.matches(slug),
            )
        }
    }

    @Test
    fun `slug unique replays the shared fixture vectors`() {
        val cases = fixture().getJSONObject("slugUnique").getJSONArray("cases")
        assertTrue("the fixture must not be empty", cases.length() > 0)
        for (index in 0 until cases.length()) {
            val case = cases.getJSONObject(index)
            val existingJson = case.getJSONArray("existing")
            val existing = (0 until existingJson.length()).map { existingJson.getString(it) }.toSet()
            val slug = McpSlug.unique(case.getString("name"), existing)
            assertEquals(case.getString("caseId"), case.getString("expect"), slug)
            assertTrue(
                "${case.getString("caseId")}: slug must match [a-z0-9]{1,16}, got $slug",
                SLUG_SHAPE.matches(slug),
            )
            assertFalse("the result must not collide with an existing one", slug in existing)
        }
    }

    /** When the suffix gains digits, room is made at the tail of the candidate; the result always stays ≤ 16 and collision-free. */
    @Test
    fun `slug unique keeps within sixteen characters as the suffix grows`() {
        val existing = mutableSetOf<String>()
        repeat(120) {
            val slug = McpSlug.unique("averylongservername", existing)
            assertTrue("got $slug", SLUG_SHAPE.matches(slug))
            assertTrue("each one must be a new value", existing.add(slug))
        }
        assertTrue("averylongserve10" in existing)
        assertTrue("averylongserv100" in existing)
    }

    // ── Local state ────────────────────────────────────────

    @Test
    fun `connection state snapshots permissions switches and payloads round trip`() = runBlocking {
        store.insertServer(record(id = "s1", name = "Notion", slug = "notion"))
        store.setToolPermission(McpToolPermission.Auto, serverId = "s1", toolName = "delete_page")
        store.setServerEnabled(true, conversationId = "c1", serverId = "s1")
        store.saveConnectionState(
            McpConnectionState(
                serverId = "s1",
                status = McpConnectionStatus.Connected,
                lastSuccessAt = 5L,
                negotiatedVersion = "2025-11-25",
                generation = McpProtocolGeneration.Session,
                sessionId = "session-1",
            ),
        )
        store.replaceToolSnapshots("s1", listOf(snapshot("delete_page")))
        store.saveStepPayload(messageId = "m1", stepId = "step-1", arguments = "{\"a\":1}", resultPrefix = "ok")

        assertEquals(mapOf("delete_page" to McpToolPermission.Auto), store.fetchToolPermissions("s1"))
        assertEquals(listOf("s1"), store.fetchEnabledServerIds("c1"))
        assertEquals("session-1", store.fetchConnectionState("s1")?.sessionId)
        assertEquals(McpProtocolGeneration.Session, store.fetchConnectionState("s1")?.generation)
        assertEquals(listOf("delete_page"), store.fetchToolSnapshots("s1").map { it.toolName })
        assertEquals(McpStepPayload("{\"a\":1}", "ok"), store.fetchStepPayload("m1", "step-1"))

        assertEquals("ids are matched case-insensitively", listOf("s1"), store.fetchEnabledServerIds("C1"))
        assertEquals(mapOf("delete_page" to McpToolPermission.Auto), store.fetchToolPermissions("S1"))
        assertEquals(emptyMap<String, McpToolPermission>(), store.fetchToolPermissions("s2"))
        assertNull(store.fetchConnectionState("s2"))
    }

    /** Payloads arrive in two parts (arguments with the first callback, the result with the terminal state): the null column of the later one must not erase the earlier one. */
    @Test
    fun `a later step payload write keeps the column it does not carry`() = runBlocking {
        store.saveStepPayload(messageId = "m1", stepId = "1:c1", arguments = "{\"a\":1}", resultPrefix = null)
        store.saveStepPayload(messageId = "m1", stepId = "1:c1", arguments = null, resultPrefix = "ok")

        assertEquals(McpStepPayload("{\"a\":1}", "ok"), store.fetchStepPayload("m1", "1:c1"))
        assertNull("other steps are unaffected", store.fetchStepPayload("m1", "2:c2"))
    }

    // ── Addresses that carry a secret ────────────────────────────────────────

    /** The database holds a display address only; the full address lives in the credential store. */
    @Test
    fun `a secret-bearing address is stored as a display address and the full one stays in the credential store`() = runBlocking {
        val full = "https://mcp.example.com/$SECRET_SEGMENT/mcp?token=$SECRET_QUERY"
        store.insertServer(record(id = "s1", name = "Private", slug = "private").copy(url = full, localOnly = true))

        assertEquals("https://mcp.example.com/\u2026/mcp", store.fetchServer("s1")?.url)
        assertNull("inserting a record does not write the credential store", credentials.loadEndpoint("s1", LOCAL_PARTITION_ID))

        // The user changes the address: the full form goes to the credential store first, the display form to the database.
        val changed = "https://mcp.example.com/mcp?key=$SECRET_QUERY"
        store.updateServer(record(id = "s1", name = "Private", slug = "private").copy(url = changed, localOnly = true))
        assertEquals(changed, credentials.loadEndpoint("s1", LOCAL_PARTITION_ID))
        assertEquals("https://mcp.example.com/mcp", store.fetchServer("s1")?.url)

        // Only the name changes: the display address passed back in must not overwrite the full one.
        store.updateServer(store.fetchServer("s1")!!.copy(name = "Renamed"))
        assertEquals(changed, credentials.loadEndpoint("s1", LOCAL_PARTITION_ID))
        assertEquals("Renamed", store.fetchServer("s1")?.name)

        val dump = dumpMcpTables()
        assertFalse("no secret may appear in any cell of any MCP table", dump.contains(SECRET_QUERY) || dump.contains(SECRET_SEGMENT))

        // The address no longer carries a secret: it lives in the record and the stored full address is dropped.
        store.updateServer(store.fetchServer("s1")!!.copy(url = "https://mcp.example.com/mcp", localOnly = false))
        assertNull(credentials.loadEndpoint("s1", LOCAL_PARTITION_ID))
        assertEquals("https://mcp.example.com/mcp", store.fetchServer("s1")?.url)
    }

    @Test
    fun `a failed write of the full address leaves the record untouched`() = runBlocking {
        val failing = McpServerStore(
            dao = db.mcpServerDao(),
            credentials = McpCredentialStore(prefsProvider = { error("keystore unavailable") }),
            now = { clock },
        )
        store.insertServer(record(id = "s1", name = "Notion", slug = "notion"))

        val error = runCatching {
            failing.updateServer(
                record(id = "s1", name = "Changed", slug = "notion")
                    .copy(url = "https://mcp.example.com/mcp?token=$SECRET_QUERY", localOnly = true),
            )
        }.exceptionOrNull()

        assertTrue("the failure must be thrown: $error", error is McpCredentialStoreException)
        assertEquals("Notion", store.fetchServer("s1")?.name)
        assertEquals("https://mcp.example.com/notion", store.fetchServer("s1")?.url)
        assertEquals(false, store.fetchServer("s1")?.localOnly)
    }

    // ── Additions awaiting confirmation ────────────────────────────────────────

    @Test
    fun `an unconfirmed addition is hidden and swept with its local state and credentials`() = runBlocking {
        val record = store.addServer(addition(id = "p1", name = "Notion", createdAt = 100L), maxServers = 5)
        assertEquals("notion", record.slug)
        credentials.save(McpCredentials(accessToken = "pending-token"), serverId = "p1", uid = LOCAL_PARTITION_ID)
        grants.grant(conversationId = "c1", serverId = "p1", toolName = "search")
        store.addServer(addition(id = "p2", name = "Linear", createdAt = 900L), maxServers = 5)
        store.addServer(addition(id = "done", name = "Done", createdAt = 50L, pendingAdd = false), maxServers = 5)

        assertEquals("pending additions are not listed", listOf("done"), store.fetchAllServers().map { it.id })
        assertEquals(listOf("search"), store.fetchToolSnapshots("p1").map { it.toolName })

        assertEquals("only records stored before the given moment are swept", 1, store.sweepUnconfirmedAdditions(createdBefore = 500L))

        assertNull(store.fetchServer("p1"))
        assertEquals("p2", store.fetchServer("p2")?.id)
        assertEquals("a confirmed server is never swept", "done", store.fetchServer("done")?.id)
        listOf("mcp_connection_state", "mcp_tool_snapshot", "mcp_tool_permission").forEach { table ->
            assertEquals("$table must be cleaned along with it", 0, countRows(table, "serverId = 'p1'"))
        }
        assertNull(credentials.load(serverId = "p1", uid = LOCAL_PARTITION_ID))
        assertFalse(grants.isGranted(conversationId = "c1", serverId = "p1", toolName = "search"))
    }

    @Test
    fun `confirming an addition lists the server and it survives the sweep`() = runBlocking {
        store.addServer(addition(id = "p1", name = "Notion", createdAt = 100L), maxServers = 5)

        assertTrue(
            store.confirmAddition(
                serverId = "p1",
                snapshots = listOf(snapshot("search")),
                permissions = mapOf("search" to McpToolPermission.Ask),
            ),
        )

        assertEquals(listOf("p1"), store.fetchAllServers().map { it.id })
        assertEquals(listOf(false), store.fetchToolSnapshots("p1").map { it.pendingReview })
        assertEquals(mapOf("search" to McpToolPermission.Ask), store.fetchToolPermissions("p1"))
        assertEquals(0, store.sweepUnconfirmedAdditions(createdBefore = Long.MAX_VALUE))
        assertEquals("p1", store.fetchServer("p1")?.id)
        assertFalse("a record that is gone cannot be confirmed", store.confirmAddition("missing", emptyList(), emptyMap()))
    }

    @Test
    fun `adding a server generates a unique slug and refuses an id that is already stored`() = runBlocking {
        store.addServer(addition(id = "a1", name = "Notion", createdAt = 1L, pendingAdd = false), maxServers = 2)
        val second = store.addServer(addition(id = "a2", name = "Notion", createdAt = 2L, pendingAdd = false), maxServers = 2)
        assertEquals("notion2", second.slug)

        val limit = runCatching { store.addServer(addition(id = "a3", name = "Third", createdAt = 3L), maxServers = 2) }
            .exceptionOrNull()
        assertTrue("$limit", limit is McpStoreError.LimitReached)

        val exists = runCatching { store.addServer(addition(id = "A1", name = "Other", createdAt = 4L), maxServers = 9) }
            .exceptionOrNull()
        assertTrue("$exists", exists is McpStoreError.ServerExists)
        assertEquals("the existing row is left untouched", "Notion", store.fetchServer("a1")?.name)
        assertTrue(store.serverExists("A1"))
        assertFalse(store.serverExists("a3"))
    }

    // ── Allow for the rest of this conversation ────────────────────────────────────────

    @Test
    fun `a permission change a catalog change and a removal revoke conversation grants`() = runBlocking {
        store.insertServer(record(id = "s1", name = "Notion", slug = "notion"))
        store.replaceToolSnapshots("s1", listOf(snapshot("search"), snapshot("write"), snapshot("keep")))
        fun grantAll() = listOf("search", "write", "keep").forEach { grants.grant("c1", "s1", it) }
        fun granted() = listOf("search", "write", "keep").filter { grants.isGranted("c1", "S1", it) }

        grantAll()
        store.setToolPermission(McpToolPermission.Ask, serverId = "s1", toolName = "search")
        assertEquals("only the tool whose permission was set loses its grant", listOf("write", "keep"), granted())

        grantAll()
        store.saveToolCatalog(
            serverId = "s1",
            // `search` changed its definition, `write` disappeared, `keep` is unchanged.
            snapshots = listOf(snapshot("search").copy(contentHash = "changed"), snapshot("keep")),
            permissions = emptyMap(),
        )
        assertEquals(listOf("keep"), granted())

        grantAll()
        store.deleteServer("s1")
        assertEquals(emptyList<String>(), granted())
    }

    // ── Unrecognized values ────────────────────────────────────────

    /** An `authKind` written by a newer version of the app is not recognized: the whole row is skipped, not guessed as auto, and does not count towards the limit. */
    @Test
    fun `row with an unknown auth kind is skipped and does not count toward the limit`() = runBlocking {
        store.insertServer(record(id = "s1", name = "Known", slug = "known"))
        db.openHelper.writableDatabase.execSQL(
            "INSERT INTO mcp_server (id, accountId, name, slug, url, authKind, localOnly, iconURL, " +
                "createdAt, updatedAt, pendingAdd) " +
                "VALUES ('future', '$LOCAL_PARTITION_ID', 'Future', 'future', 'https://x.example.com', 'passkey', 0, NULL, 1, 1, 0)",
        )

        assertEquals(listOf("Known"), store.fetchAllServers().map { it.name })
        assertNull("an unrecognized sign-in method must not be silently rewritten to auto", store.fetchServer("future"))
        assertEquals("invisible rows do not count towards the limit", 1, store.serverCount())

        // Limit 2: only 1 is visible, so 1 more can be added.
        store.insertServer(record(id = "s2", name = "Second", slug = "second"), maxServers = 2)
        assertTrue(
            runCatching { store.insertServer(record(id = "s3", slug = "third"), maxServers = 2) }
                .exceptionOrNull() is McpStoreError.LimitReached,
        )

        // Its slug still occupies the tool-name prefix though: a collision is still blocked and candidates steer around it.
        assertTrue(
            runCatching { store.insertServer(record(id = "s4", slug = "future"), maxServers = 9) }
                .exceptionOrNull() is McpStoreError.SlugConflict,
        )
        assertEquals("future2", store.uniqueSlug("Future"))
        assertEquals("not a single character of the original row was rewritten", "passkey", rawString("SELECT authKind FROM mcp_server WHERE id = 'future'"))
    }

    // ── Removal ────────────────────────────────────────

    @Test
    fun `removing a server clears its local state and its credentials`() = runBlocking {
        store.insertServer(record(id = "s1", name = "Notion", slug = "notion"))
        store.insertServer(record(id = "s2", name = "Linear", slug = "linear"))
        listOf("s1", "s2").forEach { serverId ->
            store.saveConnectionState(McpConnectionState(serverId = serverId, status = McpConnectionStatus.Connected))
            store.replaceToolSnapshots(serverId, listOf(snapshot("search")))
            store.setToolPermission(McpToolPermission.Ask, serverId = serverId, toolName = "search")
            store.setServerEnabled(true, conversationId = "c1", serverId = serverId)
            credentials.save(McpCredentials(accessToken = "secret-$serverId"), serverId = serverId, uid = LOCAL_PARTITION_ID)
        }
        store.saveStepPayload(messageId = "m1", stepId = "step-1", arguments = "{}", resultPrefix = "ok")

        store.deleteServer("s1")

        assertNull(store.fetchServer("s1"))
        assertEquals(1, store.serverCount())
        listOf("mcp_connection_state", "mcp_tool_snapshot", "mcp_tool_permission", "mcp_conversation_switch")
            .forEach { table ->
                assertEquals("$table must be cleaned along with it", 0, countRows(table, "serverId = 's1'"))
                assertEquals("other servers in $table are unaffected", 1, countRows(table, "serverId = 's2'"))
            }
        assertNull("removing a server must clear the on-device credentials", credentials.load(serverId = "s1", uid = LOCAL_PARTITION_ID))
        assertEquals("secret-s2", credentials.load(serverId = "s2", uid = LOCAL_PARTITION_ID)?.accessToken)
        assertEquals("tool records in existing conversations are kept", McpStepPayload("{}", "ok"), store.fetchStepPayload("m1", "step-1"))
    }

    /** A removal that stopped halfway may have left credentials behind: removing again clears them even though the record is gone. */
    @Test
    fun `removing an id without a record still clears leftover credentials`() = runBlocking {
        credentials.save(McpCredentials(pastedToken = "leftover-token"), serverId = "gone", uid = LOCAL_PARTITION_ID)
        credentials.saveEndpoint("https://mcp.example.com/mcp?token=$SECRET_QUERY", serverId = "gone", uid = LOCAL_PARTITION_ID)

        store.deleteServer("gone")

        assertNull(credentials.load(serverId = "gone", uid = LOCAL_PARTITION_ID))
        assertNull(credentials.loadEndpoint(serverId = "gone", uid = LOCAL_PARTITION_ID))
    }

    /** Removal is one transaction: on a mid-way failure the record and the local state are either all there or all gone. */
    @Test
    fun `removal is atomic when a later step fails`() = runBlocking {
        store.insertServer(record(id = "s1", name = "Notion", slug = "notion"))
        store.setToolPermission(McpToolPermission.Ask, serverId = "s1", toolName = "search")
        store.setServerEnabled(true, conversationId = "c1", serverId = "s1")
        // Make a later step of the cascade (deleting the conversation switches) fail for sure.
        db.openHelper.writableDatabase.execSQL(
            "CREATE TRIGGER fail_switch_delete BEFORE DELETE ON mcp_conversation_switch " +
                "BEGIN SELECT RAISE(ABORT, 'injected failure'); END",
        )

        val error = runCatching { store.deleteServer("s1") }.exceptionOrNull()

        assertTrue("the injected failure must be thrown: $error", error != null)
        assertEquals("the server record must still exist after the failure", "Notion", store.fetchServer("s1")?.name)
        assertEquals(1, countRows("mcp_tool_permission", "serverId = 's1'"))
        assertEquals(1, countRows("mcp_conversation_switch", "serverId = 's1'"))
    }

    // ── Local state details ────────────────────────────────────────

    @Test
    fun `tool snapshots are replaced as a whole and pending review can be toggled`() = runBlocking {
        store.replaceToolSnapshots("s1", listOf(snapshot("b_tool"), snapshot("a_tool")))
        assertEquals(listOf("a_tool", "b_tool"), store.fetchToolSnapshots("s1").map { it.toolName })

        store.setToolPendingReview("s1", "a_tool", pendingReview = true)
        assertEquals(listOf(true, false), store.fetchToolSnapshots("s1").map { it.pendingReview })

        store.replaceToolSnapshots("s1", listOf(snapshot("c_tool").copy(description = null, oversized = true)))
        val only = store.fetchToolSnapshots("s1").single()
        assertEquals("c_tool", only.toolName)
        assertNull("description is nullable (the server may omit it)", only.description)
        assertTrue(only.oversized)
    }

    @Test
    fun `conversation switch keeps first enable time and can be turned off`() = runBlocking {
        clock = 100L
        store.setServerEnabled(true, conversationId = "c1", serverId = "s2")
        clock = 200L
        store.setServerEnabled(true, conversationId = "c1", serverId = "s1")
        clock = 300L
        store.setServerEnabled(true, conversationId = "c1", serverId = "s2")

        assertEquals("enabling again does not change the order", listOf("s2", "s1"), store.fetchEnabledServerIds("c1"))

        store.setServerEnabled(false, conversationId = "c1", serverId = "s2")
        assertEquals(listOf("s1"), store.fetchEnabledServerIds("c1"))
        assertEquals(emptyList<String>(), store.fetchEnabledServerIds("c2"))
    }

    @Test
    fun `step payload is capped by utf8 bytes without splitting a character`() = runBlocking {
        val arguments = "あ".repeat(6_000) // 3 bytes × 6000 = 18 KB, over the 16 KB limit
        val result = "a".repeat(2_047) + "😀" + "tail" // byte 2048 falls in the middle of a 4-byte character

        store.saveStepPayload(messageId = "m1", stepId = "step-1", arguments = arguments, resultPrefix = result)

        val payload = store.fetchStepPayload("m1", "step-1")!!
        val storedArguments = payload.arguments!!
        assertTrue(storedArguments.toByteArray(Charsets.UTF_8).size <= McpServerStore.MAX_STEP_ARGUMENTS_BYTES)
        assertEquals("truncated on a whole character", "あ".repeat(McpServerStore.MAX_STEP_ARGUMENTS_BYTES / 3), storedArguments)
        assertEquals("a 4-byte character that does not fit is dropped whole, leaving no half surrogate pair", "a".repeat(2_047), payload.resultPrefix)
    }

    /** Credentials never enter Room: `mcp_server` has not a single credential column. */
    @Test
    fun `credential never lands in the server table`() = runBlocking {
        store.insertServer(record(id = "s1", name = "Notion", slug = "notion"))
        val token = "sk-mcp-top-secret-token"
        credentials.save(McpCredentials(accessToken = token, pastedToken = token), serverId = "s1", uid = LOCAL_PARTITION_ID)

        val columns = db.query(SimpleSQLiteQuery("SELECT * FROM mcp_server")).use { cursor ->
            cursor.moveToFirst()
            (0 until cursor.columnCount).map { cursor.getColumnName(it) }.toSet()
        }
        assertEquals(
            setOf(
                "id", "accountId", "name", "slug", "url", "authKind", "localOnly", "iconURL",
                "createdAt", "updatedAt", "pendingAdd",
            ),
            columns,
        )

        assertFalse("the token must not appear in any cell of any MCP table", dumpMcpTables().contains(token))
    }

    // ── helpers ──────────────────────────────────────────────────────────

    /** Every cell of every MCP table, as text. */
    private fun dumpMcpTables(): String = MCP_TABLES.joinToString("\n") { table ->
        db.query(SimpleSQLiteQuery("SELECT * FROM $table")).use { cursor ->
            buildString {
                while (cursor.moveToNext()) {
                    append((0 until cursor.columnCount).joinToString("|") { cursor.getString(it).orEmpty() })
                    append('\n')
                }
            }
        }
    }

    private fun fixture(): JSONObject {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val candidate = File(dir, "shared/test-fixtures/mcp/identifiers.json")
            if (candidate.isFile) return JSONObject(candidate.readText())
            dir = dir.parentFile
        }
        error("shared/test-fixtures/mcp/identifiers.json not found")
    }

    private fun countRows(table: String, where: String): Int =
        db.query(SimpleSQLiteQuery("SELECT COUNT(*) FROM $table WHERE $where")).use { cursor ->
            cursor.moveToFirst()
            cursor.getInt(0)
        }

    private fun rawString(sql: String): String? =
        db.query(SimpleSQLiteQuery(sql)).use { cursor ->
            if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getString(0) else null
        }

    private fun snapshot(toolName: String) = McpToolSnapshot(
        serverId = "ignored-in-favour-of-the-parameter",
        toolName = toolName,
        title = toolName,
        description = "desc",
        inputSchema = kotlinx.serialization.json.JsonObject(emptyMap()),
        annotations = kotlinx.serialization.json.JsonObject(emptyMap()),
        contentHash = "hash-$toolName",
        readOnly = false,
        updatedAt = 1L,
    )

    private fun addition(id: String, name: String, createdAt: Long, pendingAdd: Boolean = true) = McpServerAddition(
        id = id,
        name = name,
        url = "https://mcp.example.com/$id",
        authKind = McpAuthKind.Auto,
        localOnly = false,
        iconURL = null,
        createdAt = createdAt,
        snapshots = listOf(snapshot("search").copy(pendingReview = pendingAdd)),
        permissions = mapOf("search" to McpToolPermission.Ask),
        connectionState = McpConnectionState(serverId = id, status = McpConnectionStatus.Connected),
        pendingAdd = pendingAdd,
    )

    private fun record(
        id: String,
        name: String = "Server",
        slug: String = "server",
    ) = McpServerRecord(
        id = id,
        name = name,
        slug = slug,
        url = "https://mcp.example.com/notion",
        authKind = McpAuthKind.Auto,
        localOnly = false,
        iconURL = null,
        createdAt = 1_000L,
        updatedAt = 2_000L,
    )

    private companion object {
        const val SECRET_QUERY = "sk-query-0123456789"
        const val SECRET_SEGMENT = "abcdefghij0123456789zz"
        val SLUG_SHAPE = Regex("[a-z0-9]{1,16}")
        val MCP_TABLES = listOf(
            "mcp_server",
            "mcp_connection_state",
            "mcp_tool_snapshot",
            "mcp_tool_permission",
            "mcp_conversation_switch",
            "mcp_step_payload",
        )
    }
}
