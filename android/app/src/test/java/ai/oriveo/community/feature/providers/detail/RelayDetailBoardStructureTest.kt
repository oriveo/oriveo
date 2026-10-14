package ai.oriveo.community.feature.providers.detail

import androidx.lifecycle.SavedStateHandle
import ai.oriveo.community.R
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.data.mapper.ProviderMapper
import ai.oriveo.community.core.data.remote.MetadataRefreshEventBus
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.EngineDeclaration
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayKindDefaults
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.RelayTransportSource
import ai.oriveo.community.core.provider.RelayService
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.feature.providers.relay.RelayBoardProtocol
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import java.io.File
import java.nio.file.Files
import java.nio.file.Paths
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
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

/**
 * Structure snapshot of the detail-page board (RelayDetail / LocalDetail).
 *
 * Row order, string resource ids and button states come from the production [RelayDetailBoardModel.build]; re-detection drives the production
 * [ProviderDetailViewModel] → [ProviderRepository.redetectRelayModels] against a fake server;
 * The thinking row is compared case by case against thinking.cases of the shared local-engine fixture `engine-expectations.v1.json`.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class RelayDetailBoardStructureTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Before
    fun setUp() {
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private fun relay(
        requested: RelayRequestedConfig = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions),
        apiKey: String = "sk-live-0000000000007f2a",
        relayKind: RelayKind? = RelayKind.OpenAICompatible,
        models: List<AIModel> = listOf(AIModel(id = "claude-sonnet-4.5", name = "claude-sonnet-4.5", isDefault = true), AIModel(id = "gpt-5", name = "gpt-5")),
        catalog: List<AIModel> = models + listOf(AIModel(id = "o3", name = "o3"), AIModel(id = "gemini-2.5-pro", name = "gemini-2.5-pro")),
    ) = Provider(
        id = "provider-1",
        kind = ProviderKind.Relay,
        customName = "myrelay.dev",
        baseUrlText = "https://api.myrelay.dev",
        apiKey = apiKey,
        apiKeyPreview = if (apiKey.isBlank()) "" else "sk-••••••••7f2a",
        relayKind = relayKind,
        relayRequested = requested,
        models = models,
        catalogModels = catalog,
        lastCheckedAt = 1_760_000_000_000,
    )

    private fun local(engineProfile: String, channel: RelayTransport, declaredThinking: Boolean? = null) = Provider(
        id = "provider-1",
        kind = ProviderKind.Relay,
        customName = "Mac mini",
        baseUrlText = "http://192.168.1.20:8080",
        relayKind = RelayKind.OpenAICompatible,
        relayRequested = RelayRequestedConfig(
            transport = channel,
            authMode = RelayAuthMode.None,
            securityMode = RelayConnectionSecurityMode.LocalHttp,
            engineProfile = engineProfile,
        ),
        models = listOf(
            AIModel(
                id = "qwen3-8b-q4",
                name = "qwen3-8b-q4",
                isDefault = true,
                engineDeclaration = EngineDeclaration(thinking = declaredThinking),
            ),
        ),
        catalogModels = listOf(
            AIModel(id = "qwen3-8b-q4", name = "qwen3-8b-q4"),
            AIModel(id = "gemma3", name = "gemma3"),
            AIModel(id = "llava", name = "llava"),
        ),
    )

    // ── BOARD-DETAIL-01: relay connection card and model card row order + bottom button keys (with / without the secondary state)──

    @Test
    fun `BOARD-DETAIL-01 relay connection and model card rows with base paths`() {
        val provider = relay(
            requested = RelayRequestedConfig(
                transport = RelayTransport.OpenAIChatCompletions,
                resolvedAPIBaseURL = "https://api.myrelay.dev/v1",
                resolvedAPIBaseURLs = mapOf(
                    RelayTransport.GeminiGenerateContent.value to "https://api.myrelay.dev/v1beta",
                    RelayTransport.AnthropicMessages.value to "https://api.myrelay.dev/v1",
                ),
            ),
        )
        val board = RelayDetailBoardModel.build(provider, isRedetecting = false)

        assertFalse(board.isLocal)
        assertEquals(listOf(RelayDetailAction.Rename, RelayDetailAction.EditConnection), board.headerActions)
        assertEquals(
            listOf(RelayDetailRowId.RequestUrl, RelayDetailRowId.ApiKey, RelayDetailRowId.DefaultProtocol, RelayDetailRowId.BasePaths),
            board.connectionRows.map { it.id },
        )
        assertEquals(
            listOf(R.string.request_url_label, R.string.api_key, R.string.relay_detail_default_protocol, R.string.relay_detail_base_paths),
            board.connectionRows.map { it.titleRes },
        )
        val url = board.connectionRows[0]
        assertEquals("https://api.myrelay.dev", url.value)
        // BOARD-DETAIL-14: the request address row opens connection editing.
        assertEquals(RelayDetailAction.EditConnection, url.action)
        val key = board.connectionRows[1]
        assertEquals("sk-••••••••7f2a", key.value)
        assertEquals(R.string.relay_keys_add_more_hint, key.trailingRes)
        assertEquals(RelayDetailAction.OpenKeys, key.action)
        val protocol = board.connectionRows[2]
        assertEquals(R.string.relay_transport_openai_chat_completions, protocol.valueRes)
        assertEquals(RelayDetailAction.EditConnection, protocol.action)
        // Listed per protocol as "protocol name path": the per-protocol table takes priority, a legacy single-value root belongs to the connection default protocol; order is fixed Chat -> Responses -> Messages -> Gemini.
        assertEquals(
            listOf(
                RelayDetailBasePath(RelayBoardProtocol.Chat, "/v1"),
                RelayDetailBasePath(RelayBoardProtocol.Messages, "/v1"),
                RelayDetailBasePath(RelayBoardProtocol.Gemini, "/v1beta"),
            ),
            board.connectionRows[3].basePaths,
        )

        // Relays have no default model; a "web search" row is added under the model library; the parameters row merges into the third row of the model card.
        assertEquals(listOf(RelayDetailRowId.ModelLibrary, RelayDetailRowId.WebSearch, RelayDetailRowId.Parameters), board.modelRows.map { it.id })
        val library = board.modelRows[0]
        assertEquals(R.string.model_library, library.titleRes)
        assertEquals(R.string.relay_detail_library_summary, library.valueRes)
        assertEquals(listOf<Any>(2, 2), library.valueArgs)
        assertEquals(RelayDetailAction.OpenModelLibrary, library.action)

        assertEquals(listOf(R.string.relay_detail_detect_again, R.string.relay_detail_delete_relay), board.buttons.map { it.textRes })
        assertEquals(listOf(RelayDetailAction.Redetect, RelayDetailAction.Delete), board.buttons.map { it.action })
        // Selected protocol: the footnote only mentions refreshing the catalog (BOARD-DETAIL-13).
        assertEquals(R.string.relay_detail_detect_footnote_catalog, board.footnoteRes)
        // Header model count = catalog total (enabled ∪ catalog, deduplicated), time comes from lastCheckedAt.
        assertEquals(4, board.modelCount)
        assertEquals(1_760_000_000_000, board.lastCheckedAt)
    }

    @Test
    fun `BOARD-DETAIL-01 relay without any resolved root hides the base paths row`() {
        val board = RelayDetailBoardModel.build(relay(), isRedetecting = false)
        assertEquals(
            listOf(RelayDetailRowId.RequestUrl, RelayDetailRowId.ApiKey, RelayDetailRowId.DefaultProtocol),
            board.connectionRows.map { it.id },
        )
    }

    @Test
    fun `BOARD-DETAIL-01 a missing required key shows tap to set and a residual key keeps the remove exit`() {
        // Auth required with no stored key: keeps the existing "tap to set up" value, not the "no key required" one.
        val noKey = RelayDetailBoardModel.build(relay(apiKey = ""), isRedetecting = false).connectionRows[1]
        assertEquals(R.string.tap_to_set, noKey.valueRes)
        assertNull(noKey.value)
        assertNull(noKey.trailingRes)
        // A connection requiring auth can still add a key by tapping the row when it has none.
        assertEquals(RelayDetailAction.OpenKeys, noKey.action)
        assertNull(noKey.secondaryAction)

        val residual = RelayDetailBoardModel.build(
            relay(requested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions, authMode = RelayAuthMode.None)),
            isRedetecting = false,
        ).connectionRows[1]
        // Leftover key: no hint at row end, the remove entry is still there.
        assertNull(residual.trailingRes)
        assertEquals(RelayDetailAction.RemoveStoredKey, residual.secondaryAction)
    }

    // ── BOARD-DETAIL-02: local connection card and model card row order ──

    @Test
    fun `BOARD-DETAIL-02 local connection and model card rows`() {
        val board = RelayDetailBoardModel.build(local("llamacpp", RelayTransport.OpenAIChatCompletions), isRedetecting = false)

        assertTrue(board.isLocal)
        assertEquals(
            listOf(RelayDetailRowId.EngineAddress, RelayDetailRowId.Engine, RelayDetailRowId.Channel, RelayDetailRowId.ApiKey),
            board.connectionRows.map { it.id },
        )
        assertEquals(
            listOf(R.string.relay_detail_engine_address, R.string.relay_detail_engine_detected, R.string.relay_detail_channel_row, R.string.api_key),
            board.connectionRows.map { it.titleRes },
        )
        assertEquals("http://192.168.1.20:8080", board.connectionRows[0].value)
        assertEquals("llama.cpp", board.connectionRows[1].value)
        assertNull(board.connectionRows[1].action)
        assertEquals(R.string.relay_transport_openai_chat_completions, board.connectionRows[2].valueRes)
        assertEquals(RelayDetailAction.EditConnection, board.connectionRows[2].action)
        assertEquals(R.string.relay_detail_no_key, board.connectionRows[3].valueRes)
        // No auth required and no stored key: keeps the existing criterion, no "enter key" entry (canEditApiKey).
        assertNull(board.connectionRows[3].action)
        // Tappable iff requiresCredential || hasStoredKey: auth required without key shows "tap to set up" and is tappable; plaintext / no-auth-but-stored-key is tappable and offers the remove entry.
        val s1 = RelayDetailBoardModel.build(
            local("llamacpp", RelayTransport.OpenAIChatCompletions).let { it.copy(relayRequested = it.relayRequested?.copy(authMode = RelayAuthMode.Bearer)) },
            isRedetecting = false,
        ).connectionRows[3]
        assertEquals(R.string.tap_to_set, s1.valueRes)
        assertEquals(RelayDetailAction.OpenKeys, s1.action)
        val s3 = RelayDetailBoardModel.build(
            local("llamacpp", RelayTransport.OpenAIChatCompletions).copy(apiKey = "sk-local-0000001234", apiKeyPreview = "sk-••1234"),
            isRedetecting = false,
        ).connectionRows[3]
        assertEquals(RelayDetailAction.OpenKeys, s3.action)
        assertEquals(RelayDetailAction.RemoveStoredKey, s3.secondaryAction)

        assertEquals(
            listOf(RelayDetailRowId.ModelLibrary, RelayDetailRowId.Thinking, RelayDetailRowId.Parameters),
            board.modelRows.map { it.id },
        )
        assertEquals(R.string.relay_detail_library_summary_local, board.modelRows[0].valueRes)
        assertEquals(listOf<Any>(1, 2), board.modelRows[0].valueArgs)
        val thinking = board.modelRows[1]
        assertEquals(R.string.relay_detail_read_only, thinking.trailingRes)
        assertNull(thinking.action)

        assertEquals(listOf(R.string.relay_detail_detect_again, R.string.relay_detail_delete_connection), board.buttons.map { it.textRes })
        assertEquals(3, board.modelCount)
    }

    @Test
    fun `BOARD-DETAIL-02 single-channel engines show the channel without an edit action`() {
        val board = RelayDetailBoardModel.build(local("ollama", RelayTransport.OpenAIChatCompletions), isRedetecting = false)
        assertEquals("Ollama", board.connectionRows[1].value)
        assertNull(board.connectionRows[2].action)
    }

    // ── BOARD-DETAIL-03: the three copies of the local thinking row (fixture) ──

    private fun fixture(relativePath: String): JsonObject {
        val path = generateSequence(Paths.get("").toAbsolutePath()) { it.parent }
            .map { it.resolve(relativePath) }
            .firstOrNull(Files::exists)
            ?: error("fixture not found: $relativePath")
        return Json.parseToJsonElement(String(Files.readAllBytes(path), Charsets.UTF_8)).jsonObject
    }

    @Test
    fun `BOARD-DETAIL-03 local thinking row copy follows the write path table`() {
        val expectations = fixture("shared/test-fixtures/local-engine/engine-expectations.v1.json")
        val channels = expectations.getValue("channels").jsonObject
        val expectedCopy = mapOf(
            "toggle" to R.string.relay_detail_thinking_template,
            "nonChatNotice" to R.string.relay_detail_thinking_model,
            "usesModelDefaultNotice" to R.string.relay_detail_thinking_model,
            "unsupported" to R.string.relay_detail_thinking_unsupported_model,
        )
        val cases = expectations.getValue("thinking").jsonObject.getValue("cases").jsonArray.map { it.jsonObject }
            .filter { (it["engineProfile"] as? JsonPrimitive)?.contentOrNull != null }
        assertTrue("the fixture covers at least three copies", cases.map { expectedCopy.getValue(it.getValue("expect").jsonPrimitive.content) }.toSet().size == 3)
        cases.forEach { case ->
            val caseId = case.getValue("caseId").jsonPrimitive.content
            val channel = RelayTransport.entries.single {
                it.value == channels.getValue(case.getValue("channel").jsonPrimitive.content).jsonPrimitive.content
            }
            val provider = local(
                engineProfile = case.getValue("engineProfile").jsonPrimitive.content,
                channel = channel,
                declaredThinking = (case["declaredThinking"] as? JsonPrimitive)?.booleanOrNull,
            )
            val row = RelayDetailBoardModel.build(provider, isRedetecting = false).modelRows.single { it.id == RelayDetailRowId.Thinking }
            assertEquals(caseId, expectedCopy.getValue(case.getValue("expect").jsonPrimitive.content), row.valueRes)
            // unsupported fills in the display name of the fallback model (lastUsed -> first enabled); the other copies take no arguments.
            if (row.valueRes == R.string.relay_detail_thinking_unsupported_model) {
                assertEquals(caseId, listOf<Any>("qwen3-8b-q4"), row.valueArgs)
            } else {
                assertEquals(caseId, emptyList<Any>(), row.valueArgs)
            }
        }
    }

    // ── BOARD-DETAIL-08 / 09: key row ──

    @Test
    fun `BOARD-DETAIL-08 a single key keeps one row and tapping it opens the keys page`() {
        val board = RelayDetailBoardModel.build(relay(), isRedetecting = false)
        val key = board.connectionRows.single { it.id == RelayDetailRowId.ApiKey }
        assertEquals(R.string.api_key, key.titleRes)
        assertEquals("sk-••••••••7f2a", key.value)
        assertEquals("destination is now the keys page (formerly the replace-key sheet)", RelayDetailAction.OpenKeys, key.action)
        assertNull(key.keyCount)
        assertTrue(key.inlineKeys.isEmpty())
        assertEquals(0, key.moreKeys)
        // authMode none with no stored key is still not tappable.
        val none = RelayDetailBoardModel.build(
            relay(apiKey = "", requested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions, authMode = RelayAuthMode.None)),
            isRedetecting = false,
        ).connectionRows.single { it.id == RelayDetailRowId.ApiKey }
        assertNull(none.action)
        // Tapping the key row of a local connection also opens the keys page.
        val localWithKey = local("llamacpp", RelayTransport.OpenAIChatCompletions).copy(apiKey = "sk-local-0000001234", apiKeyPreview = "sk-••1234")
        assertEquals(
            RelayDetailAction.OpenKeys,
            RelayDetailBoardModel.build(localWithKey, isRedetecting = false).connectionRows.single { it.id == RelayDetailRowId.ApiKey }.action,
        )
    }

    @Test
    fun `BOARD-DETAIL-09 two or more keys show a title row with up to three inline keys and a more line`() {
        val keys = listOf(
            ai.oriveo.community.core.model.RelayKey("initial", name = "Main", status = ai.oriveo.community.core.model.RelayKeyStatus("ok")),
            ai.oriveo.community.core.model.RelayKey("k-b", apiKey = "sk-b-000000000002", status = ai.oriveo.community.core.model.RelayKeyStatus("invalid", 401)),
            ai.oriveo.community.core.model.RelayKey("k-c", apiKey = "sk-c-000000000003"),
            ai.oriveo.community.core.model.RelayKey("k-d", apiKey = "sk-d-000000000004"),
            ai.oriveo.community.core.model.RelayKey("k-e", apiKey = "sk-e-000000000005"),
        )
        val five = RelayDetailBoardModel.build(relay().copy(relayKeys = keys), isRedetecting = false)
            .connectionRows.single { it.id == RelayDetailRowId.ApiKey }
        assertEquals(R.string.relay_keys_title, five.titleRes)
        assertNull(five.value)
        assertEquals(5, five.keyCount)
        assertEquals(RelayDetailAction.OpenKeys, five.action)
        assertEquals(listOf("initial", "k-b", "k-c"), five.inlineKeys.map { it.id })
        assertEquals(listOf("Main", "sk-b…0002", "sk-c…0003"), five.inlineKeys.map { it.title })
        assertEquals(
            listOf(R.string.relay_key_status_ok, R.string.relay_key_status_invalid, null),
            five.inlineKeys.map { it.statusRes },
        )
        assertEquals(2, five.moreKeys)

        val two = RelayDetailBoardModel.build(relay().copy(relayKeys = keys.take(2)), isRedetecting = false)
            .connectionRows.single { it.id == RelayDetailRowId.ApiKey }
        assertEquals(2, two.inlineKeys.size)
        assertEquals(0, two.moreKeys)
    }

    // ── BOARD-DETAIL-10: header ──

    @Test
    fun `BOARD-DETAIL-10 relay header uses the shared avatar, a rename pencil and the union model count`() {
        val provider = relay()
        val board = RelayDetailBoardModel.build(provider, isRedetecting = false)
        assertEquals(ai.oriveo.community.core.model.RelayAvatarResolver.resolve(provider), board.avatar)
        // Icon layer (relay-avatar-icon.v1.json): a relay without a brand match draws the icon assigned by connection id by default, no longer the initial.
        assertTrue(board.avatar is ai.oriveo.community.core.model.RelayAvatarResult.Icon)
        assertTrue(board.showsRenamePencil)
        // Enabled ∪ catalog, deduplicated: 2 enabled + 2 catalog-only.
        assertEquals(4, board.modelCount)

        val localBoard = RelayDetailBoardModel.build(local("llamacpp", RelayTransport.OpenAIChatCompletions), isRedetecting = false)
        assertNull("local header is unchanged", localBoard.avatar)
        assertFalse(localBoard.showsRenamePencil)

        val view = repoFile("feature/providers/detail/RelayDetailBoardView.kt").readText()
        assertTrue("pencil next to the name", view.contains("R.drawable.ph_pencil_simple"))
        assertTrue("model count in the status line uses plurals", view.contains("R.plurals.relay_detail_models_count"))
        assertFalse(view.contains("R.string.provider_detail_available_models"))
    }

    // ── BOARD-AVATAR-PICKER: changing the detail header avatar icon ──

    @Test
    fun `BOARD-AVATAR-PICKER-01 relay header avatar is a button that opens the change icon sheet`() {
        val board = RelayDetailBoardModel.build(relay(), isRedetecting = false)
        assertTrue("the relay avatar is tappable", board.avatarPickable)
        assertFalse("local header is unchanged", RelayDetailBoardModel.build(local("llamacpp", RelayTransport.OpenAIChatCompletions), isRedetecting = false).avatarPickable)

        val header = repoFile("feature/providers/detail/RelayDetailBoardView.kt").readText()
            .substringAfter("private fun BoardHeader(").substringBefore("\n}\n")
        assertTrue("tapping the avatar sends ChangeIcon", header.contains("onAction(RelayDetailAction.ChangeIcon)"))
        assertTrue("the avatar accessibility label is Change icon", header.contains("R.string.relay_avatar_change_icon"))
        assertTrue("the avatar is exposed with button semantics", header.contains("Role.Button"))
        val screen = repoFile("feature/providers/detail/ProviderDetailScreen.kt").readText()
        assertTrue("ChangeIcon opens the sheet", Regex("""RelayDetailAction\.ChangeIcon\s*->\s*showAvatarPicker\s*=\s*true""").containsMatchIn(screen))
        assertTrue("the sheet is hosted by the detail screen", screen.contains("RelayAvatarPickerSheet("))
        val sheet = repoFile("feature/providers/detail/RelayAvatarPickerSheet.kt").readText()
        assertTrue("title Change icon", sheet.contains("stringResource(R.string.relay_avatar_change_icon)"))
        assertTrue("trailing Done reuses the existing key", sheet.contains("stringResource(R.string.done)"))
        assertTrue("cells come from the production pickerCells", sheet.contains("RelayAvatarResolver.pickerCells("))
        assertTrue("4-column grid", sheet.contains("chunked(RelayAvatarPickerColumns)") && sheet.contains("RelayAvatarPickerColumns = 4"))
        assertTrue(
            "cell labels wrap to at most 2 centered lines",
            Regex("""textAlign = TextAlign\.Center,\s*(//[^\n]*\n\s*)?maxLines = 2,""").containsMatchIn(sheet),
        )
    }

    @Test
    fun `BOARD-AVATAR-PICKER-02 tapping a cell changes the detail header avatar at once`() {
        val store = ai.oriveo.community.core.model.RelayAvatarChoiceStore
        store.configurePersistenceForTesting(emptyMap()) { _, _ -> }
        try {
            val provider = relay()
            val before = RelayDetailBoardModel.build(provider, isRedetecting = false)
            assertTrue("the default is an icon, no longer the initial", before.avatar is ai.oriveo.community.core.model.RelayAvatarResult.Icon)
            val cell = before.avatarPickerCells
                .filterIsInstance<ai.oriveo.community.core.model.RelayAvatarPickerCell.Icon>()
                .first { it.preview != before.avatar }
            assertEquals("the current avatar matches exactly one picker cell (selected state)", 1, before.avatarPickerCells.count { it.preview == before.avatar })

            RelayDetailBoardModel.pickAvatar(provider, cell)

            val after = RelayDetailBoardModel.build(provider, isRedetecting = false)
            assertEquals(cell.preview, after.avatar)
            assertEquals(cell.icon.id, store.choice(provider.id))
            // The detail header draws the board result directly and the screen subscribes to the choice store, so a tapped cell rebuilds the board in the same frame.
            val header = repoFile("feature/providers/detail/RelayDetailBoardView.kt").readText()
                .substringAfter("private fun BoardHeader(").substringBefore("\n}\n")
            assertTrue(header.contains("RelayAvatar(result = avatar"))
            val screen = repoFile("feature/providers/detail/ProviderDetailScreen.kt").readText()
            assertTrue(screen.contains("RelayAvatarChoiceStore.choices.collectAsStateWithLifecycle()"))
        } finally {
            store.resetForTesting()
        }
    }

    // ── BOARD-DETAIL-04: single entry point for actions ──

    @Test
    fun `BOARD-DETAIL-04 the four actions live on the detail board`() {
        val localWithKey = local("llamacpp", RelayTransport.OpenAIChatCompletions).copy(apiKey = "sk-local-0000001234", apiKeyPreview = "sk-••1234")
        listOf(relay(), localWithKey).forEach { provider ->
            val board = RelayDetailBoardModel.build(provider, isRedetecting = false)
            val actions = board.headerActions +
                (board.connectionRows + board.modelRows).mapNotNull { it.action } +
                board.buttons.map { it.action }
            assertTrue(actions.toString(), actions.containsAll(listOf(RelayDetailAction.Rename, RelayDetailAction.OpenKeys, RelayDetailAction.Delete)))
            // The old settings area's "Connection settings" and "Delete" rows and the model row menu's "Set as default" no longer appear for Relay / local.
            assertFalse(RelayDetailBoardModel.showsLegacySettingsRows(provider))
            assertFalse(RelayDetailBoardModel.offersSetDefaultInModelMenu(provider))
        }
        val official = Provider(id = "openai", kind = ProviderKind.OpenAI)
        assertFalse(RelayDetailBoardModel.appliesTo(official))
        assertTrue(RelayDetailBoardModel.showsLegacySettingsRows(official))
        assertTrue(RelayDetailBoardModel.offersSetDefaultInModelMenu(official))
    }

    @Test
    fun `BOARD-DETAIL-04 edit connection no longer carries rename key default model or delete`() {
        val sheet = repoFile("feature/providers/relay/RelayAdvancedSettingsSheet.kt").readText()
        val card = repoFile("feature/providers/relay/RelayEditConnectionCard.kt").readText()
        listOf("startEditApiKey", "onEditApiKey", "relay_default_model_label", "renameProvider", "showDeleteConfirm", "deleteProvider").forEach { token ->
            assertFalse("edit connection still contains $token", sheet.contains(token))
        }
        assertFalse("edit connection card still draws the API Key row", card.contains("ApiKeyRow(") || card.contains("onEditApiKey"))
        val screen = repoFile("feature/providers/detail/ProviderDetailScreen.kt").readText()
        assertTrue("the detail screen must host the board", screen.contains("RelayDetailBoardView("))
    }

    @Test
    fun `BOARD-DETAIL-04 relay has no default model so setDefaultModel writes nothing`() = runTest(StandardTestDispatcher()) {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        val provider = relay(requested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions, modelID = "claude-sonnet-4.5"))
        val repository = mockk<ProviderRepository>()
        every { repository.observeById("provider-1") } returns MutableStateFlow(provider)
        var written: Provider? = null
        coEvery { repository.updateProvider(any()) } coAnswers { written = firstArg() }
        val vm = detailViewModel(repository)
        backgroundScope.launch { vm.provider.collect {} }
        advanceUntilIdle()

        vm.setDefaultModel(provider.models.single { it.id == "gpt-5" })
        advanceUntilIdle()

        // Relays have no default model: neither isDefault nor relayRequested.modelID is written.
        assertNull(written)
    }

    // ── BOARD-DETAIL-05: re-detect button ──

    private val accountID = ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID

    private inner class Harness(initial: Provider, private val catalogStatus: HttpStatusCode) {
        val gate = CompletableDeferred<Unit>()
        val catalogRequests = AtomicInteger(0)
        var stored: ai.oriveo.community.core.data.entity.ProviderEntity? = with(ProviderMapper) { initial.toEntity(accountID) }

        private val engine = MockEngine { request ->
            if (request.method == HttpMethod.Get && request.url.encodedPath == "/v1/models") {
                catalogRequests.incrementAndGet()
                gate.await()
                if (catalogStatus != HttpStatusCode.OK) return@MockEngine respond("{}", catalogStatus)
                return@MockEngine respond(
                    """{"object":"list","data":[{"id":"claude-sonnet-4.5","object":"model"},{"id":"gpt-5","object":"model"},{"id":"o3","object":"model"}]}""",
                    HttpStatusCode.OK,
                    headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                )
            }
            respond("{}", HttpStatusCode.NotFound)
        }

        val repository: ProviderRepository = run {
            val dao = mockk<ai.oriveo.community.core.data.dao.ProviderDao>()
            coEvery { dao.getById(any(), any()) } coAnswers {
                stored?.takeIf { it.accountId == firstArg<String>() && it.id == secondArg<String>() }
            }
            coEvery { dao.upsert(any()) } coAnswers { stored = firstArg() }
            coEvery { dao.getAll(any()) } coAnswers { listOfNotNull(stored) }
            val keys = mockk<ai.oriveo.community.core.security.SecureKeyStore>(relaxed = true)
            every { keys.getApiKey(any(), any()) } returns "sk-live-0000000000007f2a"
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
                metadataRefreshEventBus = MetadataRefreshEventBus(debounceMillis = 0),
                httpClient = HttpClient(MockEngine { respond("", HttpStatusCode.NotFound) }),
            )
        }

        fun current(): Provider = with(ProviderMapper) { requireNotNull(stored).toDomain("sk-live-0000000000007f2a") }
    }

    /** The default model already has an observed protocol: re-detection only refreshes the catalog and sends no probe request. */
    private fun redetectConnection() = relay(
        models = listOf(
            AIModel(
                id = "claude-sonnet-4.5",
                name = "claude-sonnet-4.5",
                isDefault = true,
                relayTransport = RelayTransport.OpenAIChatCompletions,
                relayTransportSource = RelayTransportSource.Observed,
            ),
        ),
        catalog = emptyList(),
    ).copy(
        baseUrlText = "https://relay.example.com",
        lastCheckedAt = null,
        relayRequested = RelayRequestedConfig(
            transport = RelayTransport.OpenAIChatCompletions,
            resolvedAPIBaseURL = "https://relay.example.com/v1",
        ),
    )

    private val snackbar = mockk<GlobalSnackbarManager>(relaxed = true)

    private fun detailViewModel(repository: ProviderRepository) = ProviderDetailViewModel(
        savedStateHandle = SavedStateHandle(mapOf("providerID" to "provider-1")),
        providerRepository = repository,
        appPreferencesRepository = mockk<AppPreferencesRepository>(relaxed = true),
        metadataRefreshEventBus = MetadataRefreshEventBus(debounceMillis = 0),
        applicationScope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined),
        globalSnackbarManager = snackbar,
    )

    private fun redetectViewModel(harness: Harness): Pair<ProviderDetailViewModel, ProviderRepository> {
        val repository = mockk<ProviderRepository>()
        every { repository.observeById("provider-1") } returns MutableStateFlow(harness.current())
        coEvery { repository.redetectRelayModels(any()) } coAnswers { harness.repository.redetectRelayModels(firstArg()) }
        return detailViewModel(repository) to repository
    }

    private suspend fun awaitIdle(vm: ProviderDetailViewModel) = withTimeout(10_000) {
        while (vm.isRedetecting) delay(10)
    }

    @Test
    fun `BOARD-DETAIL-05 detect again runs production redetect once and is disabled while running`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val harness = Harness(redetectConnection(), HttpStatusCode.OK)
        val (vm, repository) = redetectViewModel(harness)

        vm.redetectRelayModels()
        assertTrue(vm.isRedetecting)
        val running = RelayDetailBoardModel.build(harness.current(), vm.isRedetecting).buttons.single { it.action == RelayDetailAction.Redetect }
        assertFalse(running.enabled)
        assertTrue(running.loading)
        // Tapping again while in progress does not send a second request.
        vm.redetectRelayModels()
        harness.gate.complete(Unit)
        awaitIdle(vm)

        coVerify(exactly = 1) { repository.redetectRelayModels("provider-1") }
        assertEquals(1, harness.catalogRequests.get())
        val stored = harness.current()
        assertEquals(listOf("claude-sonnet-4.5", "gpt-5", "o3"), stored.catalogModels.map { it.id })
        assertNotNull("success updates the header time", stored.lastCheckedAt)
        val idle = RelayDetailBoardModel.build(stored, vm.isRedetecting).buttons.single { it.action == RelayDetailAction.Redetect }
        assertTrue(idle.enabled)
        assertFalse(idle.loading)
    }

    @Test
    fun `BOARD-DETAIL-05 a failed catalog refresh keeps the old check time and shows the error`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val harness = Harness(redetectConnection(), HttpStatusCode.InternalServerError)
        harness.gate.complete(Unit)
        val (vm, _) = redetectViewModel(harness)

        vm.redetectRelayModels()
        awaitIdle(vm)

        assertNull("a failed catalog refresh does not write the check time", harness.current().lastCheckedAt)
        verify { snackbar.show(match { it.style == GlobalToastStyle.Error }) }
    }

    // ── BOARD-DETAIL-06: auto connection ──

    @Test
    fun `BOARD-DETAIL-06 auto connection is Custom and shows Auto as its protocol`() {
        val autoRequested = RelayRequestedConfig(transport = RelayTransport.Auto)
        assertEquals(RelayKind.Custom, RelayKindDefaults.inferKind(autoRequested))
        // Even if the stored relayKind is something else it is shown / edited as Custom (mapped on read, not written back).
        assertEquals(RelayKind.Custom, RelayKindDefaults.effectiveKind(RelayKind.OpenAICompatible, autoRequested))
        assertEquals(RelayKind.CodexStyle, RelayKindDefaults.effectiveKind(RelayKind.CodexStyle, RelayRequestedConfig(transport = RelayTransport.OpenAIResponses)))

        val provider = relay(requested = autoRequested, relayKind = RelayKind.OpenAICompatible)
        val protocol = RelayDetailBoardModel.build(provider, isRedetecting = false).connectionRows.single { it.id == RelayDetailRowId.DefaultProtocol }
        assertEquals(R.string.relay_detail_protocol_auto_per_model, protocol.valueRes)
        assertEquals(RelayKind.OpenAICompatible, provider.relayKind)
    }

    // ── BOARD-DETAIL-07: channel selector in local connection editing ──

    @Test
    fun `BOARD-DETAIL-07 local edit connection shows one channel control from LocalEngineChannels`() {
        val llama = requireNotNull(ai.oriveo.community.feature.providers.relay.relayEditChannelSection("llamacpp"))
        assertEquals(listOf(RelayTransport.OpenAIChatCompletions, RelayTransport.LlamaCppNative), llama.options)
        assertTrue(llama.editable)
        listOf("ollama", "lmstudio", "vllm", "openwebui").forEach { engine ->
            val section = requireNotNull(ai.oriveo.community.feature.providers.relay.relayEditChannelSection(engine))
            assertEquals(engine, listOf(RelayTransport.OpenAIChatCompletions), section.options)
            assertFalse(engine, section.editable)
        }
        // Not a local connection: keeps the protocol menu.
        assertNull(ai.oriveo.community.feature.providers.relay.relayEditChannelSection(null))
        assertNull(ai.oriveo.community.feature.providers.relay.relayEditChannelSection(""))

        // The channel block is independent of the connection type (present for any stored type); local shows no protocol group, so there is no second channel control.
        ai.oriveo.community.core.model.RelayKind.entries.forEach { kind ->
            val local = Provider(
                id = "local-1",
                kind = ProviderKind.Relay,
                baseUrlText = "http://127.0.0.1:8080/v1",
                relayKind = kind,
                relayRequested = RelayRequestedConfig(
                    transport = RelayTransport.OpenAIChatCompletions,
                    securityMode = ai.oriveo.community.core.model.RelayConnectionSecurityMode.LocalHttp,
                    engineProfile = "llamacpp",
                ),
            )
            val board = ai.oriveo.community.feature.providers.relay.RelayEditBoardModel.make(
                provider = local,
                draft = ai.oriveo.community.feature.providers.relay.RelayEditDraft.from(local, null),
                status = null,
                isSaving = false,
                issues = emptyList(),
            )
            val channel = board.groups.single { it.id == ai.oriveo.community.feature.providers.relay.RelayEditGroupId.Channel }
            assertEquals(R.string.local_setup_tile_channel, channel.titleRes)
            assertTrue(channel.rows.single { it.id == ai.oriveo.community.feature.providers.relay.RelayEditRowId.Channel }.hasMenu)
            assertTrue(board.groups.none { it.id == ai.oriveo.community.feature.providers.relay.RelayEditGroupId.ProtocolAuth })
        }
    }

    // ── BOARD-DETAIL-11: the parameters row is the third row of the model card; relay / local no longer show a Settings section ──

    @Test
    fun `BOARD-DETAIL-11 parameters is the third model row and the settings section is gone`() {
        val relayBoard = RelayDetailBoardModel.build(relay(), isRedetecting = false)
        assertEquals(
            listOf(RelayDetailRowId.ModelLibrary, RelayDetailRowId.WebSearch, RelayDetailRowId.Parameters),
            relayBoard.modelRows.map { it.id },
        )
        val localBoard = RelayDetailBoardModel.build(local("llamacpp", RelayTransport.OpenAIChatCompletions), isRedetecting = false)
        assertEquals(
            listOf(RelayDetailRowId.ModelLibrary, RelayDetailRowId.Thinking, RelayDetailRowId.Parameters),
            localBoard.modelRows.map { it.id },
        )
        listOf(relayBoard, localBoard).forEach { board ->
            val row = board.modelRows[2]
            assertEquals(R.string.generation_parameters_section, row.titleRes)
            assertEquals(RelayDetailAction.OpenParameters, row.action)
            assertNull("no value", row.value)
            assertNull("no value", row.valueRes)
            assertNull("no trailing note", row.trailingRes)
        }
        // The icon is not the slider of the top-right "Edit connection" but a thermometer; row color is rose.
        assertEquals(R.drawable.ph_thermometer_simple, relayDetailRowIcon(RelayDetailRowId.Parameters))
        assertTrue(relayDetailRowIcon(RelayDetailRowId.Parameters) != R.drawable.ph_sliders_horizontal)
        assertEquals(RelayDetailIconTone.Rose, relayDetailRowIconTone(RelayDetailRowId.Parameters))

        // The board view no longer takes a Settings section; official providers still render the settings card.
        val view = repoFile("feature/providers/detail/RelayDetailBoardView.kt").readText()
        assertFalse("the board no longer hosts settingsContent", view.contains("settingsContent"))
        val screen = repoFile("feature/providers/detail/ProviderDetailScreen.kt").readText()
        assertEquals("only the official provider settings card remains", 1, Regex("""ProviderDetailSettingsCard\(""").findAll(screen).count())
    }

    // ── BOARD-DETAIL-12: relay / local recovery card ──

    private fun issue(provider: Provider, error: String? = "HTTP 502 Bad Gateway") = provider.copy(
        status = ai.oriveo.community.core.model.ProviderConnectionState.Issue(error.orEmpty()),
        lastError = error,
    )

    @Test
    fun `BOARD-DETAIL-12 recovery card actions, title and reason row`() {
        // Not shown when the connection is healthy; not shown for official providers (they keep the original card).
        assertNull(RelayDetailBoardModel.recoveryCard(relay(), isReverifying = false, omitsDetail = false))
        assertNull(
            RelayDetailBoardModel.recoveryCard(
                issue(relay()).copy(kind = ProviderKind.OpenAI, relayRequested = null),
                isReverifying = false,
                omitsDetail = false,
            ),
        )

        // (1) Relay: edit connection / API key / re-verify.
        val card = requireNotNull(RelayDetailBoardModel.recoveryCard(issue(relay(), "  HTTP 502 Bad Gateway  "), false, false))
        assertEquals(
            listOf(RelayDetailAction.EditConnection, RelayDetailAction.OpenKeys, RelayDetailAction.Reverify),
            card.actions.map { it.action },
        )
        assertEquals(
            listOf(R.string.relay_detail_edit_connection, R.string.relay_keys_title, R.string.relay_recovery_verify_again),
            card.actions.map { it.titleRes },
        )
        assertEquals(
            listOf(R.drawable.ph_sliders_horizontal, R.drawable.ph_key, R.drawable.ph_arrow_clockwise),
            card.actions.map { it.iconRes },
        )
        // (2) Not missing a key: generic title + warning icon, title not tappable; reason row = lastError (trimmed).
        assertEquals(R.string.relay_recovery_needs_attention, card.titleRes)
        assertEquals(R.drawable.ph_warning, card.titleIconRes)
        assertNull(card.titleAction)
        assertEquals("HTTP 502 Bad Gateway", card.reason)

        // No credentials needed (local without auth): no API key action.
        val localCard = requireNotNull(
            RelayDetailBoardModel.recoveryCard(issue(local("llamacpp", RelayTransport.OpenAIChatCompletions)), false, false),
        )
        assertEquals(listOf(RelayDetailAction.EditConnection, RelayDetailAction.Reverify), localCard.actions.map { it.action })
        // Local with auth behaves like a relay.
        val localAuth = local("llamacpp", RelayTransport.OpenAIChatCompletions).let {
            it.copy(apiKey = "sk-local-0000001234", relayRequested = it.relayRequested?.copy(authMode = RelayAuthMode.Bearer))
        }
        assertEquals(
            listOf(RelayDetailAction.EditConnection, RelayDetailAction.OpenKeys, RelayDetailAction.Reverify),
            requireNotNull(RelayDetailBoardModel.recoveryCard(issue(localAuth), false, false)).actions.map { it.action },
        )

        // (2) Missing key: key icon + "not saved on this device", title tappable = same destination as API key, reason row empty.
        val missing = requireNotNull(RelayDetailBoardModel.recoveryCard(relay(apiKey = ""), false, false))
        assertEquals(R.string.provider_api_key_not_saved, missing.titleRes)
        assertEquals(R.drawable.ph_key, missing.titleIconRes)
        assertEquals(RelayDetailAction.OpenKeys, missing.titleAction)
        assertNull(missing.reason)
        assertTrue(RelayDetailAction.OpenKeys in missing.actions.map { it.action })

        // (4) When the one-time notice is "saved without verification" the reason row is omitted; title and actions are unchanged.
        val omitted = requireNotNull(RelayDetailBoardModel.recoveryCard(issue(relay()), false, omitsDetail = true))
        assertNull(omitted.reason)
        assertEquals(card.titleRes, omitted.titleRes)
        assertEquals(card.actions.map { it.action }, omitted.actions.map { it.action })
        // (5) Navigation: edit connection / API key open pages, re-verify does not.
        assertEquals(
            listOf(true, true, false),
            card.actions.map { RelayDetailBoardModel.opensPage(it.action) },
        )
    }

    @Test
    fun `BOARD-DETAIL-12 verify again runs production resync once and disables only its row`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val provider = issue(relay())
        val gate = CompletableDeferred<Unit>()
        val repository = mockk<ProviderRepository>()
        every { repository.observeById("provider-1") } returns MutableStateFlow(provider)
        coEvery { repository.reverifyRelayProvider(any()) } coAnswers {
            gate.await()
            provider
        }
        val vm = detailViewModel(repository)

        vm.resync()
        assertTrue(vm.isResyncing)
        val running = requireNotNull(RelayDetailBoardModel.recoveryCard(provider, vm.isResyncing, false))
        val reverify = running.actions.single { it.action == RelayDetailAction.Reverify }
        assertTrue(reverify.running)
        assertFalse(reverify.enabled)
        assertTrue("other actions are unaffected", running.actions.filter { it.action != RelayDetailAction.Reverify }.all { it.enabled && !it.running })
        // (3) Tapping again while in progress does not send a second request.
        vm.resync()
        gate.complete(Unit)
        withTimeout(10_000) { while (vm.isResyncing) delay(10) }

        coVerify(exactly = 1) { repository.reverifyRelayProvider("provider-1") }
        val idle = requireNotNull(RelayDetailBoardModel.recoveryCard(provider, vm.isResyncing, false))
            .actions.single { it.action == RelayDetailAction.Reverify }
        assertTrue(idle.enabled)
        assertFalse(idle.running)
    }

    // ── BOARD-DETAIL-13: two footnote states + default protocol value ──

    @Test
    fun `BOARD-DETAIL-13 footnote and default protocol value follow auto or a chosen protocol`() {
        val auto = RelayDetailBoardModel.build(relay(requested = RelayRequestedConfig(transport = RelayTransport.Auto)), isRedetecting = false)
        assertEquals(R.string.relay_detail_detect_footnote, auto.footnoteRes)
        assertEquals(
            R.string.relay_detail_protocol_auto_per_model,
            auto.connectionRows.single { it.id == RelayDetailRowId.DefaultProtocol }.valueRes,
        )
        listOf(
            RelayTransport.OpenAIChatCompletions,
            RelayTransport.OpenAIResponses,
            RelayTransport.AnthropicMessages,
            RelayTransport.GeminiGenerateContent,
        ).forEach { transport ->
            val board = RelayDetailBoardModel.build(relay(requested = RelayRequestedConfig(transport = transport)), isRedetecting = false)
            assertEquals(transport.name, R.string.relay_detail_detect_footnote_catalog, board.footnoteRes)
            assertEquals(
                transport.name,
                ai.oriveo.community.feature.providers.relay.relayTransportLabelRes(transport),
                board.connectionRows.single { it.id == RelayDetailRowId.DefaultProtocol }.valueRes,
            )
        }
        // Local: the fixed sentence (the channel is per connection; protocols are not detected per model).
        assertEquals(
            R.string.relay_detail_detect_footnote_catalog,
            RelayDetailBoardModel.build(local("llamacpp", RelayTransport.OpenAIChatCompletions), isRedetecting = false).footnoteRes,
        )
    }

    // ── BOARD-DETAIL-14: the address row opens connection editing ──

    @Test
    fun `BOARD-DETAIL-14 address rows open edit connection and the engine row is not tappable`() {
        val relayRows = RelayDetailBoardModel.build(relay(), isRedetecting = false).connectionRows
        val url = relayRows.single { it.id == RelayDetailRowId.RequestUrl }
        assertEquals(RelayDetailAction.EditConnection, url.action)
        assertEquals("same destination as the default protocol row", relayRows.single { it.id == RelayDetailRowId.DefaultProtocol }.action, url.action)

        listOf("llamacpp", "ollama", "lmstudio", "vllm", "openwebui").forEach { engine ->
            val rows = RelayDetailBoardModel.build(local(engine, RelayTransport.OpenAIChatCompletions), isRedetecting = false).connectionRows
            assertEquals(engine, RelayDetailAction.EditConnection, rows.single { it.id == RelayDetailRowId.EngineAddress }.action)
            assertNull(engine, rows.single { it.id == RelayDetailRowId.Engine }.action)
        }
    }

    // ── helpers ──

    private fun repoFile(relative: String): File {
        val direct = File("src/main/java/ai/oriveo/community/$relative")
        if (direct.exists()) return direct
        var dir = File(System.getProperty("user.dir")!!).absoluteFile
        val prefix = "android/app/src/main/java/ai/oriveo/community/"
        while (true) {
            val candidate = File(dir, prefix + relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile ?: break
        }
        error("cannot find $relative")
    }

    private fun apiKeyRowOf(provider: Provider) =
        RelayDetailBoardModel.build(provider, isRedetecting = false).connectionRows.single { it.id == RelayDetailRowId.ApiKey }

    @Test
    fun `a single stored key shows the add-more hint at row end`() {
        val key = apiKeyRowOf(relay())
        assertEquals("sk-••••••••7f2a", key.value)
        assertEquals(R.string.relay_keys_add_more_hint, key.trailingRes)
        // The hint is not a button: the whole row still opens the keys page, there is no second action.
        assertEquals(RelayDetailAction.OpenKeys, key.action)
        assertNull(key.secondaryAction)
    }

    @Test
    fun `hint is hidden for multiple keys - unset - or no key required`() {
        val keys = listOf(
            ai.oriveo.community.core.model.RelayKey("initial", name = "Main"),
            ai.oriveo.community.core.model.RelayKey("k-b", apiKey = "sk-b-000000000002"),
        )
        val many = apiKeyRowOf(relay().copy(relayKeys = keys))
        assertEquals(2, many.keyCount)
        assertNull(many.trailingRes)

        val unset = apiKeyRowOf(relay(apiKey = ""))
        assertEquals(R.string.tap_to_set, unset.valueRes)
        assertNull(unset.trailingRes)

        val notNeeded = apiKeyRowOf(
            relay(apiKey = "", requested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions, authMode = RelayAuthMode.None)),
        )
        assertEquals(R.string.relay_detail_no_key, notNeeded.valueRes)
        assertNull(notNeeded.trailingRes)

        // No auth required but a leftover key: mask, tappable and remove entry stay as before, no hint at row end.
        val residual = apiKeyRowOf(
            relay(requested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions, authMode = RelayAuthMode.None)),
        )
        assertEquals("sk-••••••••7f2a", residual.value)
        assertNull(residual.trailingRes)
        assertEquals(RelayDetailAction.OpenKeys, residual.action)
        assertEquals(RelayDetailAction.RemoveStoredKey, residual.secondaryAction)
    }

    @Test
    fun `detail row icons are colored per row`() {
        val expected = mapOf(
            RelayDetailRowId.ModelLibrary to RelayDetailIconTone.Teal,
            RelayDetailRowId.RequestUrl to RelayDetailIconTone.Cyan,
            RelayDetailRowId.EngineAddress to RelayDetailIconTone.Cyan,
            RelayDetailRowId.DefaultProtocol to RelayDetailIconTone.Indigo,
            RelayDetailRowId.Channel to RelayDetailIconTone.Indigo,
            RelayDetailRowId.ApiKey to RelayDetailIconTone.Orange,
            RelayDetailRowId.Engine to RelayDetailIconTone.Rose,
            RelayDetailRowId.Parameters to RelayDetailIconTone.Rose,
            // web search / thinking keep the capability colors
            RelayDetailRowId.WebSearch to RelayDetailIconTone.CapabilityWebSearch,
            RelayDetailRowId.Thinking to RelayDetailIconTone.CapabilityReasoning,
            // the root address row has no leading icon
            RelayDetailRowId.BasePaths to null,
        )
        RelayDetailRowId.entries.forEach { id ->
            assertEquals(id.name, expected.getValue(id), relayDetailRowIconTone(id))
        }
        // no row falls back to the identity color; the header still uses it
        assertTrue(RelayDetailRowId.entries.none { relayDetailRowIconTone(it) == RelayDetailIconTone.Identity })
        assertEquals(RelayDetailIconTone.Identity, relayDetailHeaderIconTone)
    }
}
