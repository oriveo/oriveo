package ai.oriveo.community.feature.providers.detail

import ai.oriveo.community.R
import ai.oriveo.community.core.data.entity.ProviderEntity
import ai.oriveo.community.core.data.mapper.ProviderMapper
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayKey
import ai.oriveo.community.core.model.RelayKeyStatus
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.RelayService
import ai.oriveo.community.core.provider.relay.RelayKeyBinding
import ai.oriveo.community.core.provider.transport.TransportRegistry
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import java.util.Collections
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Keys page (BOARD-KEYS-01 to 18): row content, status words and actions come from the production [RelayKeysBoardModel.build];
 * 03 to 07 first persist through the production [ProviderRepository] key operations (upstream MockEngine; the persisted object goes through production
 * ProviderMapper encode/decode), then the board is built from the persisted connection and asserted.
 */
class RelayKeysBoardTest {

    private fun model(id: String, listedBy: List<String>? = null, keyID: String? = null) =
        AIModel(id = id, name = id, relayListedByKeyIDs = listedBy, relayKeyID = keyID)

    private fun relayProvider(
        keys: List<RelayKey>?,
        catalog: List<AIModel> = emptyList(),
        enabled: List<AIModel> = emptyList(),
        authMode: RelayAuthMode = RelayAuthMode.Auto,
    ) = Provider(
        id = PROVIDER_ID,
        kind = ProviderKind.Relay,
        customName = "myrelay.dev",
        status = ProviderConnectionState.Connected,
        baseUrlText = "https://api.myrelay.dev/v1",
        apiKey = "sk-a-000000000001",
        relayKind = RelayKind.OpenAICompatible,
        relayRequested = RelayRequestedConfig(
            transport = RelayTransport.OpenAIChatCompletions,
            resolvedAPIBaseURL = "https://api.myrelay.dev/v1",
            authMode = authMode,
        ),
        relayKeys = keys,
        models = enabled,
        catalogModels = catalog,
    )

    // ── BOARD-KEYS-01: per-key row content and the six status words ──

    @Test
    fun `BOARD-KEYS-01 rows show name or mask, primary badge, status word, catalog and enabled counts`() {
        val provider = relayProvider(
            keys = listOf(
                RelayKey("initial", name = "Main", status = RelayKeyStatus("ok", 200, 1_000L)),
                RelayKey("k-b", apiKey = "sk-b-000000000002", status = RelayKeyStatus("invalid", 401, 2_000L)),
                RelayKey("k-c", name = "Team", apiKey = "sk-c-000000000003", status = RelayKeyStatus("denied", 403)),
                RelayKey("k-d", apiKey = "sk-d-000000000004", status = RelayKeyStatus("limited", 429, 3_000L)),
                RelayKey("k-e", apiKey = "sk-e-000000000005", status = RelayKeyStatus("failed")),
                RelayKey("k-f", apiKey = "sk-f-000000000006"),
            ),
            catalog = listOf(model("gpt-4o", listOf("initial", "k-b")), model("claude-opus-4", listOf("k-b"))),
            enabled = listOf(model("gpt-4o", keyID = "initial"), model("claude-opus-4", keyID = "k-b"), model("o3", keyID = "k-b")),
        )
        val board = RelayKeysBoardModel.build(provider)

        assertEquals("api.myrelay.dev", board.host)
        assertEquals(6, board.keyCount)
        assertTrue(board.showsPrimaryHint)
        assertTrue(board.showsAdd)
        assertEquals(
            listOf(
                R.string.relay_key_status_ok,
                R.string.relay_key_status_invalid,
                R.string.relay_key_status_denied,
                R.string.relay_key_status_limited,
                R.string.relay_key_status_failed,
                null,
            ),
            board.rows.map { it.statusRes },
        )
        val primary = board.rows[0]
        assertEquals("Main", primary.title)
        assertEquals("sk-a…0001", primary.maskedSecret)
        assertTrue(primary.showsPrimaryBadge)
        assertEquals(1, primary.catalogCount)
        assertEquals(1, primary.enabledCount)
        assertNull("ok shows no last-status line", primary.lastStatus)

        val second = board.rows[1]
        assertEquals("no name falls back to the mask", "sk-b…0002", second.title)
        assertFalse(second.showsPrimaryBadge)
        assertEquals(2, second.catalogCount)
        assertEquals(2, second.enabledCount)
        assertEquals(RelayKeyLastStatus(401, R.string.relay_key_status_invalid, 2_000L), second.lastStatus)

        assertEquals("Team", board.rows[2].title)
        assertNull("no catalog entries listed by it -> dash", board.rows[2].catalogCount)
        assertEquals("last-status line is shown even without a check time", RelayKeyLastStatus(403, R.string.relay_key_status_denied, null), board.rows[2].lastStatus)
        assertNull("no last-status line without httpStatus", board.rows[4].lastStatus)
        assertNull("no last-status line when never checked", board.rows[5].lastStatus)
    }

    // ── BOARD-KEYS-02: implicit single key ──

    @Test
    fun `BOARD-KEYS-02 an implicit single key is one row without name badge order or delete`() {
        val board = RelayKeysBoardModel.build(relayProvider(keys = null, catalog = listOf(model("gpt-4o")), enabled = listOf(model("gpt-4o"))))

        assertEquals(1, board.keyCount)
        assertFalse(board.showsPrimaryHint)
        assertTrue("replace key uses the existing single-key replace path", board.replaceUsesSingleKeyPath)
        val row = board.rows.single()
        assertEquals("sk-a…0001", row.title)
        assertFalse(row.showsPrimaryBadge)
        assertEquals(listOf(RelayKeyAction.ViewModels, RelayKeyAction.Replace), row.actions)
        assertFalse(row.showsPrimaryNotDeletable)
        assertEquals(1, row.catalogCount)
        assertEquals(1, row.enabledCount)
        // Connections that need no credentials (local, etc.) do not show "Add key".
        assertFalse(RelayKeysBoardModel.build(relayProvider(keys = null, authMode = RelayAuthMode.None)).showsAdd)
    }

    // ── BOARD-KEYS-03: all keys are re-fetched after adding──

