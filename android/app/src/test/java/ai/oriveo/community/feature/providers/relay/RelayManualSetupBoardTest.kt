package ai.oriveo.community.feature.providers.relay

import android.content.Context
import ai.oriveo.community.R
import ai.oriveo.community.core.data.entity.ProviderEntity
import ai.oriveo.community.core.data.mapper.ProviderMapper
import ai.oriveo.community.core.data.remote.MetadataRefreshEventBus
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.model.RelayKey
import ai.oriveo.community.core.model.RelayKeyValue
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.navigation.ProviderSetupEntryPoint
import ai.oriveo.community.core.provider.RelayDiscoveryService
import ai.oriveo.community.core.provider.RelayFormValidation
import ai.oriveo.community.core.provider.RelayService
import ai.oriveo.community.core.provider.relay.RelayKeyBinding
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.security.SecureKeyStore
import ai.oriveo.community.feature.providers.detail.ProviderDetailNotice
import ai.oriveo.community.feature.providers.detail.RelayDetailIconTone
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
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
import java.io.File
import java.util.Collections

/**
 * Manual setup merged into one page (ManualSetup board, cases BOARD-MANUAL-01 to 12): production [RelaySetupViewModel] +
 * production [ProviderRepository] / [RelayService] hit a MockEngine fake relay, counting generation / catalog requests; persisted objects round-trip through the production ProviderMapper.
 * The board only asserts the output of [RelayManualSetupBoardModel.make] (via [RelaySetupViewModel.manualBoard]).
 */