    @Test
    fun `BOARD-KEYS-03 adding a key refetches every key so the primary gets a status too`() = runTest {
        val harness = RepositoryHarness(
            initial = relayProvider(
                keys = null,
                catalog = listOf(model("gpt-4o"), model("gpt-4.1")),
                enabled = listOf(model("gpt-4o")),
            ),
            catalogs = mapOf(
                "sk-a-000000000001" to listOf("gpt-4o", "gpt-4.1"),
                "sk-new-000000000009" to listOf("claude-opus-4", "gpt-4o"),
            ),
        )
        assertNotNull(harness.repository.addRelayKey(PROVIDER_ID, "k-new", "Backup", "sk-new-000000000009"))

        assertEquals("each key is fetched once", listOf("Bearer sk-a-000000000001", "Bearer sk-new-000000000009"), harness.catalogAuthorizations)
        val board = RelayKeysBoardModel.build(harness.current())
        assertEquals(listOf("initial", "k-new"), board.rows.map { it.id })
        assertEquals(listOf("sk-a…0001", "Backup"), board.rows.map { it.title })
        assertEquals("primary key also gets a status", R.string.relay_key_status_ok, board.rows[0].statusRes)
        assertEquals(R.string.relay_key_status_ok, board.rows[1].statusRes)
        assertEquals(2, board.rows[0].catalogCount)
        assertEquals(2, board.rows[1].catalogCount)
        assertEquals(listOf(1, 0), board.rows.map { it.enabledCount })
        assertTrue(board.showsPrimaryHint)
        assertFalse(board.replaceUsesSingleKeyPath)
    }

    /** While all keys are re-fetched after adding, every key shows fetching; the outcome notice only looks at the newly added key. */
    @Test
    fun `RL2-KEYSTATUS adding a key shows every fetched key as fetching and judges the notice by the new key`() {
        val provider = relayProvider(keys = listOf(RelayKey("initial", status = RelayKeyStatus("ok")), RelayKey("k-b", apiKey = "sk-b-000000000002")))
        val add = RelayKeyOperation.Add("k-new", null, "sk-new-000000000009")
        val fetching = add.fetchingKeyIDs(provider)
        assertEquals(setOf("initial", "k-b", "k-new"), fetching)
        val busy = RelayKeysPageState().begin(add, fetching)
        assertEquals(setOf("initial", "k-b", "k-new"), busy.fetchingKeyIDs)
        assertTrue(RelayKeysBoardModel.build(provider, busy.fetchingKeyIDs).rows.all { it.statusMark == RelayKeyStatusMark.Progress })
        assertEquals(setOf("k-b"), RelayKeyOperation.ReplaceSecret("k-b", "sk").fetchingKeyIDs(provider))

        // Existing key fetch fails, new key succeeds -> no failure reported (only the new key counts).
        val landed = provider.copy(
            relayKeys = listOf(
                RelayKey("initial", status = RelayKeyStatus("invalid", 401)),
                RelayKey("k-b", apiKey = "sk-b-000000000002", status = RelayKeyStatus("ok")),
                RelayKey("k-new", apiKey = "sk-new-000000000009", status = RelayKeyStatus("ok")),
            ),
        )
        val done = busy.finish(RelayKeyOperationOutcome(true, landed, "k-new"), fetching)
        assertTrue(done.fetchingKeyIDs.isEmpty())
        assertTrue(done.notices.isEmpty())
    }

    // ── BOARD-KEYS-04: replacing a key re-fetches only that key and keeps the model library ──

    @Test
    fun `BOARD-KEYS-04 replacing a key refetches only it and keeps catalog and enabled models`() = runTest {
        val harness = RepositoryHarness(
            initial = relayProvider(
                keys = listOf(RelayKey("initial", status = RelayKeyStatus("ok")), RelayKey("k-b", apiKey = "sk-b-000000000002", status = RelayKeyStatus("invalid", 401))),
                catalog = listOf(model("gpt-4o", listOf("initial")), model("claude-opus-4", listOf("k-b"))),
                enabled = listOf(model("gpt-4o", keyID = "initial"), model("claude-opus-4", keyID = "k-b")),
            ),
            catalogs = mapOf("sk-b-000000000099" to listOf("claude-opus-4", "claude-sonnet-4-5")),
        )
        assertNotNull(harness.repository.replaceRelayKeySecret(PROVIDER_ID, "k-b", "sk-b-000000000099"))

        assertEquals(listOf("Bearer sk-b-000000000099"), harness.catalogAuthorizations)
        val stored = harness.current()
        assertEquals("enabled models are kept", listOf("gpt-4o", "claude-opus-4"), stored.models.map { it.id })
        assertEquals("catalog is kept and newly listed entries are added", listOf("gpt-4o", "claude-opus-4", "claude-sonnet-4-5"), stored.catalogModels.map { it.id })
        val board = RelayKeysBoardModel.build(stored)
        assertEquals(R.string.relay_key_status_ok, board.rows[1].statusRes)
        assertEquals("sk-b…0099", board.rows[1].maskedSecret)
        assertEquals(2, board.rows[1].catalogCount)
        assertEquals(R.string.relay_key_status_ok, board.rows[0].statusRes)
    }

    // ── BOARD-KEYS-05: delete ──

    @Test
    fun `BOARD-KEYS-05 primary is not deletable and deleting another lists its models and falls back to the primary`() = runTest {
        val harness = RepositoryHarness(
            initial = relayProvider(
                keys = listOf(RelayKey("initial", name = "Main"), RelayKey("k-b", apiKey = "sk-b-000000000002")),
                catalog = listOf(model("gpt-4o", listOf("initial", "k-b")), model("claude-opus-4", listOf("k-b"))),
                enabled = listOf(model("gpt-4o", keyID = "initial"), model("claude-opus-4", keyID = "k-b"), model("o3", keyID = "k-b")),
            ),
            catalogs = emptyMap(),
        )
        val before = RelayKeysBoardModel.build(harness.current())
        assertFalse("primary key cannot be deleted", RelayKeyAction.Delete in before.rows[0].actions)
        assertTrue("primary key shows the explanatory sentence", before.rows[0].showsPrimaryNotDeletable)
        assertTrue(RelayKeyAction.Delete in before.rows[1].actions)
        assertFalse(before.rows[1].showsPrimaryNotDeletable)
        assertNull("primary key has no confirmation dialog", RelayKeysBoardModel.deleteConfirmation(harness.current(), "initial"))
        val confirmation = RelayKeysBoardModel.deleteConfirmation(harness.current(), "k-b")!!
        assertEquals(listOf("claude-opus-4", "o3"), confirmation.modelIds)
        // The confirmation dialog lists the display name, falling back to the id when unnamed.
        val named = harness.current().let { p -> p.copy(models = p.models.map { if (it.id == "claude-opus-4") it.copy(name = "Claude Opus 4") else it.copy(name = "") }) }
        assertEquals(listOf("Claude Opus 4", "o3"), RelayKeysBoardModel.deleteConfirmation(named, "k-b")!!.modelNames)
        assertEquals("name of the primary key it falls back to", "Main", confirmation.fallbackName)

        assertNotNull(harness.repository.deleteRelayKey(PROVIDER_ID, "k-b"))
        val stored = harness.current()
        assertEquals(listOf("initial", "initial", "initial"), stored.models.map { it.relayKeyID })
        assertEquals("entries listed only by it leave the catalog", listOf("gpt-4o"), stored.catalogModels.map { it.id })
        val after = RelayKeysBoardModel.build(stored)
        assertEquals(1, after.keyCount)
        assertEquals(3, after.rows.single().enabledCount)
    }

    // ── BOARD-KEYS-06: move up / down, the first key is the primary key ──

    @Test
    fun `BOARD-KEYS-06 move up and down follow position and the first key becomes primary`() = runTest {
        val harness = RepositoryHarness(
            initial = relayProvider(
                keys = listOf(RelayKey("initial"), RelayKey("k-b", apiKey = "sk-b-000000000002"), RelayKey("k-c", apiKey = "sk-c-000000000003")),
                enabled = listOf(model("gpt-4o", keyID = "initial")),
            ),
            catalogs = emptyMap(),
        )
        val before = RelayKeysBoardModel.build(harness.current())
        assertFalse(RelayKeyAction.MoveUp in before.rows[0].actions)
        assertTrue(RelayKeyAction.MoveDown in before.rows[0].actions)
        assertTrue(RelayKeyAction.MoveUp in before.rows[1].actions && RelayKeyAction.MoveDown in before.rows[1].actions)
        assertTrue(RelayKeyAction.MoveUp in before.rows[2].actions)
        assertFalse(RelayKeyAction.MoveDown in before.rows[2].actions)
        assertEquals(0, RelayKeysBoardModel.moveTarget(harness.current(), "k-b", RelayKeyAction.MoveUp))
        assertEquals(2, RelayKeysBoardModel.moveTarget(harness.current(), "k-b", RelayKeyAction.MoveDown))
        assertNull(RelayKeysBoardModel.moveTarget(harness.current(), "initial", RelayKeyAction.MoveUp))

        assertNotNull(harness.repository.moveRelayKey(PROVIDER_ID, "k-b", 0))
        val stored = harness.current()
        assertEquals("the new primary key value lands in apiKey", "sk-b-000000000002", harness.apiKey)
        val after = RelayKeysBoardModel.build(stored)
        assertEquals(listOf("k-b", "initial", "k-c"), after.rows.map { it.id })
        assertTrue(after.rows[0].isPrimary && after.rows[0].showsPrimaryBadge)
        assertEquals("sk-b…0002", after.rows[0].maskedSecret)
        assertEquals("the model stays bound to the original key", "initial", stored.models.single().relayKeyID)
    }

    // ── BOARD-KEYS-07: rename (2 or more keys) ──

    @Test
    fun `BOARD-KEYS-07 rename only with two or more keys and it persists`() = runTest {
        val harness = RepositoryHarness(
            initial = relayProvider(keys = listOf(RelayKey("initial"), RelayKey("k-b", apiKey = "sk-b-000000000002"))),
            catalogs = emptyMap(),
        )
        assertTrue(RelayKeysBoardModel.build(harness.current()).rows.all { RelayKeyAction.Rename in it.actions })
        assertFalse(RelayKeyAction.Rename in RelayKeysBoardModel.build(relayProvider(keys = null)).rows.single().actions)

        assertNotNull(harness.repository.renameRelayKey(PROVIDER_ID, "k-b", "Team"))
        assertEquals(listOf("sk-a…0001", "Team"), RelayKeysBoardModel.build(harness.current()).rows.map { it.title })
    }

    // ── BOARD-KEYS-08: mark before the status word + primary key badge ──

    @Test
    fun `BOARD-KEYS-08 status marks are a dot for active, nothing for never checked and a warning otherwise`() {
        val board = RelayKeysBoardModel.build(
            relayProvider(
                keys = listOf(
                    RelayKey("initial", status = RelayKeyStatus("ok", 200)),
                    RelayKey("k-b", apiKey = "sk-b-000000000002", status = RelayKeyStatus("invalid", 401)),
                    RelayKey("k-c", apiKey = "sk-c-000000000003", status = RelayKeyStatus("denied", 403)),
                    RelayKey("k-d", apiKey = "sk-d-000000000004", status = RelayKeyStatus("limited", 429)),
                    RelayKey("k-e", apiKey = "sk-e-000000000005", status = RelayKeyStatus("failed")),
                    RelayKey("k-f", apiKey = "sk-f-000000000006"),
                ),
            ),
        )
        assertEquals(
            listOf(
                RelayKeyStatusMark.Dot,
                RelayKeyStatusMark.Warning,
                RelayKeyStatusMark.Warning,
                RelayKeyStatusMark.Warning,
                RelayKeyStatusMark.Warning,
                null,
            ),
            board.rows.map { it.statusMark },
        )
        assertEquals(listOf(true, false, false, false, false, false), board.rows.map { it.showsPrimaryBadge })
        assertFalse("a single key has no Primary badge", RelayKeysBoardModel.build(relayProvider(keys = null)).rows.single().showsPrimaryBadge)
        // Unknown states (values added in the future) use the default: neither a status word nor a mark is drawn.
        val unknown = RelayKeysBoardModel.build(
            relayProvider(keys = listOf(RelayKey("initial"), RelayKey("k-b", apiKey = "sk-b-000000000002", status = RelayKeyStatus("quota_exhausted", 402)))),
        )
        assertEquals(listOf<RelayKeyStatusMark?>(null, null), unknown.rows.map { it.statusMark })
        assertNull(unknown.rows[1].statusRes)
        assertNull(unknown.rows[1].lastStatus)
    }