@OptIn(ExperimentalCoroutinesApi::class)
class RelayManualSetupBoardTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Before
    fun setUp() {
        Dispatchers.setMain(Dispatchers.Unconfined)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    // ── BOARD-MANUAL-01 ──

    @Test
    fun `BOARD-MANUAL-01 one page block order hero fields and no test connection or step counter`() {
        val harness = Harness()
        val vm = harness.viewModel()
        vm.showManualSetup()
        val board = vm.manualBoard

        assertEquals(
            listOf(
                RelayManualBlock.RequestUrl,
                RelayManualBlock.ApiKeys,
                RelayManualBlock.Model,
                RelayManualBlock.ConnectionName,
                RelayManualBlock.ProtocolCard,
                RelayManualBlock.Advanced,
            ),
            board.blocks,
        )
        // The hero shares its label / title with quick setup step 1; the subtitle and trailing labels belong to the manual page.
        assertEquals(vm.board.heroLabel, board.heroLabelRes)
        assertEquals(vm.board.heroTitle, board.heroTitleRes)
        assertEquals(R.string.relay_manual_hero_subtitle, board.heroSubtitleRes)
        assertEquals(R.string.relay_manual_setup, board.heroTagRes)
        assertEquals(R.string.relay_manual_use_quick_setup, board.leadingActionRes)

        // Address: the same preview function as step 1.
        assertEquals(R.string.relay_field_endpoint, board.requestUrlTitleRes)
        assertEquals(R.drawable.ph_link, board.requestUrlIcon)
        assertEquals(vm.board.willRequest, board.willRequest)
        assertEquals("https://relay.example.com/v1/…", board.willRequest)

        // Key: the same slots as step 1.
        assertEquals(vm.board.keys, board.keys)
        assertFalse(board.keys.single().showsName)
        vm.addKey()
        assertTrue(vm.manualBoard.keys.all { it.showsName })
        assertEquals(vm.board.keys, vm.manualBoard.keys)

        // Model: placeholder = the flagship model ID delivered by the server.
        assertEquals(R.string.relay_default_model_label, board.modelTitleRes)
        assertEquals(R.drawable.ph_squares_four, board.modelIcon)
        assertEquals(FLAGSHIP, board.modelPlaceholder)
        assertEquals(R.string.relay_manual_model_footnote, board.modelFootnoteRes)

        // Connection name: in-slot label "Name (optional)", placeholder = the domain in the address.
        assertEquals(R.string.relay_manual_connection_name, board.connectionNameTitleRes)
        assertEquals(R.drawable.ph_pencil_simple, board.connectionNameIcon)
        assertEquals(R.string.relay_setup_key_name, board.connectionNameSlotLabelRes)
        assertEquals("example.com", board.connectionNamePlaceholder)
        assertEquals(R.string.relay_manual_connection_name_footnote, board.connectionNameFootnoteRes)

        // Protocol card: not collapsible, only the default protocol row.
        assertEquals(R.string.relay_advanced_transport, board.protocolGroup.titleRes)
        assertFalse(board.protocolGroup.collapsible)
        assertEquals(listOf(RelayEditRowId.DefaultProtocol), board.protocolGroup.rows.map { it.id })

        // Collapsible group: collapsed by default; rows = auth / UA / each request header / each query parameter / add, the same rows as edit connection.
        val advanced = board.advancedGroup
        assertEquals(R.string.relay_manual_group_auth_headers, advanced.titleRes)
        assertTrue(advanced.collapsible)
        assertFalse(advanced.expanded)
        vm.updateManualHeaders(listOf(RelayKeyValue("X-Trace", "1")))
        vm.updateManualQueryParams(listOf(RelayKeyValue("region", "us")))
        vm.toggleManualAdvanced()
        val rows = vm.manualBoard.advancedGroup.rows
        assertTrue(vm.manualBoard.advancedGroup.expanded)
        assertEquals(
            listOf(RelayEditRowId.Authentication, RelayEditRowId.UserAgent, RelayEditRowId.Header, RelayEditRowId.QueryParam, RelayEditRowId.AddEntry),
            rows.map { it.id },
        )
        val auth = rows.first()
        assertEquals(R.string.relay_advanced_auth_mode, auth.titleRes)
        assertTrue(auth.hasMenu)
        assertNull("the manual page auth row has no \"keys are managed on the detail page\" footnote", auth.footnote)
        assertEquals(R.string.relay_edit_user_agent, rows[1].titleRes)
        assertEquals(R.string.relay_edit_headers, rows[2].titleRes)
        assertTrue(rows[2].masked)
        assertEquals(R.string.relay_edit_query_params, rows[3].titleRes)
        assertFalse(rows[3].masked)

        // Only one primary button at the bottom.
        assertEquals(R.string.relay_validate_and_save, vm.manualBoard.primary.titleRes)

        // No type card page, step counter, test connection, streaming / service tier / do-not-retain-response / transport_kind.
        val screen = source("feature/providers/relay/RelaySetupScreen.kt")
        listOf(
            "RelayKindPicker(", "RelayStepHeader", "RelayStep2Header", "RelaySimpleSection", "RelayCustomAdvancedSection",
            "RelayActionBar(", "relay_setup_step_1_of_2", "relay_setup_step_2_of_2", "R.string.relay_test_connection",
            "relay_setup_test_connection_button", "relay_setup_stream_toggle", "relay_setup_transport_kind_picker",
            "R.string.relay_advanced_service_tier", "R.string.relay_advanced_disable_response_storage",
        ).forEach { assertFalse("the manual page must no longer contain $it", screen.contains(it)) }
        assertFalse(File("src/main/java/ai/oriveo/community/feature/providers/relay/RelayKindPicker.kt").exists())
        assertFalse(File("src/main/java/ai/oriveo/community/feature/providers/relay/RelayKindMeta.kt").exists())
        // The visible text and screen-reader name of the step 2 manual add confirm button = the generic "Add" (a text button inside the dialog).
        val confirm = screen.substringAfter("relay_setup_models_add_manual_confirm_button").substringBefore("dismissButton")
        assertTrue(confirm.contains("Text(stringResource(R.string.add))"))
        val vmSource = source("feature/providers/relay/RelaySetupViewModel.kt")
        assertFalse(vmSource.contains("RelayKindDefaults.makeRequested"))
        assertFalse(vmSource.contains("fun testConnection"))

        // New strings exist in all 16 languages.
        val newKeys = listOf(
            "relay_manual_hero_subtitle", "relay_manual_model_footnote", "relay_manual_connection_name",
            "relay_manual_connection_name_footnote", "relay_manual_group_auth_headers", "relay_manual_not_set",
            "relay_manual_use_quick_setup", "relay_manual_validate_again", "relay_manual_not_saved_yet",
            "relay_connection_not_verified",
        )
        LOCALES.forEach { dir ->
            val strings = File("src/main/res/$dir/strings.xml").readText()
            newKeys.forEach { key -> assertTrue("$dir is missing $key", strings.contains("name=\"$key\"")) }
        }
    }

    // ── BOARD-MANUAL-02 ──

    @Test
    fun `BOARD-MANUAL-02 default protocol starts at auto and renders the edit connection row`() {
        val vm = Harness().viewModel()
        vm.showManualSetup()
        val row = vm.manualBoard.protocolGroup.rows.single()
        assertEquals(RelayTransport.Auto, vm.manualTransport)
        assertEquals(R.string.relay_edit_default_protocol, row.titleRes)
        assertEquals(R.drawable.ph_hard_drives_duotone, row.icon)
        assertEquals(RelayDetailIconTone.Indigo, row.tone)
        assertTrue(row.hasMenu)
        assertEquals(RelayEditText(R.string.relay_edit_protocol_auto_footnote), row.footnote)
        // Candidate set = the same set as edit connection.
        assertEquals(RelayTransport.entries, RelayManualSetupBoardModel.protocolOptions)

        // The same protocol yields the same row value on the edit board.
        RelayTransport.entries.forEach { transport ->
            vm.selectManualTransport(transport)
            val edit = RelayEditBoardModel.make(
                provider = Provider(id = "p", kind = ProviderKind.Relay, relayRequested = RelayRequestedConfig(transport = transport)),
                draft = RelayEditDraft.from(
                    Provider(id = "p", kind = ProviderKind.Relay, relayRequested = RelayRequestedConfig(transport = transport)),
                    null,
                ),
                status = null,
                isSaving = false,
                issues = emptyList(),
            ).groups.single { it.id == RelayEditGroupId.ProtocolAuth }.rows.first()
            assertEquals(edit, vm.manualBoard.protocolGroup.rows.single())
        }
    }

    // ── BOARD-MANUAL-03 ──

    @Test
    fun `BOARD-MANUAL-03 collapsed group summary is auth mode and filled count`() {
        val vm = Harness().viewModel()
        vm.showManualSetup()
        assertEquals(RelayManualSummary(relayAuthModeMenuValueRes(RelayAuthMode.Auto), 0), vm.manualBoard.advancedSummary)

        vm.selectManualAuthMode(RelayAuthMode.Bearer)
        vm.updateManualUserAgent("my-agent")
        vm.updateManualHeaders(listOf(RelayKeyValue("X-Token", "v"), RelayKeyValue("", "orphan")))
        assertEquals(RelayManualSummary(relayAuthModeMenuValueRes(RelayAuthMode.Bearer), 2), vm.manualBoard.advancedSummary)
        vm.updateManualQueryParams(listOf(RelayKeyValue("region", "us")))
        assertEquals(3, vm.manualBoard.advancedSummary.filledCount)
        vm.updateManualUserAgent("   ")
        assertEquals(2, vm.manualBoard.advancedSummary.filledCount)
    }

    // ── BOARD-MANUAL-04 ──

    @Test
    fun `BOARD-MANUAL-04 one primary button and its enabled states`() = runBlocking {
        val harness = Harness(postStatus = HttpStatusCode.Unauthorized)
        val vm = harness.viewModel(endpoint = "", key = "")
        vm.showManualSetup()
        assertEquals(RelayManualPrimary(R.string.relay_validate_and_save, enabled = false, loading = false), vm.manualBoard.primary)

        vm.updateEndpoint("https://relay.example.com")
        vm.updateApiKey(KEY_A)
        assertFalse(vm.manualBoard.primary.enabled)
        vm.updateDefaultModel("   ")
        assertFalse(vm.manualBoard.primary.enabled)
        vm.updateDefaultModel("m1")
        assertTrue(vm.manualBoard.primary.enabled)

        // Public http: not tappable, and a tap sends no request.
        vm.updateEndpoint("http://relay.example.com")
        assertFalse(vm.manualBoard.primary.enabled)
        vm.validateManual()
        settle(vm)
        assertEquals(0, harness.posts.size)

        // Verifying: spinner + not tappable.
        vm.updateEndpoint("https://relay.example.com")
        harness.gate = CompletableDeferred()
        vm.validateManual()
        harness.awaitPosts(1)
        assertEquals(RelayManualPrimary(R.string.relay_validate_and_save, enabled = false, loading = true), vm.manualBoard.primary)
        harness.gate!!.complete(Unit)
        settle(vm)

        // After failure: "Verify again" is tappable.
        assertEquals(RelayManualPrimary(R.string.relay_manual_validate_again, enabled = true, loading = false), vm.manualBoard.primary)
    }

    // ── BOARD-MANUAL-05 ──

    @Test
    fun `BOARD-MANUAL-05 failed validation does not persist and the failure card hides every secret`() = runBlocking {
        val harness = Harness(postStatus = HttpStatusCode.Unauthorized)
        val vm = harness.filledManual()
        vm.addKey()
        vm.updateKeySecret(vm.board.keys[1].id, KEY_B)
        vm.selectManualTransport(RelayTransport.OpenAIChatCompletions)
        vm.updateManualUserAgent(UA_SECRET)
        vm.updateManualHeaders(listOf(RelayKeyValue("X-Api-Key", HEADER_SECRET)))
        vm.updateManualQueryParams(listOf(RelayKeyValue("token", QUERY_SECRET)))
        harness.echoInError = listOf(KEY_A, KEY_B, HEADER_SECRET, QUERY_SECRET, UA_SECRET)
        vm.validateManual()
        settle(vm)

        assertNull("a failed verification is not persisted", harness.stored)
        assertNull(vm.completionTarget)
        // Only the primary key is used, once.
        assertEquals(listOf("Bearer $KEY_A"), harness.posts.map { it.auth })
        val status = vm.manualBoard.status as RelayEditStatus.Failed
        assertTrue(status.canSaveUnverified)
        assertEquals(R.string.relay_manual_not_saved_yet, vm.manualBoard.failureNoteRes)
        assertEquals(RelayManualBlock.Failure, vm.manualBoard.blocks.last())
        val presentation = requireNotNull(status.presentation)
        assertNull("the failure card has no local exception text", presentation.localErrorDetail)
        val shown = listOf(status.message, presentation.endpoint, presentation.upstreamJson.orEmpty()).joinToString("\n")
        listOf(KEY_A, KEY_B, HEADER_SECRET, QUERY_SECRET, UA_SECRET).forEach { secret ->
            assertFalse("the failure card must not show $secret", shown.contains(secret))
        }
    }

    // ── BOARD-MANUAL-06 ──

    @Test
    fun `BOARD-MANUAL-06 save anyway persists once as unverified with no extra request`() = runBlocking {
        val harness = Harness(postStatus = HttpStatusCode.Unauthorized)
        val vm = harness.filledManual(endpoint = "relay.example.com")
        vm.selectManualTransport(RelayTransport.AnthropicMessages)
        vm.validateManual()
        settle(vm)
        // Input without a scheme is normalized and written back before verification.
        assertEquals("https://relay.example.com", vm.endpoint)
        val reason = (vm.manualBoard.status as RelayEditStatus.Failed).message

        vm.saveManualUnverified()
        settle(vm)
        assertEquals("no further requests", 1, harness.posts.size)
        val stored = harness.current()
        assertEquals(ProviderConnectionState.Issue(ProviderRepository.RELAY_UNVERIFIED_MESSAGE), stored.status)
        assertEquals(ProviderRepository.RELAY_UNVERIFIED_MESSAGE, stored.lastError)
        assertEquals("https://relay.example.com", stored.baseUrlText)
        assertEquals(listOf("m1"), stored.models.map { it.id })
        assertEquals(RelayKind.AnthropicCompatible, stored.relayKind)
        assertNull(stored.relayRequested?.modelID)

        val target = vm.completionTarget as RelaySetupCompletionTarget.ProviderDetail
        assertEquals(stored.id, target.providerId)
        assertNull(target.addedModelCount)
        assertEquals(reason, target.unverifiedReason)
        target.postAddedNotice(ProviderSetupEntryPoint.Providers)
        assertEquals(reason, ProviderDetailNotice.takeUnverified(stored.id))
        assertNull(ProviderDetailNotice.takeUnverified(stored.id))
        // The detail page notice is drawn the same way as on iOS: light warning-colored background + 30% warning-colored border, semibold title in the primary text color, reason in caption secondary color on its own line.
        val notice = source("feature/providers/detail/ProviderDetailScreen.kt")
            .substringAfter("private fun ProviderDetailUnverifiedNotice(").substringBefore("\n}\n")
        listOf(
            ".background(colors.warningSoft)",
            ".border(1.dp, colors.warning.copy(alpha = 0.3f), shape)",
            "R.string.relay_connection_not_verified",
            "fontWeight = FontWeight.SemiBold",
            "color = colors.textPrimary",
            "Text(text = reason, style = OriveoTheme.typography.caption, color = colors.textSecondary)",
        ).forEach { assertTrue("unverified notice is missing $it", notice.contains(it)) }

        // Completion latch: after persisting, neither the primary button nor "Save anyway" responds.
        vm.saveManualUnverified()
        vm.validateManual()
        settle(vm)
        assertEquals(1, harness.posts.size)
        assertEquals(1, harness.insertedIds.distinct().size)

    }

    // ── BOARD-MANUAL-07 ──

    @Test
    fun `BOARD-MANUAL-07-1 a chosen protocol is verified with one request and saved in the quick setup shape`() = runBlocking {
        val harness = Harness(catalog = listOf("m1", "m2"))
        val vm = harness.filledManual(endpoint = "relay.example.com")
        vm.addKey()
        val second = vm.board.keys[1].id
        vm.updateKeySecret(second, KEY_B)
        vm.updateKeyName(second, "Backup")
        vm.addKey() // the empty key is not attached
        vm.selectManualTransport(RelayTransport.OpenAIResponses)
        vm.selectManualAuthMode(RelayAuthMode.Bearer)
        vm.updateManualUserAgent("  my-agent  ")
        vm.updateManualHeaders(listOf(RelayKeyValue("X-Trace", "1"), RelayKeyValue("", "dropped")))
        vm.updateManualQueryParams(listOf(RelayKeyValue("region", "us"), RelayKeyValue("", "")))
        // Persist first, then refresh the catalog: persistence is done even while the catalog request hangs.
        harness.getGate = CompletableDeferred()
        vm.validateManual()
        settle(vm)
        harness.awaitStored()
        harness.awaitGets(1)

        assertEquals(listOf("/v1/responses" to "m1"), harness.posts.map { it.path to it.model })
        assertEquals("Bearer $KEY_A", harness.posts.single().auth)
        val stored = harness.current()
        assertEquals(ProviderConnectionState.Connected, stored.status)
        assertEquals("example.com", stored.displayName)
        assertEquals(RelayKind.CodexStyle, stored.relayKind)
        assertEquals(
            RelayRequestedConfig(
                transport = RelayTransport.OpenAIResponses,
                authMode = RelayAuthMode.Bearer,
                securityMode = RelayConnectionSecurityMode.RemoteHttps,
                modelID = null,
                serviceTier = null,
                stream = true,
                disableResponseStorage = true,
                codexCompatIdentity = true,
                headers = listOf(RelayKeyValue("X-Trace", "1")),
                queryParams = listOf(RelayKeyValue("region", "us")),
                customUserAgent = "my-agent",
            ),
            stored.relayRequested?.copy(resolvedAPIBaseURL = null, resolvedAPIBaseURLs = null),
        )
        assertNull("a selected protocol is not written to the model", stored.models.single { it.id == "m1" }.relayTransport)
        assertEquals(listOf(RelayKeyBinding.IMPLICIT_KEY_ID, second), RelayKeyBinding.keyIDs(stored))
        assertEquals("Backup", stored.relayKeys?.get(1)?.name)
        assertEquals(KEY_B, harness.secrets[second])
        assertTrue("detection did not run: per-key status not written", stored.relayKeys.orEmpty().all { it.status == null })
        assertTrue("detection did not run: which key listed which model is not written", stored.catalogModels.all { it.relayListedByKeyIDs == null })
        harness.getGate!!.complete(Unit)

        val target = vm.completionTarget as RelaySetupCompletionTarget.ProviderDetail
        assertEquals(1, target.addedModelCount)
        assertNull(target.unverifiedReason)
        // The one-time notice "N models added" has no reason line: only the added slot is written, not the unverified slot; the notice composable has a single line of text.
        target.postAddedNotice(ProviderSetupEntryPoint.Providers)
        assertNull(ProviderDetailNotice.takeUnverified(stored.id))
        assertEquals(1, ProviderDetailNotice.take(stored.id))
        val addedNotice = source("feature/providers/detail/ProviderDetailScreen.kt")
            .substringAfter("private fun ProviderDetailAddedNotice(").substringBefore("\n}\n")
        assertEquals("the added notice has a single line of text", 1, Regex("""\bText\(""").findAll(addedNotice).count())
        assertFalse("the added notice has no reason", addedNotice.contains("reason"))
        assertEquals(stored.id to "m1", harness.remembered)

        // A single key does not produce a multi-key list: at most the one entry materialized by the post-persist catalog fetch writing the primary key status.
        val single = Harness()
        val one = single.filledManual()
        one.selectManualTransport(RelayTransport.OpenAIChatCompletions)
        one.validateManual()
        settle(one)
        single.awaitStored()
        assertEquals(listOf(RelayKeyBinding.IMPLICIT_KEY_ID), RelayKeyBinding.keyIDs(single.current()))
        assertTrue(single.current().relayKeys.orEmpty().size <= 1)
    }

    @Test
    fun `BOARD-MANUAL-07-2 auto probes the family candidates and lands the passing protocol on the model`() = runBlocking {
        val harness = Harness(postStatusByPath = mapOf("/v1/chat/completions" to HttpStatusCode.NotFound))
        val vm = harness.filledManual(model = "claude-x", family = { "anthropic" })
        vm.updateConnectionName("  My Relay  ")
        vm.validateManual()
        settle(vm)
        // Between probe success and the start of persisting, the coordinator briefly returns to Ready (visible across threads in tests), so settle can return early: wait for persistence before reading.
        harness.awaitStored()

        assertTrue(harness.posts.size in 1..2)
        val stored = harness.current()
        assertEquals("My Relay", stored.displayName)
        assertEquals(RelayKind.Custom, stored.relayKind)
        val requested = requireNotNull(stored.relayRequested)
        assertEquals(RelayTransport.Auto, requested.transport)
        assertEquals(true, requested.disableResponseStorage)
        assertNull(requested.codexCompatIdentity)
        assertNull(requested.headers)
        assertNull(requested.queryParams)
        assertNull(requested.customUserAgent)
        assertEquals(RelayTransport.AnthropicMessages, stored.models.single().relayTransport)
    }

    @Test
    fun `BOARD-MANUAL-07-3 the catalog is refreshed once after saving and its failure never rolls back`() = runBlocking {
        val harness = Harness(catalog = listOf("m1", "m2"))
        val vm = harness.filledManual()
        vm.selectManualTransport(RelayTransport.OpenAIChatCompletions)
        vm.validateManual()
        settle(vm)
        harness.awaitGets(1)
        harness.awaitCatalog { it.size == 2 }
        assertEquals(setOf("m1", "m2"), harness.current().catalogModels.map { it.id }.toSet())

        val failing = Harness(catalogStatus = HttpStatusCode.InternalServerError)
        val other = failing.filledManual()
        other.selectManualTransport(RelayTransport.OpenAIChatCompletions)
        other.validateManual()
        settle(other)
        failing.awaitGets(1)
        delay(50)
        val stored = failing.current()
        assertEquals(ProviderConnectionState.Connected, stored.status)
        assertEquals(listOf("m1"), stored.models.map { it.id })
    }

    @Test
    fun `BOARD-MANUAL-07-4 telemetry relay kind follows the effective protocol`() {
        assertEquals(RelayKind.CodexStyle, RelayManualSetupBoardModel.telemetryKind(RelayTransport.OpenAIResponses, "https://relay.example.com"))
        assertEquals(RelayKind.AnthropicCompatible, RelayManualSetupBoardModel.telemetryKind(RelayTransport.Auto, "https://relay.example.com/v1/messages"))
        assertEquals(RelayKind.Custom, RelayManualSetupBoardModel.telemetryKind(RelayTransport.Auto, "https://relay.example.com"))
        assertEquals(RelayKind.Custom, RelayManualSetupBoardModel.telemetryKind(RelayTransport.Auto, "://"))
        val source = source("feature/providers/relay/RelaySetupViewModel.kt")
        assertFalse("the add relay page no longer emits kind_picker", source.contains("ProviderSetupStep.KindPicker"))
    }

    // ── BOARD-MANUAL-08 ──

    @Test
    fun `BOARD-MANUAL-08 changing an input retires the failure card while names do not`() = runBlocking {
        val edits: List<Pair<String, (RelaySetupViewModel) -> Unit>> = listOf(
            "address" to { it.updateEndpoint("https://relay2.example.com") },
            "key" to { it.updateApiKey("sk-other-0000000000009999") },
            "model" to { it.updateDefaultModel("m9") },
            "protocol" to { it.selectManualTransport(RelayTransport.GeminiGenerateContent) },
            "auth" to { it.selectManualAuthMode(RelayAuthMode.XApiKey) },
            "ua" to { it.updateManualUserAgent("ua") },
            "header" to { it.updateManualHeaders(listOf(RelayKeyValue("X-A", "1"))) },
            "query" to { it.updateManualQueryParams(listOf(RelayKeyValue("q", "1"))) },
        )
        edits.forEach { (label, edit) ->
            val harness = Harness(postStatus = HttpStatusCode.Unauthorized)
            val vm = harness.failedManual()
            edit(vm)
            assertNull("$label changed, the failure card disappears", vm.manualBoard.status)
            assertEquals(label, RelayManualPrimary(R.string.relay_validate_and_save, enabled = true, loading = false), vm.manualBoard.primary)
            vm.saveManualUnverified()
            settle(vm)
            assertNull("$label old failure can no longer be saved anyway", harness.stored)
        }

        // Changing the connection name / a single key name does not invalidate; Save anyway uses the name at that time.
        val harness = Harness(postStatus = HttpStatusCode.Unauthorized)
        val vm = harness.failedManual()
        vm.addKey()
        val keyID = vm.board.keys[1].id
        vm.updateKeySecret(keyID, KEY_B)
        // Adding a key with a value = changing the input.
        assertNull(vm.manualBoard.status)
        vm.validateManual()
        settle(vm)
        assertNotNull(vm.manualBoard.status)
        vm.updateConnectionName("Renamed")
        vm.updateKeyName(keyID, "Second")
        assertNotNull(vm.manualBoard.status)
        vm.saveManualUnverified()
        settle(vm)
        val stored = harness.current()
        assertEquals("Renamed", stored.displayName)
        assertEquals("Second", stored.relayKeys?.get(1)?.name)
    }

    @Test
    fun `BOARD-MANUAL-08 in flight results only commit while the attempt and the inputs are still current`() = runBlocking {
        // In-flight success: invalidated after the input changes, not persisted and no navigation; the button resets immediately.
        val pass = Harness()
        val vm = pass.filledManual()
        vm.selectManualTransport(RelayTransport.OpenAIChatCompletions)
        pass.gate = CompletableDeferred()
        vm.validateManual()
        pass.awaitPosts(1)
        vm.updateDefaultModel("m2")
        assertEquals(RelayManualPrimary(R.string.relay_validate_and_save, enabled = true, loading = false), vm.manualBoard.primary)
        vm.updateDefaultModel("m1") // changing it back also invalidates
        pass.gate!!.complete(Unit)
        settle(vm)
        delay(50)
        assertNull(pass.stored)
        assertNull(vm.completionTarget)
        assertNull(vm.manualBoard.status)

        // In-flight failure: no failure card after invalidation.
        val fail = Harness(postStatus = HttpStatusCode.Unauthorized)
        val failing = fail.filledManual()
        failing.selectManualTransport(RelayTransport.OpenAIChatCompletions)
        fail.gate = CompletableDeferred()
        failing.validateManual()
        fail.awaitPosts(1)
        failing.selectManualAuthMode(RelayAuthMode.XApiKey)
        fail.gate!!.complete(Unit)
        settle(failing)
        delay(50)
        assertNull(failing.manualBoard.status)

        // Leaving the manual page: the in-flight result is invalidated.
        val leave = Harness()
        val leaving = leave.filledManual()
        leaving.selectManualTransport(RelayTransport.OpenAIChatCompletions)
        leave.gate = CompletableDeferred()
        leaving.validateManual()
        leave.awaitPosts(1)
        leaving.showQuickSetup()
        leave.gate!!.complete(Unit)
        settle(leaving)
        delay(50)
        assertNull(leave.stored)
        assertNull(leaving.completionTarget)
    }

    // ── BOARD-MANUAL-09 ──

    @Test
    fun `BOARD-MANUAL-09 quick and manual share the address and every key both ways`() = runBlocking {
        val harness = Harness(catalog = listOf("m1"))
        val vm = harness.viewModel()
        vm.addKey()
        val second = vm.board.keys[1].id
        vm.updateKeySecret(second, KEY_B)
        vm.updateKeyName(second, "Backup")
        vm.updatePrimaryKeyName("Main")

        vm.showManualSetup()
        assertEquals("https://relay.example.com", vm.endpoint)
        assertEquals(vm.board.keys, vm.manualBoard.keys)
        assertEquals(listOf("Main", "Backup"), vm.manualBoard.keys.map { it.name })
        vm.updateDefaultModel("m1")
        vm.selectManualTransport(RelayTransport.AnthropicMessages)

        vm.showQuickSetup()
        assertEquals("https://relay.example.com", vm.endpoint)
        assertEquals(listOf(KEY_A, KEY_B), vm.board.keys.map { it.secret })
        vm.showManualSetup()
        assertEquals("m1", vm.defaultModel)
        assertEquals(RelayTransport.AnthropicMessages, vm.manualTransport)

        // Entering the manual page while quick setup detection is in flight -> detection is cancelled; coming back stays on step 1.
        vm.showQuickSetup()
        harness.getGate = CompletableDeferred()
        vm.next()
        harness.awaitGets(1)
        assertTrue(vm.isDiscovering)
        vm.showManualSetup()
        assertFalse(vm.isDiscovering)
        harness.getGate!!.complete(Unit)
        delay(50)
        vm.showQuickSetup()
        assertEquals(RelaySetupStep.Address, vm.step)
        assertNull(vm.board.detection)
    }

    // ── BOARD-MANUAL-10 ──

    @Test
    fun `BOARD-MANUAL-10 issues sit where they belong and header issues open the group`() {
        val base = RelayManualSetupBoardTestInputs.input()
        val headerIssue = RelayFormValidation.FieldIssue(RelayFormValidation.Field.Headers, RelayFormValidation.IssueCode.CleartextCredentials)
        val keyIssue = RelayFormValidation.FieldIssue(RelayFormValidation.Field.ApiKey, RelayFormValidation.IssueCode.CredentialInvalidCharacters)
        val endpointIssue = RelayFormValidation.FieldIssue(RelayFormValidation.Field.Endpoint, RelayFormValidation.IssueCode.EndpointRejected, "cleartext_not_allowed")
        val board = RelayManualSetupBoardModel.make(
            base.copy(
                headers = listOf(RelayKeyValue("X-A", "1"), RelayKeyValue("Authorization", "x")),
                issues = listOf(endpointIssue, keyIssue, headerIssue),
                advancedExpanded = false,
            ),
        )
        assertEquals(listOf(endpointIssue, keyIssue), board.keyIssues)
        assertTrue("expanded even if the user collapsed it", board.advancedGroup.expanded)
        val headerRows = board.advancedGroup.rows.filter { it.id == RelayEditRowId.Header }
        assertTrue(headerRows.first().issues.isEmpty())
        assertEquals(listOf(headerIssue), headerRows.last().issues)
        assertFalse(board.primary.enabled)
        // Required items show no text.
        val silent = RelayManualSetupBoardModel.make(
            base.copy(issues = listOf(RelayFormValidation.FieldIssue(RelayFormValidation.Field.Endpoint, RelayFormValidation.IssueCode.EndpointRequired))),
        )
        assertTrue(silent.keyIssues.isEmpty())
        // Tapping the group header while a notice holds it open counts as expanded (same criterion as BOARD-EDIT-17).
        assertTrue(RelayEditBoardModel.toggledExpansion(current = false, forcedOpen = true))
    }

    // ── BOARD-MANUAL-11 ──

    @Test
    fun `BOARD-MANUAL-11 a click is accepted exactly when the button is enabled`() = runBlocking {
        val harness = Harness()
        val vm = harness.filledManual(model = "")
        vm.selectManualTransport(RelayTransport.OpenAIChatCompletions)
        vm.validateManual()
        settle(vm)
        assertEquals("not accepted when not tappable", 0, harness.posts.size)

        vm.updateDefaultModel("m1")
        harness.gate = CompletableDeferred()
        vm.validateManual()
        vm.validateManual()
        harness.awaitPosts(1)
        delay(20)
        assertEquals("rapid taps are accepted only once", 1, harness.posts.size)

        // Changing input in flight -> button stays enabled -> tapping again starts a new verification immediately; a late old result is not persisted and shows no failure card.
        vm.updateDefaultModel("m2")
        assertTrue(vm.manualBoard.primary.enabled)
        vm.validateManual()
        harness.awaitPosts(2)
        harness.gate!!.complete(Unit)
        settle(vm)
        harness.awaitStored()
        assertEquals(listOf("m1", "m2"), harness.posts.map { it.model })
        assertEquals(listOf("m2"), harness.current().models.map { it.id })
        assertEquals(1, harness.insertedIds.distinct().size)
    }

    // ── BOARD-MANUAL-12 ──

    @Test
    fun `BOARD-MANUAL-12 a new failure card is revealed once with the edit connection reveal function`() = runBlocking {
        val harness = Harness(postStatus = HttpStatusCode.Unauthorized)
        val vm = harness.filledManual()
        vm.selectManualTransport(RelayTransport.OpenAIChatCompletions)
        val before = vm.manualBoard.status
        vm.validateManual()
        settle(vm)
        val first = vm.manualBoard.status
        assertTrue(RelayEditBoardModel.revealsStatus(before, first))
        assertFalse("the same card does not scroll again", RelayEditBoardModel.revealsStatus(first, vm.manualBoard.status))
        vm.validateManual()
        val during = vm.manualBoard.status
        assertFalse("a dismissed card does not scroll", RelayEditBoardModel.revealsStatus(first, during))
        settle(vm)
        assertTrue("a new failure is a different card", RelayEditBoardModel.revealsStatus(during, vm.manualBoard.status))
        assertTrue(source("feature/providers/relay/RelaySetupScreen.kt").contains("RelayEditBoardModel.revealsStatus("))
    }

    // ── BOARD-MANUAL-13 ──

    @Test
    fun `BOARD-MANUAL-13 persist error shows technical details and no save anyway`() = runBlocking {
        // Verification passed, persisting itself failed.
        val harness = Harness()
        harness.upsertError = IllegalStateException("database is locked for $KEY_A via $HEADER_SECRET")
        val vm = harness.filledManual()
        vm.selectManualTransport(RelayTransport.OpenAIChatCompletions)
        vm.updateManualHeaders(listOf(RelayKeyValue("X-Api-Key", HEADER_SECRET)))
        vm.validateManual()
        settle(vm)

        assertNull("persisting failed", harness.stored)
        assertNull(vm.completionTarget)
        val status = vm.manualBoard.status as RelayEditStatus.Failed
        assertFalse("a persistence error does not offer Save anyway", status.canSaveUnverified)
        val presentation = requireNotNull(status.presentation) { "the failure card for a persistence error also carries technical details" }
        assertEquals("https://relay.example.com", presentation.endpoint)
        assertNull(presentation.statusCode)
        // A local exception has no upstream response: upstreamJson is null, and RelayEditFailureDetails shows no "upstream response redacted" note.
        assertNull(presentation.upstreamJson)
        // Technical details contain the exception text (class name: message); the same redaction list masks keys and header values.
        val local = requireNotNull(presentation.localErrorDetail)
        assertTrue(local, local.startsWith("IllegalStateException: database is locked for "))
        assertFalse(local.contains(KEY_A))
        assertFalse(local.contains(HEADER_SECRET))
        val shown = listOf(status.message, presentation.endpoint, presentation.upstreamJson.orEmpty(), local).joinToString("\n")
        listOf(KEY_A, HEADER_SECRET).forEach { assertFalse("the failure card must not show $it", shown.contains(it)) }
        assertEquals(RelayManualPrimary(R.string.relay_manual_validate_again, enabled = true, loading = false), vm.manualBoard.primary)
        // Tap acceptance uses the same criterion as tappability: no button, no acceptance.
        harness.upsertError = null
        vm.saveManualUnverified()
        settle(vm)
        assertNull(harness.stored)

        // If the Save anyway path itself fails to persist, it is handled the same way.
        val unverifiedHarness = Harness(postStatus = HttpStatusCode.Unauthorized)
        val failed = unverifiedHarness.failedManual()
        assertTrue((failed.manualBoard.status as RelayEditStatus.Failed).canSaveUnverified)
        unverifiedHarness.upsertError = IllegalStateException("disk full")
        failed.saveManualUnverified()
        settle(failed)
        assertNull(unverifiedHarness.stored)
        val again = failed.manualBoard.status as RelayEditStatus.Failed
        assertFalse(again.canSaveUnverified)
        assertEquals("IllegalStateException: disk full", again.presentation?.localErrorDetail)
    }

    // ── BOARD-MANUAL-14 ──

    @Test
    fun `BOARD-MANUAL-14 persist error reason line is the generic sentence and raw text stays in details`() = runBlocking {
        val harness = Harness()
        harness.upsertError = IllegalStateException("database is locked for $KEY_A via $HEADER_SECRET")
        val vm = harness.filledManual()
        vm.selectManualTransport(RelayTransport.OpenAIChatCompletions)
        vm.updateManualHeaders(listOf(RelayKeyValue("X-Api-Key", HEADER_SECRET)))
        vm.validateManual()
        settle(vm)

        val status = vm.manualBoard.status as RelayEditStatus.Failed
        // Reason line: a localized generic sentence; the exception text does not go on the reason line.
        assertEquals("string-${R.string.error_generic_message}", status.message)
        val presentation = requireNotNull(status.presentation)
        // Technical details: an address line + one line of redacted exception text.
        assertEquals("https://relay.example.com", presentation.endpoint)
        val local = requireNotNull(presentation.localErrorDetail)
        assertTrue(local, local.startsWith("IllegalStateException: database is locked for "))
        listOf(KEY_A, HEADER_SECRET).forEach { assertFalse(local.contains(it)) }
    }

    // ── BOARD-MANUAL-15 ──

    @Test
    fun `BOARD-MANUAL-15 quick setup button picks full one line then reduced one line then reduced wrapping`() {
        assertEquals(0.85f, RELAY_QUICK_SETUP_REDUCED_SCALE)
        // Tier 1: fits on one line at 100% (including exactly equal width).
        assertEquals(RelayQuickSetupButtonTier.FullSizeOneLine, relayQuickSetupButtonTier(availableWidth = 200f, fullSizeLineWidth = 120f))
        assertEquals(RelayQuickSetupButtonTier.FullSizeOneLine, relayQuickSetupButtonTier(availableWidth = 200f, fullSizeLineWidth = 200f))
        // Tier 2: does not fit at 100%, fits on one line at 85% (including exactly equal width at 85%).
        assertEquals(RelayQuickSetupButtonTier.ReducedOneLine, relayQuickSetupButtonTier(availableWidth = 200f, fullSizeLineWidth = 200.5f))
        assertEquals(RelayQuickSetupButtonTier.ReducedOneLine, relayQuickSetupButtonTier(availableWidth = 170f, fullSizeLineWidth = 200f))
        // Tier 3: does not fit on one line even at 85% -> wraps as needed at 85%.
        assertEquals(RelayQuickSetupButtonTier.ReducedWrapping, relayQuickSetupButtonTier(availableWidth = 169.9f, fullSizeLineWidth = 200f))
        assertEquals(RelayQuickSetupButtonTier.ReducedWrapping, relayQuickSetupButtonTier(availableWidth = 80f, fullSizeLineWidth = 400f))
        // Font size and lines per tier: tier 1 100% / 1 line, tier 2 85% / 1 line, tier 3 85% / unlimited lines.
        assertEquals(1f, RelayQuickSetupButtonTier.FullSizeOneLine.scale)
        assertEquals(1, RelayQuickSetupButtonTier.FullSizeOneLine.maxLines)
        assertEquals(RELAY_QUICK_SETUP_REDUCED_SCALE, RelayQuickSetupButtonTier.ReducedOneLine.scale)
        assertEquals(1, RelayQuickSetupButtonTier.ReducedOneLine.maxLines)
        assertEquals(RELAY_QUICK_SETUP_REDUCED_SCALE, RelayQuickSetupButtonTier.ReducedWrapping.scale)
        assertEquals("tier 3 has no line limit: wraps as needed and never truncates", Int.MAX_VALUE, RelayQuickSetupButtonTier.ReducedWrapping.maxLines)
        // The top bar button uses footnote SemiBold, takes font size and line count by tier, no truncation, no ellipsis, no continuous auto-shrinking.
        val bar = source("feature/providers/relay/RelaySetupScreen.kt")
            .substringAfter("private fun RelaySetupTopBar(").substringBefore("\n@Composable")
        assertTrue(bar, bar.contains("OriveoTheme.typography.footnote"))
        assertTrue(bar, bar.contains("relayQuickSetupButtonTier("))
        assertFalse(bar, bar.contains("Ellipsis"))
        assertFalse(bar, bar.contains("autoSize"))
        assertFalse(bar, bar.contains("maxLines = 2"))
    }

    // ── harness ──

    private fun source(path: String) = File("src/main/java/ai/oriveo/community/$path").readText()

    private suspend fun settle(vm: RelaySetupViewModel) = withTimeout(10_000) {
        delay(5)
        while (vm.isDiscovering || vm.isSubmitting || vm.isValidatingManual) delay(5)
    }

    private data class Post(val path: String, val model: String, val auth: String?)

    private inner class Harness(
        private val catalog: List<String> = listOf("m1"),
        private val catalogStatus: HttpStatusCode = HttpStatusCode.OK,
        private val postStatus: HttpStatusCode = HttpStatusCode.OK,
        private val postStatusByPath: Map<String, HttpStatusCode> = emptyMap(),
    ) {
        var apiKey = ""
        val secrets: MutableMap<String, String> = mutableMapOf()
        @Volatile var stored: ProviderEntity? = null
        val insertedIds: MutableList<String> = Collections.synchronizedList(mutableListOf())
        val posts: MutableList<Post> = Collections.synchronizedList(mutableListOf())
        val gets: MutableList<String> = Collections.synchronizedList(mutableListOf())
        @Volatile var gate: CompletableDeferred<Unit>? = null
        @Volatile var getGate: CompletableDeferred<Unit>? = null
        @Volatile var echoInError: List<String> = emptyList()
        @Volatile var remembered: Pair<String, String>? = null
        /** When non-null, persisting throws it (BOARD-MANUAL-13: persisting itself fails). */
        @Volatile var upsertError: Exception? = null

        private val engine = MockEngine { request ->
            val auth = request.headers[HttpHeaders.Authorization]
            if (request.method == HttpMethod.Get) {
                gets += request.url.encodedPath
                getGate?.await()
                if (!request.url.encodedPath.endsWith("/models")) return@MockEngine respond("", HttpStatusCode.NotFound)
                if (catalogStatus != HttpStatusCode.OK) return@MockEngine respond("{}", catalogStatus)
                return@MockEngine respond(
                    "{\"object\":\"list\",\"data\":[" + catalog.joinToString(",") { "{\"id\":\"$it\",\"object\":\"model\"}" } + "]}",
                    HttpStatusCode.OK,
                    headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                )
            }
            val body = runCatching { json.parseToJsonElement((request.body as TextContent).text).jsonObject }.getOrDefault(JsonObject(emptyMap()))
            val model = body["model"]?.jsonPrimitive?.content.orEmpty()
            posts += Post(request.url.encodedPath, model, auth)
            gate?.await()
            val status = postStatusByPath[request.url.encodedPath] ?: postStatus
            respond(
                if (status == HttpStatusCode.OK) {
                    "{\"id\":\"x\",\"choices\":[{\"message\":{\"content\":\"p\"}}],\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"p\"}]}],\"content\":[{\"type\":\"text\",\"text\":\"p\"}],\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"p\"}]}}]}"
                } else {
                    "{\"error\":{\"message\":\"Invalid API key " + echoInError.joinToString(" ") + "\"}}"
                },
                status,
                headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
            )
        }

        val repository: ProviderRepository = run {
            val dao = mockk<ai.oriveo.community.core.data.dao.ProviderDao>()
            coEvery { dao.getById(any(), any()) } coAnswers {
                stored?.takeIf { it.accountId == firstArg<String>() && it.id == secondArg<String>() }
            }
            coEvery { dao.upsert(any()) } coAnswers {
                upsertError?.let { throw it }
                val entity = firstArg<ProviderEntity>()
                insertedIds += entity.id
                stored = entity
            }
            coEvery { dao.getAll(any()) } coAnswers { listOfNotNull(stored) }
            val keys = mockk<SecureKeyStore>(relaxed = true)
            every { keys.getApiKey(any(), any()) } answers { apiKey }
            every { keys.saveApiKey(any(), any(), any()) } answers { apiKey = thirdArg() }
            every { keys.getRelayKeySecret(any(), any(), any()) } answers { secrets[thirdArg()] }
            every { keys.saveRelayKeySecrets(any(), any(), any()) } answers {
                thirdArg<List<RelayKey>?>().orEmpty().drop(1).filter { it.apiKey.isNotEmpty() }.forEach { secrets[it.id] = it.apiKey }
            }
            ProviderRepository(
                dao = dao,
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
                relayModelFamily = { null },
            )
        }

        fun viewModel(
            endpoint: String = "https://relay.example.com",
            key: String = KEY_A,
            family: (String) -> String? = { null },
        ): RelaySetupViewModel {
            val context = mockk<Context>()
            every { context.getString(any()) } answers { "string-${firstArg<Int>()}" }
            every { context.getString(any(), *anyVararg()) } answers { "string-${firstArg<Int>()}" }
            return RelaySetupViewModel(
                context = context,
                providerRepository = repository,
                discoveryService = RelayDiscoveryService(HttpClient(engine), json, retryBackoffMs = emptyList()),
                modelFamily = family,
                cachedModelFamily = { null },
                modelPlaceholder = { FLAGSHIP },
                backgroundScope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined),
                rememberLastUsedModel = { providerId, modelId -> remembered = providerId to modelId },
            ).apply {
                if (endpoint.isNotEmpty()) updateEndpoint(endpoint)
                if (key.isNotEmpty()) updateApiKey(key)
            }
        }

        fun filledManual(
            endpoint: String = "https://relay.example.com",
            model: String = "m1",
            family: (String) -> String? = { null },
        ): RelaySetupViewModel = viewModel(endpoint = endpoint, family = family).apply {
            showManualSetup()
            updateDefaultModel(model)
        }

        suspend fun failedManual(): RelaySetupViewModel = filledManual().apply {
            selectManualTransport(RelayTransport.OpenAIChatCompletions)
            validateManual()
            settle(this)
            assertTrue(manualBoard.status is RelayEditStatus.Failed)
        }

        suspend fun awaitPosts(count: Int) = withTimeout(10_000) { while (posts.size < count) delay(5) }

        suspend fun awaitGets(count: Int) = withTimeout(10_000) { while (gets.size < count) delay(5) }

        suspend fun awaitStored() = withTimeout(10_000) { while (stored == null) delay(5) }

        suspend fun awaitCatalog(done: (List<ai.oriveo.community.core.model.AIModel>) -> Boolean) = withTimeout(10_000) {
            while (stored == null || !done(current().catalogModels)) delay(5)
        }

        fun current(): Provider = with(ProviderMapper) { requireNotNull(stored).toDomain(apiKey) { secrets[it] } }
    }

    private companion object {
        const val ACCOUNT = "acct-manual-setup"
        const val KEY_A = "sk-aaaa-0000000000001111"
        const val KEY_B = "sk-bbbb-0000000000002222"
        const val FLAGSHIP = "gpt-5.6-sol"
        const val HEADER_SECRET = "hv-secret-123456"
        const val QUERY_SECRET = "qv-secret-123456"
        const val UA_SECRET = "ua-secret-123456"
        val LOCALES = listOf(
            "values", "values-zh-rCN", "values-zh-rTW", "values-ja", "values-ko", "values-es", "values-fr", "values-de",
            "values-pt-rBR", "values-ar", "values-hi", "values-in", "values-vi", "values-th", "values-tr", "values-ru",
        )
    }
}

/** Default inputs of the pure-function board (not via the ViewModel). */
internal object RelayManualSetupBoardTestInputs {
    fun input() = RelayManualSetupInput(
        endpoint = "https://relay.example.com",
        keys = listOf(RelaySetupKeyRow(RelayKeyBinding.IMPLICIT_KEY_ID, true, "sk-test", "", showsName = false, removable = false)),
        model = "m1",
        connectionName = "",
        transport = RelayTransport.Auto,
        authMode = RelayAuthMode.Auto,
        userAgent = "",
        headers = emptyList(),
        queryParams = emptyList(),
        issues = emptyList(),
        advancedExpanded = false,
        isValidating = false,
        failure = null,
        completed = false,
        modelPlaceholder = "gpt-5.6-sol",
    )
}