    // ── RL2-KEYSTATUS-10: never-checked keys draw no status word or mark──

    @Test
    fun `RL2-KEYSTATUS-10 a never checked key shows no status word or mark and a one-entry list with ok shows Active`() {
        val implicit = RelayKeysBoardModel.build(relayProvider(keys = null, catalog = listOf(model("gpt-4o")), enabled = listOf(model("gpt-4o")))).rows.single()
        assertNull("no status word", implicit.statusRes)
        assertNull("no mark", implicit.statusMark)
        assertNull(implicit.lastStatus)

        val multi = RelayKeysBoardModel.build(
            relayProvider(keys = listOf(RelayKey("initial", status = RelayKeyStatus("ok")), RelayKey("k-b", apiKey = "sk-b-000000000002"))),
        )
        assertNull(multi.rows[1].statusRes)
        assertNull(multi.rows[1].statusMark)
        // Fetching still shows the spinner.
        val fetching = RelayKeysBoardModel.build(relayProvider(keys = null), fetchingKeyIDs = setOf("initial")).rows.single()
        assertEquals(RelayKeyStatusMark.Progress, fetching.statusMark)
        assertEquals(R.string.relay_catalog_loading, fetching.statusRes)

        // Single-entry list (a single key with a written status): shows OK as usual, still offers only "Replace key" and uses the single-key path (decided by fewer than 2 keys).
        val single = RelayKeysBoardModel.build(
            relayProvider(keys = listOf(RelayKey("initial", status = RelayKeyStatus("ok"))), catalog = listOf(model("gpt-4o")), enabled = listOf(model("gpt-4o"))),
        )
        val row = single.rows.single()
        assertEquals(R.string.relay_key_status_ok, row.statusRes)
        assertEquals(RelayKeyStatusMark.Dot, row.statusMark)
        assertEquals(listOf(RelayKeyAction.ViewModels, RelayKeyAction.Replace), row.actions)
        assertTrue(single.replaceUsesSingleKeyPath)
        assertFalse(row.showsPrimaryBadge)

    }

    // ── footer rewrite: no longer says that no separate probe is sent ──

    @Test
    fun `RL2-KEYS-FOOTNOTE footnote is the rewritten relay_keys_footnote`() {
        val board = RelayKeysBoardModel.build(relayProvider(keys = listOf(RelayKey("initial"))))
        assertEquals(R.string.relay_keys_footnote, board.footnoteRes.last())
        fun footnote(dir: String): String {
            val doc = javax.xml.parsers.DocumentBuilderFactory.newInstance().newDocumentBuilder()
                .parse(java.io.File("src/main/res/$dir/strings.xml"))
            val nodes = doc.getElementsByTagName("string")
            return (0 until nodes.length).map { nodes.item(it) as org.w3c.dom.Element }
                .single { it.getAttribute("name") == "relay_keys_footnote" }.textContent
        }
        assertEquals("Key status comes from model list fetches and real requests, including capability tests.", footnote("values"))
        assertEquals("\u5bc6\u94a5\u72b6\u6001\u6765\u81ea\u62c9\u53d6\u76ee\u5f55\u548c\u771f\u5b9e\u8bf7\u6c42\uff0c\u5305\u62ec\u80fd\u529b\u6d4b\u8bd5\u3002", footnote("values-zh-rCN"))
    }

    // ── BOARD-KEYS-09: "Add key" is the last row of the keys card ──

    @Test
    fun `BOARD-KEYS-09 add key is the last row of the keys card`() {
        val board = RelayKeysBoardModel.build(
            relayProvider(keys = listOf(RelayKey("initial"), RelayKey("k-b", apiKey = "sk-b-000000000002"))),
        )
        assertEquals(listOf("initial", "k-b", RelayKeysListItem.ADD_KEY_ID), board.listItems.map { it.id })
        assertTrue(board.listItems.last() is RelayKeysListItem.AddKey)
        assertEquals("row ids are unique", board.listItems.size, board.listItems.map { it.id }.toSet().size)
        // Footer has two sentences: first "changes take effect immediately", then "status comes from ...".
        assertEquals(listOf(R.string.relay_keys_apply_footnote, R.string.relay_keys_footnote), board.footnoteRes)
        val noAuth = RelayKeysBoardModel.build(relayProvider(keys = null, authMode = RelayAuthMode.None))
        assertTrue("not shown when no credentials are needed", noAuth.listItems.none { it is RelayKeysListItem.AddKey })
    }

    // ── BOARD-KEYS-10: per-key actions + action consequence note cards ──

    @Test
    fun `BOARD-KEYS-10 actions per position and the actions explanation card`() {
        val board = RelayKeysBoardModel.build(
            relayProvider(
                keys = listOf(RelayKey("initial"), RelayKey("k-b", apiKey = "sk-b-000000000002"), RelayKey("k-c", apiKey = "sk-c-000000000003")),
            ),
        )
        assertEquals(listOf(RelayKeyAction.Rename, RelayKeyAction.Replace, RelayKeyAction.MoveDown), board.rows[0].actions)
        assertEquals(
            listOf(RelayKeyAction.Rename, RelayKeyAction.Replace, RelayKeyAction.MoveUp, RelayKeyAction.MoveDown, RelayKeyAction.Delete),
            board.rows[1].actions,
        )
        assertEquals(listOf(RelayKeyAction.Rename, RelayKeyAction.Replace, RelayKeyAction.MoveUp, RelayKeyAction.Delete), board.rows[2].actions)
        assertEquals(R.string.relay_key_primary_not_deletable, board.rows[0].panelNoteRes)
        assertNull(board.rows[1].panelNoteRes)
        assertNull(board.rows[2].panelNoteRes)

        assertEquals(R.string.relay_keys_actions_title, board.actionNotesTitleRes)
        assertEquals(
            listOf(
                RelayKeyActionNote(RelayKeyAction.Rename, R.string.relay_key_rename_hint),
                RelayKeyActionNote(RelayKeyAction.Replace, R.string.relay_key_replace_hint),
                RelayKeyActionNote(RelayKeyAction.Delete, R.string.relay_key_delete_hint),
            ),
            board.actionNotes,
        )
        assertTrue("a single key shows no note cards", RelayKeysBoardModel.build(relayProvider(keys = null)).actionNotes.isEmpty())
    }

    // ── BOARD-KEYS-11: the key being fetched ──

    @Test
    fun `BOARD-KEYS-11 the key being fetched shows progress and only add or replace fetch`() {
        val provider = relayProvider(
            keys = listOf(RelayKey("initial", status = RelayKeyStatus("ok", 200)), RelayKey("k-b", apiKey = "sk-b-000000000002", status = RelayKeyStatus("invalid", 401, 1_000L))),
        )
        val idle = RelayKeysBoardModel.build(provider)
        val busy = RelayKeysBoardModel.build(provider, fetchingKeyIDs = setOf("k-b"))
        val row = busy.rows[1]
        assertEquals(RelayKeyStatusMark.Progress, row.statusMark)
        assertEquals(R.string.relay_catalog_loading, row.statusRes)
        assertNull("no last status code", row.lastStatus)
        assertEquals("other rows are the same as when idle", idle.rows[0], busy.rows[0])

        assertEquals("k-new", RelayKeyOperation.Add("k-new", null, "sk").fetchedKeyID)
        assertEquals("k-b", RelayKeyOperation.ReplaceSecret("k-b", "sk").fetchedKeyID)
        assertNull(RelayKeyOperation.Rename("k-b", "x").fetchedKeyID)
        assertNull(RelayKeyOperation.Move("k-b", 0).fetchedKeyID)
        assertNull(RelayKeyOperation.Delete("k-b").fetchedKeyID)
    }

    // ── BOARD-KEYS-12: production key operations + fake upstream -> row status and notices ──

    @Test
    fun `BOARD-KEYS-12 a bad key is saved but marked invalid with a fetch failed notice`() = runTest {
        val harness = RepositoryHarness(
            initial = relayProvider(keys = listOf(RelayKey("initial", status = RelayKeyStatus("ok")), RelayKey("k-b", apiKey = "sk-b-000000000002"))),
            catalogs = mapOf("sk-b-000000000099" to listOf("gpt-4o")),
        )
        val bad = applyRelayKeyOperation(harness.repository, PROVIDER_ID, RelayKeyOperation.ReplaceSecret("k-b", "sk-b-000000000666"))
        assertTrue("key is stored anyway", bad.accepted)
        val badRow = RelayKeysBoardModel.build(harness.current()).rows[1]
        assertEquals("mask is the new key", "sk-b…0666", badRow.maskedSecret)
        assertEquals(R.string.relay_key_status_invalid, badRow.statusRes)
        assertEquals(RelayKeyStatusMark.Warning, badRow.statusMark)
        assertEquals(401, badRow.lastStatus?.httpStatus)
        assertEquals(RelayKeysNotice.FetchFailed, RelayKeysBoardModel.notice(bad))
        assertEquals(R.string.relay_keys_notice_fetch_failed, RelayKeysNotice.FetchFailed.messageRes)

        val good = applyRelayKeyOperation(harness.repository, PROVIDER_ID, RelayKeyOperation.ReplaceSecret("k-b", "sk-b-000000000099"))
        val goodRow = RelayKeysBoardModel.build(harness.current()).rows[1]
        assertEquals(R.string.relay_key_status_ok, goodRow.statusRes)
        assertEquals(RelayKeyStatusMark.Dot, goodRow.statusMark)
        assertNull(RelayKeysBoardModel.notice(good))

        val renamed = applyRelayKeyOperation(harness.repository, PROVIDER_ID, RelayKeyOperation.Rename("k-b", "Team"))
        assertTrue(renamed.accepted)
        assertNull(RelayKeysBoardModel.notice(renamed))

        val rejected = applyRelayKeyOperation(harness.repository, PROVIDER_ID, RelayKeyOperation.ReplaceSecret("missing", "sk-x-000000000001"))
        assertFalse(rejected.accepted)
        assertEquals(RelayKeysNotice.Rejected, RelayKeysBoardModel.notice(rejected))
        assertEquals(R.string.relay_keys_notice_rejected, RelayKeysNotice.Rejected.messageRes)

        // Criterion: the fetched key's written-back status is empty -> fetch was interrupted; the key no longer exists -> none.
        val connection = harness.current()
        val cleared = connection.copy(relayKeys = connection.relayKeys!!.map { if (it.id == "k-b") it.copy(status = null) else it })
        assertEquals(RelayKeysNotice.FetchInterrupted, RelayKeysBoardModel.notice(RelayKeyOperationOutcome(true, cleared, "k-b")))
        assertEquals(R.string.relay_keys_notice_fetch_interrupted, RelayKeysNotice.FetchInterrupted.messageRes)
        assertNull(RelayKeysBoardModel.notice(RelayKeyOperationOutcome(true, connection, "gone")))
    }

    @Test
    fun `BOARD-KEYS-12 an explicit single-key list replaced with a good key returns to Active without a notice`() = runTest {
        // After deleting down to one key the list is still explicit: fetching goes through the single-key refresh and must also write back a status for this key.
        val harness = RepositoryHarness(
            initial = relayProvider(keys = listOf(RelayKey("initial", name = "Main", status = RelayKeyStatus("invalid", 401)))),
            catalogs = mapOf("sk-a-000000000099" to listOf("gpt-4o")),
        )
        val good = applyRelayKeyOperation(harness.repository, PROVIDER_ID, RelayKeyOperation.ReplaceSecret("initial", "sk-a-000000000099"))
        assertTrue(good.accepted)
        val row = RelayKeysBoardModel.build(harness.current()).rows.single()
        assertEquals(R.string.relay_key_status_ok, row.statusRes)
        assertEquals(RelayKeyStatusMark.Dot, row.statusMark)
        assertNull("no false report of an interrupted fetch", RelayKeysBoardModel.notice(good))

        val bad = applyRelayKeyOperation(harness.repository, PROVIDER_ID, RelayKeyOperation.ReplaceSecret("initial", "sk-a-000000000666"))
        assertEquals(R.string.relay_key_status_invalid, RelayKeysBoardModel.build(harness.current()).rows.single().statusRes)
        assertEquals(RelayKeysNotice.FetchFailed, RelayKeysBoardModel.notice(bad))
    }

    // ── BOARD-KEYS-13: the three input sheets ──

    @Test
    fun `BOARD-KEYS-13 input dialogs carry title, fields, placeholders and notes`() {
        val row = RelayKeysBoardModel.build(
            relayProvider(keys = listOf(RelayKey("initial"), RelayKey("k-b", name = "Team", apiKey = "sk-b-000000000002"))),
        ).rows[1]

        val add = RelayKeysBoardModel.inputSheet(RelayKeyInputKind.Add, null)
        assertEquals(R.string.relay_keys_add, add.titleRes)
        assertEquals(listOf(R.string.relay_setup_key_name, R.string.api_key), add.fields.map { it.labelRes })
        assertNull(add.noteRes)

        val replace = RelayKeysBoardModel.inputSheet(RelayKeyInputKind.Replace, row)
        assertEquals(R.string.relay_key_replace, replace.titleRes)
        assertEquals(listOf(RelayKeyInputFieldId.Secret), replace.fields.map { it.id })
        assertEquals(R.string.relay_key_replace_hint, replace.noteRes)

        val rename = RelayKeysBoardModel.inputSheet(RelayKeyInputKind.Rename, row)
        assertEquals(R.string.rename, rename.titleRes)
        assertEquals(listOf(RelayKeyInputFieldId.Name), rename.fields.map { it.id })
        assertEquals("placeholder = mask of that key", "sk-b…0002", rename.fields.single().placeholderText)
        assertEquals(R.string.relay_key_rename_hint, rename.noteRes)

        listOf(add, replace, rename).forEach { sheet ->
            sheet.fields.forEach { field ->
                assertTrue("placeholder != field title", field.placeholderRes == null || field.placeholderRes != field.labelRes)
                assertTrue("field title != sheet title", field.labelRes != sheet.titleRes)
            }
        }
        assertEquals(R.string.relay_api_key_placeholder, add.fields.single { it.id == RelayKeyInputFieldId.Secret }.placeholderRes)
    }

    // ── BOARD-KEYS-14: page state begin / finish ──

    @Test
    fun `BOARD-KEYS-14 page state counts in-flight fetches per key and reports the last outcome`() = runTest {
        // Single success: fetching while in flight, no notice after completion.
        val ok = RepositoryHarness(
            initial = relayProvider(keys = listOf(RelayKey("initial"), RelayKey("k-b", apiKey = "sk-b-000000000002"))),
            catalogs = mapOf("sk-b-000000000099" to listOf("gpt-4o")),
        )
        var state = RelayKeysPageState()
        val replace = RelayKeyOperation.ReplaceSecret("k-b", "sk-b-000000000099")
        state = state.begin(replace)
        assertEquals(setOf("k-b"), state.fetchingKeyIDs)
        state = state.finish(applyRelayKeyOperation(ok.repository, PROVIDER_ID, replace))
        assertTrue(state.fetchingKeyIDs.isEmpty())
        assertTrue(state.notices.isEmpty())

        // Single rejection: no leftover fetching, notice is [rejected].
        val missing = RelayKeyOperation.ReplaceSecret("missing", "sk-x-000000000001")
        state = state.begin(missing).let { it.finish(applyRelayKeyOperation(ok.repository, PROVIDER_ID, missing)) }
        assertTrue(state.fetchingKeyIDs.isEmpty())
        assertEquals(listOf(RelayKeysNotice.Rejected), state.notices)

        // Same key in flight twice: begin withdraws the old notice; the first to finish neither clears fetching nor reports, and the last one reports against the connection at completion time.
        val twice = RepositoryHarness(
            initial = relayProvider(keys = listOf(RelayKey("initial"), RelayKey("k-b", apiKey = "sk-b-000000000002"))),
            catalogs = mapOf("sk-b-000000000099" to listOf("gpt-4o")),
        )
        val first = RelayKeyOperation.ReplaceSecret("k-b", "sk-b-000000000099")
        val second = RelayKeyOperation.ReplaceSecret("k-b", "sk-b-000000000666")
        state = state.begin(first)
        assertTrue("begin withdraws the previous notice", state.notices.isEmpty())
        twice.onCatalog = { auth ->
            if (auth == "Bearer sk-b-000000000099") {
                twice.onCatalog = null
                state = state.begin(second)
                assertEquals(2, state.fetchingCounts["k-b"])
                // The later call finishes first (accepted): still in flight, does not clear fetching and does not report.
                state = state.finish(applyRelayKeyOperation(twice.repository, PROVIDER_ID, second))
                assertEquals(setOf("k-b"), state.fetchingKeyIDs)
                assertTrue(state.notices.isEmpty())
            }
        }
        state = state.finish(applyRelayKeyOperation(twice.repository, PROVIDER_ID, first))
        assertTrue(state.fetchingKeyIDs.isEmpty())
        assertEquals(listOf(RelayKeysNotice.FetchFailed), state.notices)
        assertEquals(R.string.relay_key_status_invalid, RelayKeysBoardModel.build(twice.current(), state.fetchingKeyIDs).rows[1].statusRes)
    }

    // ── BOARD-KEYS-15: two interleaved keys, both outcomes are present ──

    @Test
    fun `BOARD-KEYS-15 two keys interleaved keep both outcomes in completion order`() = runTest {
        val harness = RepositoryHarness(
            initial = relayProvider(
                keys = listOf(RelayKey("initial"), RelayKey("k-b", apiKey = "sk-b-000000000002"), RelayKey("k-c", apiKey = "sk-c-000000000003")),
            ),
            catalogs = mapOf("sk-b-000000000099" to listOf("gpt-4o")),
        )
        val first = RelayKeyOperation.ReplaceSecret("k-b", "sk-b-000000000099")
        val second = RelayKeyOperation.ReplaceSecret("k-c", "sk-c-000000000666")
        var state = RelayKeysPageState().begin(first)
        var armed = false
        harness.onCatalog = { auth -> if (auth == "Bearer sk-b-000000000099") armed = true }
        // After the first key finishes fetching and reads the latest connection (holding the refresh), the second key completes and persists in full, so the first key's write-back is discarded by the concurrency check.
        harness.afterRead = {
            if (armed) {
                armed = false
                state = state.begin(second)
                state = state.finish(applyRelayKeyOperation(harness.repository, PROVIDER_ID, second))
            }
        }
        val outcome = applyRelayKeyOperation(harness.repository, PROVIDER_ID, first)
        state = state.finish(outcome)

        assertTrue("key is stored anyway", outcome.accepted)
        val stored = harness.current()
        assertEquals("sk-b-000000000099", harness.secrets["k-b"])
        assertNull("status is not written back", stored.relayKeys!!.single { it.id == "k-b" }.status)
        assertEquals("invalid", stored.relayKeys!!.single { it.id == "k-c" }.status?.state)
        assertEquals(listOf(RelayKeysNotice.FetchFailed, RelayKeysNotice.FetchInterrupted), state.notices)
        assertTrue(state.fetchingKeyIDs.isEmpty())
        // Identical sentences are deduplicated.
        assertEquals(
            listOf(RelayKeysNotice.FetchFailed),
            RelayKeysPageState(notices = listOf(RelayKeysNotice.FetchFailed))
                .finish(RelayKeyOperationOutcome(true, stored.copy(relayKeys = stored.relayKeys!!.map { if (it.id == "k-b") it.copy(status = RelayKeyStatus("invalid", 401)) else it }), "k-b"))
                .notices,
        )
    }

    // ── BOARD-KEYS-16: first panel item "View models (N)"──

    @Test
    fun `BOARD-KEYS-16 view models is the first panel action, absent for an empty catalog, present for a single key`() {
        val multi = RelayKeysBoardModel.build(
            relayProvider(
                keys = listOf(RelayKey("initial"), RelayKey("k-b", apiKey = "sk-b-000000000002")),
                catalog = listOf(model("gpt-4o", listedBy = listOf("initial")), model("gpt-4.1")),
            ),
        )
        assertEquals(2, multi.rows[0].catalogCount)
        assertEquals(
            listOf(RelayKeyAction.ViewModels, RelayKeyAction.Rename, RelayKeyAction.Replace, RelayKeyAction.MoveDown),
            multi.rows[0].actions,
        )
        assertNull("k-b catalog is 0", multi.rows[1].catalogCount)
        assertFalse("empty catalog is not shown", RelayKeyAction.ViewModels in multi.rows[1].actions)

        val single = RelayKeysBoardModel.build(relayProvider(keys = null, catalog = listOf(model("gpt-4o"))))
        assertEquals("the implicit single key has it too", listOf(RelayKeyAction.ViewModels, RelayKeyAction.Replace), single.rows.single().actions)
        val empty = RelayKeysBoardModel.build(relayProvider(keys = null))
        assertEquals(listOf(RelayKeyAction.Replace), empty.rows.single().actions)
    }

    // ── BOARD-KEYS-17: the added(N, M) success notice and the warning are mutually exclusive ──

    @Test
    fun `BOARD-KEYS-17 a successful add reports listed and new counts and excludes the warnings`() = runTest {
        val harness = RepositoryHarness(
            initial = relayProvider(keys = null, catalog = listOf(model("gpt-4o"), model("gpt-4.1"))),
            catalogs = mapOf(
                "sk-a-000000000001" to listOf("gpt-4o", "gpt-4.1"),
                "sk-new-000000000009" to listOf("claude-opus-4", "gpt-4o", "o3"),
                "sk-sub-000000000008" to listOf("gpt-4o"),
                "sk-none-000000000007" to emptyList(),
            ),
        )
        val add = RelayKeyOperation.Add("k-new", "Team", "sk-new-000000000009")
        val outcome = applyRelayKeyOperation(harness.repository, PROVIDER_ID, add)
        val state = RelayKeysPageState().begin(add, add.fetchingKeyIDs(null)).finish(outcome, add.fetchingKeyIDs(null))
        val stored = harness.current()
        // M comes from the same source as listingKeyIDs: entries listed only by k-new.
        val onlyNew = stored.catalogModels.count { RelayKeyBinding.listingKeyIDs(stored, it.id) == listOf("k-new") }
        assertEquals(2, onlyNew)
        assertEquals(listOf<RelayKeysNotice>(RelayKeysNotice.Added("k-new", listed = 3, new = 2)), state.notices)
        assertEquals(RelayKeysBoardModel.build(stored).rows.single { it.id == "k-new" }.catalogCount, 3)

        // All listed by other keys as well -> M = 0.
        val sub = applyRelayKeyOperation(harness.repository, PROVIDER_ID, RelayKeyOperation.Add("k-sub", null, "sk-sub-000000000008"))
        assertEquals(RelayKeysNotice.Added("k-sub", listed = 1, new = 0), RelayKeysBoardModel.notice(sub))
        // Empty catalog -> no notice.
        val none = applyRelayKeyOperation(harness.repository, PROVIDER_ID, RelayKeyOperation.Add("k-none", null, "sk-none-000000000007"))
        assertNull(RelayKeysBoardModel.notice(none))
        // Fetch failed -> only the warning, no added.
        val bad = applyRelayKeyOperation(harness.repository, PROVIDER_ID, RelayKeyOperation.Add("k-bad", null, "sk-bad-000000000666"))
        assertEquals(RelayKeysNotice.FetchFailed, RelayKeysBoardModel.notice(bad))
        // Value replaced successfully -> no notice.
        val replaced = applyRelayKeyOperation(harness.repository, PROVIDER_ID, RelayKeyOperation.ReplaceSecret("k-bad", "sk-new-000000000009"))
        assertEquals("ok", replaced.connection!!.relayKeys!!.single { it.id == "k-bad" }.status?.state)
        assertNull(RelayKeysBoardModel.notice(replaced))
        // Not accepted -> rejected.
        assertEquals(RelayKeysNotice.Rejected, RelayKeysBoardModel.notice(RelayKeyOperationOutcome(false, null, "k-x", isAdd = true)))
    }

    // ── BOARD-KEYS-18: panel items and notice links both open the model library by key(id) ──

    @Test
    fun `BOARD-KEYS-18 the panel action and the notice link both open the library filtered by key`() {
        val provider = relayProvider(
            keys = listOf(RelayKey("initial"), RelayKey("k-b", apiKey = "sk-b-000000000002", status = RelayKeyStatus("ok"))),
            catalog = listOf(model("gpt-4o", listedBy = listOf("initial", "k-b")), model("o3", listedBy = listOf("k-b"))),
        )
        val row = RelayKeysBoardModel.build(provider).rows.single { it.id == "k-b" }
        assertEquals(RelayKeyAction.ViewModels, row.actions.first())
        val added = RelayKeysBoardModel.notice(RelayKeyOperationOutcome(true, provider, "k-b", isAdd = true)) as RelayKeysNotice.Added
        assertEquals(RelayKeysNotice.Added("k-b", listed = 2, new = 1), added)

        val keysPage = RelayDetailNavStack().push(RelayDetailLayer.Keys)
        for (keyID in listOf(row.id, added.keyID)) {
            val opened = keysPage.push(RelayKeysBoardModel.libraryLayer(keyID))
            assertEquals(RelayDetailLayer.Library(keyFilter = "k-b"), opened.top)
            assertTrue(opened.showsLibrary)
            assertEquals(RelayCatalogFilter.Key("k-b"), RelayCatalogBoardModel.initialFilter(opened))
            assertTrue("back returns to the keys page", opened.pop().showsKeys)
        }
    }

    /** Production ProviderRepository + production RelayService; the upstream MockEngine returns each key's catalog by Authorization. */
    private inner class RepositoryHarness(
        initial: Provider,
        catalogs: Map<String, List<String>>,
    ) {
        var apiKey = "sk-a-000000000001"
        val secrets: MutableMap<String, String> = initial.relayKeys.orEmpty().drop(1).associate { it.id to it.apiKey }.toMutableMap()
        var stored: ProviderEntity? = with(ProviderMapper) { initial.toEntity(ACCOUNT) }
        val catalogAuthorizations: MutableList<String?> = Collections.synchronizedList(mutableListOf())
        /** Hook invoked when a catalog request reaches the upstream (before the response): used to insert another key operation while one key is being fetched. */
        var onCatalog: (suspend (String?) -> Unit)? = null
        /** Hook invoked after each store read returns and before handing back to the caller: used to build "read the latest, then overwritten by another write". */
        var afterRead: (suspend () -> Unit)? = null
        private val json = Json { ignoreUnknownKeys = true }

        private val engine = MockEngine { request ->
            val auth = request.headers[HttpHeaders.Authorization]
            if (request.method == HttpMethod.Get) {
                catalogAuthorizations += auth
                onCatalog?.invoke(auth)
                val ids = catalogs[auth?.removePrefix("Bearer ")]
                    ?: return@MockEngine respond("{\"error\":\"Invalid API key\"}", HttpStatusCode.Unauthorized)
                respond(
                    "{\"data\":[" + ids.joinToString(",") { "{\"id\":\"$it\"}" } + "]}",
                    HttpStatusCode.OK,
                    headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                )
            } else {
                respond(
                    "{\"id\":\"x\",\"choices\":[{\"message\":{\"content\":\"p\"}}]}",
                    HttpStatusCode.OK,
                    headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                )
            }
        }

        val repository: ProviderRepository = run {
            val dao = mockk<ai.oriveo.community.core.data.dao.ProviderDao>()
            coEvery { dao.getById(any(), any()) } coAnswers {
                val read = stored?.takeIf { it.accountId == firstArg<String>() && it.id == secondArg<String>() }
                afterRead?.invoke()
                read
            }
            coEvery { dao.upsert(any()) } coAnswers { stored = firstArg() }
            coEvery { dao.getAll(any()) } coAnswers { listOfNotNull(stored) }
            val keys = mockk<ai.oriveo.community.core.security.SecureKeyStore>(relaxed = true)
            every { keys.getApiKey(any(), any()) } answers { apiKey }
            every { keys.saveApiKey(any(), any(), any()) } answers { apiKey = thirdArg() }
            every { keys.getRelayKeySecret(any(), any(), any()) } answers { secrets[thirdArg()] }
            every { keys.saveRelayKeySecrets(any(), any(), any()) } answers {
                thirdArg<List<RelayKey>?>().orEmpty().drop(1).filter { it.apiKey.isNotEmpty() }.forEach { secrets[it.id] = it.apiKey }
            }
            ProviderRepository(
                dao = dao,
                conversationDao = mockk(relaxed = true),
                secureKeyStore = keys,
                openRouterService = mockk(relaxed = true),
                openAIService = mockk(relaxed = true),
                deepSeekService = mockk(relaxed = true),
                grokService = mockk(relaxed = true),
                anthropicService = mockk(relaxed = true),
                geminiService = mockk(relaxed = true),
                groqService = mockk(relaxed = true),
                togetherService = mockk(relaxed = true),
                fireworksService = mockk(relaxed = true),
                miniMaxService = mockk(relaxed = true),
                zhipuService = mockk(relaxed = true),
                qwenService = mockk(relaxed = true),
                moonshotService = mockk(relaxed = true),
                mistralService = mockk(relaxed = true),
                siliconFlowService = mockk(relaxed = true),
                relayService = RelayService(client = HttpClient(engine), json = json, transportRegistry = TransportRegistry(json)),
                metadataRefreshEventBus = ai.oriveo.community.core.data.remote.MetadataRefreshEventBus(debounceMillis = 0),
                httpClient = HttpClient(MockEngine { respond("", HttpStatusCode.NotFound) }),
                relayModelFamily = { null },
            )
        }

        fun current(): Provider = with(ProviderMapper) { requireNotNull(stored).toDomain(apiKey) { secrets[it] } }
    }

    private companion object {
        const val ACCOUNT = ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
        const val PROVIDER_ID = "33333333-3333-4333-8333-333333333333"
    }
}
